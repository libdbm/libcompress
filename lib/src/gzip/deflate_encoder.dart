import 'dart:typed_data';
import 'dart:math' as math;
import '../util/bit_stream.dart';
import 'deflate_common.dart';
import 'lz77_encoder.dart';
import '../util/huffman.dart';

/// DEFLATE compression encoder implementing RFC 1951
///
/// Compresses data using LZ77 sliding window compression followed by
/// Huffman coding. Supports three block types: stored (no compression),
/// fixed Huffman, and dynamic Huffman.
class DeflateEncoder {
  /// Compression level (1-9)
  final int level;

  /// Maximum block size before starting a new block
  final int blockSize;

  /// LZ77 encoder instance
  final Lz77Encoder _lz77;

  DeflateEncoder({this.level = 6, this.blockSize = 65535})
    : _lz77 = Lz77Encoder(level: level);

  /// Compresses data using DEFLATE algorithm
  ///
  /// Returns compressed data as a byte array. The output includes DEFLATE
  /// blocks but not the GZIP header/trailer (use GzipCodec for complete GZIP).
  Uint8List compress(final Uint8List data) {
    // Reset LZ77 state to avoid using history from previous compressions
    _lz77.reset();

    final output = BitStreamWriter();

    if (data.isEmpty) {
      // Empty input: write single stored block with final flag
      _writeStoredBlock(output, data, isFinal: true);
      return output.toBytes();
    }

    // Process data in blocks; matches reach back into earlier blocks, and the
    // last match of a block may run past its end.
    var offset = 0;
    while (offset < data.length) {
      final limit = math.min(offset + blockSize, data.length);
      final (tokens, end) = _lz77.tokenize(data, offset, limit);
      final isFinal = end >= data.length;

      writeBlock(
        output,
        tokens,
        Uint8List.sublistView(data, offset, end),
        isFinal: isFinal,
      );

      offset = end;
    }

    return output.toBytes();
  }

  /// Writes a stored (uncompressed) block
  void _writeStoredBlock(
    final BitStreamWriter output,
    final Uint8List data, {
    required final bool isFinal,
  }) {
    // Validate block size - DEFLATE stored blocks have 16-bit length field
    if (data.length > 65535) {
      throw ArgumentError(
        'Stored block size ${data.length} exceeds maximum 65535 bytes',
      );
    }

    // Block header: BFINAL (1 bit) + BTYPE (2 bits = 00 for stored)
    output.writeBits(isFinal ? 1 : 0, 1);
    output.writeBits(BlockType.stored.value, 2);

    // Align to byte boundary
    output.flushToByte();

    // Write length (16 bits) and one's complement
    final size = data.length;
    final complement = (~size) & 0xFFFF;

    output.writeBits(size & 0xFF, 8);
    output.writeBits((size >> 8) & 0xFF, 8);
    output.writeBits(complement & 0xFF, 8);
    output.writeBits((complement >> 8) & 0xFF, 8);

    // Write literal data
    for (final byte in data) {
      output.writeBits(byte, 8);
    }
  }

  /// Writes a block using fixed Huffman codes from precomputed [tokens].
  void writeFixedBlock(
    final BitStreamWriter output,
    final List<Token> tokens, {
    required final bool isFinal,
  }) {
    // Block header: BFINAL (1 bit) + BTYPE (2 bits = 01 for fixed)
    output.writeBits(isFinal ? 1 : 0, 1);
    output.writeBits(BlockType.fixedHuffman.value, 2);

    // Fixed Huffman code tables are RFC constants (cached).
    final literalCodes = _fixedLiteralCodes;
    final distanceCodes = _fixedDistanceCodes;

    for (final token in tokens) {
      if (token is LiteralToken) {
        _emit(output, literalCodes, token.value);
      } else if (token is MatchToken) {
        final lengthCode = encodeLength(token.length);
        _emit(output, literalCodes, lengthCode.code);
        if (lengthCode.extraBits > 0) {
          output.writeBits(lengthCode.extraValue, lengthCode.extraBits);
        }

        final distanceCode = encodeDistance(token.distance);
        _emit(output, distanceCodes, distanceCode.code);
        if (distanceCode.extraBits > 0) {
          output.writeBits(distanceCode.extraValue, distanceCode.extraBits);
        }
      }
    }

    // End-of-block symbol
    _emit(output, literalCodes, endBlock);
  }

