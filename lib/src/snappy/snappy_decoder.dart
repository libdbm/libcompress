import 'dart:typed_data';

import '../exceptions.dart';
import '../util/byte_utils.dart';
import '../util/varint.dart';

// Re-export exception from centralized location
export '../exceptions.dart' show SnappyFormatException;

/// Default decompression cap for the Snappy codecs, matching the other codecs'
/// 256 MB default. `null` may be passed for unlimited (trusted input only).
const int snappyDefaultMaxDecompressedSize = 256 * 1024 * 1024;

/// Native Dart implementation of Snappy decompression
/// Based on the Snappy format specification and jsnappy Java implementation
class SnappyDecoder {
  /// Maximum allowed uncompressed size (default: 100MB)
  /// Can be overridden by passing a different value to decompress()
  static const int defaultMaxSize = 100 * 1024 * 1024;

  /// Decompress Snappy compressed data
  ///
  /// [maxUncompressedSize] sets a safety limit on the declared uncompressed
  /// length to prevent memory exhaustion attacks. Defaults to 100MB.
  static Uint8List decompress(
    final Uint8List compressed, {
    final int? maxUncompressedSize = defaultMaxSize,
    int? uncompressedLength,
  }) {
    if (compressed.isEmpty) {
      throw SnappyFormatException('Cannot decompress empty input');
    }

    int sourceIndex = 0;
    int targetIndex = 0;

    // Read uncompressed length (varint format) from the beginning of the stream
    final int actualUncompressedLength;
    if (uncompressedLength != null) {
      actualUncompressedLength = uncompressedLength;
    } else {
      final VarintResult result;
      try {
        // Snappy's uncompressed-length preamble is at most 32 bits (5 bytes).
        result = Varint.decode(compressed, sourceIndex, maxBytes: 5);
      } on FormatException catch (e) {
        throw SnappyFormatException('Invalid Snappy length prefix: ${e.message}');
      }
      actualUncompressedLength = result.value;
      sourceIndex += result.bytesRead;
    }

    // Enforce maximum uncompressed size to prevent memory exhaustion
    // (null = unlimited).
    if (maxUncompressedSize != null &&
        actualUncompressedLength > maxUncompressedSize) {
      throw SnappyFormatException(
        'Uncompressed size $actualUncompressedLength exceeds maximum $maxUncompressedSize',
      );
    }

    // Preallocate output buffer with exact size
    final uncompressed = Uint8List(actualUncompressedLength);

    // Decompress data
    while (sourceIndex < compressed.length) {
      final tag = compressed[sourceIndex];
      final tagType = tag & 3;

      switch (tagType) {
        case 0: // Literal
          int literalLength = (tag >> 2) & 0x3f;
          sourceIndex++;

          // Handle extended literal lengths
          if (literalLength == 60) {
            if (sourceIndex >= compressed.length) {
              throw SnappyFormatException('Truncated literal length at offset $sourceIndex');
            }
            literalLength = compressed[sourceIndex++] + 1;
          } else if (literalLength == 61) {
            if (sourceIndex + 2 > compressed.length) {
              throw SnappyFormatException('Truncated literal length at offset $sourceIndex');
            }
            literalLength =
                (compressed[sourceIndex] | (compressed[sourceIndex + 1] << 8)) +
                1;
            sourceIndex += 2;
          } else if (literalLength == 62) {
            if (sourceIndex + 3 > compressed.length) {
              throw SnappyFormatException('Truncated literal length at offset $sourceIndex');
            }
            literalLength =
                (compressed[sourceIndex] |
                    (compressed[sourceIndex + 1] << 8) |
                    (compressed[sourceIndex + 2] << 16)) +
                1;
            sourceIndex += 3;
          } else if (literalLength == 63) {
            if (sourceIndex + 4 > compressed.length) {
              throw SnappyFormatException('Truncated literal length at offset $sourceIndex');
            }
            // Use ByteUtils for JS-safe 32-bit read (avoids signed overflow)
            literalLength = ByteUtils.readUint32LE(compressed, sourceIndex) + 1;
            sourceIndex += 4;
          } else {
            literalLength++;
          }

          // Copy literal data
          if (sourceIndex + literalLength > compressed.length) {
            throw SnappyFormatException('Literal extends past end of input');
          }
          if (targetIndex + literalLength > actualUncompressedLength) {
            throw SnappyFormatException('Literal write exceeds output buffer');
          }
          uncompressed.setRange(
            targetIndex,
            targetIndex + literalLength,
            compressed,
            sourceIndex,
          );
          sourceIndex += literalLength;
          targetIndex += literalLength;
          break;

        case 1: // Copy with 1-byte offset
          if (sourceIndex + 2 > compressed.length) {
            throw SnappyFormatException('Truncated copy tag at offset $sourceIndex');
          }
          final length = 4 + ((tag >> 2) & 7);
          final offset = ((tag & 0xe0) << 3) | compressed[sourceIndex + 1];
          sourceIndex += 2;

          // Validate offset for 1-byte encoding (11-bit max = 2047)
          if (offset > 2047) {
            throw SnappyFormatException(
                'Offset $offset exceeds 1-byte encoding max (2047)');
          }

          if (targetIndex + length > actualUncompressedLength) {
            throw SnappyFormatException('Copy write exceeds output buffer');
          }
          _copyBytes(uncompressed, targetIndex, offset, length);
          targetIndex += length;
          break;

        case 2: // Copy with 2-byte offset
          if (sourceIndex + 3 > compressed.length) {
            throw SnappyFormatException('Truncated copy tag at offset $sourceIndex');
          }
          final length = ((tag >> 2) & 0x3f) + 1;
          final offset =
              compressed[sourceIndex + 1] | (compressed[sourceIndex + 2] << 8);
          sourceIndex += 3;

          // Validate offset for 2-byte encoding (16-bit max = 65535)
          if (offset > 65535) {
            throw SnappyFormatException(
                'Offset $offset exceeds 2-byte encoding max (65535)');
          }

          if (targetIndex + length > actualUncompressedLength) {
            throw SnappyFormatException('Copy write exceeds output buffer');
          }
          _copyBytes(uncompressed, targetIndex, offset, length);
          targetIndex += length;
          break;

        case 3: // Copy with 4-byte offset
          if (sourceIndex + 5 > compressed.length) {
            throw SnappyFormatException('Truncated copy tag at offset $sourceIndex');
          }
          final length = ((tag >> 2) & 0x3f) + 1;
          // Use ByteUtils for JS-safe 32-bit read (avoids signed overflow)
          final offset = ByteUtils.readUint32LE(compressed, sourceIndex + 1);
          sourceIndex += 5;

          if (targetIndex + length > actualUncompressedLength) {
            throw SnappyFormatException('Copy write exceeds output buffer');
          }
          _copyBytes(uncompressed, targetIndex, offset, length);
          targetIndex += length;
          break;
      }
    }

    if (targetIndex != actualUncompressedLength) {
      throw SnappyFormatException(
        'Decompressed size mismatch: expected $actualUncompressedLength, got $targetIndex',
      );
    }

    return uncompressed;
  }

  /// Copy bytes from earlier in the output
  static void _copyBytes(
    Uint8List output,
    int targetIndex,
    int offset,
    int length,
  ) {
    if (offset <= 0) {
      throw SnappyFormatException('Invalid offset: $offset at position $targetIndex');
    }
    if (offset > targetIndex) {
      throw SnappyFormatException('Invalid offset: $offset at position $targetIndex');
    }
    if (targetIndex + length > output.length) {
      throw SnappyFormatException('Copy write exceeds output buffer');
    }

    final sourceIndex = targetIndex - offset;

    // Handle overlapping copies (when offset < length)
    if (offset >= length) {
      // Non-overlapping copy - can use setRange for efficiency
      output.setRange(targetIndex, targetIndex + length, output, sourceIndex);
    } else if (offset == 1) {
      // Special case: repeat single byte
      final byte = output[sourceIndex];
      output.fillRange(targetIndex, targetIndex + length, byte);
    } else {
      // Overlapping copy - must copy byte by byte
      for (int i = 0; i < length; i++) {
        output[targetIndex + i] = output[sourceIndex + (i % offset)];
      }
    }
  }
}
