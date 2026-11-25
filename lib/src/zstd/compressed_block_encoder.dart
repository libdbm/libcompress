import 'dart:typed_data';
import '../util/growable_buffer.dart';
import 'compressed_block_decoder.dart';
import 'fse_encoder.dart';
import 'huffman_encoder.dart';
import 'match_finder.dart';
import 'sequence_constants.dart' as seq;
import 'sequence_encoder.dart';
import 'sequences.dart';

/// Compressed block encoder for Zstd, as the Java port's `BlockWriter`.
///
/// Encodes a block as a literals section (RLE, Huffman with a tree, Huffman
/// reusing the previous block's tree, or raw) and a sequences section. A
/// block with no matches is its literals alone. One whose encoding fails is
/// returned empty so the frame writes it raw.
///
/// The encoder tracks what the decoder holds from block to block: the repeat
/// offsets (in [MatchFinder]) and the last Huffman tree. A frame starts with
/// [start] (streams) or [frame] (one-shot frames, whose match tables persist
/// across blocks). When the caller writes a block raw or RLE instead of the
/// encoded body, it calls [discard] so neither is kept.
class CompressedBlockEncoder {
  /// Search depth for match finding (higher = better compression, slower)
  final int searchDepth;

  /// Minimum match length to emit (level-derived; 3 or 4).
  final int minMatch;

  /// The match length that ends a search.
  final int nice;

  /// How fast the search skips ahead after misses; 31 for none.
  final int strength;

  /// Whether to use the double-fast search (levels 1-3).
  final bool fast;

  /// Whether to validate encoded blocks by decompressing them
  ///
  /// When enabled, each block is decompressed immediately after compression
  /// to verify correctness. This doubles CPU work but is useful for debugging.
  final bool validate;

  String? lastValidationError;
  String? lastValidationStack;

  /// Optional hook invoked when an unexpected encode error makes the block fall
  /// back to raw output. Lets production wire a log/metric so the fallback isn't
  /// silent; null = no-op.
  final void Function(Object error, StackTrace stackTrace)? onFallback;

  /// When true, an unexpected compressed-encode error is rethrown instead of
  /// silently falling back to a raw block (fail-loud). Independent of [validate]
  /// (which also rethrows but doubles CPU by decoding every block).
  final bool strict;

  /// Count of unexpected-error fallbacks to raw output. Does NOT count the
  /// legitimate "incompressible" path (empty result with no error).
  int fallbacks = 0;

  /// Creates a compressed block encoder; the defaults are those of level 3.
  CompressedBlockEncoder({
    this.searchDepth = 32,
    this.minMatch = 4,
    this.nice = 32,
    this.strength = 8,
    this.fast = true,
    this.validate = false,
    this.strict = false,
    this.onFallback,
  });

  /// An encoder with the search parameters of compression [level] (1-22).
  factory CompressedBlockEncoder.level(
    final int level, {
    final bool validate = false,
    final bool strict = false,
    final void Function(Object error, StackTrace stackTrace)? onFallback,
  }) => CompressedBlockEncoder(
    searchDepth: _depth(level),
    minMatch: level >= 6 ? 3 : 4,
    nice: _nice(level),
    strength: _strength(level),
    fast: level <= 3,
    validate: validate,
    strict: strict,
    onFallback: onFallback,
  );

  /// The hash chain search depth of [level].
  static int _depth(final int level) {
    if (level <= 1) return 4;
    if (level <= 2) return 8;
    if (level <= 3) return 32;
    if (level <= 4) return 48;
    if (level <= 5) return 64;
    if (level <= 6) return 96;
    if (level <= 9) return 128;
    if (level <= 12) return 256;
    if (level <= 16) return 512;
    return 1024;
  }

  /// How fast the search skips ahead after misses at [level]: fastest at
  /// levels 1 and 2, not at all from level 6.
  static int _strength(final int level) {
    if (level <= 1) return 5;
    if (level <= 2) return 6;
    return level <= 5 ? 8 : 31;
  }

