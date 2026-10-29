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
  static const int _margin = 15;

  /// Compress data using Snappy algorithm
  static Uint8List compress(final Uint8List uncompressed) {
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
    // Allocate one unboxed table per operation, then reset it for each block.
    // Tiny inputs are literals and need no match table at all.
    // Sized to the largest block: small inputs clear a small table.
    final largest = math.min(uncompressed.length, _blockSize);
    final hashTable = uncompressed.length >= _minNonLiteralBlockSize
        ? Int32List(
            math.min(
              _maxHashTableSize,
              1 << math.max(8, (largest - 1).bitLength),
            ),
          )
        : null;
    while (sourceIndex < uncompressed.length) {
      final blockEnd = math.min(sourceIndex + _blockSize, uncompressed.length);
      compressedIndex = _compressBlock(
        uncompressed,
        sourceIndex,
        blockEnd - sourceIndex,
        compressed,
        compressedIndex,
        hashTable,
      );
      sourceIndex = blockEnd;
    }

    // Return trimmed result
    return Uint8List.fromList(
      Uint8List.sublistView(compressed, 0, compressedIndex),
    );
  }

  /// Compress a single block of data
  static int _compressBlock(
    final Uint8List input,
    final int inputOffset,
    final int inputLength,
    final Uint8List output,
    final int outputOffset,
    final Int32List? hashTable,
  ) {
    final inputEnd = inputOffset + inputLength;

    int op = outputOffset;
    int literalStart = inputOffset;

    if (inputLength < _minNonLiteralBlockSize) {
      // Too small to compress, emit as literal
      op = _emitLiteral(input, literalStart, inputLength, output, op);
      return op;
    }

    // As the reference, every entry starts at the block start, so a
    // candidate is always a position in the block.
    final table = hashTable!..fillRange(0, hashTable.length, inputOffset);
    // The hash spans the full table; smaller tables keep its low bits.
    final mask = table.length - 1;
    // No match starts in the last bytes (the reference kInputMarginBytes).
    final limit = inputEnd - _margin;

    var ip = inputOffset + 1;
    search:
    while (true) {
      // Look further apart the longer no match is found: one byte at a time
      // for the first 32 misses, then two, and so on.
      var skip = 32;
      var next = ip;
      var candidate = inputOffset;
      do {
        ip = next;
        final step = skip >> 5;
        skip += step;
        next = ip + step;
        if (next > limit) break search;
        final hash = LZ77Hash.snappyHash(input, ip) & mask;
        candidate = table[hash];
        table[hash] = ip;
      } while (!ByteUtils.equals4Bytes(input, ip, candidate));

      op = _emitLiteral(input, literalStart, ip - literalStart, output, op);

      // Emit copies for as long as another match starts where one ends.
      do {
        var length = 4;
        while (ip + length < inputEnd &&
            input[ip + length] == input[candidate + length]) {
          length++;
        }
        op = _emitCopy(output, op, ip - candidate, length);
        ip += length;
        literalStart = ip;
        if (ip >= limit) break search;
        table[LZ77Hash.snappyHash(input, ip - 1) & mask] = ip - 1;
        final hash = LZ77Hash.snappyHash(input, ip) & mask;
        candidate = table[hash];
        table[hash] = ip;
      } while (ByteUtils.equals4Bytes(input, ip, candidate));
      ip++;
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
    final Uint8List input,
    final int offset,
    final int length,
    final Uint8List output,
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

  /// Emit a copy operation, split as the reference does: pieces of 64 while
  /// at least 68 bytes remain, then 60 if over 64 remain, so the last piece
  /// holds at least 4 bytes. Offsets in a 64 KB block fit two bytes.
  static int _emitCopy(
    final Uint8List output,
    int op,
    final int offset,
    int length,
  ) {
    while (length >= 68) {
      op = _emitShortCopy(output, op, offset, 64);
      length -= 64;
    }
    if (length > 64) {
      op = _emitShortCopy(output, op, offset, 60);
      length -= 60;
    }
    return _emitShortCopy(output, op, offset, length);
  }

  /// Emits one copy of at most 64 bytes, in the 1-byte offset form when it
  /// fits.
  static int _emitShortCopy(
    final Uint8List output,
    int op,
    final int offset,
    final int length,
  ) {
    if (length < 12 && offset < 2048) {
      output[op++] = 1 | ((length - 4) << 2) | ((offset >> 8) << 5);
      output[op++] = offset & 0xff;
    } else {
      output[op++] = 2 | ((length - 1) << 2);
      output[op++] = offset & 0xff;
      output[op++] = (offset >> 8) & 0xff;
    }
    return op;
  }

  /// Get maximum compressed length for given input size
  static int _getMaxCompressedLength(final int sourceLength) {
    // Worst case: varint length + uncompressed data + 1 tag per 60 bytes
    return 10 + sourceLength + (sourceLength ~/ 60) + 16;
  }
}
