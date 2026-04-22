import 'dart:typed_data';
import '../util/bit_math.dart';
import '../util/growable_buffer.dart';
import 'fse_decoder.dart';
import 'huffman_decoder.dart';
import 'sequence_bit_reader.dart';
import 'sequence_constants.dart' as seq;
import 'zstd_common.dart';

enum SequenceComponent { literalLength, offset, matchLength }

class SequenceSymbol {
  final int symbol;
  final int baseValue;
  final int additionalBits;
  final int numberOfBits;
  final int nextState;

  const SequenceSymbol({
    required this.symbol,
    required this.baseValue,
    required this.additionalBits,
    required this.numberOfBits,
    required this.nextState,
  });
}

/// Represents an FSE decoding table for sequence components (LL/Off/ML).
class SequenceCodingTable {
  final int tableLog;
  final List<SequenceSymbol> entries;
  final bool isPredefined;

  const SequenceCodingTable._({
    required this.tableLog,
    required this.entries,
    required this.isPredefined,
  });

  factory SequenceCodingTable.rleSymbol(
    SequenceComponent component,
    int symbolIndex,
  ) {
    return SequenceCodingTable._(
      tableLog: 0,
      entries: [
        _symbolForComponent(
          component,
          symbolIndex,
          numberOfBits: 0,
          nextState: 0,
        ),
      ],
      isPredefined: false,
    );
  }

  factory SequenceCodingTable.fromFse(
    int tableLog,
    List<FseStateEntry> entries,
    SequenceComponent component, {
    bool isPredefined = false,
  }) {
    final symbols = List<SequenceSymbol>.generate(entries.length, (index) {
      final entry = entries[index];
      return _symbolForComponent(
        component,
        entry.symbol,
        numberOfBits: entry.numberOfBits,
        nextState: entry.baseline,
      );
    }, growable: false);

    return SequenceCodingTable._(
      tableLog: tableLog,
      entries: List<SequenceSymbol>.unmodifiable(symbols),
      isPredefined: isPredefined,
    );
  }

  bool get isRle => tableLog == 0;

  int initializeState(SequenceBitReader reader) {
    if (tableLog == 0) {
      return 0;
    }
    return reader.readBits(tableLog);
  }

  (SequenceSymbol, int) decodeSymbol(
    SequenceBitReader reader,
    int state, {
    bool readNextState = true,
  }) {
    if (state < 0 || state >= entries.length) {
      throw ZstdFormatException('FSE state out of range: $state');
    }

    final symbol = entries[state];
    var nextState = state;
    if (readNextState) {
      if (symbol.numberOfBits > 0) {
        nextState = symbol.nextState + reader.readBits(symbol.numberOfBits);
      } else {
        nextState = symbol.nextState;
      }
    }
    return (symbol, nextState);
  }

  /// Get symbol for current state without reading bits
  SequenceSymbol peekSymbol(final int state) {
    if (state < 0 || state >= entries.length) {
      throw ZstdFormatException('FSE state out of range: $state');
    }
    return entries[state];
  }

  /// Compute next state by reading bits from stream
  int readNextState(SequenceBitReader reader, final int state) {
    final symbol = entries[state];
    if (symbol.numberOfBits > 0) {
      return symbol.nextState + reader.readBits(symbol.numberOfBits);
    }
    return symbol.nextState;
  }
}

class _NormalizedCountsResult {
  final List<int> counts;
  final int tableLog;
  final int nextOffset;
  final int maxSymbol;

  _NormalizedCountsResult(
    this.counts,
    this.tableLog,
    this.nextOffset,
    this.maxSymbol,
  );
}

class _SequenceTableResult {
  final SequenceCodingTable table;
  final int nextOffset;

  _SequenceTableResult(this.table, this.nextOffset);
}

class _CompressedLiteralHeader {
  final int headerSize;
  final int regeneratedSize;
  final int compressedSize;
  final int numStreams;

  const _CompressedLiteralHeader({
    required this.headerSize,
    required this.regeneratedSize,
    required this.compressedSize,
    required this.numStreams,
  });
}

SequenceSymbol _symbolForComponent(
  SequenceComponent component,
  int symbolIndex, {
  required int numberOfBits,
  required int nextState,
}) {
  final base = _baseValueFor(component, symbolIndex);
  final extraBits = _extraBitsFor(component, symbolIndex);
  return SequenceSymbol(
    symbol: symbolIndex,
    baseValue: base,
    additionalBits: extraBits,
    numberOfBits: numberOfBits,
    nextState: nextState,
  );
}

