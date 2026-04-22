import 'dart:typed_data';

/// Common utilities for LZ77-based compression algorithms
///
/// LZ77 is a sliding window compression algorithm used by GZIP, LZ4, Snappy,
/// and many other formats. This module provides shared data structures and
/// utilities for implementing LZ77 variants.

/// Represents a match found during LZ77 compression
///
/// A match is a sequence of bytes that appears earlier in the input.
/// The encoder replaces the sequence with a (length, distance) pair.
class Match {
  /// Length of the matching sequence in bytes
  final int length;

  /// Distance back to the start of the match
  ///
  /// Distance of 1 means the previous byte, distance of 2 means two bytes back, etc.
  final int distance;

  const Match(this.length, this.distance);

  @override
  String toString() => 'Match(length: $length, distance: $distance)';

  @override
  bool operator ==(Object other) =>
      other is Match && length == other.length && distance == other.distance;

  @override
  int get hashCode => Object.hash(length, distance);
}

/// Hash function constants used across LZ77 implementations
class LZ77Hash {
  /// LZ4 hash multiplier (Knuth's multiplicative hash constant)
  static const int lz4Multiplier = 2654435761;

  /// Snappy hash multiplier
  static const int snappyMultiplier = 0x1e35a7bd;

  static final BigInt _u32Mask = BigInt.from(0xFFFFFFFF);

  /// Computes LZ4-style hash of 4 bytes
  ///
  /// Uses Knuth's multiplicative hashing for fast, good distribution.
  static int lz4Hash(Uint8List data, int pos, int shift) {
    if (pos + 3 >= data.length) {
      return 0;
    }
    final value =
        data[pos] |
        (data[pos + 1] << 8) |
        (data[pos + 2] << 16) |
        (data[pos + 3] << 24);
    return (_mul32(value, lz4Multiplier) >> shift) & 0xFFFF;
  }

  /// Computes Snappy-style hash of 4 bytes
  static int snappyHash(Uint8List data, int pos) {
    if (pos + 3 >= data.length) {
      return 0;
    }
    final value =
        data[pos] |
        (data[pos + 1] << 8) |
        (data[pos + 2] << 16) |
        (data[pos + 3] << 24);
    return (_mul32(value, snappyMultiplier) >> 16) & 0x3FFF;
  }

  /// Computes GZIP/DEFLATE-style hash of 3 bytes
  ///
  /// Uses simple XOR combination with bit shifts.
  static int deflateHash(Uint8List data, int pos, int tableSizeBits) {
    if (pos + 2 >= data.length) {
      return 0;
    }
    final hash = ((data[pos] << 10) ^ (data[pos + 1] << 5) ^ data[pos + 2]);
    return hash & ((1 << tableSizeBits) - 1);
  }
}

int _mul32(int left, int right) {
  return (BigInt.from(left) * BigInt.from(right) & LZ77Hash._u32Mask).toInt();
}

/// Constants for LZ77-based algorithms
class LZ77Constants {
  /// LZ4 constants
  static const int lz4MinMatch = 4;
  static const int lz4MaxDistance = 65535;

  /// Snappy constants
  static const int snappyMinMatch = 4;
  static const int snappyMaxDistance = 65536;

  /// DEFLATE constants
  static const int deflateMinMatch = 3;
  static const int deflateMaxMatch = 258;
  static const int deflateMaxDistance = 32768;
}
