import 'dart:math' as math;
import 'dart:typed_data';
import '../util/bit_stream.dart';
import 'deflate_common.dart';
import 'huffman_tables.dart';

/// DEFLATE decompression decoder implementing RFC 1951
///
/// Decompresses DEFLATE-compressed data by parsing block headers,
/// decoding Huffman codes, and reconstructing the original data.
class DeflateDecoder {
  /// Maximum output size (null = unlimited)
  final int? maxSize;

  /// Creates a DEFLATE decoder with optional size limit
  DeflateDecoder({this.maxSize});

  /// Decodes DEFLATE-compressed data
  ///
  /// Returns the decompressed data as a byte array. Throws DeflateFormatException
  /// if the input is invalid or corrupted, or if maxSize is exceeded.
  Uint8List decompress(Uint8List data) {
    return decompressWithPosition(data).$1;
  }

  /// Decodes DEFLATE-compressed data and returns bytes consumed
  ///
  /// Returns a record containing:
  /// - The decompressed data as a byte array
  /// - The number of bytes consumed from input (aligned to byte boundary)
  ///
  /// This is useful for GZIP concatenated members where you need to know
  /// where the next member starts.
  (Uint8List, int) decompressWithPosition(Uint8List data) {
    try {
      return _decode(data);
    } on DeflateFormatException {
      rethrow;
    } on StateError catch (e) {
      throw DeflateFormatException('Malformed DEFLATE stream: ${e.message}');
    } on RangeError catch (e) {
      throw DeflateFormatException('Malformed DEFLATE stream: $e');
    }
  }

  (Uint8List, int) _decode(Uint8List data) {
    final input = BitStreamReader(data);
    final output = <int>[];

    var isFinal = false;

    while (!isFinal) {
      // Read block header
      isFinal = input.readBits(1) == 1;
      final blockType = input.readBits(2);

      switch (blockType) {
        case 0: // Stored block
          _readStoredBlock(input, output);
          break;
        case 1: // Fixed Huffman block
          _readFixedHuffmanBlock(input, output);
          break;
        case 2: // Dynamic Huffman block
          _readDynamicHuffmanBlock(input, output);
          break;
        default:
          throw DeflateFormatException('Invalid block type: $blockType');
      }
    }

    // Align to byte boundary to get accurate consumed count
    input.flushToByte();

    return (Uint8List.fromList(output), input.bytePosition);
  }

  /// Check output size limit and throw if exceeded
  void _checkLimit(final List<int> output) {
    final limit = maxSize;
    if (limit != null && output.length > limit) {
      throw DeflateFormatException(
        'Decompressed size ${output.length} exceeds limit $limit',
      );
    }
  }

  /// Reads a stored (uncompressed) block
  void _readStoredBlock(final BitStreamReader input, final List<int> output) {
    // Skip to byte boundary
    input.flushToByte();

    // Read length and verify one's complement
    final len = input.readBits(8) | (input.readBits(8) << 8);
    final nlen = input.readBits(8) | (input.readBits(8) << 8);

    if ((len ^ nlen) != 0xFFFF) {
      throw DeflateFormatException('Stored block length mismatch');
    }

    // Check size limit before reading block
    final limit = maxSize;
    if (limit != null && output.length + len > limit) {
      throw DeflateFormatException(
        'Decompressed size would exceed limit $limit',
      );
    }

    // Read literal bytes
    for (var i = 0; i < len; i++) {
      output.add(input.readBits(8));
    }
  }

  /// Reads a block compressed with fixed Huffman codes
  void _readFixedHuffmanBlock(
    final BitStreamReader input,
    final List<int> output,
  ) {
    // Reuse the shared fixed Huffman decode tables (RFC 1951 constants)
    _decodeHuffmanBlock(input, output, fixedLiteralDecoder, fixedDistanceDecoder);
  }

