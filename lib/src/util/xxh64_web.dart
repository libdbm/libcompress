import 'dart:typed_data';

/// XXH64 hash algorithm implementation for JavaScript targets.
///
/// This is a fast, non-cryptographic hash function that produces a 64-bit hash.
/// Based on the XXHash specification: https://github.com/Cyan4973/xxHash
///
/// JavaScript numbers hold integers exactly only up to 2^53 and bitwise
/// operations are 32-bit, so every 64-bit value is kept as two unsigned 32-bit
/// halves, and products are formed from 16-bit pieces so that no intermediate
/// exceeds 2^53. The arithmetic is masked, so it is exact on the VM too
/// (native platforms use the `int`-based `xxh64_native.dart`). [BigInt] is
/// used only to convert the seed and the signed 64-bit result of [hash].
class XXH64 {
  /// Computes the XXH64 hash of the given data with an optional seed.
  ///
  /// [data] - The input data to hash
  /// [seed] - Optional seed value (default: 0)
  /// Returns the 64-bit hash as a signed integer, as the native version does
  /// (on JavaScript, values beyond 2^53 lose precision).
  static int hash(final Uint8List data, [final int seed = 0]) {
    _hash(data, seed);
    return _signed(_hi, _lo);
  }

  /// Computes the low 32 bits of XXH64.
  static int hashLow32(final Uint8List data, [final int seed = 0]) {
    _hash(data, seed);
    return _lo;
  }

  /// Computes XXH64 hash of a list of integers (treating each as a byte).
  static int hashFromList(final List<int> data, [final int seed = 0]) {
    return hash(Uint8List.fromList(data), seed);
  }

  /// Hashes [data] into [_hi]/[_lo].
  static void _hash(final Uint8List data, final int seed) {
    _split(seed);
    final seedHi = _hi;
    final seedLo = _lo;
    final length = data.length;
    var index = 0;

    if (length >= 32) {
      final limit = length - 32;
      _add(seedHi, seedLo, _p1h, _p1l);
      _add(_hi, _lo, _p2h, _p2l);
      var v1h = _hi, v1l = _lo;
      _add(seedHi, seedLo, _p2h, _p2l);
      var v2h = _hi, v2l = _lo;
      var v3h = seedHi, v3l = seedLo;
      _sub(seedHi, seedLo, _p1h, _p1l);
      var v4h = _hi, v4l = _lo;

      while (index <= limit) {
        _round(v1h, v1l, _high(data, index), _low(data, index));
        v1h = _hi;
        v1l = _lo;
        _round(v2h, v2l, _high(data, index + 8), _low(data, index + 8));
        v2h = _hi;
        v2l = _lo;
        _round(v3h, v3l, _high(data, index + 16), _low(data, index + 16));
        v3h = _hi;
        v3l = _lo;
        _round(v4h, v4l, _high(data, index + 24), _low(data, index + 24));
        v4h = _hi;
        v4l = _lo;
        index += 32;
      }
      _converge(v1h, v1l, v2h, v2l, v3h, v3l, v4h, v4l);
    } else {
      _add(seedHi, seedLo, _p5h, _p5l);
    }

    _add(_hi, _lo, 0, length & _mask);
    _finish(data, index, length);
  }

  /// Combines the four lanes into [_hi]/[_lo].
  static void _converge(
    final int v1h,
    final int v1l,
    final int v2h,
    final int v2l,
    final int v3h,
    final int v3l,
    final int v4h,
    final int v4l,
  ) {
    _rotate(v1h, v1l, 1);
    var hh = _hi, hl = _lo;
    _rotate(v2h, v2l, 7);
    _add(hh, hl, _hi, _lo);
    hh = _hi;
    hl = _lo;
    _rotate(v3h, v3l, 12);
    _add(hh, hl, _hi, _lo);
    hh = _hi;
    hl = _lo;
    _rotate(v4h, v4l, 18);
    _add(hh, hl, _hi, _lo);
    _merge(_hi, _lo, v1h, v1l);
    _merge(_hi, _lo, v2h, v2l);
    _merge(_hi, _lo, v3h, v3l);
    _merge(_hi, _lo, v4h, v4l);
  }

