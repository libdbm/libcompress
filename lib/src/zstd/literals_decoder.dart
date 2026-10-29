import 'dart:typed_data';

import 'backward_bit_reader.dart';
import 'fse_decoder.dart';
import 'huffman_decoder.dart';
import 'zstd_common.dart';

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

/// Decoder for the literals section of compressed blocks (RFC 8878
/// §3.1.1.3.1). Keeps the last Huffman tree for treeless blocks.
class LiteralsDecoder {
  /// Cached Huffman decoder from previous compressed block
  HuffmanDecoder? _cachedHuffmanTree;

  /// Clear cached state (should be called between frames)
  void reset() {
    _cachedHuffmanTree = null;
  }

  /// Rejects a literals section larger than any block can hold before its
  /// buffer is allocated (the per-frame limit is enforced on output).
  static void _checkLiteralsSize(final int size) {
    if (size > zstdMaxBlockSize) {
      throw ZstdFormatException(
        'Literals size $size exceeds maximum block size $zstdMaxBlockSize',
      );
    }
  }

  /// Decodes the literals section at [offset]; returns the literals and the
  /// offset after the section.
  (Uint8List, int) decode(
    final Uint8List data,
    int offset,
    final int blockEnd,
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
      _checkLiteralsSize(regeneratedSize);
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
        // The byte is present even when Regenerated_Size is 0.
        if (offset >= blockEnd) {
          throw ZstdFormatException('RLE byte missing');
        }
        final literals = Uint8List(regeneratedSize)
          ..fillRange(0, regeneratedSize, data[offset]);
        return (literals, offset + 1);
      }
    }

    final compressedHeader = _parseCompressedLiteralHeader(
      data,
      offset,
      blockEnd,
      sizeFormat,
    );

    _checkLiteralsSize(compressedHeader.regeneratedSize);
    // Four streams each regenerate a quarter (rounded up) of the literals, so
    // fewer than 6 cannot fill them (zstd's MIN_LITERALS_FOR_4_STREAMS).
    if (compressedHeader.numStreams == 4 &&
        compressedHeader.regeneratedSize < 6) {
      throw ZstdFormatException(
        '4-stream Huffman literals need at least 6, got '
        '${compressedHeader.regeneratedSize}',
      );
    }
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
    final Uint8List data,
    final int offset,
    final int blockEnd,
    final int sizeFormat,
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
    final Uint8List data,
    final int offset,
    final int blockEnd,
    final int sizeFormat,
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

    // Up to 40 bits: assemble with multiplication and split with integer
    // division, which are exact on the VM and dart2js alike (JS bitwise
    // operators truncate to 32 bits).
    var value = 0;
    var scale = 1;
    for (var i = 0; i < headerSize; i++) {
      value += data[offset + i] * scale;
      scale *= 256;
    }

    final sizeRange = 1 << bitsPerSize;
    final regeneratedSize = (value ~/ 16) % sizeRange;
    final compressedSize = (value ~/ (1 << (4 + bitsPerSize))) % sizeRange;

    return _CompressedLiteralHeader(
      headerSize: headerSize,
      regeneratedSize: regeneratedSize,
      compressedSize: compressedSize,
      numStreams: numStreams,
    );
  }

  /// Decode Huffman-compressed literals
  Uint8List _decodeHuffmanLiterals(
    final Uint8List data,
    final int offset,
    final int compressedSize,
    final int regeneratedSize,
    final bool hasTree,
    final int numStreams,
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
    final Uint8List data,
    int offset,
    final int streamEnd,
    final int expectedSymbolCount,
  ) {
    if (streamEnd > data.length) {
      throw ZstdFormatException(
        'FSE stream extends beyond available data: streamEnd=$streamEnd, length=${data.length}',
      );
    }

    // The FSE table description, read forward. The Huffman-weight table is
    // capped at accuracy log 6 (RFC 8878), checked before allocating.
    final (normalizedCounters, accuracyLog, next) = readNormalizedCounts(
      data,
      offset,
      streamEnd,
      12, // Max symbol for Huffman weights
      6,
    );
    offset = next;

    // Build FSE decoder table
    final fseDecoder = FseDecoder();
    fseDecoder.buildTable(normalizedCounters, accuracyLog);

    // FSE decompression uses backward bitstream (MSB-first from end)
    final reader = BackwardBitReader(data, offset, streamEnd);

    // Initialize FSE states (read tableLog bits each)
    // Note: like Java, read state first, then load
    var state1 = reader.readBits(accuracyLog);
    var state2 = reader.readBits(accuracyLog);

    // Now load before decoding loop
    reader.load();

    // Decode weights from FSE stream. A table holds at most 255 weights (the
    // last symbol's weight is implied), and that output size is what bounds
    // the decode, as in the reference decoder: a state whose entry reads zero
    // bits emits a weight without consuming input.
    const maxWeights = 255;
    final weights = <int>[];

    // Main decode loop - decode 4 symbols at a time
    mainLoop:
    while (weights.length < maxWeights - 3) {
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
    while (true) {
      if (weights.length > maxWeights - 2) {
        throw ZstdFormatException(
          'FSE weight decode: more than $maxWeights Huffman weights',
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
  (List<int>, int) _decodeHuffmanWeights(final Uint8List data, int offset) {
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
}