  /// The match length that ends a search at [level]: longer at higher
  /// levels, unlimited from level 17.
  static int _nice(final int level) {
    if (level <= 2) return 16;
    if (level <= 5) return 32;
    if (level <= 9) return 64;
    return level <= 16 ? 128 : 1 << 30;
  }

  // Reused across blocks so its large hash/chain tables are allocated once.
  late final MatchFinder _matchFinder = MatchFinder(
    depth: searchDepth,
    min: minMatch,
    nice: nice,
    strength: strength,
    fast: fast,
  );

  // Sequence codes, reused across blocks.
  final SequenceCodes _codes = SequenceCodes();

  HuffmanEncoder _huffman = HuffmanEncoder();

  /// The tree the decoder holds from the last block written with one, which
  /// a block may reuse (literals type 3).
  HuffmanEncoder _previous = HuffmanEncoder();

  /// Whether [_previous] is a tree the decoder holds.
  bool _reusable = false;

  Uint8List _literals = Uint8List(0);

  /// The decoder that validation runs, which keeps the Huffman tree from
  /// block to block as a frame's decoder does.
  CompressedBlockDecoder? _checker;

  /// Starts a frame in stream mode: the decoder's initial repeat offsets.
  void start() {
    _matchFinder.start();
    _reusable = false;
    _checker?.reset();
  }

  /// Starts a frame in frame mode over `data[0, total)`: the match tables
  /// persist across its blocks, encoded with `persistent: true`.
  void frame(final Uint8List data, final int total) {
    _matchFinder.prepare(data, total);
    _reusable = false;
    _checker?.reset();
  }

  /// Undoes the last block's repeat offset updates and forgets its tree,
  /// when the caller writes it raw or RLE instead.
  void discard() {
    _matchFinder.restore();
    _reusable = false;
    _checker?.reset();
  }

  /// Encode a block using compressed format
  ///
  /// Returns the encoded block data (without block header), empty when the
  /// block should be written raw.
  ///
  /// Bytes in `input[0..from)` are history used only for matching; the block
  /// encodes `input[from..end)`. [end] defaults to `input.length`. In stream
  /// mode (the default) the match tables are rebuilt from the history; with
  /// [persistent], after [frame] over the same input, they already hold it.
  Uint8List encodeBlock(
    final Uint8List input, {
    final int from = 0,
    final int? end,
    final bool persistent = false,
  }) {
    final limit = end ?? input.length;
    final matchFinder = _matchFinder..save();
    if (limit - from <= 0) {
      return Uint8List(0);
    }

    try {
      final trailing = persistent
          ? matchFinder.next(from, limit)
          : matchFinder.find(input, from, limit);
      if (_literals.length < limit - from) {
        _literals = Uint8List(limit - from);
      }
      final count = matchFinder.literals(
        input,
        from,
        trailing,
        limit,
        _literals,
      );
      final literals = Uint8List.sublistView(_literals, 0, count);

      final literalSection = _encodeLiteralSection(literals);
      final sequencesSection = _encodeSequencesSectionFse(
        matchFinder.sequences,
      );

      final output = Uint8List(literalSection.length + sequencesSection.length);
      output.setRange(0, literalSection.length, literalSection);
      output.setRange(literalSection.length, output.length, sequencesSection);

      if (validate) {
        _validateEncodedBlock(
          output,
          input,
          from: from,
          end: limit,
          repeats: matchFinder.saved,
        );
      }
      lastValidationError = null;
      lastValidationStack = null;

      return output;
    } catch (e, st) {
      // Compressed encoding failed unexpectedly. Fall back to a raw block so
      // the stream stays valid, but do not hide the failure: record it (so the
      // silent ratio collapse is at least inspectable) and surface it loudly
      // when validation is enabled.
      lastValidationError = 'Compressed block encoding failed: $e';
      lastValidationStack = st.toString();
      fallbacks++;
      if (validate || strict) rethrow;
      matchFinder.restore();
      onFallback?.call(e, st);
      return Uint8List(0);
    }
  }

