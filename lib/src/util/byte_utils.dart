import 'dart:typed_data';

/// Utility functions for reading and writing multi-byte integers
///
/// Provides little-endian and big-endian read/write operations for various
/// integer sizes. Used across multiple compression formats (LZ4, Snappy, GZIP).
class ByteUtils {
  /// Reads a 16-bit unsigned integer in little-endian byte order
  static int readUint16LE(Uint8List data, int offset) {
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

  /// Reads a 32-bit unsigned integer in little-endian byte order
  ///
  /// Uses multiplication instead of bit shifts to avoid signed integer issues
  /// on JavaScript platforms where `x << 24` produces a negative signed int32.
  static int readUint32LE(Uint8List data, int offset) {
    return data[offset] +
        data[offset + 1] * 0x100 +
        data[offset + 2] * 0x10000 +
        data[offset + 3] * 0x1000000;
  }

  /// Reads a 64-bit unsigned integer in little-endian byte order
  ///
  /// Note: Dart's int is 64-bit signed, so values >= 2^63 will appear negative
  /// when interpreted as a signed integer. For bitwise operations this is fine,
  /// but for numeric comparisons use [readBigUint64LE] instead.
  static int readUint64LE(Uint8List data, int offset) {
    final lo = readUint32LE(data, offset);
    final hi = readUint32LE(data, offset + 4);
    // Use multiplication to avoid potential bit shift issues with large values
    return lo + hi * 0x100000000;
  }

  /// Writes a 16-bit unsigned integer in little-endian byte order (appends)
  static void writeUint16LE(List<int> out, int value) {
    out.add(value & 0xff);
    out.add((value >> 8) & 0xff);
  }

  /// Writes a 16-bit unsigned integer in little-endian byte order at offset
  static void writeUint16LEAt(Uint8List out, int offset, int value) {
    out[offset] = value & 0xff;
    out[offset + 1] = (value >> 8) & 0xff;
  }

  /// Writes a 32-bit unsigned integer in little-endian byte order (appends)
  static void writeUint32LE(List<int> out, int value) {
    out.add(value & 0xff);
    out.add((value >> 8) & 0xff);
    out.add((value >> 16) & 0xff);
    out.add((value >> 24) & 0xff);
  }

  /// Writes a 32-bit unsigned integer in little-endian byte order at offset
  static void writeUint32LEAt(Uint8List out, int offset, int value) {
    out[offset] = value & 0xff;
    out[offset + 1] = (value >> 8) & 0xff;
    out[offset + 2] = (value >> 16) & 0xff;
    out[offset + 3] = (value >> 24) & 0xff;
  }

  /// Writes a 64-bit unsigned integer in little-endian byte order (appends)
  static void writeUint64LE(List<int> out, int value) {
    writeUint32LE(out, value & 0xffffffff);
    writeUint32LE(out, (value >> 32) & 0xffffffff);
  }

  /// Reads a 16-bit unsigned integer in big-endian byte order
  static int readUint16BE(Uint8List data, int offset) {
    return (data[offset] << 8) | data[offset + 1];
  }

  /// Reads a 32-bit unsigned integer in big-endian byte order
  ///
  /// Uses multiplication instead of bit shifts to avoid signed integer issues
  /// on JavaScript platforms where `x << 24` produces a negative signed int32.
  static int readUint32BE(Uint8List data, int offset) {
    return data[offset] * 0x1000000 +
        data[offset + 1] * 0x10000 +
        data[offset + 2] * 0x100 +
        data[offset + 3];
  }

  /// Writes a 16-bit unsigned integer in big-endian byte order
  static void writeUint16BE(List<int> out, int value) {
    out.add((value >> 8) & 0xff);
    out.add(value & 0xff);
  }

  /// Writes a 32-bit unsigned integer in big-endian byte order
  static void writeUint32BE(List<int> out, int value) {
    out.add((value >> 24) & 0xff);
    out.add((value >> 16) & 0xff);
    out.add((value >> 8) & 0xff);
    out.add(value & 0xff);
  }

  /// Checks if four consecutive bytes are equal at two positions
  ///
  /// Used for fast match detection in LZ77-based compression.
  /// Returns false if either position would read beyond data bounds.
  static bool equals4Bytes(Uint8List data, int pos1, int pos2) {
    if (pos1 + 3 >= data.length || pos2 + 3 >= data.length) {
      return false;
    }
    return data[pos1] == data[pos2] &&
        data[pos1 + 1] == data[pos2 + 1] &&
        data[pos1 + 2] == data[pos2 + 2] &&
        data[pos1 + 3] == data[pos2 + 3];
  }

}