int _baseValueFor(SequenceComponent component, int symbolIndex) {
  switch (component) {
    case SequenceComponent.literalLength:
      if (symbolIndex < 0 || symbolIndex >= seq.literalLengthBase.length) {
        throw ZstdFormatException(
          'Literal length symbol out of range: $symbolIndex',
        );
      }
      return seq.literalLengthBase[symbolIndex];
    case SequenceComponent.offset:
      if (symbolIndex < 0 || symbolIndex >= seq.offsetBase.length) {
        throw ZstdFormatException('Offset symbol out of range: $symbolIndex');
      }
      return seq.offsetBase[symbolIndex];
    case SequenceComponent.matchLength:
      if (symbolIndex < 0 || symbolIndex >= seq.matchLengthBase.length) {
        throw ZstdFormatException(
          'Match length symbol out of range: $symbolIndex',
        );
      }
      return seq.matchLengthBase[symbolIndex];
  }
}

int _extraBitsFor(SequenceComponent component, int symbolIndex) {
  switch (component) {
    case SequenceComponent.literalLength:
      if (symbolIndex < 0 || symbolIndex >= seq.literalLengthBits.length) {
        throw ZstdFormatException(
          'Literal length bits index out of range: $symbolIndex',
        );
      }
      return seq.literalLengthBits[symbolIndex];
    case SequenceComponent.offset:
      if (symbolIndex < 0 || symbolIndex >= seq.offsetBits.length) {
        throw ZstdFormatException(
          'Offset bits index out of range: $symbolIndex',
        );
      }
      return seq.offsetBits[symbolIndex];
    case SequenceComponent.matchLength:
      if (symbolIndex < 0 || symbolIndex >= seq.matchLengthBits.length) {
        throw ZstdFormatException(
          'Match length bits index out of range: $symbolIndex',
        );
      }
      return seq.matchLengthBits[symbolIndex];
  }
}

class _ForwardBitReader {
  final Uint8List _data;
  final int _end;
  final int _start;
  int _bytePos;
  int _bitBuffer = 0;
  int _bitsAvailable = 0;

  _ForwardBitReader(this._data, int offset, int end)
    : _end = end,
      _start = offset,
      _bytePos = offset;

  int _ensureBits(int count) {
    while (_bitsAvailable < count) {
      if (_bytePos >= _end) {
        throw ZstdFormatException(
          'Unexpected end of data while reading sequences',
        );
      }
      _bitBuffer |= _data[_bytePos++] << _bitsAvailable;
      _bitsAvailable += 8;
    }
    return _bitsAvailable;
  }

  int readBits(int count) {
    if (count == 0) return 0;
    _ensureBits(count);
    final value = _bitBuffer & ((1 << count) - 1);
    _bitBuffer >>= count;
    _bitsAvailable -= count;
    return value;
  }

  int peekBits(int count) {
    if (count == 0) return 0;
    _ensureBits(count);
    return _bitBuffer & ((1 << count) - 1);
  }

  void skipBits(int count) {
    if (count == 0) return;
    _ensureBits(count);
    _bitBuffer >>= count;
    _bitsAvailable -= count;
  }

  int get bitsConsumed => (_bytePos - _start) * 8 - _bitsAvailable;

  int get bytesConsumed => (bitsConsumed + 7) >> 3;
}

/// Decoder for Zstd compressed blocks
///
/// Maintains state for Huffman tree persistence to support "treeless" mode
/// where blocks can reuse the Huffman tree from a previous block.
class CompressedBlockDecoder {
  CompressedBlockDecoder() {
    reset();
  }

  /// Cached Huffman decoder from previous compressed block
  HuffmanDecoder? _cachedHuffmanTree;
  SequenceCodingTable? _cachedLiteralLengthTable;
  SequenceCodingTable? _cachedOffsetTable;
  SequenceCodingTable? _cachedMatchLengthTable;

  /// Clear cached state (should be called between frames)
  void reset() {
    _cachedHuffmanTree = null;
    _cachedLiteralLengthTable = _predefinedLiteralLengthTable;
    _cachedOffsetTable = _predefinedOffsetTable;
    _cachedMatchLengthTable = _predefinedMatchLengthTable;
  }

  /// Decode a compressed block
  ///
  /// [windowSize] is used to validate that match offsets don't exceed
  /// the declared window size. If null, no window size validation is performed.
  void decodeBlock(
    Uint8List data,
    int offset,
    int blockSize,
    GrowableBuffer output,
    List<int> previousOffsets, {
    int? windowSize,
  }) {
    final blockEnd = offset + blockSize;

    if (blockEnd > data.length) {
      throw ZstdFormatException(
        'Compressed block extends beyond input data: '
        'offset=$offset, blockSize=$blockSize, dataLength=${data.length}',
      );
    }

    var pos = offset;

    // Decode literals section
    final literalsResult = _decodeLiteralsSection(data, pos, blockEnd);
    final literals = literalsResult.$1;
    pos = literalsResult.$2;

    // Decode sequences section
    final sequencesResult = _decodeSequencesSection(data, pos, blockEnd);
    final sequences = sequencesResult.$1;
    pos = sequencesResult.$2;

    // Execute sequences
    _executeSequences(literals, sequences, output, previousOffsets, windowSize);
  }

