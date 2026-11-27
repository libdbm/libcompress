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

  /// Room the fast loop keeps before the end of the input: a tag and a
  /// literal of up to 60 bytes read as eight words (65 bytes).
  static const int _inputSlack = 65;

  /// Room the fast loop keeps before the end of the output: a copy of up to
  /// 64 bytes written as words writes at most 7 bytes past its end (71
  /// bytes); doubling a short pattern first writes less than that.
  static const int _outputSlack = 71;

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
    final end = compressed.length;
    final bound = end - _inputSlack;
    final room = actualUncompressedLength - _outputSlack;
    while (sourceIndex < end) {
      // The fast loop, while far from both ends: no element here can read or
      // write past either buffer (see [_inputSlack] and [_outputSlack]), so
      // only a copy's offset is checked. A literal of more than 60 bytes,
      // which carries extra length bytes, and every element near either end
      // take the checked path below.
      if (wide) {
        fast:
        while (sourceIndex <= bound && targetIndex <= room) {
          final tag = compressed[sourceIndex];
          final int length;
          final int offset;
          switch (tag & 3) {
            case 0:
              final size = (tag >> 2) + 1;
              if (size > 60) break fast;
              // 8 bytes at a time; bytes written past the literal are
              // overwritten later.
              words.setUint64(
                targetIndex,
                input.getUint64(sourceIndex + 1, Endian.little),
                Endian.little,
              );
              for (var i = 8; i < size; i += 8) {
                words.setUint64(
                  targetIndex + i,
                  input.getUint64(sourceIndex + 1 + i, Endian.little),
                  Endian.little,
                );
              }
              sourceIndex += size + 1;
              targetIndex += size;
              continue;
            case 1:
              length = 4 + ((tag >> 2) & 7);
              offset = ((tag & 0xe0) << 3) | compressed[sourceIndex + 1];
              sourceIndex += 2;
            case 2:
              length = (tag >> 2) + 1;
              offset = input.getUint16(sourceIndex + 1, Endian.little);
              sourceIndex += 3;
            default:
              length = (tag >> 2) + 1;
              offset = input.getUint32(sourceIndex + 1, Endian.little);
              sourceIndex += 5;
          }
          if (offset == 0 || offset > targetIndex) {
            throw SnappyFormatException(
              'Invalid offset: $offset at position $targetIndex',
            );
          }
          final from = targetIndex - offset;
          final stop = targetIndex + length;
          if (offset >= 8) {
            // Each word read was written before, and bytes written past the
            // copy are overwritten later.
            words.setUint64(
              targetIndex,
              words.getUint64(from, Endian.little),
              Endian.little,
            );
            for (var i = 8; i < length; i += 8) {
              words.setUint64(
                targetIndex + i,
                words.getUint64(from + i, Endian.little),
                Endian.little,
              );
            }
          } else {
            // A pattern shorter than a word is doubled by word copies from
            // [from] until it spans one: each copy leaves a whole number of
            // periods valid, and its tail is overwritten by the next. Then
            // words are copied at that distance, a multiple of the period.
            var to = targetIndex;
            while (to - from < 8) {
              words.setUint64(
                to,
                words.getUint64(from, Endian.little),
                Endian.little,
              );
              to += to - from;
            }
            for (var at = from; to < stop; to += 8, at += 8) {
              words.setUint64(
                to,
                words.getUint64(at, Endian.little),
                Endian.little,
              );
            }
          }
          targetIndex = stop;
        }
      }

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
