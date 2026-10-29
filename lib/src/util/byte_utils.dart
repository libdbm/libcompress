import 'dart:typed_data';

/// Utility functions for reading and writing multi-byte integers
///
/// Provides little-endian and big-endian read/write operations for various
/// integer sizes. Used across multiple compression formats (LZ4, Snappy, GZIP).
class ByteUtils {
  /// Reads a 16-bit unsigned integer in little-endian byte order
  static int readUint16LE(final Uint8List data, final int offset) {
    return data[offset] | (data[offset + 1] << 8);
  }

  /// Returns the low 32 bits of `left * right`, treating both as unsigned
  /// 32-bit values, without allocating.
  ///
  /// A full 32x32 product is up to 2^64 and loses precision on JavaScript
  /// (doubles are exact only below 2^53). This splits `left` into 16-bit
  /// halves so every intermediate stays below 2^53, giving the exact result
  /// on both native and dart2js without the cost of [BigInt].
  static int mul32(final int left, final int right) {
    final low = (left & 0xFFFF) * right;
    final high = ((left >> 16) & 0xFFFF) * right;
    return (low + (high & 0xFFFF) * 0x10000) % 0x100000000;
  }

  /// Reads a [count]-byte little-endian unsigned integer using multiplication,
  /// so it is exact and non-negative on both the VM and dart2js (unlike
  /// `byte << 56`, which truncates/signs on JS).
  ///
  /// Sizes that need more than 6 bytes (>= 2^48, ~281 TB) cannot be a
  /// legitimate decompressed-size field and exceed any sane limit, so the top
  /// bytes are required to be zero — otherwise a [FormatException] is thrown
  /// (rather than silently producing a wrong or negative value that could slip
  /// past a maxSize check).
  static int readUintLE(
    final Uint8List data,
    final int offset,
    final int count,
  ) {
    var value = 0;
    var multiplier = 1;
    final exact = count < 6 ? count : 6;
    for (var i = 0; i < exact; i++) {
      value += data[offset + i] * multiplier;
      multiplier *= 256;
    }
    for (var i = exact; i < count; i++) {
      if (data[offset + i] != 0) {
        throw const FormatException(
          'Multi-byte size field exceeds the supported range (2^48)',
        );
      }
    }
    return value;
  }

  /// Reads a 32-bit unsigned integer in little-endian byte order
  ///
  /// Uses multiplication instead of bit shifts to avoid signed integer issues
  /// on JavaScript platforms where `x << 24` produces a negative signed int32.
  static int readUint32LE(final Uint8List data, final int offset) {
    return data[offset] +
        data[offset + 1] * 0x100 +
        data[offset + 2] * 0x10000 +
        data[offset + 3] * 0x1000000;
  }

  /// Writes a 16-bit unsigned integer in little-endian byte order at offset
  static void writeUint16LEAt(
    final Uint8List out,
    final int offset,
    final int value,
  ) {
    out[offset] = value & 0xff;
    out[offset + 1] = (value >> 8) & 0xff;
  }

  /// [value] as 4 little-endian bytes.
  static Uint8List uint32LE(final int value) => Uint8List.fromList([
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ]);

  /// Writes a 32-bit unsigned integer in little-endian byte order at offset
  static void writeUint32LEAt(
    final Uint8List out,
    final int offset,
    final int value,
  ) {
    out[offset] = value & 0xff;
    out[offset + 1] = (value >> 8) & 0xff;
    out[offset + 2] = (value >> 16) & 0xff;
    out[offset + 3] = (value >> 24) & 0xff;
  }

  /// Checks if four consecutive bytes are equal at two positions
  ///
  /// Used for fast match detection in LZ77-based compression.
  /// Returns false if either position would read beyond data bounds.
  static bool equals4Bytes(
    final Uint8List data,
    final int pos1,
    final int pos2,
  ) {
    if (pos1 + 3 >= data.length || pos2 + 3 >= data.length) {
      return false;
    }
    return data[pos1] == data[pos2] &&
        data[pos1 + 1] == data[pos2 + 1] &&
        data[pos1 + 2] == data[pos2 + 2] &&
        data[pos1 + 3] == data[pos2 + 3];
  }
}