  /// Decode literals section
  (Uint8List, int) _decodeLiteralsSection(
    Uint8List data,
    int offset,
    int blockEnd,
  ) {
    if (offset >= blockEnd) {
      throw ZstdFormatException('Invalid literals section');
    }

    final header = data[offset];
    final literalsBlockType = header & 0x03;
    final sizeFormat = (header >> 2) & 0x03;

    if (literalsBlockType == 0 || literalsBlockType == 1) {
      // Raw or RLE literals
      final (regeneratedSize, headerSize) = _parseRawOrRleLiteralHeader(
        data,
        offset,
        blockEnd,
        sizeFormat,
      );
      offset += headerSize;

      if (literalsBlockType == 0) {
        if (offset + regeneratedSize > blockEnd) {
          throw ZstdFormatException(
            'Raw literals extend beyond block boundary',
          );
        }
        final literals = Uint8List.sublistView(
          data,
          offset,
          offset + regeneratedSize,
        );
        return (literals, offset + regeneratedSize);
      } else {
        if (offset >= blockEnd && regeneratedSize > 0) {
          throw ZstdFormatException('RLE byte missing');
        }
        final byte = regeneratedSize > 0 ? data[offset] : 0;
        final literals = Uint8List(regeneratedSize);
        if (regeneratedSize > 0) {
          literals.fillRange(0, regeneratedSize, byte);
        }
        return (literals, offset + (regeneratedSize > 0 ? 1 : 0));
      }
    }

    final compressedHeader = _parseCompressedLiteralHeader(
      data,
      offset,
      blockEnd,
      sizeFormat,
    );

    final payloadStart = offset + compressedHeader.headerSize;
    final payloadEnd = payloadStart + compressedHeader.compressedSize;

    if (payloadEnd > blockEnd) {
      throw ZstdFormatException(
        'Compressed literals extend beyond block boundary: '
        'start=$payloadStart, size=${compressedHeader.compressedSize}, '
        'blockEnd=$blockEnd',
      );
    }

    if (compressedHeader.regeneratedSize == 0) {
      return (Uint8List(0), payloadEnd);
    }

    final literals = _decodeHuffmanLiterals(
      data,
      payloadStart,
      compressedHeader.compressedSize,
      compressedHeader.regeneratedSize,
      literalsBlockType == 2,
      compressedHeader.numStreams,
    );

    if (literals.length != compressedHeader.regeneratedSize) {
      throw ZstdFormatException(
        'Literal size mismatch: expected ${compressedHeader.regeneratedSize}, '
        'decoded ${literals.length}',
      );
    }

    return (literals, payloadEnd);
  }

  (int, int) _parseRawOrRleLiteralHeader(
    Uint8List data,
    int offset,
    int blockEnd,
    int sizeFormat,
  ) {
    if (offset >= blockEnd) {
      throw ZstdFormatException('Literals header exceeds block boundary');
    }

    final firstByte = data[offset];
    switch (sizeFormat) {
      case 0:
      case 2:
        return ((firstByte >> 3) & 0x1F, 1);
      case 1:
        if (offset + 1 >= blockEnd) {
          throw ZstdFormatException('Literals header exceeds block boundary');
        }
        final regen =
            ((firstByte >> 4) & 0x0F) | ((data[offset + 1] & 0xFF) << 4);
        return (regen & 0x0FFF, 2);
      case 3:
        if (offset + 2 >= blockEnd) {
          throw ZstdFormatException('Literals header exceeds block boundary');
        }
        final regen =
            ((firstByte >> 4) & 0x0F) |
            ((data[offset + 1] & 0xFF) << 4) |
            ((data[offset + 2] & 0xFF) << 12);
        return (regen & 0xFFFFF, 3);
      default:
        throw ZstdFormatException(
          'Unsupported literals size format for raw/RLE block: $sizeFormat',
        );
    }
  }

  _CompressedLiteralHeader _parseCompressedLiteralHeader(
    Uint8List data,
    int offset,
    int blockEnd,
    int sizeFormat,
  ) {
    int headerSize;
    int numStreams;
    int bitsPerSize;

    switch (sizeFormat) {
      case 0:
        headerSize = 3;
        numStreams = 1;
        bitsPerSize = 10;
        break;
      case 1:
        headerSize = 3;
        numStreams = 4;
        bitsPerSize = 10;
        break;
      case 2:
        headerSize = 4;
        numStreams = 4;
        bitsPerSize = 14;
        break;
      case 3:
        headerSize = 5;
        numStreams = 4;
        bitsPerSize = 18;
        break;
      default:
        throw ZstdFormatException(
          'Unsupported literals size format for compressed block: $sizeFormat',
        );
    }

    if (offset + headerSize > blockEnd) {
      throw ZstdFormatException(
        'Literals header extends beyond block boundary',
      );
    }

    var value = BigInt.zero;
    for (var i = 0; i < headerSize; i++) {
      value |= BigInt.from(data[offset + i] & 0xff) << (8 * i);
    }

    final regeneratedMask = (BigInt.one << bitsPerSize) - BigInt.one;
    final compressedMask = regeneratedMask;
    final regeneratedSize = ((value >> 4) & regeneratedMask).toInt();
    final compressedShift = 4 + bitsPerSize;
    final compressedSize = ((value >> compressedShift) & compressedMask)
        .toInt();

    return _CompressedLiteralHeader(
      headerSize: headerSize,
      regeneratedSize: regeneratedSize,
      compressedSize: compressedSize,
      numStreams: numStreams,
    );
  }

