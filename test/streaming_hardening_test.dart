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

    test('Snappy rejects many chunks exceeding the cumulative cap', () {
      // ~400 KB -> multiple <=64 KB framing chunks, each under the 100 KB cap
      // but cumulatively over it.
      final big = _bytes(List.generate(400 * 1024, (i) => (i * 31 + 7) % 256));
      final framed = SnappyCodec(framing: true).compress(big);
      // streaming path
      expect(
        _decodeStream(SnappyStreamCodec(maxSize: 100 * 1024), framed),
        throwsA(isA<CompressionFormatException>()),
      );
      // block multi-chunk path
      expect(
        () => SnappyCodec(framing: true, maxSize: 100 * 1024).decompress(framed),
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

  group('Verified mode withholds output until validated (#3)', () {
    Future<(List<int>, Object?)> decodeCollect(
        final CompressionStreamCodec codec, final Uint8List data) async {
      final out = <int>[];
      Object? err;
      try {
        await for (final c in codec.decompress(Stream.fromIterable([data]))) {
          out.addAll(c);
        }
      } catch (e) {
        err = e;
      }
      return (out, err);
    }

    final payload = _bytes(List.generate(5000, (i) => (i * 31 + 7) % 256));

    test('GZIP verified emits nothing when the trailer CRC is corrupted', () async {
      final comp = Uint8List.fromList(GzipCodec().compress(payload));
      comp[comp.length - 5] ^= 0xFF; // flip a CRC32 trailer byte
      final (out, err) = await decodeCollect(GzipStreamCodec(verified: true), comp);
      expect(err, isA<CompressionFormatException>());
      expect(out, isEmpty,
          reason: 'verified mode must not emit bytes from a member that fails CRC');
    });

    test('GZIP verified round-trips valid data', () async {
      final comp = GzipCodec().compress(payload);
      final (out, err) = await decodeCollect(GzipStreamCodec(verified: true), comp);
      expect(err, isNull);
      expect(out, orderedEquals(payload));
    });

    test('Zstd verified emits nothing when the checksum is corrupted', () async {
      final comp = Uint8List.fromList(ZstdCodec(enableChecksum: true).compress(payload));
      comp[comp.length - 1] ^= 0xFF; // flip a content-checksum byte
      final (out, err) = await decodeCollect(ZstdStreamCodec(verified: true), comp);
      expect(err, isA<CompressionFormatException>());
      expect(out, isEmpty);
    });

    test('Zstd verified round-trips valid data', () async {
      final comp = ZstdCodec(enableChecksum: true).compress(payload);
      final (out, err) = await decodeCollect(ZstdStreamCodec(verified: true), comp);
      expect(err, isNull);
      expect(out, orderedEquals(payload));
    });

    test('LZ4 verified round-trips valid data', () async {
      final comp = Lz4Codec().compress(payload);
      final (out, err) = await decodeCollect(Lz4StreamCodec(verified: true), comp);
      expect(err, isNull);
      expect(out, orderedEquals(payload));
    });
  });
}
