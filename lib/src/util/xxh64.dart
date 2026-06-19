import 'dart:typed_data';

/// XXH64 hash algorithm implementation.
///
/// This is a fast, non-cryptographic hash function that produces a 64-bit hash.
/// Based on the XXHash specification: https://github.com/Cyan4973/xxHash
class XXH64 {
  // XXH64 constants
  static final BigInt _prime1 = BigInt.parse(
    '9E3779B185EBCA87',
    radix: 16,
  );
  static final BigInt _prime2 = BigInt.parse(
    'C2B2AE3D27D4EB4F',
    radix: 16,
  );
  static final BigInt _prime3 = BigInt.parse(
    '165667B19E3779F9',
    radix: 16,
  );
  static final BigInt _prime4 = BigInt.parse(
    '85EBCA77C2B2AE63',
    radix: 16,
  );
  static final BigInt _prime5 = BigInt.parse(
    '27D4EB2F165667C5',
    radix: 16,
  );
  static final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;
  static final BigInt _mask32 = (BigInt.one << 32) - BigInt.one;
  static final BigInt _signBit64 = BigInt.one << 63;

  /// Computes the XXH64 hash of the given data with an optional seed.
  ///
  /// [data] - The input data to hash
  /// [seed] - Optional seed value (default: 0)
  /// Returns the 64-bit hash as an unsigned integer
  static int hash(Uint8List data, [int seed = 0]) {
    return _toSignedInt64(_hashBigInt(data, BigInt.from(seed)));
  }

  /// Computes the low 32 bits of XXH64.
  static int hashLow32(Uint8List data, [int seed = 0]) {
    return (_hashBigInt(data, BigInt.from(seed)) & _mask32).toInt();
  }

  static BigInt _hashBigInt(Uint8List data, BigInt seed) {
    final length = data.length;
    BigInt h64;
    int index = 0;

    if (length >= 32) {
      final limit = length - 32;
      BigInt v1 = _add64(seed, _add64(_prime1, _prime2));
      BigInt v2 = _add64(seed, _prime2);
      BigInt v3 = seed;
      BigInt v4 = _sub64(seed, _prime1);

      while (index <= limit) {
        v1 = _round64(v1, _readLittleEndian64(data, index));
        index += 8;
        v2 = _round64(v2, _readLittleEndian64(data, index));
        index += 8;
        v3 = _round64(v3, _readLittleEndian64(data, index));
        index += 8;
        v4 = _round64(v4, _readLittleEndian64(data, index));
        index += 8;
      }

      h64 = _add64(
        _add64(
          _add64(_rotateLeft64(v1, 1), _rotateLeft64(v2, 7)),
          _add64(_rotateLeft64(v3, 12), _rotateLeft64(v4, 18)),
        ),
        BigInt.zero,
      );

      h64 = _mergeRound64(h64, v1);
      h64 = _mergeRound64(h64, v2);
      h64 = _mergeRound64(h64, v3);
      h64 = _mergeRound64(h64, v4);
    } else {
      h64 = _add64(seed, _prime5);
    }

    h64 = _add64(h64, BigInt.from(length));

    // Process remaining bytes in 8-byte chunks
    while (index <= length - 8) {
      BigInt k1 = _readLittleEndian64(data, index);
      k1 = _mult64(k1, _prime2);
      k1 = _rotateLeft64(k1, 31);
      k1 = _mult64(k1, _prime1);

      h64 ^= k1;
      h64 = _add64(_mult64(_rotateLeft64(h64, 27), _prime1), _prime4);
      index += 8;
    }

    // Process remaining bytes in 4-byte chunks
    while (index <= length - 4) {
      BigInt k1 = BigInt.from(_readLittleEndian32(data, index));
      k1 = _mult64(k1, _prime1);
      h64 ^= k1;
      h64 = _add64(_mult64(_rotateLeft64(h64, 23), _prime2), _prime3);
      index += 4;
    }

    // Process remaining bytes individually
    while (index < length) {
      final k1 = _mult64(BigInt.from(data[index]), _prime5);
      h64 ^= k1;
      h64 = _mult64(_rotateLeft64(h64, 11), _prime1);
      index++;
    }

    // Final avalanche
    h64 ^= h64 >> 33;
    h64 = _mult64(h64, _prime2);
    h64 ^= h64 >> 29;
    h64 = _mult64(h64, _prime3);
    h64 ^= h64 >> 32;

    return h64;
  }

  /// Computes XXH64 hash of a list of integers (treating each as a byte).
  static int hashFromList(List<int> data, [int seed = 0]) {
    return hash(Uint8List.fromList(data), seed);
  }

  static int _toSignedInt64(BigInt value) {
    final unsigned = value & _mask64;
    if (unsigned >= _signBit64) {
      return (unsigned - (_mask64 + BigInt.one)).toInt();
    }
    return unsigned.toInt();
  }

  static BigInt _add64(BigInt a, BigInt b) {
    return (a + b) & _mask64;
  }

  static BigInt _sub64(BigInt a, BigInt b) {
    return (a - b) & _mask64;
  }

  static BigInt _mult64(BigInt a, BigInt b) {
    return (a * b) & _mask64;
  }

  static BigInt _round64(BigInt acc, BigInt input) {
    acc = _add64(acc, _mult64(input, _prime2));
    acc = _rotateLeft64(acc, 31);
    acc = _mult64(acc, _prime1);
    return acc;
  }

  static BigInt _mergeRound64(BigInt acc, BigInt val) {
    val = _mult64(val, _prime2);
    val = _rotateLeft64(val, 31);
    val = _mult64(val, _prime1);

    acc ^= val;
    acc = _add64(_mult64(acc, _prime1), _prime4);
    return acc;
  }

  static BigInt _rotateLeft64(BigInt value, int amount) {
    value &= _mask64;
    return ((value << amount) | (value >> (64 - amount))) & _mask64;
  }

  static int _readLittleEndian32(Uint8List data, int offset) {
    return data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
  }

  static BigInt _readLittleEndian64(Uint8List data, int offset) {
    var result = BigInt.zero;
    for (var i = 0; i < 8; i++) {
      result |= BigInt.from(data[offset + i]) << (8 * i);
    }
    return result;
  }
}