  /// Decode Huffman-compressed literals
  Uint8List _decodeHuffmanLiterals(
    Uint8List data,
    int offset,
    int compressedSize,
    int regeneratedSize,
    bool hasTree,
    int numStreams,
  ) {
    var pos = offset;

    // Build Huffman decoder if we have a tree
    HuffmanDecoder? decoder;
    if (hasTree) {
      final weightsResult = _decodeHuffmanWeights(data, pos);
      final weights = weightsResult.$1;
      pos = weightsResult.$2;

      decoder = HuffmanDecoder();
      decoder.buildFromWeights(weights);

      // Cache the tree for potential treeless reuse
      _cachedHuffmanTree = decoder;
    } else {
      // Treeless mode: reuse previous tree
      decoder = _cachedHuffmanTree;
      if (decoder == null) {
        throw ZstdFormatException(
          'Treeless Huffman mode requires previous tree',
        );
      }
    }

    final compressedEnd = offset + compressedSize;
    if (compressedEnd > data.length) {
      throw ZstdFormatException(
        'Compressed literals exceed input buffer: '
        'end=$compressedEnd, length=${data.length}',
      );
    }

    final treeBytes = pos - offset;
    if (treeBytes < 0 || treeBytes > compressedSize) {
      throw ZstdFormatException(
        'Invalid Huffman tree size: treeBytes=$treeBytes, compressedSize=$compressedSize',
      );
    }

    final totalStreamsSize = compressedSize - treeBytes;
    if (totalStreamsSize < 0) {
      throw ZstdFormatException('Negative total streams size');
    }

    final literals = Uint8List(regeneratedSize);

    if (numStreams == 1) {
      // Single stream decoding
      decoder.decodeSingle(
        data,
        pos,
        compressedEnd,
        literals,
        0,
        regeneratedSize,
      );
    } else if (numStreams == 4) {
      // 4-stream decoding
      if (totalStreamsSize < 6) {
        throw ZstdFormatException(
          'Insufficient data for jump table: totalStreamsSize=$totalStreamsSize',
        );
      }
      decoder.decode4Streams(
        data,
        pos,
        compressedEnd,
        literals,
        0,
        regeneratedSize,
      );
    } else {
      throw ZstdFormatException(
        'Unsupported literals stream count: $numStreams',
      );
    }

    return literals;
  }

  /// Decode FSE-compressed Huffman weights
  /// Uses backward bitstream reading per RFC 8878
  List<int> _decodeFseCompressedHuffmanWeights(
    Uint8List data,
    int offset,
    int streamEnd,
    int expectedSymbolCount,
  ) {
    if (streamEnd > data.length) {
      throw ZstdFormatException(
        'FSE stream extends beyond available data: streamEnd=$streamEnd, length=${data.length}',
      );
    }

    // First 4 bits encode the accuracy log (value 0-6 for weights, +5 gives 5-11)
    final accuracyLog = (data[offset] & 0x0F) + 5;

    // Decode the FSE distribution (normalized counters) - uses forward reading
    // Start from the same byte but skip the first 4 bits (accuracy log)
    final result = FseDecoder.decodeNormalizedCounters(
      data,
      offset,
      12, // Max symbol for Huffman weights
      accuracyLog,
      skipBits: 4, // Skip accuracy log bits
    );
    final normalizedCounters = result.$1;
    offset = result.$2;

    // Build FSE decoder table
    final fseDecoder = FseDecoder();
    fseDecoder.buildTable(normalizedCounters, accuracyLog);

    // FSE decompression uses backward bitstream (MSB-first from end)
    // Use the same SequenceBitReader that works for sequences
    final reader = SequenceBitReader(data, streamEnd, startOffset: offset);

    // Initialize FSE states (read tableLog bits each)
    // Note: like Java, read state first, then load
    var state1 = reader.readBits(accuracyLog);
    var state2 = reader.readBits(accuracyLog);

    // Now load before decoding loop
    reader.load();

    // Decode weights from FSE stream
    final weights = <int>[];

    // Main decode loop - decode 4 symbols at a time
    mainLoop:
    while (true) {
      for (var i = 0; i < 4; i++) {
        // Alternate between state1 and state2
        final state = (i & 1) == 0 ? state1 : state2;
        final entry = fseDecoder.tableEntries[state];

        weights.add(entry.symbol);

        final bits = reader.readBits(entry.numberOfBits);
        final newState = entry.baseline + bits;

        if ((i & 1) == 0) {
          state1 = newState;
        } else {
          state2 = newState;
        }
      }

      // Try to reload - if we're at the start of stream, switch to tail
      if (reader.load()) {
        break mainLoop;
      }
    }

    // Tail loop - decode remaining symbols one by one
    var tailIter = 0;
    while (true) {
      tailIter++;
      if (tailIter > 100) {
        throw ZstdFormatException(
          'FSE weight decode: tail loop exceeded 100 iterations',
        );
      }

      // Decode from state1
      var entry = fseDecoder.tableEntries[state1];
      weights.add(entry.symbol);

      final bits1 = reader.readBits(entry.numberOfBits);
      state1 = entry.baseline + bits1;

      reader.load();
      if (reader.isOverflow) {
        // Emit final symbol from state2
        weights.add(fseDecoder.tableEntries[state2].symbol);
        break;
      }

      // Decode from state2
      entry = fseDecoder.tableEntries[state2];
      weights.add(entry.symbol);

      final bits2 = reader.readBits(entry.numberOfBits);
      state2 = entry.baseline + bits2;

      reader.load();
      if (reader.isOverflow) {
        // Emit final symbol from state1
        weights.add(fseDecoder.tableEntries[state1].symbol);
        break;
      }
    }

    return weights;
  }

