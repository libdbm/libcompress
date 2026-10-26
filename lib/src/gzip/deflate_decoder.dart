import 'dart:typed_data';
import '../util/growable_buffer.dart';
import 'deflate_common.dart';
import 'deflate_reader.dart';
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
    final input = DeflateReader(data);
    // Uint8List-backed (doubling) buffer instead of a boxed growable <int>;
    // back-references use copyFromHistory rather than sublist allocations.
    final output = GrowableBuffer();

    var isFinal = false;

    while (!isFinal) {
      // Read block header
      isFinal = input.read(1) == 1;
      final blockType = input.read(2);

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
    input.align();

    return (output.toBytes(), input.position);
  }

  /// Check output size limit and throw if exceeded
  void _checkLimit(final GrowableBuffer output) {
    final limit = maxSize;
    if (limit != null && output.length > limit) {
      throw DeflateFormatException(
        'Decompressed size ${output.length} exceeds limit $limit',
      );
    }
  }

  /// Reads a stored (uncompressed) block
  void _readStoredBlock(
    final DeflateReader input,
    final GrowableBuffer output,
  ) {
    // Skip to byte boundary
    input.align();

    // Read length and verify one's complement
    final len = input.read(16);
    final nlen = input.read(16);

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

    // Copy the literal bytes in bulk
    output.addBytes(input.take(len));
  }

  /// Reads a block compressed with fixed Huffman codes
  void _readFixedHuffmanBlock(
    final DeflateReader input,
    final GrowableBuffer output,
  ) {
    // Reuse the shared fixed Huffman decode tables (RFC 1951 constants)
    _decodeHuffmanBlock(
      input,
      output,
      fixedLiteralDecoder,
      fixedDistanceDecoder,
    );
  }

  /// Reads a block compressed with dynamic Huffman codes
  void _readDynamicHuffmanBlock(
    final DeflateReader input,
    final GrowableBuffer output,
  ) {
    final (literals, distances) = readDynamicTables(input);
    _decodeHuffmanBlock(input, output, literals, distances);
  }

  /// Decodes a Huffman-coded block
  void _decodeHuffmanBlock(
    final DeflateReader input,
    final GrowableBuffer output,
    final HuffmanDecoder literalDecoder,
    final HuffmanDecoder distanceDecoder,
  ) {
    // Check limit periodically - more frequently when limit is small
    final limit = maxSize;
    final checkInterval = limit != null && limit < 4096 ? 1 : 4096;
    var nextCheck = output.length + checkInterval;

    while (true) {
      final symbol = input.decode(literalDecoder);

      if (symbol < 256) {
        // Literal byte
        output.addByte(symbol);

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
          length += input.read(extra);
        }

        // Check size limit before copy
        final limit = maxSize;
        if (limit != null && output.length + length > limit) {
          throw DeflateFormatException(
            'Decompressed size would exceed limit $limit',
          );
        }

        // Decode distance
        final distanceCode = input.decode(distanceDecoder);
        if (distanceCode >= 30) {
          throw DeflateFormatException('Invalid distance code: $distanceCode');
        }

        var distance = distanceBase[distanceCode];
        final distanceExtra = distanceExtraBits[distanceCode];
        if (distanceExtra > 0) {
          distance += input.read(distanceExtra);
        }

        // Copy from history
        if (distance > output.length) {
          throw DeflateFormatException(
            'Distance exceeds output size: distance=$distance, '
            'outputLength=${output.length}, length=$length, distanceCode=$distanceCode',
          );
        }

        // Copy from history (handles overlapping copies internally).
        output.copyFromHistory(distance, length);
      } else {
        throw DeflateFormatException('Invalid literal/length symbol: $symbol');
      }
    }
  }
}
