import 'dart:typed_data';

/// A compressed Parquet page: its codec and declared uncompressed size.
typedef Page = ({int codec, int size, Uint8List data});

/// The pages of every column chunk in a Parquet [file], found through the
/// footer's column metadata. Reads only what tests need from the Thrift
/// compact protocol; it is not a Parquet reader.
List<Page> parquetPages(final Uint8List file) {
  final view = ByteData.sublistView(file);
  final footer = view.getUint32(file.length - 8, Endian.little);
  final metadata = _Reader(file, file.length - 8 - footer).struct();
  final pages = <Page>[];
  for (final group in metadata[4] as List) {
    for (final column in (group as Map)[1] as List) {
      final chunk = (column as Map)[3] as Map;
      final dictionary = chunk[11] as int?;
      final data = chunk[9] as int;
      var position = dictionary != null && dictionary < data
          ? dictionary
          : data;
      final end = position + (chunk[7] as int);
      while (position < end) {
        final reader = _Reader(file, position);
        final header = reader.struct();
        final size = header[3] as int;
        pages.add((
          codec: chunk[4] as int,
          size: header[2] as int,
          data: Uint8List.sublistView(
            file,
            reader.position,
            reader.position + size,
          ),
        ));
        position = reader.position + size;
      }
    }
  }
  return pages;
}

/// Thrift compact protocol values: structs as maps from field id, lists as
/// lists, integers as ints and binaries as bytes.
class _Reader {
  _Reader(this.data, this.position);

  final Uint8List data;
  int position;

  int _byte() => data[position++];

  int _varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = _byte();
      result |= (byte & 0x7F) << shift;
      shift += 7;
      if (byte < 0x80) return result;
    }
  }

  int _zigzag() {
    final value = _varint();
    return (value >>> 1) ^ -(value & 1);
  }

  Object? _value(final int type) {
    switch (type) {
      case 1:
      case 2:
        return type == 1;
      case 3:
        return _byte();
      case 4:
      case 5:
      case 6:
        return _zigzag();
      case 7:
        position += 8;
        return null;
      case 8:
        final length = _varint();
        position += length;
        return Uint8List.sublistView(data, position - length, position);
      case 9:
      case 10:
        final header = _byte();
        var count = header >> 4;
        if (count == 15) count = _varint();
        return [for (var i = 0; i < count; i++) _value(header & 0x0F)];
      case 12:
        return struct();
    }
    throw FormatException('Unsupported Thrift type $type');
  }

  Map<int, Object?> struct() {
    final fields = <int, Object?>{};
    var last = 0;
    while (true) {
      final header = _byte();
      if (header == 0) return fields;
      final delta = header >> 4;
      last = delta != 0 ? last + delta : _zigzag();
      fields[last] = _value(header & 0x0F);
    }
  }
}