  /// Decode Huffman weights from header
  (List<int>, int) _decodeHuffmanWeights(Uint8List data, int offset) {
    if (offset >= data.length) {
      throw ZstdFormatException('Missing Huffman weights header');
    }

    final header = data[offset++];

    if (header < 128) {
      // FSE compressed weights
      // Header byte contains the total compressed size of the FSE stream
      final fseStreamSize = header;
      final fseStreamEnd = offset + fseStreamSize;

      if (fseStreamEnd > data.length) {
        throw ZstdFormatException('FSE Huffman stream exceeds data length');
      }

      // Maximum possible Huffman symbols is 256 (one per byte value)
      // We decode until the FSE stream is exhausted
      const expectedSymbolCount = 256;

      // Decode the FSE compressed stream of weights
      final weights = _decodeFseCompressedHuffmanWeights(
        data,
        offset,
        fseStreamEnd,
        expectedSymbolCount,
      );

      return (weights, fseStreamEnd);
    } else {
      // Direct representation: 4-bit weights packed 2 per byte
      final numWeights = header - 127;
      final numBytes = (numWeights + 1) ~/ 2; // Round up

      if (offset + numBytes > data.length) {
        throw ZstdFormatException('Not enough data for Huffman weights');
      }

      final weights = List<int>.filled(numWeights, 0, growable: false);
      for (var i = 0; i < numWeights; i += 2) {
        final byte = data[offset + i ~/ 2];
        weights[i] = byte >> 4; // High 4 bits
        if (i + 1 < numWeights) {
          weights[i + 1] = byte & 0x0F; // Low 4 bits
        }
      }

      return (weights, offset + numBytes);
    }
  }

  /// Decode sequences section
  (List<ZstdSequence>, int) _decodeSequencesSection(
    Uint8List data,
    int offset,
    int blockEnd,
  ) {
    if (offset >= blockEnd) {
      return (<ZstdSequence>[], offset);
    }

    // Read sequence count
    final firstByte = data[offset++];
    var numSequences = 0;

    if (firstByte == 0) {
      return (<ZstdSequence>[], offset);
    } else if (firstByte < 128) {
      numSequences = firstByte;
    } else if (firstByte < 255) {
      if (offset >= blockEnd) {
        throw ZstdFormatException('Incomplete sequence count header');
      }
      numSequences = ((firstByte - 128) << 8) + data[offset++];
    } else {
      if (offset + 2 > blockEnd) {
        throw ZstdFormatException('Incomplete sequence count header');
      }
      numSequences = data[offset] + (data[offset + 1] << 8) + 0x7F00;
      offset += 2;
    }

    if (numSequences == 0) {
      return (<ZstdSequence>[], offset);
    }

    if (offset >= blockEnd) {
      throw ZstdFormatException('Missing sequence compression modes');
    }
    final modes = data[offset++];
    final literalLengthsMode = modes >> 6;
    final offsetsMode = (modes >> 4) & 0x03;
    final matchLengthsMode = (modes >> 2) & 0x03;

    final llTableResult = _readSequenceTable(
      data,
      offset,
      blockEnd,
      literalLengthsMode,
      _cachedLiteralLengthTable,
      _predefinedLiteralLengthTable,
      SequenceComponent.literalLength,
      maxSymbolValue: 35,
    );
    final literalLengthTable = llTableResult.table;
    offset = llTableResult.nextOffset;
    if (literalLengthsMode != 3) {
      _cachedLiteralLengthTable = literalLengthTable;
    }

    final ofTableResult = _readSequenceTable(
      data,
      offset,
      blockEnd,
      offsetsMode,
      _cachedOffsetTable,
      _predefinedOffsetTable,
      SequenceComponent.offset,
      maxSymbolValue: 31,
    );
    final offsetTable = ofTableResult.table;
    offset = ofTableResult.nextOffset;
    if (offsetsMode != 3) {
      _cachedOffsetTable = offsetTable;
    }

    final mlTableResult = _readSequenceTable(
      data,
      offset,
      blockEnd,
      matchLengthsMode,
      _cachedMatchLengthTable,
      _predefinedMatchLengthTable,
      SequenceComponent.matchLength,
      maxSymbolValue: 52,
    );
    final matchLengthTable = mlTableResult.table;
    offset = mlTableResult.nextOffset;
    if (matchLengthsMode != 3) {
      _cachedMatchLengthTable = matchLengthTable;
    }

    if (offset > blockEnd) {
      throw ZstdFormatException('Sequence headers exceed block boundary');
    }

    final (sequences, reader) = _decodeSequences(
      data,
      offset,
      blockEnd,
      numSequences,
      literalLengthTable,
      offsetTable,
      matchLengthTable,
    );

    // Validate bitstream was fully consumed (no trailing bytes)
    // A well-formed block should consume all bits in the sequences section
    if (!reader.isFullyConsumed && reader.remaining > 0) {
      throw ZstdFormatException(
        'Sequences bitstream not fully consumed: '
        '~${reader.remaining} bytes remaining',
      );
    }

    return (sequences, blockEnd);
  }