  /// Folds the tail `data[index..end)` into the hash in [_hi]/[_lo], then
  /// applies the final avalanche.
  static void _finish(final Uint8List data, int index, final int end) {
    var hh = _hi, hl = _lo;
    while (index <= end - 8) {
      _round(0, 0, _high(data, index), _low(data, index));
      hh ^= _hi;
      hl ^= _lo;
      _rotate(hh, hl, 27);
      _mul(_hi, _lo, _p1h, _p1l);
      _add(_hi, _lo, _p4h, _p4l);
      hh = _hi;
      hl = _lo;
      index += 8;
    }
    if (index <= end - 4) {
      _mul(0, _low(data, index), _p1h, _p1l);
      hh ^= _hi;
      hl ^= _lo;
      _rotate(hh, hl, 23);
      _mul(_hi, _lo, _p2h, _p2l);
      _add(_hi, _lo, _p3h, _p3l);
      hh = _hi;
      hl = _lo;
      index += 4;
    }
    while (index < end) {
      _mul(0, data[index], _p5h, _p5l);
      hh ^= _hi;
      hl ^= _lo;
      _rotate(hh, hl, 11);
      _mul(_hi, _lo, _p1h, _p1l);
      hh = _hi;
      hl = _lo;
      index++;
    }

    // Final avalanche: h ^= h >> 33; h *= P2; h ^= h >> 29; h *= P3;
    // h ^= h >> 32.
    hl ^= hh >> 1;
    _mul(hh, hl, _p2h, _p2l);
    hh = _hi;
    hl = _lo;
    hl ^= ((hl >> 29) | (hh << 3)) & _mask;
    hh ^= hh >> 29;
    _mul(hh, hl, _p3h, _p3l);
    _lo ^= _hi;
  }

  /// [_hi]/[_lo] = round(acc, input): (acc + input * P2) rotated 31, * P1.
  static void _round(
    final int accHi,
    final int accLo,
    final int inHi,
    final int inLo,
  ) {
    _mul(inHi, inLo, _p2h, _p2l);
    _add(accHi, accLo, _hi, _lo);
    _rotate(_hi, _lo, 31);
    _mul(_hi, _lo, _p1h, _p1l);
  }

  /// [_hi]/[_lo] = (acc ^ round(0, value)) * P1 + P4.
  static void _merge(
    final int accHi,
    final int accLo,
    final int valueHi,
    final int valueLo,
  ) {
    _round(0, 0, valueHi, valueLo);
    _mul(accHi ^ _hi, accLo ^ _lo, _p1h, _p1l);
    _add(_hi, _lo, _p4h, _p4l);
  }

  /// Splits [seed] into unsigned 64-bit halves in [_hi]/[_lo].
  static void _split(final int seed) {
    final value = BigInt.from(seed).toUnsigned(64);
    _hi = (value >> 32).toInt();
    _lo = (value & BigInt.from(_mask)).toInt();
  }

  /// The signed 64-bit value with halves [hi] and [lo], as the native hash
  /// returns it.
  static int _signed(final int hi, final int lo) =>
      ((BigInt.from(hi) << 32) | BigInt.from(lo)).toSigned(64).toInt();

  static int _low(final Uint8List data, final int offset) =>
      (data[offset] |
          (data[offset + 1] << 8) |
          (data[offset + 2] << 16) |
          (data[offset + 3] << 24)) &
      _mask;

  static int _high(final Uint8List data, final int offset) =>
      _low(data, offset + 4);
}

/// Incremental XXH64 — fed in pieces via [add], finalized with [digest] /
/// [digestLow32]. Produces the same result as [XXH64] over the concatenated
/// input regardless of chunking. Used to verify a whole-frame content checksum
/// without retaining the whole frame.
class Xxh64Sink {
  late final int _seedHi;
  late final int _seedLo;
  late int _v1h, _v1l, _v2h, _v2l, _v3h, _v3l, _v4h, _v4l;
  final Uint8List _stripe = Uint8List(32); // buffers a partial 32-byte stripe
  int _buffered = 0;
  int _total = 0;