  /// Reads a block compressed with dynamic Huffman codes
  void _readDynamicHuffmanBlock(
    final BitStreamReader input,
    final List<int> output,
  ) {
    // Read tree descriptions
    final hlit = input.readBits(5) + 257;
    final hdist = input.readBits(5) + 1;
    final hclen = input.readBits(4) + 4;

    // Read code length code lengths
    final lengths = List<int>.filled(19, 0);
    for (var i = 0; i < hclen; i++) {
      lengths[codeLengthOrder[i]] = input.readBits(3);
    }

    // Build code length decoder
    final decoder = buildDecoder(lengths);

    // Decode literal/length and distance code lengths
    final codeLengths = <int>[];
    final totalLength = hlit + hdist;
    while (codeLengths.length < totalLength) {
      final symbol = _decodeSymbol(input, decoder);

      if (symbol < 16) {
        // Literal code length
        codeLengths.add(symbol);
      } else if (symbol == 16) {
        // Repeat previous code length 3-6 times
        if (codeLengths.isEmpty) {
          throw DeflateFormatException('Invalid repeat code at start');
        }
        final prev = codeLengths.last;
        var repeat = input.readBits(2) + 3;
        repeat = math.min(repeat, totalLength - codeLengths.length);
        for (var i = 0; i < repeat; i++) {
          codeLengths.add(prev);
        }
      } else if (symbol == 17) {
        // Repeat zero 3-10 times
        var repeat = input.readBits(3) + 3;
        repeat = math.min(repeat, totalLength - codeLengths.length);
        for (var i = 0; i < repeat; i++) {
          codeLengths.add(0);
        }
      } else if (symbol == 18) {
        // Repeat zero 11-138 times
        var repeat = input.readBits(7) + 11;
        repeat = math.min(repeat, totalLength - codeLengths.length);
        for (var i = 0; i < repeat; i++) {
          codeLengths.add(0);
        }
      } else {
        throw DeflateFormatException('Invalid code length symbol: $symbol');
      }
    }

    // Split into literal/length and distance code lengths
    final litLenLengths = codeLengths.sublist(0, hlit);
    final distLengths = codeLengths.sublist(hlit, hlit + hdist);

    // Build decoders
    final litLenDecoder = buildDecoder(litLenLengths);
    final distDecoder = buildDecoder(distLengths);

    _decodeHuffmanBlock(input, output, litLenDecoder, distDecoder);
  }

  /// Decodes a Huffman-coded block
  void _decodeHuffmanBlock(
    final BitStreamReader input,
    final List<int> output,
    final HuffmanDecoder literalDecoder,
    final HuffmanDecoder distanceDecoder,
  ) {
    // Check limit periodically - more frequently when limit is small
    final limit = maxSize;
    final checkInterval = limit != null && limit < 4096 ? 1 : 4096;
    var nextCheck = output.length + checkInterval;

    while (true) {
      final symbol = _decodeSymbol(input, literalDecoder);

      if (symbol < 256) {
        // Literal byte
        output.add(symbol);

        // Periodic size check
        if (output.length >= nextCheck) {
          _checkLimit(output);
          nextCheck = output.length + checkInterval;
        }
      } else if (symbol == endBlock) {
        // End of block
        break;
      } else if (symbol <= 285) {
        // Length/distance pair
        final code = symbol - 257;

        // Decode length
        var length = lengthBase[code];
        final extra = lengthExtraBits[code];
        if (extra > 0) {
          length += input.readBits(extra);
        }

        // Check size limit before copy
        final limit = maxSize;
        if (limit != null && output.length + length > limit) {
          throw DeflateFormatException(
            'Decompressed size would exceed limit $limit',
          );
        }

        // Decode distance
        final distanceCode = _decodeSymbol(input, distanceDecoder);
        if (distanceCode >= 30) {
          throw DeflateFormatException('Invalid distance code: $distanceCode');
        }

        var distance = distanceBase[distanceCode];
        final distanceExtra = distanceExtraBits[distanceCode];
        if (distanceExtra > 0) {
          distance += input.readBits(distanceExtra);
        }

        // Copy from history
        if (distance > output.length) {
          throw DeflateFormatException(
            'Distance exceeds output size: distance=$distance, '
            'outputLength=${output.length}, length=$length, distanceCode=$distanceCode',
          );
        }

        final start = output.length - distance;
        // Use bulk copy for non-overlapping matches (distance >= length)
        if (distance >= length) {
          output.addAll(output.sublist(start, start + length));
        } else {
          // Overlapping copy: must copy byte-by-byte
          for (var i = 0; i < length; i++) {
            output.add(output[start + i]);
          }
        }
      } else {
        throw DeflateFormatException('Invalid literal/length symbol: $symbol');
      }
    }
  }

  /// Decodes a single symbol from the input using a Huffman decoder
  int _decodeSymbol(BitStreamReader input, HuffmanDecoder decoder) {
    var code = 0;
    var bits = 0;

    while (bits < 15) {
      // Bits are stored LSB-first in bytes, but code bits are read MSB-first.
      final bit = input.readBits(1);
      code = (code << 1) | bit;
      bits++;

      // Check if this code exists
      final symbol = decoder.decode(code, bits);
      if (symbol != null) {
        return symbol;
      }
    }

    throw DeflateFormatException('Invalid Huffman code');
  }
}
