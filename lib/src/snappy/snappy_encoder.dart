import 'dart:typed_data';
import 'dart:math' as math;

import '../util/lz77_common.dart';
import '../util/byte_utils.dart';
import '../util/varint.dart';

/// Native Dart implementation of Snappy compression
/// Based on the Snappy format specification
class SnappyEncoder {
  static const int _minNonLiteralBlockSize = 16;
  static const int _blockSize = 65536;
  static const int _maxHashTableSize = 16384;

  /// Compress data using Snappy algorithm
  static Uint8List compress(Uint8List uncompressed) {
    if (uncompressed.isEmpty) {
      return Uint8List.fromList([0]); // Just the length varint (0)
    }

    // Estimate compressed size (worst case: length header + uncompressed data + tags)
    final maxCompressedSize = _getMaxCompressedLength(uncompressed.length);
    final compressed = Uint8List(maxCompressedSize);
    int compressedIndex = 0;

    // Write uncompressed length as varint
    final lengthVarint = Varint.encode(uncompressed.length);
    for (final byte in lengthVarint) {
      compressed[compressedIndex++] = byte;
    }

    // Compress data in blocks
    int sourceIndex = 0;
    while (sourceIndex < uncompressed.length) {
      final blockEnd = math.min(sourceIndex + _blockSize, uncompressed.length);
      compressedIndex = _compressBlock(
        uncompressed,
        sourceIndex,
        blockEnd - sourceIndex,
        compressed,
        compressedIndex,
      );
      sourceIndex = blockEnd;
    }

    // Return trimmed result
    return Uint8List.sublistView(compressed, 0, compressedIndex);
  }

  /// Compress a single block of data
  static int _compressBlock(
    Uint8List input,
    int inputOffset,
    int inputLength,
    Uint8List output,
    int outputOffset,
  ) {
    final inputEnd = inputOffset + inputLength;
    final hashTable = List<int>.filled(_maxHashTableSize, -1);

    int ip = inputOffset;
    int op = outputOffset;
    int literalStart = ip;

    if (inputLength < _minNonLiteralBlockSize) {
      // Too small to compress, emit as literal
      op = _emitLiteral(input, literalStart, inputLength, output, op);
      return op;
    }

    // Main compression loop
    while (ip < inputEnd - 3) {
      // Calculate hash for current position
      final hash = LZ77Hash.snappyHash(input, ip);
      final candidate = hashTable[hash];
      hashTable[hash] = ip;

      // Check if we have a match
      if (candidate >= 0 &&
          candidate >= inputOffset &&
          ip - candidate < 65536 && // Max offset for 2-byte encoding
          ByteUtils.equals4Bytes(input, ip, candidate)) {
        // Emit any pending literal
        if (literalStart < ip) {
          op = _emitLiteral(input, literalStart, ip - literalStart, output, op);
        }

        // Find match length
        int matchLength = 4;
        while (ip + matchLength < inputEnd &&
            candidate + matchLength < inputEnd &&
            input[ip + matchLength] == input[candidate + matchLength]) {
          matchLength++;
        }

        // Emit copy
        op = _emitCopy(output, op, ip - candidate, matchLength);

        // Advance ip by match length
        ip += matchLength;
        literalStart = ip;

        // Heuristic: if the match is long, we can skip ahead, as it's
        // unlikely to find a better match starting just after the current one.
        if (matchLength > 16) {
          ip += (matchLength >> 4);
        }

        // Update hash table for the byte just before the new ip
        if (ip < inputEnd - 3) {
          hashTable[LZ77Hash.snappyHash(input, ip - 1)] = ip - 1;
        }
      } else {
        // No match, continue
        ip++;
      }
    }

    // Emit remaining literal
    if (literalStart < inputEnd) {
      op = _emitLiteral(
        input,
        literalStart,
        inputEnd - literalStart,
        output,
        op,
      );
    }

    return op;
  }

  /// Emit a literal sequence
  static int _emitLiteral(
    Uint8List input,
    int offset,
    int length,
    Uint8List output,
    int op,
  ) {
    if (length <= 60) {
      output[op++] = ((length - 1) << 2);
    } else if (length <= 256) {
      output[op++] = (60 << 2);
      output[op++] = length - 1;
    } else if (length <= 65536) {
      output[op++] = (61 << 2);
      output[op++] = (length - 1) & 0xff;
      output[op++] = ((length - 1) >> 8) & 0xff;
    } else {
      output[op++] = (62 << 2);
      output[op++] = (length - 1) & 0xff;
      output[op++] = ((length - 1) >> 8) & 0xff;
      output[op++] = ((length - 1) >> 16) & 0xff;
    }

    // Copy literal data
    output.setRange(op, op + length, input, offset);
    return op + length;
  }

  /// Emit a copy operation
  static int _emitCopy(Uint8List output, int op, int offset, int length) {
    // Emit copies, splitting if necessary
    while (length > 0) {
      final copyLength = math.min(length, 64);

      if (offset < 2048 && copyLength >= 4 && copyLength <= 11) {
        // Use 1-byte offset encoding
        output[op++] = 1 | ((copyLength - 4) << 2) | ((offset >> 8) << 5);
        output[op++] = offset & 0xff;
      } else if (offset < 65536) {
        // Use 2-byte offset encoding
        output[op++] = 2 | ((copyLength - 1) << 2);
        output[op++] = offset & 0xff;
        output[op++] = (offset >> 8) & 0xff;
      } else {
        // Use 4-byte offset encoding
        output[op++] = 3 | ((copyLength - 1) << 2);
        output[op++] = offset & 0xff;
        output[op++] = (offset >> 8) & 0xff;
        output[op++] = (offset >> 16) & 0xff;
        output[op++] = (offset >> 24) & 0xff;
      }

      length -= copyLength;
    }

    return op;
  }

  /// Get maximum compressed length for given input size
  static int _getMaxCompressedLength(int sourceLength) {
    // Worst case: varint length + uncompressed data + 1 tag per 60 bytes
    return 10 + sourceLength + (sourceLength ~/ 60) + 16;
  }
}
