import 'dart:typed_data';

/// CRC32 checksum implementation for data integrity verification
///
/// Implements the CRC-32 algorithm used in GZIP, ZIP, PNG, and other formats.
/// Uses the IEEE 802.3 polynomial: 0xEDB88320 (reversed).
class Crc32 {
  /// Precomputed CRC32 lookup table
  static final Uint32List _table = _createTable();

  /// Eight extended tables for slice-by-8: `_t8[j][i]` applies the basic table
  /// step j+1 times. Lets [hash]/[update] consume 8 bytes per iteration with
  /// independent (ILP-friendly) lookups instead of one byte at a time.
  static final List<Uint32List> _t8 = _createSlice8();

  /// Creates the CRC32 lookup table
  static Uint32List _createTable() {
    final table = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        if ((c & 1) != 0) {
          c = 0xEDB88320 ^ (c >> 1);
        } else {
          c = c >> 1;
        }
      }
      table[n] = c;
    }
    return table;
  }

  static List<Uint32List> _createSlice8() {
    final tables = List<Uint32List>.generate(8, (_) => Uint32List(256));
    tables[0].setAll(0, _table);
    for (var i = 0; i < 256; i++) {
      var c = _table[i];
      for (var j = 1; j < 8; j++) {
        c = _table[c & 0xFF] ^ (c >> 8);
        tables[j][i] = c;
      }
    }
    return tables;
  }

  /// Non-finalized CRC over [data] starting from [crc] (slice-by-8 with a
  /// byte-at-a-time tail). Byte extractions mask with `& 0xFF`, so the result
  /// is identical on the VM and dart2js.
  static int _crc(Uint8List data, int crc) {
    var c = crc;
    final len = data.length;
    final t0 = _t8[0], t1 = _t8[1], t2 = _t8[2], t3 = _t8[3];
    final t4 = _t8[4], t5 = _t8[5], t6 = _t8[6], t7 = _t8[7];
    var i = 0;
    while (i + 8 <= len) {
      c = c ^
          data[i] ^
          (data[i + 1] << 8) ^
          (data[i + 2] << 16) ^
          (data[i + 3] << 24);
      c = t0[data[i + 7]] ^
          t1[data[i + 6]] ^
          t2[data[i + 5]] ^
          t3[data[i + 4]] ^
          t4[(c >> 24) & 0xFF] ^
          t5[(c >> 16) & 0xFF] ^
          t6[(c >> 8) & 0xFF] ^
          t7[c & 0xFF];
      i += 8;
    }
    for (; i < len; i++) {
      c = _table[(c ^ data[i]) & 0xFF] ^ (c >> 8);
    }
    return c;
  }

  /// Computes CRC32 checksum of the given data
  ///
  /// Returns a 32-bit unsigned integer checksum. The same input will always
  /// produce the same checksum. Different inputs are highly likely to produce
  /// different checksums.
  ///
  /// Example:
  /// ```dart
  /// final data = Uint8List.fromList([1, 2, 3, 4, 5]);
  /// final checksum = Crc32.hash(data);
  /// print('CRC32: 0x${checksum.toRadixString(16)}');
  /// ```
  static int hash(Uint8List data, [int crc = 0xFFFFFFFF]) =>
      _crc(data, crc) ^ 0xFFFFFFFF;

  /// Computes CRC32 checksum from a `List<int>`
  ///
  /// Convenience method for lists that aren't already `Uint8List`.
  /// Values outside 0-255 range are masked to the lower 8 bits.
  static int hashFromList(List<int> data, [int crc = 0xFFFFFFFF]) {
    var c = crc;
    for (var i = 0; i < data.length; i++) {
      c = _table[(c ^ (data[i] & 0xFF)) & 0xFF] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
  }

  /// Updates CRC32 checksum incrementally
  ///
  /// Allows computing CRC32 over multiple chunks of data without
  /// concatenating them. Pass the previous CRC value (or 0xFFFFFFFF
  /// for the first chunk) and get the updated value.
  ///
  /// Example:
  /// ```dart
  /// var crc = 0xFFFFFFFF;
  /// crc = Crc32.update(chunk1, crc);
  /// crc = Crc32.update(chunk2, crc);
  /// final final_crc = crc ^ 0xFFFFFFFF;
  /// ```
  static int update(Uint8List data, int crc) => _crc(data, crc);

  /// Combines two CRC32 values
  ///
  /// Given CRC of data blocks A and B separately, computes CRC of A+B.
  /// Requires knowing the length of block B.
  ///
  /// This uses GF(2) polynomial arithmetic to compute what the CRC would
  /// be if both blocks were concatenated, without needing the original data.
  ///
  /// Example:
  /// ```dart
  /// final crcA = Crc32.hash(blockA);
  /// final crcB = Crc32.hash(blockB);
  /// final combined = Crc32.combine(crcA, crcB, blockB.length);
  /// // combined == Crc32.hash(Uint8List.fromList([...blockA, ...blockB]))
  /// ```
  static int combine(int crc1, int crc2, int len2) {
    if (len2 <= 0) {
      return crc1;
    }

    // We need to compute: crc1 * x^(8*len2) XOR crc2 in GF(2)
    // Using matrix squaring for efficient exponentiation

    var result = crc1 ^ 0xFFFFFFFF; // Un-finalize crc1
    var matrix = _zeros.toList(); // Start with zeros matrix (x^1)
    var power = _ones.toList(); // Power accumulator (identity-ish)

    // Build power matrix for x^(8*len2) using binary exponentiation
    var remaining = len2;
    while (remaining > 0) {
      if ((remaining & 1) != 0) {
        power = _matrixMul(power, matrix);
      }
      remaining >>= 1;
      if (remaining > 0) {
        matrix = _matrixMul(matrix, matrix);
      }
    }

    // Apply the power matrix to crc1
    result = _matrixApply(power, result);

    // Re-finalize and XOR with crc2
    return (result ^ 0xFFFFFFFF) ^ crc2;
  }

  /// Matrix representing x^1 operation in GF(2)
  static final List<int> _zeros = _createZerosMatrix();

  /// Matrix representing x^0 (identity) operation
  static final List<int> _ones = _createOnesMatrix();

  /// Creates the zeros matrix (shift by 1 byte with polynomial feedback)
  static List<int> _createZerosMatrix() {
    final matrix = List<int>.filled(32, 0);
    // First row is the polynomial (reversed)
    matrix[0] = 0xEDB88320;
    // Remaining rows shift the bit position
    for (var i = 1; i < 32; i++) {
      matrix[i] = 1 << (i - 1);
    }
    return matrix;
  }

  /// Creates the ones matrix (shift by 8 bytes = 1 byte of data)
  static List<int> _createOnesMatrix() {
    // Start with zeros matrix and square it 8 times to get x^8
    var matrix = _createZerosMatrix();
    for (var i = 0; i < 8; i++) {
      matrix = _matrixMul(matrix, matrix);
    }
    return matrix;
  }

  /// Multiplies two 32x32 GF(2) matrices
  static List<int> _matrixMul(List<int> a, List<int> b) {
    final result = List<int>.filled(32, 0);
    for (var i = 0; i < 32; i++) {
      var row = 0;
      var mask = 1;
      for (var j = 0; j < 32; j++) {
        if ((a[i] & mask) != 0) {
          row ^= b[j];
        }
        mask <<= 1;
      }
      result[i] = row;
    }
    return result;
  }

  /// Applies a 32x32 GF(2) matrix to a 32-bit value
  static int _matrixApply(List<int> matrix, int value) {
    var result = 0;
    var bit = 0;
    while (value != 0) {
      if ((value & 1) != 0) {
        result ^= matrix[bit];
      }
      value >>= 1;
      bit++;
    }
    return result;
  }
}