  Uint8List _encodeLiteralSection(final Uint8List literals) {
    final count = literals.length;
    if (count >= 4 && _same(literals)) {
      return _encodeRleLiterals(literals);
    }
    if (count >= 64) {
      final huffman = _encodeHuffmanLiterals(literals);
      if (huffman != null) return huffman;
    }
    return _encodeRawLiteralsOnly(literals);
  }

  static bool _same(final Uint8List literals) {
    final first = literals[0];
    for (var i = 1; i < literals.length; i++) {
      if (literals[i] != first) return false;
    }
    return true;
  }

  /// RLE literals section: the size header, then the one byte.
  static Uint8List _encodeRleLiterals(final Uint8List literals) {
    final count = literals.length;
    final value = literals[0];
    if (count < 32) return Uint8List.fromList([(count << 3) | 1, value]);
    if (count < 4096) {
      return Uint8List.fromList([
        ((count & 0x0F) << 4) | 0x05,
        (count >> 4) & 0xFF,
        value,
      ]);
    }
    return Uint8List.fromList([
      ((count & 0x0F) << 4) | 0x0D,
      (count >> 4) & 0xFF,
      (count >> 12) & 0xFF,
      value,
    ]);
  }

  /// The Huffman literals section, reusing the previous tree when that is
  /// cheaper, or null when it would not be smaller than the raw literals.
  Uint8List? _encodeHuffmanLiterals(final Uint8List literals) {
    final count = literals.length;
    final counts = List<int>.filled(256, 0);
    for (var i = 0; i < count; i++) {
      counts[literals[i]]++;
    }
    var highest = 0;
    var distinct = 0;
    var largest = 0;
    for (var value = 0; value < 256; value++) {
      final total = counts[value];
      if (total > 0) {
        highest = value;
        distinct++;
        if (total > largest) largest = total;
      }
    }
    // zstd's test for literals Huffman coding cannot shrink: no byte much
    // more frequent than the rest.
    if (distinct < 2 || largest <= (count >> 7) + 4) return null;

    final four = count >= 256;
    final reuse = _reusable ? _previous.cost(counts, highest, four) : -1;
    if (reuse > 0 && reuse < count && count < 1024) {
      final reused = _reuse(literals, four);
      if (reused != null) return reused;
    }
    final encoder = _huffman;
    try {
      encoder.buildFromCounts(counts, highest);
    } catch (_) {
      return null;
    }
    final header = encoder.encodeWeightsHeader(highest);
    if (header == null) return null;
    final fresh = encoder.cost(counts, highest, four);
    if (reuse > 0 && reuse <= header.length + fresh) {
      final reused = _reuse(literals, four);
      if (reused != null) return reused;
    }
    final encoded = four
        ? encoder.encode4Streams(literals)
        : encoder.encodeSingle(literals);
    if (encoded == null) return null;
    final compressed = header.length + encoded.length;
    if (compressed >= count) return null;
    final section = _buildHuffmanLiteralSection(
      2,
      count,
      compressed,
      header,
      encoded,
      four,
    );
    _huffman = _previous;
    _previous = encoder;
    _reusable = true;
    return section;
  }

  /// A treeless literals section (type 3) coded with the previous tree, or
  /// null when that is not smaller than the raw literals.
  Uint8List? _reuse(final Uint8List literals, final bool four) {
    final encoded = four
        ? _previous.encode4Streams(literals)
        : _previous.encodeSingle(literals);
    if (encoded == null ||
        encoded.isEmpty ||
        encoded.length >= literals.length) {
      return null;
    }
    return _buildHuffmanLiteralSection(
      3,
      literals.length,
      encoded.length,
      Uint8List(0),
      encoded,
      four,
    );
  }