  /// Writes a block using dynamic Huffman codes from precomputed [tokens].
  void writeDynamicBlock(
    final BitStreamWriter output,
    final List<Token> tokens, {
    required final bool isFinal,
  }) {
    _writeDynamic(output, tokens, _Tables(_Counts(tokens)), isFinal: isFinal);
  }

  /// Writes [tokens], which encode the bytes [raw], as whichever of a stored,
  /// fixed or dynamic Huffman block is smallest, as zlib's `_tr_flush_block`
  /// does. Stored data over 65535 bytes goes in several stored blocks.
  void writeBlock(
    final BitStreamWriter output,
    final List<Token> tokens,
    final Uint8List raw, {
    required final bool isFinal,
  }) {
    final counts = _Counts(tokens);
    final tables = _Tables(counts);
    // Sizes in bytes, each with the 3-bit block header.
    final custom =
        (10 +
            tables.description.bits +
            counts.cost(tables.literals, tables.distances)) >>
        3;
    final fixed =
        (10 +
            counts.cost(
              _fixedLiteralCodes.lengths,
              _fixedDistanceCodes.lengths,
            )) >>
        3;
    // Each stored block takes a header byte (with padding) and LEN/NLEN.
    final stored = raw.length + 5 * math.max(1, (raw.length + 65534) ~/ 65535);

    if (stored <= math.min(custom, fixed)) {
      var offset = 0;
      do {
        final end = math.min(offset + 65535, raw.length);
        _writeStoredBlock(
          output,
          Uint8List.sublistView(raw, offset, end),
          isFinal: isFinal && end == raw.length,
        );
        offset = end;
      } while (offset < raw.length);
    } else if (fixed <= custom) {
      writeFixedBlock(output, tokens, isFinal: isFinal);
    } else {
      _writeDynamic(output, tokens, tables, isFinal: isFinal);
    }
  }

  /// Writes [tokens] as a dynamic Huffman block with code lengths [tables].
  void _writeDynamic(
    final BitStreamWriter output,
    final List<Token> tokens,
    final _Tables tables, {
    required final bool isFinal,
  }) {
    // Block header: BFINAL (1 bit) + BTYPE (2 bits = 10 for dynamic)
    output.writeBits(isFinal ? 1 : 0, 1);
    output.writeBits(BlockType.dynamicHuffman.value, 2);

    final literalCodes = _buildCodes(tables.literals);
    final distanceCodes = _buildCodes(tables.distances);
    _writeDescription(output, tables.description);

    // Encode tokens using dynamic Huffman codes
    for (final token in tokens) {
      if (token is LiteralToken) {
        _emit(output, literalCodes, token.value);
      } else if (token is MatchToken) {
        final lengthCode = encodeLength(token.length);
        _emit(output, literalCodes, lengthCode.code);
        if (lengthCode.extraBits > 0) {
          output.writeBits(lengthCode.extraValue, lengthCode.extraBits);
        }

        final distanceCode = encodeDistance(token.distance);
        _emit(output, distanceCodes, distanceCode.code);
        if (distanceCode.extraBits > 0) {
          output.writeBits(distanceCode.extraValue, distanceCode.extraBits);
        }
      }
    }

    // End-of-block symbol
    _emit(output, literalCodes, endBlock);
  }

  /// Writes Huffman tree descriptions to the output stream
  void _writeDescription(
    final BitStreamWriter output,
    final _Description description,
  ) {
    final _Description(:hlit, :hdist, :hclen, :alphabetLengths, :encoded) =
        description;
    final alphabetCodes = _buildCodes(alphabetLengths);

    // Write header
    output.writeBits(hlit - 257, 5); // HLIT
    output.writeBits(hdist - 1, 5); // HDIST
    output.writeBits(hclen - 4, 4); // HCLEN

    // Write code length code lengths in specified order
    for (var i = 0; i < hclen; i++) {
      final index = codeLengthOrder[i];
      output.writeBits(alphabetLengths[index], 3);
    }

    // Write encoded code lengths
    for (final item in encoded) {
      _emit(output, alphabetCodes, item.symbol);
      if (item.extraBits > 0) {
        output.writeBits(item.extraValue, item.extraBits);
      }
    }
  }