  Xxh64Sink([final int seed = 0]) {
    _split(seed);
    _seedHi = _hi;
    _seedLo = _lo;
    _add(_seedHi, _seedLo, _p1h, _p1l);
    _add(_hi, _lo, _p2h, _p2l);
    _v1h = _hi;
    _v1l = _lo;
    _add(_seedHi, _seedLo, _p2h, _p2l);
    _v2h = _hi;
    _v2l = _lo;
    _v3h = _seedHi;
    _v3l = _seedLo;
    _sub(_seedHi, _seedLo, _p1h, _p1l);
    _v4h = _hi;
    _v4l = _lo;
  }

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
        _round32(_stripe, 0);
        _buffered = 0;
      }
    }
    while (end - i >= 32) {
      _round32(data, i);
      i += 32;
    }
    while (i < end) {
      _stripe[_buffered++] = data[i++];
    }
  }

  void _round32(final Uint8List d, final int o) {
    XXH64._round(_v1h, _v1l, XXH64._high(d, o), XXH64._low(d, o));
    _v1h = _hi;
    _v1l = _lo;
    XXH64._round(_v2h, _v2l, XXH64._high(d, o + 8), XXH64._low(d, o + 8));
    _v2h = _hi;
    _v2l = _lo;
    XXH64._round(_v3h, _v3l, XXH64._high(d, o + 16), XXH64._low(d, o + 16));
    _v3h = _hi;
    _v3l = _lo;
    XXH64._round(_v4h, _v4l, XXH64._high(d, o + 24), XXH64._low(d, o + 24));
    _v4h = _hi;
    _v4l = _lo;
  }

  /// Computes the digest into [_hi]/[_lo].
  void _digest() {
    if (_total >= 32) {
      XXH64._converge(_v1h, _v1l, _v2h, _v2l, _v3h, _v3l, _v4h, _v4l);
    } else {
      _add(_seedHi, _seedLo, _p5h, _p5l);
    }
    // The total length is added modulo 2^64; it never exceeds 2^53.
    _add(_hi, _lo, _total ~/ 0x100000000, _total & _mask);
    XXH64._finish(_stripe, 0, _buffered);
  }

  /// The full 64-bit XXH64 (signed, matching [XXH64.hash]).
  int digest() {
    _digest();
    return XXH64._signed(_hi, _lo);
  }

  /// The low 32 bits (matching [XXH64.hashLow32]) — Zstd's content checksum.
  int digestLow32() {
    _digest();
    return _lo;
  }
}

const int _mask = 0xFFFFFFFF;

// XXH64 primes as 32-bit halves.
const int _p1h = 0x9E3779B1, _p1l = 0x85EBCA87;
const int _p2h = 0xC2B2AE3D, _p2l = 0x27D4EB4F;
const int _p3h = 0x165667B1, _p3l = 0x9E3779F9;
const int _p4h = 0x85EBCA77, _p4l = 0xC2B2AE63;
const int _p5h = 0x27D4EB2F, _p5l = 0x165667C5;

// Result registers for the helpers below, so no operation allocates.
int _hi = 0;
int _lo = 0;

/// [_hi]/[_lo] = a + b (mod 2^64).
void _add(final int ah, final int al, final int bh, final int bl) {
  final low = al + bl;
  _lo = low & _mask;
  _hi = (ah + bh + (low > _mask ? 1 : 0)) & _mask;
}

/// [_hi]/[_lo] = a - b (mod 2^64).
void _sub(final int ah, final int al, final int bh, final int bl) {
  final low = al - bl;
  _lo = low & _mask;
  _hi = (ah - bh - (low < 0 ? 1 : 0)) & _mask;
}

/// [_hi]/[_lo] = a * b (mod 2^64), from 16-bit pieces so that every
/// intermediate stays below 2^53.
void _mul(final int ah, final int al, final int bh, final int bl) {
  final a0 = al & 0xFFFF, a1 = al >> 16;
  final b0 = bl & 0xFFFF, b1 = bl >> 16;
  final middle = a0 * b1 + a1 * b0; // < 2^33
  final low = a0 * b0 + (middle & 0xFFFF) * 0x10000; // < 2^33
  _lo = low & _mask;
  _hi =
      (a1 * b1 +
          middle ~/ 0x10000 +
          low ~/ 0x100000000 +
          _mulLow(ah, bl) +
          _mulLow(al, bh)) &
      _mask;
}

/// (x * y) mod 2^32 for unsigned 32-bit [x] and [y].
int _mulLow(final int x, final int y) {
  final x0 = x & 0xFFFF, x1 = x >> 16;
  final y0 = y & 0xFFFF, y1 = y >> 16;
  return (x0 * y0 + ((x1 * y0 + x0 * y1) & 0xFFFF) * 0x10000) & _mask;
}

/// [_hi]/[_lo] = the 64-bit value rotated left by [amount] (1-63).
void _rotate(final int hi, final int lo, final int amount) {
  var h = hi, l = lo, r = amount;
  if (r >= 32) {
    h = lo;
    l = hi;
    r -= 32;
  }
  if (r == 0) {
    _hi = h;
    _lo = l;
    return;
  }
  _hi = ((h << r) | (l >> (32 - r))) & _mask;
  _lo = ((l << r) | (h >> (32 - r))) & _mask;
}

/// Unsigned 64-bit halves of [seed], into [_hi]/[_lo].
void _split(final int seed) => XXH64._split(seed);