  /// Build the complete Huffman literals section
  ///
  /// Header format (decoder reads as little-endian):
  /// - Bits 0-1: Literals_Block_Type (2 = Compressed, 3 = Treeless)
  /// - Bits 2-3: Size_Format
  /// - Bits 4+: Regenerated_Size, then Compressed_Size
  Uint8List _buildHuffmanLiteralSection(
    final int type,
    final int regeneratedSize,
    final int compressedSize,
    final Uint8List weightsHeader,
    final Uint8List compressedStreams,
    final bool use4Streams,
  ) {
    // Choose format based on size requirements
    // Format 0/1: 10-bit sizes (max 1023), 3 bytes
    // Format 2: 14-bit sizes (max 16383), 4 bytes
    // Format 3: 18-bit sizes (max 262143), 5 bytes

    int sizeFormat;
    int headerSize;
    int bitsPerSize;

    if (regeneratedSize < 1024 && compressedSize < 1024) {
      sizeFormat = use4Streams ? 1 : 0;
      headerSize = 3;
      bitsPerSize = 10;
    } else if (regeneratedSize < 16384 && compressedSize < 16384) {
      sizeFormat = 2; // Always 4 streams for format 2
      headerSize = 4;
      bitsPerSize = 14;
    } else {
      sizeFormat = 3; // Always 4 streams for format 3
      headerSize = 5;
      bitsPerSize = 18;
    }

    // Build header as little-endian value. This can require more than 32 bits
    // for size format 3, so combine with multiplication rather than JS-unsafe
    // bitwise operators (exact up to 2^53 on dart2js).
    final sizeRange = 1 << bitsPerSize;
    var header =
        ((type & 0x03) | ((sizeFormat & 0x03) << 2)) +
        (regeneratedSize % sizeRange) * 16 +
        (compressedSize % sizeRange) * (1 << (4 + bitsPerSize));

    final output = Uint8List(
      headerSize + weightsHeader.length + compressedStreams.length,
    );

    // Convert to bytes (little-endian).
    for (var i = 0; i < headerSize; i++) {
      output[i] = header % 256;
      header ~/= 256;
    }

    var pos = headerSize;
    output.setRange(pos, pos + weightsHeader.length, weightsHeader);
    pos += weightsHeader.length;
    output.setRange(pos, pos + compressedStreams.length, compressedStreams);

    return output;
  }

  /// Encode raw literals section (header + payload)
  Uint8List _encodeRawLiteralsOnly(final Uint8List literals) {
    final output = BytesBuilder(copy: false);

    // Literals section header - Raw format
    final size = literals.length;
    if (size < 32) {
      // Small raw: Bits[0-1]=00 (raw), Bits[2-3]=00 (format), Bits[4-8]=size (5 bits)
      output.addByte((size << 3) | 0x00);
    } else if (size < 4096) {
      // Medium raw: Bits[0-1]=00 (raw), Bits[2-3]=01 (format), Bits[4-15]=size (12 bits)
      // Byte 1: bits 0-3 = 0100, bits 4-7 = size[0:3]
      // Byte 2: bits 0-7 = size[4:11]
      output.addByte(((size & 0x0F) << 4) | 0x04);
      output.addByte((size >> 4) & 0xFF);
    } else {
      // Large raw: Bits[0-1]=00 (raw), Bits[2-3]=11 (format), Bits[4-23]=size (20 bits)
      // Byte 1: bits 0-3 = 1100, bits 4-7 = size[0:3]
      // Byte 2: bits 0-7 = size[4:11]
      // Byte 3: bits 0-7 = size[12:19]
      output.addByte(((size & 0x0F) << 4) | 0x0C);
      output.addByte((size >> 4) & 0xFF);
      output.addByte((size >> 12) & 0xFF);
    }

    output.add(literals);

    return output.takeBytes();
  }

