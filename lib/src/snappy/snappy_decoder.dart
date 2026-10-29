import 'dart:typed_data';

import '../exceptions.dart';
import '../util/byte_utils.dart';
import '../util/varint.dart';
import '../util/platform.dart';
import '../compression_options.dart' as options;

// Re-export exception from centralized location
export '../exceptions.dart' show SnappyFormatException;

class SnappyDecoder {
  /// Maximum allowed uncompressed size, shared with the codecs (256 MB).
  /// Can be overridden by passing a different value to decompress()
  static const int defaultMaxSize = options.defaultMaxSize;

  /// Largest output a single body byte can contribute: a 3-byte copy element
  /// emits at most 64 bytes, and no element does better.
  static const int _maxExpansionNumerator = 64;
  static const int _maxExpansionDenominator = 3;

  /// Decompress Snappy compressed data
  ///
  /// [maxUncompressedSize] sets a safety limit on the declared uncompressed
  /// length to prevent memory exhaustion attacks. Defaults to 256MB. A
  /// declared length larger than the body could ever expand to is rejected
  /// before the output is allocated.
  static Uint8List decompress(
    final Uint8List compressed, {
    final int? maxUncompressedSize = defaultMaxSize,
  }) {
    if (compressed.isEmpty) {
      throw SnappyFormatException('Cannot decompress empty input');
    }

    int sourceIndex = 0;
    int targetIndex = 0;

    // Read uncompressed length (varint format) from the beginning of the stream
    final VarintResult result;
    try {
      // Snappy's uncompressed-length preamble is at most 32 bits (5 bytes).
      result = Varint.decode(compressed, sourceIndex, maxBytes: 5);
    } on FormatException catch (e) {
      throw SnappyFormatException('Invalid Snappy length prefix: ${e.message}');
    }
    final actualUncompressedLength = result.value;
    sourceIndex += result.bytesRead;

    // Enforce maximum uncompressed size to prevent memory exhaustion
    // (null = unlimited).
    if (maxUncompressedSize != null &&
        actualUncompressedLength > maxUncompressedSize) {
      throw LimitException(maxUncompressedSize);
    }

    // Reject a declared length the body cannot produce before allocating it,
    // so a few bytes of input cannot force a large allocation.
    final expansion =
        (compressed.length - sourceIndex) *
        _maxExpansionNumerator ~/
        _maxExpansionDenominator;
    if (actualUncompressedLength > expansion) {
      throw SnappyFormatException(
        'Declared length $actualUncompressedLength exceeds the maximum '
        'expansion ($expansion) of ${compressed.length - sourceIndex} bytes',
      );
    }

    // Preallocate output buffer with exact size
    final uncompressed = Uint8List(actualUncompressedLength);
    final words = ByteData.sublistView(uncompressed);
    final input = ByteData.sublistView(compressed);

    // Decompress data
    while (sourceIndex < compressed.length) {
      final tag = compressed[sourceIndex];
      final int length;
      final int offset;

      switch (tag & 3) {
        case 0: // Literal
          int literalLength = (tag >> 2) & 0x3f;
          sourceIndex++;

          // Handle extended literal lengths
          if (literalLength == 60) {
            if (sourceIndex >= compressed.length) {
              throw SnappyFormatException(
                'Truncated literal length at offset $sourceIndex',
              );
            }
            literalLength = compressed[sourceIndex++] + 1;
          } else if (literalLength == 61) {
            if (sourceIndex + 2 > compressed.length) {
              throw SnappyFormatException(
                'Truncated literal length at offset $sourceIndex',
              );
            }
            literalLength =
                (compressed[sourceIndex] | (compressed[sourceIndex + 1] << 8)) +
                1;
            sourceIndex += 2;
          } else if (literalLength == 62) {
            if (sourceIndex + 3 > compressed.length) {
              throw SnappyFormatException(
                'Truncated literal length at offset $sourceIndex',
              );
            }
            literalLength =
                (compressed[sourceIndex] |
                    (compressed[sourceIndex + 1] << 8) |
                    (compressed[sourceIndex + 2] << 16)) +
                1;
            sourceIndex += 3;
          } else if (literalLength == 63) {
            if (sourceIndex + 4 > compressed.length) {
              throw SnappyFormatException(
                'Truncated literal length at offset $sourceIndex',
              );
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
          if (wide &&
              literalLength <= 64 &&
              targetIndex + literalLength + 8 <= actualUncompressedLength &&
              sourceIndex + literalLength + 8 <= compressed.length) {
            // 8 bytes at a time; bytes written past the literal are
            // overwritten later.
            for (var i = 0; i < literalLength; i += 8) {
              words.setUint64(
                targetIndex + i,
                input.getUint64(sourceIndex + i, Endian.little),
                Endian.little,
              );
            }
          } else if (literalLength <= 16) {
            for (var i = 0; i < literalLength; i++) {
              uncompressed[targetIndex + i] = compressed[sourceIndex + i];
            }
          } else {
            uncompressed.setRange(
              targetIndex,
              targetIndex + literalLength,
              compressed,
              sourceIndex,
            );
          }
          sourceIndex += literalLength;
          targetIndex += literalLength;
          continue;

        case 1: // Copy with 1-byte offset
          if (sourceIndex + 2 > compressed.length) {
            throw SnappyFormatException(
              'Truncated copy tag at offset $sourceIndex',
            );
          }
          length = 4 + ((tag >> 2) & 7);
          offset = ((tag & 0xe0) << 3) | compressed[sourceIndex + 1];
          sourceIndex += 2;

        case 2: // Copy with 2-byte offset
          if (sourceIndex + 3 > compressed.length) {
            throw SnappyFormatException(
              'Truncated copy tag at offset $sourceIndex',
            );
          }
          length = ((tag >> 2) & 0x3f) + 1;
          offset =
              compressed[sourceIndex + 1] | (compressed[sourceIndex + 2] << 8);
          sourceIndex += 3;

        default: // 3: Copy with 4-byte offset
          if (sourceIndex + 5 > compressed.length) {
            throw SnappyFormatException(
              'Truncated copy tag at offset $sourceIndex',
            );
          }
          length = ((tag >> 2) & 0x3f) + 1;
          // Use ByteUtils for JS-safe 32-bit read (avoids signed overflow)
          offset = ByteUtils.readUint32LE(compressed, sourceIndex + 1);
          sourceIndex += 5;
      }

      // Copy [length] bytes from [offset] back, checked once per copy.
      if (offset == 0 || offset > targetIndex) {
        throw SnappyFormatException(
          'Invalid offset: $offset at position $targetIndex',
        );
      }
      if (targetIndex + length > actualUncompressedLength) {
        throw SnappyFormatException('Copy write exceeds output buffer');
      }
      final from = targetIndex - offset;
      if (wide &&
          offset >= 8 &&
          targetIndex + length + 8 <= actualUncompressedLength) {
        // 8 bytes at a time: each word read was written before, and bytes
        // written past the copy are overwritten later.
        for (var i = 0; i < length; i += 8) {
          words.setUint64(
            targetIndex + i,
            words.getUint64(from + i, Endian.little),
            Endian.little,
          );
        }
      } else if (offset >= length) {
        // Short copies, which are most of them, are cheaper as a loop than a
        // setRange call.
        if (length <= 16) {
          for (var i = 0; i < length; i++) {
            uncompressed[targetIndex + i] = uncompressed[from + i];
          }
        } else {
          uncompressed.setRange(
            targetIndex,
            targetIndex + length,
            uncompressed,
            from,
          );
        }
      } else if (offset == 1) {
        uncompressed.fillRange(
          targetIndex,
          targetIndex + length,
          uncompressed[from],
        );
      } else {
        // Forward copying reads bytes written earlier in this same match,
        // naturally repeating the pattern without a modulo per byte.
        for (var i = 0; i < length; i++) {
          uncompressed[targetIndex + i] = uncompressed[from + i];
        }
      }
      targetIndex += length;
    }

    if (targetIndex != actualUncompressedLength) {
      throw SnappyFormatException(
        'Decompressed size mismatch: expected $actualUncompressedLength, got $targetIndex',
      );
    }

    return uncompressed;
  }
}
