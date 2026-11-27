import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';

Future<void> main() async {
  final results = <String, Object?>{};
  for (final type in CodecFactory.types) {
    results[type.name] = await _runCodec(
      type,
      CodecFactory.codec(type),
      CodecFactory.streaming(type),
    );
  }
  // The factory leaves the Zstd content checksum off; cover XXH64 explicitly.
  results['zstdChecksum'] = await _runCodec(
    CodecType.zstd,
    ZstdCodec(checksum: true),
    ZstdStreamCodec(checksum: true),
  );
  results['zstdLargeWindow'] = await _largeWindows();
  // An expected size far above maxSize must be capped before the output is
  // allocated (2^40 as a literal: `1 << 40` is 0 on the web).
  results['brotliLargeSize'] = _attempt(
    () => BrotliCodec().decompress(
      BrotliCodec().compress(Uint8List(100)),
      size: 1099511627776,
    ),
  );
  print(jsonEncode(results));
}

/// Decodes frames whose Window_Descriptor exponent makes the window 2^31 bytes
/// or more (exponent 22 is 2^32), which a 32-bit shift gets wrong on the web.
/// Each frame holds one raw block, `abc`. Each is decoded with the default
/// window cap (rejected) and with a cap above 2^41 (accepted), so a window
/// size computed wrongly on the web shows up either way.
Future<List<Object?>> _largeWindows() async {
  final results = <Object?>[];
  for (final exponent in [21, 22, 31]) {
    final frame = Uint8List.fromList([
      0x28, 0xB5, 0x2F, 0xFD, 0x00, exponent << 3, //
      (3 << 3) | 1, 0, 0, 0x61, 0x62, 0x63,
    ]);
    // 2^42 as a literal: `1 << 42` is 0 on the web, where shifts are 32-bit.
    for (final window in [zstdDefaultWindow, 4398046511104]) {
      results
        ..add(_attempt(() => ZstdCodec(window: window).decompress(frame)))
        ..add(
          await _attemptAsync(
            () => ZstdStreamCodec(
              window: window,
            ).decompress(Stream.value(frame)).toList(),
          ),
        );
    }
  }
  return results;
}

Object? _attempt(final Uint8List Function() decode) {
  try {
    return _encode(decode());
  } on CompressionFormatException catch (error) {
    return 'error: ${error.message}';
  }
}

Future<Object?> _attemptAsync(
  final Future<List<Uint8List>> Function() decode,
) async {
  try {
    return _encode(_concat(await decode()));
  } on CompressionFormatException catch (error) {
    return 'error: ${error.message}';
  }
}

Future<Map<String, Object?>> _runCodec(
  final CodecType type,
  final CompressionCodec blockCodec,
  final CompressionStreamCodec streamCodec,
) async {
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
      'input': _encode(data),
      'compressed': _encode(_normalizeCompressed(type, compressed)),
      'decompressed': _encode(decompressed),
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
      'input': _encode(data),
      'compressed': _encode(_normalizeCompressed(type, streamCompressed)),
      'decompressed': _encode(streamDecompressed),
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
      List<int>.generate(1024, (final index) => (index * 37 + 11) & 0xff),
    ),
    'large': _large(),
    'skewed': _skewed(),
  };
}

/// 64 KB over the whole byte range, skewed towards low values (the product of
/// two pseudo-random bytes), so Zstd Huffman literals need FSE-compressed
/// weights. Products stay below 2^53, as in [_large].
Uint8List _skewed() {
  final data = Uint8List(64 * 1024);
  var seed = 11;
  int next() => seed = (seed * 48271) % 2147483647;
  for (var index = 0; index < data.length; index++) {
    data[index] = (((next() >> 8) & 0xff) * ((next() >> 8) & 0xff)) >> 8;
  }
  return data;
}

/// 600 KB alternating 1500-byte pseudo-random runs with repeats of them, so
/// Zstd sequences carry long literal runs and large offsets (many extra bits
/// per sequence). The generator's products stay below 2^53, so the VM and
/// dart2js produce identical input.
Uint8List _large() {
  final data = Uint8List(600000);
  var seed = 7;
  for (var index = 0; index < data.length; index++) {
    seed = (seed * 48271) % 2147483647;
    data[index] = (index % 3000 < 1500)
        ? (seed >> 8) & 0xff
        : data[index - 1500];
  }
  return data;
}

List<Uint8List> _splitData(final Uint8List data) {
  if (data.isEmpty) {
    return <Uint8List>[Uint8List(0)];
  }
  final midpoint = data.length ~/ 2;
  return <Uint8List>[
    Uint8List.fromList(data.sublist(0, midpoint)),
    Uint8List.fromList(data.sublist(midpoint)),
  ];
}

Uint8List _normalizeCompressed(final CodecType type, final Uint8List bytes) {
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

int? _nextGzipMemberOffset(final Uint8List bytes, final int offset) {
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

Uint8List _concat(final List<Uint8List> chunks) {
  final total = chunks.fold<int>(
    0,
    (final sum, final chunk) => sum + chunk.length,
  );
  final result = Uint8List(total);
  var offset = 0;
  for (final chunk in chunks) {
    result.setAll(offset, chunk);
    offset += chunk.length;
  }
  return result;
}

/// Small payloads are compared byte for byte; large ones by length and digest
/// to keep the VM/JS comparison output small.
String _encode(final Uint8List bytes) {
  if (bytes.length <= 4096) return base64Encode(bytes);
  var digest = 17;
  for (final byte in bytes) {
    digest = (digest * 31 + byte) % 1000000007;
  }
  return '${bytes.length}:$digest';
}

bool _bytesEqual(final Uint8List left, final Uint8List right) {
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
