import 'dart:typed_data';

import 'byte_utils.dart';

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
  bool operator ==(final Object other) =>
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

  /// Computes LZ4-style hash of 4 bytes
  ///
  /// Uses Knuth's multiplicative hashing for fast, good distribution.
  static int lz4Hash(final Uint8List data, final int pos, final int shift) {
    if (pos + 3 >= data.length) {
      return 0;
    }
    final value =
        data[pos] |
        (data[pos + 1] << 8) |
        (data[pos + 2] << 16) |
        (data[pos + 3] << 24);
    return (ByteUtils.mul32(value, lz4Multiplier) >> shift) & 0xFFFF;
  }

  /// Computes Snappy-style hash of 4 bytes
  static int snappyHash(final Uint8List data, final int pos) {
    if (pos + 3 >= data.length) {
      return 0;
    }
    final value =
        data[pos] |
        (data[pos + 1] << 8) |
        (data[pos + 2] << 16) |
        (data[pos + 3] << 24);
    return (ByteUtils.mul32(value, snappyMultiplier) >> 16) & 0x3FFF;
  }
}