  static final SequenceCodingTable _predefinedLiteralLengthTable =
      _buildPredefinedTable(
        seq.llDefaultNorm,
        seq.llDefaultNormLog,
        SequenceComponent.literalLength,
        isPredefined: true,
      );

  static final SequenceCodingTable _predefinedOffsetTable =
      _buildPredefinedTable(
        seq.ofDefaultNorm,
        seq.ofDefaultNormLog,
        SequenceComponent.offset,
        isPredefined: true,
      );

  static final SequenceCodingTable _predefinedMatchLengthTable =
      _buildPredefinedTable(
        seq.mlDefaultNorm,
        seq.mlDefaultNormLog,
        SequenceComponent.matchLength,
        isPredefined: true,
      );

  static SequenceCodingTable _buildPredefinedTable(
    List<int> normalizedCounters,
    int tableLog,
    SequenceComponent component, {
    required bool isPredefined,
  }) {
    final decoder = FseDecoder();
    decoder.buildTable(List<int>.from(normalizedCounters), tableLog);
    return SequenceCodingTable.fromFse(
      tableLog,
      decoder.tableEntries,
      component,
      isPredefined: isPredefined,
    );
  }

  _SequenceTableResult _readSequenceTable(
    Uint8List data,
    int offset,
    int blockEnd,
    int mode,
    SequenceCodingTable? cached,
    SequenceCodingTable predefined,
    SequenceComponent component, {
    required int maxSymbolValue,
  }) {
    // RFC 8878 Section 3.1.1.3.2.1:
    // Mode 0: Predefined
    // Mode 1: RLE
    // Mode 2: FSE compressed
    // Mode 3: Repeat (reuse from previous block)
    switch (mode) {
      case 0:
        return _SequenceTableResult(predefined, offset);
      case 1:
        if (offset >= blockEnd) {
          throw ZstdFormatException('RLE sequence table missing symbol byte');
        }
        final symbol = data[offset];
        if (symbol > maxSymbolValue) {
          throw ZstdFormatException(
            'RLE sequence symbol $symbol exceeds max $maxSymbolValue',
          );
        }
        return _SequenceTableResult(
          SequenceCodingTable.rleSymbol(component, symbol),
          offset + 1,
        );
      case 2:
        final result = _readFseSequenceTable(
          data,
          offset,
          blockEnd,
          maxSymbolValue,
          component,
        );
        return result;
      case 3:
        if (cached == null) {
          throw ZstdFormatException(
            'Repeat sequence table requested but none cached',
          );
        }
        return _SequenceTableResult(cached, offset);
      default:
        throw ZstdFormatException('Unsupported sequence table mode: $mode');
    }
  }

  _SequenceTableResult _readFseSequenceTable(
    Uint8List data,
    int offset,
    int blockEnd,
    int maxSymbolValue,
    SequenceComponent component,
  ) {
    final countsResult = _readNormalizedCounts(
      data,
      offset,
      blockEnd,
      maxSymbolValue,
    );
    final decoder = FseDecoder();
    decoder.buildTable(countsResult.counts, countsResult.tableLog);
    final table = SequenceCodingTable.fromFse(
      countsResult.tableLog,
      decoder.tableEntries,
      component,
    );
    return _SequenceTableResult(table, countsResult.nextOffset);
  }