  /// Builds the tree description of a dynamic block from its code lengths.
  static _Description _describe(
    final List<int> literalLengths,
    final List<int> distanceLengths,
  ) {
    // Find actual number of codes used
    var hlit = 286;
    while (hlit > 257 && literalLengths[hlit - 1] == 0) {
      hlit--;
    }

    var hdist = 30;
    while (hdist > 1 && distanceLengths[hdist - 1] == 0) {
      hdist--;
    }

    // Combine code lengths for encoding
    final combinedLengths = <int>[
      ...literalLengths.sublist(0, hlit),
      ...distanceLengths.sublist(0, hdist),
    ];

    // Run-length encode the code lengths
    final encoded = _runLengthEncode(combinedLengths);

    // Build code length alphabet frequencies
    final codeLengthFrequencies = List<int>.filled(19, 0);
    for (final symbol in encoded) {
      codeLengthFrequencies[symbol.symbol]++;
    }

    // Build code length Huffman tree (limited to 7 bits per RFC 1951)
    final alphabetLengths = HuffmanTreeBuilder.computeLimitedCodeLengths(
      codeLengthFrequencies,
      7,
    );

    // Find number of code length codes to transmit
    var hclen = 19;
    for (var i = 18; i >= 0; i--) {
      if (alphabetLengths[codeLengthOrder[i]] != 0) {
        hclen = i + 1;
        break;
      }
    }

    return _Description(hlit, hdist, hclen, alphabetLengths, encoded);
  }

  /// Run-length encodes code lengths for transmission
  static List<_CodeLengthSymbol> _runLengthEncode(final List<int> lengths) {
    final result = <_CodeLengthSymbol>[];

    var i = 0;
    while (i < lengths.length) {
      final width = lengths[i];

      if (width == 0) {
        // Count consecutive zeros
        var count = 1;
        while (i + count < lengths.length &&
            lengths[i + count] == 0 &&
            count < 138) {
          count++;
        }

        if (count >= 11) {
          // Use code 18 (7-bit length)
          result.add(_CodeLengthSymbol(18, 7, count - 11));
        } else if (count >= 3) {
          // Use code 17 (3-bit length)
          result.add(_CodeLengthSymbol(17, 3, count - 3));
        } else {
          // Write individual zeros
          for (var j = 0; j < count; j++) {
            result.add(_CodeLengthSymbol(0, 0, 0));
          }
        }
        i += count;
      } else {
        // Write the length
        result.add(_CodeLengthSymbol(width, 0, 0));
        i++;

        // Check for repetitions
        var count = 0;
        while (i < lengths.length && lengths[i] == width && count < 6) {
          count++;
          i++;
        }

        if (count >= 3) {
          // Use code 16 (2-bit length)
          result.add(_CodeLengthSymbol(16, 2, count - 3));
        } else {
          // Write individual values
          for (var j = 0; j < count; j++) {
            result.add(_CodeLengthSymbol(width, 0, 0));
          }
        }
      }
    }

    return result;
  }

  // Fixed Huffman code tables are RFC 1951 constants — built once, reused.
  static final _HuffmanCodes _fixedLiteralCodes = _buildCodes(
    _fixedLiteralLengths(),
  );
  static final _HuffmanCodes _fixedDistanceCodes = _buildCodes(
    List<int>.filled(30, 5),
  );

  static List<int> _fixedLiteralLengths() {
    final lengths = List<int>.filled(288, 0);
    for (var i = 0; i <= 143; i++) {
      lengths[i] = 8;
    }
    for (var i = 144; i <= 255; i++) {
      lengths[i] = 9;
    }
    for (var i = 256; i <= 279; i++) {
      lengths[i] = 7;
    }
    for (var i = 280; i <= 287; i++) {
      lengths[i] = 8;
    }
    return lengths;
  }

  /// Emits the canonical Huffman code for [symbol] in a single write. Codes are
  /// pre-reversed so an LSB-first [BitStreamWriter.writeBits] emits them
  /// MSB-first as DEFLATE requires.
  void _emit(
    final BitStreamWriter output,
    final _HuffmanCodes codes,
    final int symbol,
  ) {
    // Every emitted symbol was counted, so it has a code; a zero length here
    // would silently write invalid DEFLATE.
    assert(codes.lengths[symbol] != 0, 'symbol $symbol has no code');
    output.writeBits(codes.values[symbol], codes.lengths[symbol]);
  }