  /// Encode sequences section using FSE with optimal table selection
  Uint8List _encodeSequencesSectionFse(final Sequences sequences) {
    final output = BytesBuilder(copy: false);

    // Write sequence count per RFC 8878 Section 3.1.1.3.2.1.1
    final count = sequences.count;
    if (count < 128) {
      output.addByte(count);
    } else if (count < 0x7F00) {
      output.addByte(128 + (count >> 8));
      output.addByte(count & 0xFF);
    } else {
      output.addByte(0xFF);
      final adjusted = count - 0x7F00;
      output.addByte(adjusted & 0xFF);
      output.addByte((adjusted >> 8) & 0xFF);
    }

    if (count == 0) return output.takeBytes();

    // Codes are computed once, so the statistics describe exactly the symbols
    // the encoder writes.
    final codes = _codes..compute(sequences);

    final llStats = FseEncoder.stats(
      Uint8List.sublistView(codes.literals, 0, count),
      35,
    );
    final ofStats = FseEncoder.stats(
      Uint8List.sublistView(codes.offsets, 0, count),
      31,
    );
    final mlStats = FseEncoder.stats(
      Uint8List.sublistView(codes.matches, 0, count),
      52,
    );

    // Select optimal encoding mode for each component
    final selector = EncodingModeSelector(
      llStats: llStats,
      ofStats: ofStats,
      mlStats: mlStats,
    );

    final (llMode, ofMode, mlMode, llEnc, ofEnc, mlEnc) = selector.select(
      llPredefined: seq.llDefaultNorm,
      llPredefinedLog: seq.llDefaultNormLog,
      ofPredefined: seq.ofDefaultNorm,
      ofPredefinedLog: seq.ofDefaultNormLog,
      mlPredefined: seq.mlDefaultNorm,
      mlPredefinedLog: seq.mlDefaultNormLog,
    );

    // Write symbol compression modes byte
    output.addByte(encodeSymbolMode(llMode, ofMode, mlMode));

    // Write table descriptions per RFC 8878 Section 3.1.1.3.2.1
    // Order: LL, OF, ML. Each gets FSE table (mode 2) or RLE byte (mode 1)

    // Literal Lengths table
    if (llMode == 2 && llEnc != null) {
      output.add(llEnc.encodeHeader());
    } else if (llMode == 1) {
      output.addByte(_findRleSymbol(llStats));
    }

    // Offsets table
    if (ofMode == 2 && ofEnc != null) {
      output.add(ofEnc.encodeHeader());
    } else if (ofMode == 1) {
      output.addByte(_findRleSymbol(ofStats));
    }

    // Match Lengths table
    if (mlMode == 2 && mlEnc != null) {
      output.add(mlEnc.encodeHeader());
    } else if (mlMode == 1) {
      output.addByte(_findRleSymbol(mlStats));
    }

    // Encode sequences using appropriate tables
    final encoder = SequenceEncoder.withModes(
      llMode: llMode,
      ofMode: ofMode,
      mlMode: mlMode,
      llNorm: llEnc?.normalized,
      ofNorm: ofEnc?.normalized,
      mlNorm: mlEnc?.normalized,
      llLog: llEnc?.tableLog,
      ofLog: ofEnc?.tableLog,
      mlLog: mlEnc?.tableLog,
    );

    final bits = encoder.encodeSequences(sequences, codes);
    output.add(bits);

    return output.takeBytes();
  }

  int _findRleSymbol(final SymbolStats stats) {
    for (var i = 0; i < stats.counts.length; i++) {
      if (stats.counts[i] > 0) return i;
    }
    return 0;
  }

  void _validateEncodedBlock(
    final Uint8List blockData,
    final Uint8List source, {
    required final int from,
    required final int end,
    required final List<int> repeats,
  }) {
    final decoder = _checker ??= CompressedBlockDecoder();
    final buffer = GrowableBuffer(end, end);
    // The block encodes only source[from..end), but its matches can reference
    // source[0..from). Reconstruct the same history used by the encoder.
    buffer.addBytes(source, 0, from);
    decoder.decodeBlock(blockData, 0, blockData.length, buffer, repeats);
    final decoded = buffer.toBytes();
    if (decoded.length != end) {
      throw StateError(
        'Block validation size mismatch: ${decoded.length} != $end',
      );
    }
    for (var i = from; i < end; i++) {
      if (decoded[i] != source[i]) {
        throw StateError('Block validation byte mismatch at $i');
      }
    }
  }
}