  _NormalizedCountsResult _readNormalizedCounts(
    Uint8List data,
    int offset,
    int blockEnd,
    int maxSymbolValue,
  ) {
    final reader = _ForwardBitReader(data, offset, blockEnd);

    final tableLog = reader.readBits(4) + 5; // FSE_MIN_TABLELOG
    var remaining = (1 << tableLog) + 1;
    var threshold = 1 << tableLog;
    var nbBits = tableLog + 1;
    var symbol = 0;
    var previousZero = false;

    final counts = List<int>.filled(maxSymbolValue + 1, 0);

    while (symbol <= maxSymbolValue && remaining > 1) {
      if (previousZero) {
        var zeros = 0;
        while (true) {
          final code = reader.readBits(2);
          if (code == 3) {
            zeros += 3;
          } else {
            zeros += code;
            break;
          }
        }
        symbol += zeros;
        if (symbol > maxSymbolValue + 1) {
          throw ZstdFormatException('Zero run exceeds symbol capacity');
        }
        previousZero = false;
        continue;
      }

      if (symbol > maxSymbolValue) {
        break;
      }

      final max = (2 * threshold - 1) - remaining;
      int count;
      final bitsMinusOne = nbBits - 1;
      final value = bitsMinusOne > 0 ? reader.peekBits(bitsMinusOne) : 0;
      if (value < max) {
        if (bitsMinusOne > 0) {
          reader.skipBits(bitsMinusOne);
        }
        count = value;
      } else {
        final fullValue = reader.readBits(nbBits);
        count = fullValue;
        if (fullValue >= threshold) {
          count -= max;
        }
      }

      count -= 1;

      if (count >= 0) {
        remaining -= count;
      } else {
        remaining += count;
      }

      if (symbol <= maxSymbolValue) {
        counts[symbol] = count;
      }
      symbol++;
      previousZero = count == 0;

      if (remaining < threshold) {
        if (remaining <= 1) {
          break;
        }
        nbBits = BitMath.highBit32(remaining) + 1;
        threshold = 1 << (nbBits - 1);
      }
    }

    if (remaining != 1) {
      throw ZstdFormatException(
        'Invalid normalized counts (remaining=$remaining)',
      );
    }
    final highestSymbol = symbol - 1;
    if (highestSymbol > maxSymbolValue) {
      throw ZstdFormatException('Normalized counts reference invalid symbol');
    }

    final nextOffset = offset + reader.bytesConsumed;
    if (nextOffset > blockEnd) {
      throw ZstdFormatException('Normalized counts exceed block boundary');
    }

    return _NormalizedCountsResult(counts, tableLog, nextOffset, highestSymbol);
  }

  (List<ZstdSequence>, SequenceBitReader) _decodeSequences(
    Uint8List data,
    int bitstreamStart,
    int blockEnd,
    int count,
    SequenceCodingTable literalLengthTable,
    SequenceCodingTable offsetTable,
    SequenceCodingTable matchLengthTable,
  ) {
    final reader = SequenceBitReader(
      data,
      blockEnd,
      startOffset: bitstreamStart,
    );

    // Initialize states: LL, OF, ML (in that order per RFC 8878)
    var llState = literalLengthTable.initializeState(reader);
    var ofState = offsetTable.initializeState(reader);
    var mlState = matchLengthTable.initializeState(reader);

    final sequences = List<ZstdSequence?>.filled(count, null, growable: false);

    for (var seqIndex = 0; seqIndex < count; seqIndex++) {
      // Reload bits at start of each sequence
      reader.load();
      if (reader.isOverflow) {
        if (seqIndex != count - 1) {
          throw ZstdFormatException(
            'Bitstream overflow at sequence $seqIndex of $count',
          );
        }
        break;
      }

      // Step 1: Look up symbols from current states (NO bit reads)
      final llSymbol = literalLengthTable.peekSymbol(llState);
      final ofSymbol = offsetTable.peekSymbol(ofState);
      final mlSymbol = matchLengthTable.peekSymbol(mlState);

      // Step 2: Read offset extra bits first
      final offsetBits = ofSymbol.additionalBits;
      final offsetAdditional = offsetBits > 0 ? reader.readBits(offsetBits) : 0;

      // Step 3: Read match length extra bits
      final matchBits = mlSymbol.additionalBits;
      final matchExtra = matchBits > 0 ? reader.readBits(matchBits) : 0;
      final matchLength = mlSymbol.baseValue + matchExtra;

      // Step 4: Read literal length extra bits
      final literalBits = llSymbol.additionalBits;
      final literalExtra = literalBits > 0 ? reader.readBits(literalBits) : 0;
      final literalLength = llSymbol.baseValue + literalExtra;

      // Step 5: Update states by reading bits (LL, ML, OF order per RFC)
      // Don't update on last sequence
      if (seqIndex < count - 1) {
        llState = literalLengthTable.readNextState(reader, llState);
        mlState = matchLengthTable.readNextState(reader, mlState);
        ofState = offsetTable.readNextState(reader, ofState);
      }

      sequences[seqIndex] = ZstdSequence(
        literalLength,
        matchLength,
        ofSymbol,
        offsetAdditional: offsetAdditional,
        literalSymbol: llSymbol.symbol,
        matchSymbol: mlSymbol.symbol,
        offsetSymbol: ofSymbol.symbol,
      );
    }

    return (
      List<ZstdSequence>.unmodifiable(sequences.map((sequence) => sequence!)),
      reader,
    );
  }

