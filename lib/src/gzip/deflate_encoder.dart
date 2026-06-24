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
  late final Lz77Encoder _lz77;

  DeflateEncoder({this.level = 6, this.blockSize = 65535}) {
    // Configure LZ77 based on compression level
    final lazyMatch = level >= 4;
    final lazyMatchLevel = level >= 7 ? 8 : 4;
    _lz77 = Lz77Encoder(
      lazyMatching: lazyMatch,
      lazyMatchLevel: lazyMatchLevel,
    );
  }

  /// Compresses data using DEFLATE algorithm
  ///
  /// Returns compressed data as a byte array. The output includes DEFLATE
  /// blocks but not the GZIP header/trailer (use GzipCodec for complete GZIP).
  Uint8List compress(Uint8List data) {
    // Reset LZ77 state to avoid using history from previous compressions
    _lz77.reset();

    final output = BitStreamWriter();

    if (data.isEmpty) {
      // Empty input: write single stored block with final flag
      _writeStoredBlock(output, data, isFinal: true);
      return output.toBytes();
    }

    // Process data in blocks
    var offset = 0;
    while (offset < data.length) {
      final remaining = data.length - offset;
      final chunkSize = math.min(blockSize, remaining);
      final isFinal = offset + chunkSize >= data.length;

      final chunk = Uint8List.sublistView(data, offset, offset + chunkSize);
      final tokens = _lz77.compress(chunk);

      // Choose compression strategy based on level
      // All levels compress - differ in Huffman strategy and lazy matching
      if (level <= 3) {
        // Fast: use fixed Huffman (no tree overhead)
        writeFixedBlock(output, tokens, isFinal: isFinal);
      } else {
        // Use dynamic Huffman for better compression
        writeDynamicBlock(output, tokens, isFinal: isFinal);
      }

      offset += chunkSize;
    }

    return output.toBytes();
  }

  /// Writes a stored (uncompressed) block
  void _writeStoredBlock(
    BitStreamWriter output,
    Uint8List data, {
    required bool isFinal,
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
    final len = data.length;
    final nlen = (~len) & 0xFFFF;

    output.writeBits(len & 0xFF, 8);
    output.writeBits((len >> 8) & 0xFF, 8);
    output.writeBits(nlen & 0xFF, 8);
    output.writeBits((nlen >> 8) & 0xFF, 8);

    // Write literal data
    for (final byte in data) {
      output.writeBits(byte, 8);
    }
  }

  /// Writes a block using fixed Huffman codes from precomputed [tokens].
  void writeFixedBlock(
    BitStreamWriter output,
    List<Token> tokens, {
    required bool isFinal,
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
    BitStreamWriter output,
    List<Token> tokens, {
    required bool isFinal,
  }) {
    // Block header: BFINAL (1 bit) + BTYPE (2 bits = 10 for dynamic)
    output.writeBits(isFinal ? 1 : 0, 1);
    output.writeBits(BlockType.dynamicHuffman.value, 2);

    // Build frequency tables
    final literalFrequencies = List<int>.filled(286, 0);
    final distanceFrequencies = List<int>.filled(30, 0);

    for (final token in tokens) {
      if (token is LiteralToken) {
        literalFrequencies[token.value]++;
      } else if (token is MatchToken) {
        final lengthCode = encodeLength(token.length);
        literalFrequencies[lengthCode.code]++;

        final distanceCode = encodeDistance(token.distance);
        distanceFrequencies[distanceCode.code]++;
      }
    }

    // Always include end-of-block symbol
    literalFrequencies[endBlock]++;

    var hasDistance = false;
    for (final frequency in distanceFrequencies) {
      if (frequency != 0) {
        hasDistance = true;
        break;
      }
    }
    if (!hasDistance) {
      distanceFrequencies[0] = 1;
    }

    // Generate code lengths (limited to 15 bits for DEFLATE)
    final literalLengths = HuffmanTreeBuilder.computeLimitedCodeLengths(
      literalFrequencies,
      15,
    );
    final distanceLengths = HuffmanTreeBuilder.computeLimitedCodeLengths(
      distanceFrequencies,
      15,
    );

    // Generate canonical codes (pre-reversed, typed arrays).
    final literalCodes = _buildCodes(literalLengths);
    final distanceCodes = _buildCodes(distanceLengths);

    // Write tree descriptions
    _writeTreeDescriptions(output, literalLengths, distanceLengths);

    // Encode tokens using dynamic Huffman codes
    for (final token in tokens) {
      if (token is LiteralToken) {
        if (literalCodes.lengths[token.value] != 0) {
          _emit(output, literalCodes, token.value);
        }
      } else if (token is MatchToken) {
        final lengthCode = encodeLength(token.length);
        if (literalCodes.lengths[lengthCode.code] != 0) {
          _emit(output, literalCodes, lengthCode.code);
          if (lengthCode.extraBits > 0) {
            output.writeBits(lengthCode.extraValue, lengthCode.extraBits);
          }
        }

        final distanceCode = encodeDistance(token.distance);
        if (distanceCodes.lengths[distanceCode.code] != 0) {
          _emit(output, distanceCodes, distanceCode.code);
          if (distanceCode.extraBits > 0) {
            output.writeBits(distanceCode.extraValue, distanceCode.extraBits);
          }
        }
      }
    }

    // End-of-block symbol
    if (literalCodes.lengths[endBlock] != 0) {
      _emit(output, literalCodes, endBlock);
    }
  }

  /// Writes Huffman tree descriptions to the output stream
  void _writeTreeDescriptions(
    BitStreamWriter output,
    List<int> literalLengths,
    List<int> distanceLengths,
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
    final clLengths = HuffmanTreeBuilder.computeLimitedCodeLengths(
      codeLengthFrequencies,
      7,
    );
    final clCodes = _buildCodes(clLengths);

    // Find number of code length codes to transmit
    var hclen = 19;
    for (var i = 18; i >= 0; i--) {
      if (clLengths[codeLengthOrder[i]] != 0) {
        hclen = i + 1;
        break;
      }
    }

    // Write header
    output.writeBits(hlit - 257, 5); // HLIT
    output.writeBits(hdist - 1, 5); // HDIST
    output.writeBits(hclen - 4, 4); // HCLEN

    // Write code length code lengths in specified order
    for (var i = 0; i < hclen; i++) {
      final idx = codeLengthOrder[i];
      output.writeBits(clLengths[idx], 3);
    }

    // Write encoded code lengths
    for (final item in encoded) {
      if (clCodes.lengths[item.symbol] != 0) {
        _emit(output, clCodes, item.symbol);
        if (item.extraBits > 0) {
          output.writeBits(item.extraValue, item.extraBits);
        }
      }
    }
  }

  /// Run-length encodes code lengths for transmission
  List<_CodeLengthSymbol> _runLengthEncode(List<int> lengths) {
    final result = <_CodeLengthSymbol>[];

    var i = 0;
    while (i < lengths.length) {
      final len = lengths[i];

      if (len == 0) {
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
        result.add(_CodeLengthSymbol(len, 0, 0));
        i++;

        // Check for repetitions
        var count = 0;
        while (i < lengths.length && lengths[i] == len && count < 6) {
          count++;
          i++;
        }

        if (count >= 3) {
          // Use code 16 (2-bit length)
          result.add(_CodeLengthSymbol(16, 2, count - 3));
        } else {
          // Write individual values
          for (var j = 0; j < count; j++) {
            result.add(_CodeLengthSymbol(len, 0, 0));
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
  void _emit(BitStreamWriter output, _HuffmanCodes codes, int symbol) {
    output.writeBits(codes.revCodes[symbol], codes.lengths[symbol]);
  }

  /// Builds canonical Huffman codes (pre-reversed) + lengths indexed by symbol,
  /// in typed arrays (length 0 = symbol unused).
  static _HuffmanCodes _buildCodes(List<int> codeLengths) {
    final n = codeLengths.length;
    final lengths = Uint8List(n);
    final revCodes = Uint16List(n);

    var maxLength = 0;
    for (final len in codeLengths) {
      if (len > maxLength) maxLength = len;
    }
    if (maxLength == 0) return _HuffmanCodes(revCodes, lengths);

    final lengthCounts = Uint32List(maxLength + 1);
    for (final len in codeLengths) {
      if (len > 0) lengthCounts[len]++;
    }
    final nextCode = Uint32List(maxLength + 1);
    var code = 0;
    for (var i = 1; i <= maxLength; i++) {
      code = (code + lengthCounts[i - 1]) << 1;
      nextCode[i] = code;
    }
    for (var symbol = 0; symbol < n; symbol++) {
      final len = codeLengths[symbol];
      if (len > 0) {
        lengths[symbol] = len;
        revCodes[symbol] = _reverseBits(nextCode[len], len);
        nextCode[len]++;
      }
    }
    return _HuffmanCodes(revCodes, lengths);
  }

  static int _reverseBits(int value, int count) {
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
  _HuffmanCodes(this.revCodes, this.lengths);
  final Uint16List revCodes;
  final Uint8List lengths;
}

/// Represents a run-length encoded code length symbol
class _CodeLengthSymbol {
  final int symbol;
  final int extraBits;
  final int extraValue;

  _CodeLengthSymbol(this.symbol, this.extraBits, this.extraValue);
}
