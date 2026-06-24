import 'dart:typed_data';

import 'byte_utils.dart';

/// XXH32 hash algorithm implementation as used by Zstandard.
///
/// This is a fast, non-cryptographic hash function that produces a 32-bit hash.
/// Based on the XXHash specification: https://github.com/Cyan4973/xxHash
class XXH32 {
  // XXH32 constants
  static const int _prime1 = 0x9E3779B1;
  static const int _prime2 = 0x85EBCA77;
  static const int _prime3 = 0xC2B2AE3D;
  static const int _prime4 = 0x27D4EB2F;
  static const int _prime5 = 0x165667B1;

  /// Computes the XXH32 hash of the given data with an optional seed.
  ///
  /// [data] - The input data to hash
  /// [seed] - Optional seed value (default: 0)
  /// Returns the 32-bit hash as an unsigned integer
  static int hash(Uint8List data, [int seed = 0]) {
    final length = data.length;
    int h32;
    int index = 0;

    if (length >= 16) {
      final limit = length - 16;
      int v1 = (seed + _prime1 + _prime2) & 0xFFFFFFFF;
      int v2 = (seed + _prime2) & 0xFFFFFFFF;
      int v3 = (seed + 0) & 0xFFFFFFFF;
      int v4 = (seed - _prime1) & 0xFFFFFFFF;

      while (index <= limit) {
        v1 = _round(v1, _readLittleEndian32(data, index));
        index += 4;
        v2 = _round(v2, _readLittleEndian32(data, index));
        index += 4;
        v3 = _round(v3, _readLittleEndian32(data, index));
        index += 4;
        v4 = _round(v4, _readLittleEndian32(data, index));
        index += 4;
      }

      h32 =
          (_rotateLeft(v1, 1) +
              _rotateLeft(v2, 7) +
              _rotateLeft(v3, 12) +
              _rotateLeft(v4, 18)) &
          0xFFFFFFFF;
    } else {
      h32 = (seed + _prime5) & 0xFFFFFFFF;
    }

    h32 = (h32 + length) & 0xFFFFFFFF;

    // Process remaining bytes in 4-byte chunks
    while (index <= length - 4) {
      h32 =
          (h32 + _mul32(_readLittleEndian32(data, index), _prime3)) &
          0xFFFFFFFF;
      h32 = _mul32(_rotateLeft(h32, 17), _prime4);
      index += 4;
    }

    // Process remaining bytes individually
    while (index < length) {
      h32 = (h32 + _mul32(data[index], _prime5)) & 0xFFFFFFFF;
      h32 = _mul32(_rotateLeft(h32, 11), _prime1);
      index++;
    }

    // Final mixing
    h32 ^= h32 >> 15;
    h32 = _mul32(h32, _prime2);
    h32 ^= h32 >> 13;
    h32 = _mul32(h32, _prime3);
    h32 ^= h32 >> 16;

    return h32;
  }

  /// Computes XXH32 hash of a list of integers (treating each as a byte).
  static int hashFromList(List<int> data, [int seed = 0]) {
    return hash(Uint8List.fromList(data), seed);
  }

  static int _round(int acc, int input) {
    acc = (acc + _mul32(input, _prime2)) & 0xFFFFFFFF;
    acc = _rotateLeft(acc, 13);
    acc = _mul32(acc, _prime1);
    return acc;
  }

  static int _mul32(int left, int right) => ByteUtils.mul32(left, right);

  static int _rotateLeft(int value, int amount) {
    value &= 0xFFFFFFFF;
    return ((value << amount) | (value >> (32 - amount))) & 0xFFFFFFFF;
  }

  static int _readLittleEndian32(Uint8List data, int offset) {
    return data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
  }
}

/// Incremental XXH32 — fed in pieces via [add], finalized with [digest].
///
/// Produces the same result as [XXH32.hash] over the concatenated input,
/// regardless of how it was chunked. Used by streaming codecs to verify a
/// whole-content checksum without retaining the whole content.
class Xxh32Sink {
  static const int _mask = 0xFFFFFFFF;

  final int _seed;
  int _v1;
  int _v2;
  int _v3;
  int _v4;
  final Uint8List _stripe = Uint8List(16); // buffers a partial 16-byte stripe
  int _buffered = 0;
  int _total = 0;

  Xxh32Sink([final int seed = 0])
    : _seed = seed,
      _v1 = (seed + XXH32._prime1 + XXH32._prime2) & _mask,
      _v2 = (seed + XXH32._prime2) & _mask,
      _v3 = seed & _mask,
      _v4 = (seed - XXH32._prime1) & _mask;

  /// Feeds [count] bytes of [data] starting at [offset] (defaults to all).
  void add(final Uint8List data, [final int offset = 0, final int? count]) {
    var i = offset;
    final end = offset + (count ?? data.length - offset);
    _total += end - i;

    if (_buffered > 0) {
      while (_buffered < 16 && i < end) {
        _stripe[_buffered++] = data[i++];
      }
      if (_buffered == 16) {
        _round16(_stripe, 0);
        _buffered = 0;
      }
    }
    while (end - i >= 16) {
      _round16(data, i);
      i += 16;
    }
    while (i < end) {
      _stripe[_buffered++] = data[i++];
    }
  }

  void _round16(final Uint8List d, final int o) {
    _v1 = XXH32._round(_v1, XXH32._readLittleEndian32(d, o));
    _v2 = XXH32._round(_v2, XXH32._readLittleEndian32(d, o + 4));
    _v3 = XXH32._round(_v3, XXH32._readLittleEndian32(d, o + 8));
    _v4 = XXH32._round(_v4, XXH32._readLittleEndian32(d, o + 12));
  }

  /// Returns the XXH32 of everything fed so far.
  int digest() {
    var h32 = _total >= 16
        ? (XXH32._rotateLeft(_v1, 1) +
                  XXH32._rotateLeft(_v2, 7) +
                  XXH32._rotateLeft(_v3, 12) +
                  XXH32._rotateLeft(_v4, 18)) &
              _mask
        : (_seed + XXH32._prime5) & _mask;

    h32 = (h32 + _total) & _mask;

    var index = 0;
    while (index <= _buffered - 4) {
      h32 =
          (h32 +
              XXH32._mul32(
                XXH32._readLittleEndian32(_stripe, index),
                XXH32._prime3,
              )) &
          _mask;
      h32 = XXH32._mul32(XXH32._rotateLeft(h32, 17), XXH32._prime4);
      index += 4;
    }
    while (index < _buffered) {
      h32 = (h32 + XXH32._mul32(_stripe[index], XXH32._prime5)) & _mask;
      h32 = XXH32._mul32(XXH32._rotateLeft(h32, 11), XXH32._prime1);
      index++;
    }

    h32 ^= h32 >> 15;
    h32 = XXH32._mul32(h32, XXH32._prime2);
    h32 ^= h32 >> 13;
    h32 = XXH32._mul32(h32, XXH32._prime3);
    h32 ^= h32 >> 16;
    return h32;
  }
}
