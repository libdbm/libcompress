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
      c =
          c ^
          data[i] ^
          (data[i + 1] << 8) ^
          (data[i + 2] << 16) ^
          (data[i + 3] << 24);
      c =
          t0[data[i + 7]] ^
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
}
