import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

Uint8List _bytes(final Iterable<int> v) => Uint8List.fromList(v.toList());

Future<Uint8List> _decodeStream(
  final CompressionStreamCodec codec,
  final Uint8List data, {
  final int chunk = 64,
}) async {
  final chunks = <Uint8List>[
    for (var i = 0; i < data.length; i += chunk)
      Uint8List.sublistView(data, i, (i + chunk) < data.length ? i + chunk : data.length),
  ];
  final out = BytesBuilder(copy: false);
  await for (final c in codec.decompress(Stream.fromIterable(chunks))) {
    out.add(c);
  }
  return out.takeBytes();
}

void main() {
  group('Streaming cumulative output limit (#1)', () {
    final payload = _bytes(List.filled(1000, 65)); // 1000 'A'

    test('GZIP rejects many small members exceeding the cumulative cap', () {
      final member = GzipCodec().compress(payload);
      final concat = _bytes([for (var i = 0; i < 5; i++) ...member]); // 5000 out
      // Each member (1000) is under the cap, but the cumulative total is not.
      expect(
        _decodeStream(GzipStreamCodec(maxSize: 2500), concat),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('GZIP allows cumulative output up to the cap', () async {
      final member = GzipCodec().compress(payload);
      final concat = _bytes([...member, ...member]); // 2000 out
      final out = await _decodeStream(GzipStreamCodec(maxSize: 5000), concat);
      expect(out.length, 2000);
    });

    test('LZ4 rejects many frames exceeding the cumulative cap', () {
      final frame = Lz4Codec().compress(payload);
      final concat = _bytes([for (var i = 0; i < 5; i++) ...frame]);
      expect(
        _decodeStream(Lz4StreamCodec(maxSize: 2500), concat),
        throwsA(isA<CompressionFormatException>()),
      );
    });
  });

  group('GZIP streaming header CRC (#4)', () {
    test('rejects a member with an invalid header CRC16', () {
      // FLG=FHCRC (0x02) with a deliberately wrong 2-byte header CRC.
      final data = _bytes([
        0x1f, 0x8b, 0x08, 0x02, // magic, CM=deflate, FLG=FHCRC
        0, 0, 0, 0, // mtime
        0, 3, // xfl, os
        0xff, 0xff, // wrong header CRC16
        0x03, 0x00, // (some DEFLATE bytes; never reached)
      ]);
      expect(
        _decodeStream(GzipStreamCodec(), data),
        throwsA(isA<CompressionFormatException>()),
      );
    });
  });

  group('Streaming error boundary surfaces CompressionFormatException (#5)', () {
    final garbage = _bytes(List.generate(80, (i) => (i * 7 + 3) & 0xFF));

    test('Zstd', () {
      expect(_decodeStream(ZstdStreamCodec(), garbage),
          throwsA(isA<CompressionFormatException>()));
    });
    test('LZ4', () {
      expect(_decodeStream(Lz4StreamCodec(), garbage),
          throwsA(isA<CompressionFormatException>()));
    });
    test('GZIP', () {
      expect(_decodeStream(GzipStreamCodec(), garbage),
          throwsA(isA<CompressionFormatException>()));
    });
  });
}
