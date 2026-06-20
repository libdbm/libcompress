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

  DeflateEncoder({
    this.level = 6,
    this.blockSize = 65535,
  }) {
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

    // Encode tokens using fixed Huffman codes
    final literalLengths = List<int>.filled(288, 0);
    for (var i = 0; i <= 143; i++) {
      literalLengths[i] = 8;
    }
    for (var i = 144; i <= 255; i++) {
      literalLengths[i] = 9;
    }
    for (var i = 256; i <= 279; i++) {
      literalLengths[i] = 7;
    }
    for (var i = 280; i <= 287; i++) {
      literalLengths[i] = 8;
    }
    final literalCodes = HuffmanTreeBuilder.generateCanonicalCodes(literalLengths);
    final distanceLengths = List<int>.filled(30, 5);
    final distanceCodes = HuffmanTreeBuilder.generateCanonicalCodes(distanceLengths);

    for (final token in tokens) {
      if (token is LiteralToken) {
        // Write literal using fixed code
        final code = literalCodes[token.value]!;
        _writeHuffmanCode(output, code);
      } else if (token is MatchToken) {
        // Encode length
        final lengthCode = encodeLength(token.length);
        final literalCode = literalCodes[lengthCode.code]!;
        _writeHuffmanCode(output, literalCode);

        // Write extra bits for length
        if (lengthCode.extraBits > 0) {
          output.writeBits(lengthCode.extraValue, lengthCode.extraBits);
        }

        // Encode distance
        final distanceCode = encodeDistance(token.distance);
        final dcode = distanceCodes[distanceCode.code]!;
        _writeHuffmanCode(output, dcode);

        // Write extra bits for distance
        if (distanceCode.extraBits > 0) {
          output.writeBits(distanceCode.extraValue, distanceCode.extraBits);
        }
      }
    }

    // Write end-of-block symbol
    final endCode = literalCodes[endBlock]!;
    _writeHuffmanCode(output, endCode);
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
    final literalLengths =
        HuffmanTreeBuilder.computeLimitedCodeLengths(literalFrequencies, 15);
    final distanceLengths =
        HuffmanTreeBuilder.computeLimitedCodeLengths(distanceFrequencies, 15);

    // Generate canonical codes
    final literalCodes = HuffmanTreeBuilder.generateCanonicalCodes(literalLengths);
    final distanceCodes = HuffmanTreeBuilder.generateCanonicalCodes(distanceLengths);

    // Write tree descriptions
    _writeTreeDescriptions(output, literalLengths, distanceLengths);

    // Encode tokens using dynamic Huffman codes
    for (final token in tokens) {
      if (token is LiteralToken) {
        final code = literalCodes[token.value];
        if (code != null) {
          _writeHuffmanCode(output, code);
        }
      } else if (token is MatchToken) {
        // Encode length
        final lengthCode = encodeLength(token.length);
        final literalCode = literalCodes[lengthCode.code];
        if (literalCode != null) {
          _writeHuffmanCode(output, literalCode);
          if (lengthCode.extraBits > 0) {
            output.writeBits(lengthCode.extraValue, lengthCode.extraBits);
          }
        }

        // Encode distance
        final distanceCode = encodeDistance(token.distance);
        final dcode = distanceCodes[distanceCode.code];
        if (dcode != null) {
          _writeHuffmanCode(output, dcode);
          if (distanceCode.extraBits > 0) {
            output.writeBits(distanceCode.extraValue, distanceCode.extraBits);
          }
        }
      }
    }

    // Write end-of-block symbol
    final endCode = literalCodes[endBlock];
    if (endCode != null) {
      _writeHuffmanCode(output, endCode);
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
    final clLengths = HuffmanTreeBuilder.computeLimitedCodeLengths(codeLengthFrequencies, 7);
    final clCodes = HuffmanTreeBuilder.generateCanonicalCodes(clLengths);

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
      final code = clCodes[item.symbol];
      if (code != null) {
        _writeHuffmanCode(output, code);
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
        while (i + count < lengths.length && lengths[i + count] == 0 && count < 138) {
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

  /// Writes a Huffman code to the output stream
  void _writeHuffmanCode(BitStreamWriter output, HuffmanCode code) {
    // Emit code bits MSB-first into the LSB-first bitstream.
    for (var i = code.length - 1; i >= 0; i--) {
      final bit = (code.code >> i) & 1;
      output.writeBits(bit, 1);
    }
  }
}

/// Represents a run-length encoded code length symbol
class _CodeLengthSymbol {
  final int symbol;
  final int extraBits;
  final int extraValue;

  _CodeLengthSymbol(this.symbol, this.extraBits, this.extraValue);
}