  /// Builds canonical Huffman codes (pre-reversed) + lengths indexed by symbol,
  /// in typed arrays (length 0 = symbol unused).
  static _HuffmanCodes _buildCodes(final List<int> codeLengths) {
    final n = codeLengths.length;
    final lengths = Uint8List(n);
    final values = Uint16List(n);

    var maxLength = 0;
    for (final width in codeLengths) {
      if (width > maxLength) maxLength = width;
    }
    if (maxLength == 0) return _HuffmanCodes(values, lengths);

    final lengthCounts = Uint32List(maxLength + 1);
    for (final width in codeLengths) {
      if (width > 0) lengthCounts[width]++;
    }
    final nextCode = Uint32List(maxLength + 1);
    var code = 0;
    for (var i = 1; i <= maxLength; i++) {
      code = (code + lengthCounts[i - 1]) << 1;
      nextCode[i] = code;
    }
    for (var symbol = 0; symbol < n; symbol++) {
      final width = codeLengths[symbol];
      if (width > 0) {
        lengths[symbol] = width;
        values[symbol] = _reverseBits(nextCode[width], width);
        nextCode[width]++;
      }
    }
    return _HuffmanCodes(values, lengths);
  }

  static int _reverseBits(final int value, final int count) {
    var result = 0;
    for (var i = 0; i < count; i++) {
      result = (result << 1) | ((value >> i) & 1);
    }
    return result;
  }
}

/// Canonical Huffman codes for one alphabet: pre-reversed code values and code
/// lengths indexed by symbol (length 0 = unused). Replaces the old
/// `Map<int, HuffmanCode>` for unboxed, allocation-light lookups.
class _HuffmanCodes {
  _HuffmanCodes(this.values, this.lengths);
  final Uint16List values;
  final Uint8List lengths;
}

/// Represents a run-length encoded code length symbol
class _CodeLengthSymbol {
  final int symbol;
  final int extraBits;
  final int extraValue;

  _CodeLengthSymbol(this.symbol, this.extraBits, this.extraValue);
}

/// Symbol frequencies of a block's tokens, with the end-of-block symbol, and
/// the number of extra bits their lengths and distances take.
class _Counts {
  _Counts(final List<Token> tokens) {
    for (final token in tokens) {
      if (token is LiteralToken) {
        literals[token.value]++;
      } else if (token is MatchToken) {
        final length = encodeLength(token.length);
        literals[length.code]++;
        final distance = encodeDistance(token.distance);
        distances[distance.code]++;
        extra += length.extraBits + distance.extraBits;
      }
    }
    literals[endBlock]++;
  }

  final literals = List<int>.filled(286, 0);
  final distances = List<int>.filled(30, 0);
  var extra = 0;

  /// Bits to code the tokens and end of block with these code lengths.
  int cost(final List<int> literalLengths, final List<int> distanceLengths) {
    var bits = extra;
    for (var i = 0; i < literals.length; i++) {
      bits += literals[i] * literalLengths[i];
    }
    for (var i = 0; i < distances.length; i++) {
      bits += distances[i] * distanceLengths[i];
    }
    return bits;
  }
}

/// The code lengths of a dynamic block and their tree description.
class _Tables {
  factory _Tables(final _Counts counts) {
    // A block with no matches still describes one distance code.
    final distances = counts.distances.any((final count) => count != 0)
        ? counts.distances
        : (List<int>.filled(30, 0)..[0] = 1);
    // Code lengths are limited to 15 bits for DEFLATE.
    final literalLengths = HuffmanTreeBuilder.computeLimitedCodeLengths(
      counts.literals,
      15,
    );
    final distanceLengths = HuffmanTreeBuilder.computeLimitedCodeLengths(
      distances,
      15,
    );
    return _Tables._(
      literalLengths,
      distanceLengths,
      DeflateEncoder._describe(literalLengths, distanceLengths),
    );
  }

  _Tables._(this.literals, this.distances, this.description);

  final List<int> literals;
  final List<int> distances;
  final _Description description;
}

/// The header of a dynamic block: HLIT, HDIST, HCLEN, the code length code's
/// lengths and the run-length encoded code lengths.
class _Description {
  _Description(
    this.hlit,
    this.hdist,
    this.hclen,
    this.alphabetLengths,
    this.encoded,
  );

  final int hlit;
  final int hdist;
  final int hclen;
  final List<int> alphabetLengths;
  final List<_CodeLengthSymbol> encoded;

  /// Bits the description takes.
  int get bits {
    var total = 14 + 3 * hclen;
    for (final item in encoded) {
      total += alphabetLengths[item.symbol] + item.extraBits;
    }
    return total;
  }
}
