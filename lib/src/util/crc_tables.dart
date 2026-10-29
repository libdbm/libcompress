import 'dart:typed_data';

/// Slice-by-8 tables and update loops for a reflected CRC-32 [polynomial],
/// shared by `Crc32` and `Crc32c`. `slices[j][i]` is the CRC of byte `i`
/// followed by `j` zero bytes, so eight input bytes advance the CRC with eight
/// independent lookups.
class CrcTables {
  CrcTables(final int polynomial) : slices = _build(polynomial);

  final List<Uint32List> slices;

  static List<Uint32List> _build(final int polynomial) {
    final slices = List<Uint32List>.generate(8, (_) => Uint32List(256));
    final table = slices[0];
    for (var i = 0; i < 256; i++) {
      var crc = i;
      for (var j = 0; j < 8; j++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ polynomial : crc >> 1;
      }
      table[i] = crc;
    }
    for (var i = 0; i < 256; i++) {
      var crc = table[i];
      for (var j = 1; j < 8; j++) {
        crc = table[crc & 0xFF] ^ (crc >> 8);
        slices[j][i] = crc;
      }
    }
    return slices;
  }

  /// Non-finalized CRC over [data] starting from [crc] (slice-by-8 with a
  /// byte-at-a-time tail). Byte extractions mask with `& 0xFF`, so the result
  /// is identical on the VM and dart2js.
  int update(final Uint8List data, final int crc) {
    var c = crc;
    final size = data.length;
    final t0 = slices[0], t1 = slices[1], t2 = slices[2], t3 = slices[3];
    final t4 = slices[4], t5 = slices[5], t6 = slices[6], t7 = slices[7];
    var i = 0;
    while (i + 8 <= size) {
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
    for (; i < size; i++) {
      c = t0[(c ^ data[i]) & 0xFF] ^ (c >> 8);
    }
    return c;
  }

  /// As [update], a byte at a time over any int list, masking each value to
  /// its low 8 bits.
  int updateList(final List<int> data, final int crc) {
    final table = slices[0];
    var c = crc;
    for (var i = 0; i < data.length; i++) {
      c = table[(c ^ (data[i] & 0xFF)) & 0xFF] ^ (c >> 8);
    }
    return c;
  }
}
