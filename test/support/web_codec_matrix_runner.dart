import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';

Future<void> main() async {
  final results = <String, Object?>{};
  for (final type in CodecFactory.types) {
    results[type.name] = await _runCodec(type);
  }
  print(jsonEncode(results));
}

Future<Map<String, Object?>> _runCodec(CodecType type) async {
  final blockCodec = CodecFactory.codec(type);
  final streamCodec = CodecFactory.streaming(type);
  final cases = _dataCases();
  final blockResults = <Map<String, Object?>>[];
  final streamResults = <Map<String, Object?>>[];

  for (final entry in cases.entries) {
    final data = entry.value;
    final compressed = blockCodec.compress(data);
    final decompressed = blockCodec.decompress(compressed);
    if (!_bytesEqual(decompressed, data)) {
      throw StateError('${type.name}/${entry.key} block round trip failed');
    }
    blockResults.add(<String, Object?>{
      'case': entry.key,
      'input': _b64(data),
      'compressed': _b64(_normalizeCompressed(type, compressed)),
      'decompressed': _b64(decompressed),
    });

    final compressedChunks = await streamCodec
        .compress(Stream<Uint8List>.fromIterable(_splitData(data)))
        .toList();
    final streamCompressed = _concat(compressedChunks);
    final decompressedChunks = await streamCodec
        .decompress(Stream<Uint8List>.fromIterable(compressedChunks))
        .toList();
    final streamDecompressed = _concat(decompressedChunks);
    if (!_bytesEqual(streamDecompressed, data)) {
      throw StateError('${type.name}/${entry.key} stream round trip failed');
    }
    streamResults.add(<String, Object?>{
      'case': entry.key,
      'input': _b64(data),
      'compressed': _b64(_normalizeCompressed(type, streamCompressed)),
      'decompressed': _b64(streamDecompressed),
    });
  }

  return <String, Object?>{'block': blockResults, 'stream': streamResults};
}

Map<String, Uint8List> _dataCases() {
  return <String, Uint8List>{
    'empty': Uint8List(0),
    'shortText': Uint8List.fromList(
      utf8.encode('Hello, web compression. こんにちは、圧縮です。'),
    ),
    'repeatedText': Uint8List.fromList(
      utf8.encode(List<String>.filled(128, 'plate-label-').join()),
    ),
    'binary': Uint8List.fromList(
      List<int>.generate(1024, (index) => (index * 37 + 11) & 0xff),
    ),
  };
}

List<Uint8List> _splitData(Uint8List data) {
  if (data.isEmpty) {
    return <Uint8List>[Uint8List(0)];
  }
  final midpoint = data.length ~/ 2;
  return <Uint8List>[
    Uint8List.fromList(data.sublist(0, midpoint)),
    Uint8List.fromList(data.sublist(midpoint)),
  ];
}

Uint8List _normalizeCompressed(CodecType type, Uint8List bytes) {
  if (type != CodecType.gzip) {
    return bytes;
  }
  final normalized = Uint8List.fromList(bytes);
  var offset = 0;
  while (offset + 10 <= normalized.length) {
    if (normalized[offset] != 0x1f || normalized[offset + 1] != 0x8b) {
      break;
    }
    normalized[offset + 4] = 0;
    normalized[offset + 5] = 0;
    normalized[offset + 6] = 0;
    normalized[offset + 7] = 0;

    final next = _nextGzipMemberOffset(normalized, offset);
    if (next == null || next <= offset) {
      break;
    }
    offset = next;
  }
  return normalized;
}

int? _nextGzipMemberOffset(Uint8List bytes, int offset) {
  var pos = offset + 10;
  final flags = bytes[offset + 3];
  if ((flags & 0x04) != 0) {
    if (pos + 2 > bytes.length) return null;
    final extraLength = bytes[pos] | (bytes[pos + 1] << 8);
    pos += 2 + extraLength;
  }
  if ((flags & 0x08) != 0) {
    while (pos < bytes.length && bytes[pos] != 0) {
      pos += 1;
    }
    pos += 1;
  }
  if ((flags & 0x10) != 0) {
    while (pos < bytes.length && bytes[pos] != 0) {
      pos += 1;
    }
    pos += 1;
  }
  if ((flags & 0x02) != 0) {
    pos += 2;
  }
  while (pos + 1 < bytes.length) {
    if (bytes[pos] == 0x1f && bytes[pos + 1] == 0x8b) {
      return pos;
    }
    pos += 1;
  }
  return bytes.length;
}

Uint8List _concat(List<Uint8List> chunks) {
  final total = chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
  final result = Uint8List(total);
  var offset = 0;
  for (final chunk in chunks) {
    result.setAll(offset, chunk);
    offset += chunk.length;
  }
  return result;
}

String _b64(Uint8List bytes) => base64Encode(bytes);

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}
