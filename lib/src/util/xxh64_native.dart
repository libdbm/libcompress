import 'dart:typed_data';

/// XXH64 hash algorithm implementation for native platforms.
///
/// This is a fast, non-cryptographic hash function that produces a 64-bit hash.
/// Based on the XXHash specification: https://github.com/Cyan4973/xxHash
///
/// Native `int` arithmetic wraps modulo 2^64, which is exactly the arithmetic
/// XXH64 is defined in, so no masking is needed. JavaScript targets use the
/// [BigInt]-based `xxh64_web.dart` with the same API.
class XXH64 {
  // XXH64 constants (two's-complement 64-bit literals)
  static const int _prime1 = 0x9E3779B185EBCA87;
  static const int _prime2 = 0xC2B2AE3D27D4EB4F;
  static const int _prime3 = 0x165667B19E3779F9;
  static const int _prime4 = 0x85EBCA77C2B2AE63;
  static const int _prime5 = 0x27D4EB2F165667C5;

  /// Computes the XXH64 hash of the given data with an optional seed.
  ///
  /// [data] - The input data to hash
  /// [seed] - Optional seed value (default: 0)
  /// Returns the 64-bit hash as a (signed) 64-bit integer
  static int hash(final Uint8List data, [final int seed = 0]) {
    final lanes = ByteData.sublistView(data);
    final length = data.length;
    int h64;
    var index = 0;

    if (length >= 32) {
      final limit = length - 32;
      var v1 = seed + _prime1 + _prime2;
      var v2 = seed + _prime2;
      var v3 = seed;
      var v4 = seed - _prime1;

      while (index <= limit) {
        v1 = _round(v1, lanes.getUint64(index, Endian.little));
        v2 = _round(v2, lanes.getUint64(index + 8, Endian.little));
        v3 = _round(v3, lanes.getUint64(index + 16, Endian.little));
        v4 = _round(v4, lanes.getUint64(index + 24, Endian.little));
        index += 32;
      }
      h64 = _converge(v1, v2, v3, v4);
    } else {
      h64 = seed + _prime5;
    }

    return _finish(h64 + length, lanes, index, length);
  }

  /// Computes the low 32 bits of XXH64.
  static int hashLow32(final Uint8List data, [final int seed = 0]) {
    return hash(data, seed) & 0xFFFFFFFF;
  }

  /// Computes XXH64 hash of a list of integers (treating each as a byte).
  static int hashFromList(final List<int> data, [final int seed = 0]) {
    return hash(Uint8List.fromList(data), seed);
  }

  static int _rotate(final int value, final int amount) =>
      (value << amount) | (value >>> (64 - amount));

  static int _round(final int acc, final int input) =>
      _rotate(acc + input * _prime2, 31) * _prime1;

  static int _merge(final int acc, final int value) =>
      (acc ^ _round(0, value)) * _prime1 + _prime4;

  /// Folds the four stripe accumulators into one value.
  static int _converge(final int v1, final int v2, final int v3, final int v4) {
    var h64 = _rotate(v1, 1) + _rotate(v2, 7) + _rotate(v3, 12);
    h64 += _rotate(v4, 18);
    h64 = _merge(h64, v1);
    h64 = _merge(h64, v2);
    h64 = _merge(h64, v3);
    return _merge(h64, v4);
  }

  /// Consumes the tail `[index, end)` of [lanes] into [h64] and applies the
  /// final avalanche.
  static int _finish(int h64, final ByteData lanes, int index, final int end) {
    while (index <= end - 8) {
      h64 ^= _round(0, lanes.getUint64(index, Endian.little));
      h64 = _rotate(h64, 27) * _prime1 + _prime4;
      index += 8;
    }
    if (index <= end - 4) {
      h64 ^= lanes.getUint32(index, Endian.little) * _prime1;
      h64 = _rotate(h64, 23) * _prime2 + _prime3;
      index += 4;
    }
    while (index < end) {
      h64 ^= lanes.getUint8(index) * _prime5;
      h64 = _rotate(h64, 11) * _prime1;
      index++;
    }

    h64 ^= h64 >>> 33;
    h64 *= _prime2;
    h64 ^= h64 >>> 29;
    h64 *= _prime3;
    h64 ^= h64 >>> 32;
    return h64;
  }
}

/// Incremental XXH64 — fed in pieces via [add], finalized with [digest] /
/// [digestLow32]. Produces the same result as [XXH64] over the concatenated
/// input regardless of chunking. Used to verify a whole-frame content checksum
/// without retaining the whole frame.
class Xxh64Sink {
  final int _seed;
  int _v1;
  int _v2;
  int _v3;
  int _v4;
  final Uint8List _stripe = Uint8List(32); // buffers a partial 32-byte stripe
  late final ByteData _stripeLanes = ByteData.sublistView(_stripe);
  int _buffered = 0;
  int _total = 0;

  Xxh64Sink([final int seed = 0])
    : _seed = seed,
      _v1 = seed + XXH64._prime1 + XXH64._prime2,
      _v2 = seed + XXH64._prime2,
      _v3 = seed,
      _v4 = seed - XXH64._prime1;

  /// Feeds [count] bytes of [data] starting at [offset] (defaults to all).
  void add(final Uint8List data, [final int offset = 0, final int? count]) {
    var i = offset;
    final end = offset + (count ?? data.length - offset);
    _total += end - i;

    if (_buffered > 0) {
      while (_buffered < 32 && i < end) {
        _stripe[_buffered++] = data[i++];
      }
      if (_buffered == 32) {
        _round32(_stripeLanes, 0);
        _buffered = 0;
      }
    }
    if (end - i >= 32) {
      final lanes = ByteData.sublistView(data);
      while (end - i >= 32) {
        _round32(lanes, i);
        i += 32;
      }
    }
    while (i < end) {
      _stripe[_buffered++] = data[i++];
    }
  }

  void _round32(final ByteData lanes, final int o) {
    _v1 = XXH64._round(_v1, lanes.getUint64(o, Endian.little));
    _v2 = XXH64._round(_v2, lanes.getUint64(o + 8, Endian.little));
    _v3 = XXH64._round(_v3, lanes.getUint64(o + 16, Endian.little));
    _v4 = XXH64._round(_v4, lanes.getUint64(o + 24, Endian.little));
  }

  /// The full 64-bit XXH64 (signed, matching [XXH64.hash]).
  int digest() {
    final h64 = _total >= 32
        ? XXH64._converge(_v1, _v2, _v3, _v4)
        : _seed + XXH64._prime5;
    return XXH64._finish(h64 + _total, _stripeLanes, 0, _buffered);
  }

  /// The low 32 bits (matching [XXH64.hashLow32]) — Zstd's content checksum.
  int digestLow32() => digest() & 0xFFFFFFFF;
}