  int _computeOffset(
    SequenceSymbol symbol,
    int literalLength,
    List<int> previousOffsets,
    int offsetAdditional,
  ) {
    final offsetValue = symbol.baseValue + offsetAdditional;
    final symbolIndex = symbol.symbol;

    var repeatValue = 0;
    var isRepeat = false;

    if (symbolIndex == 0) {
      // Repeat offset value 0 (rep0)
      isRepeat = true;
      repeatValue = 0;
    } else if (symbolIndex == 1) {
      // Repeat offset value 1-2 (rep1/rep2)
      isRepeat = true;
      repeatValue = offsetValue;
    }

    if (isRepeat) {
      if (literalLength == 0) {
        repeatValue++;
      }

      if (repeatValue <= 3) {
        int temp;
        if (repeatValue == 0) {
          temp = previousOffsets[0];
        } else if (repeatValue == 3) {
          temp = previousOffsets[0] - 1;
        } else {
          temp = previousOffsets[repeatValue];
        }

        if (temp == 0) {
          temp = 1;
        }

        switch (repeatValue) {
          case 0:
            break;
          case 1:
            final prev0 = previousOffsets[0];
            previousOffsets[0] = previousOffsets[1];
            previousOffsets[1] = prev0;
            break;
          case 2:
            final prev0 = previousOffsets[0];
            final prev1 = previousOffsets[1];
            previousOffsets[0] = previousOffsets[2];
            previousOffsets[1] = prev0;
            previousOffsets[2] = prev1;
            break;
          case 3:
            previousOffsets[2] = previousOffsets[1];
            previousOffsets[1] = previousOffsets[0];
            previousOffsets[0] = temp;
            break;
        }

        return temp;
      }
    }

    // Absolute offset: update history with new offset
    previousOffsets[2] = previousOffsets[1];
    previousOffsets[1] = previousOffsets[0];
    previousOffsets[0] = offsetValue;

    return offsetValue;
  }

  /// Execute sequences to reconstruct data
  void _executeSequences(
    Uint8List literals,
    List<ZstdSequence> sequences,
    GrowableBuffer output,
    List<int> previousOffsets,
    int? windowSize,
  ) {
    // If no sequences, just output literals
    if (sequences.isEmpty) {
      output.addBytes(literals, 0, literals.length);
      return;
    }

    // Execute each sequence
    var literalPos = 0;
    final isFirstSequenceOfFirstBlock = output.length == 0;
    for (var i = 0; i < sequences.length; i++) {
      final sequence = sequences[i];
      final isFirstSequence = (i == 0) && isFirstSequenceOfFirstBlock;
      // Copy literals
      if (sequence.literalLength > 0) {
        output.addBytes(literals, literalPos, sequence.literalLength);
        literalPos += sequence.literalLength;
      }

      // Copy match from history
      if (sequence.matchLength > 0) {
        final offset = _computeOffset(
          sequence.offsetSymbolData,
          sequence.literalLength,
          previousOffsets,
          sequence.offsetAdditional,
        );

        // Validate offset against window size
        if (windowSize != null && offset > windowSize) {
          throw ZstdFormatException(
            'Match offset $offset exceeds window size $windowSize',
          );
        }

        final available = output.length;

        if (offset > available) {
          // This is a valid case for the first sequence in the first block without a dictionary.
          // The zstd format allows this, and the match should be ignored.
          if (available == 0 && isFirstSequence) {
            continue;
          }
          throw ZstdFormatException(
            'Match offset $offset exceeds available $available '
            '(literalLength=${sequence.literalLength}, matchLength=${sequence.matchLength}, '
            'isFirstSequence=$isFirstSequence)',
          );
        }
        output.copyFromHistory(offset, sequence.matchLength);
      }
    }

    // Copy remaining literals
    if (literalPos < literals.length) {
      output.addBytes(literals, literalPos, literals.length - literalPos);
    }
  }
}

/// Represents a decoded sequence
class ZstdSequence {
  final int literalLength;
  final int matchLength;
  final SequenceSymbol offsetSymbolData;
  final int offsetAdditional;
  final int literalSymbol;
  final int matchSymbol;
  final int offsetSymbol;

  ZstdSequence(
    this.literalLength,
    this.matchLength,
    this.offsetSymbolData, {
    required this.offsetAdditional,
    required this.literalSymbol,
    required this.matchSymbol,
    required this.offsetSymbol,
  });
}
