import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

void main() {
  final data = Uint8List.fromList(List.generate(200000, (i) => (i * 31 + 7) % 256));
  // Codecs that enforce a decompressed-size cap (noop passes through unbounded).
  final capped = [CodecType.snappy, CodecType.gzip, CodecType.lz4, CodecType.zstd];

  group('CodecFactory limit params', () {
    test('codec(type, maxDecompressedSize: small) enforces the cap', () {
      for (final type in capped) {
        final comp = CodecFactory.codec(type).compress(data);
        expect(
          () => CodecFactory.codec(type, maxDecompressedSize: 1000).decompress(comp),
          throwsA(isA<CompressionFormatException>()),
          reason: '$type should reject output beyond a 1000-byte cap',
        );
        // Default (no param) round-trips.
        expect(CodecFactory.codec(type).decompress(comp), orderedEquals(data));
        // Explicit null = unlimited round-trips.
        expect(CodecFactory.codec(type, maxDecompressedSize: null).decompress(comp),
            orderedEquals(data));
      }
    });

    Future<(List<int>, Object?)> decodeStream(
        final CompressionStreamCodec codec, final Uint8List bytes) async {
      final out = <int>[];
      Object? err;
      try {
        await for (final c in codec.decompress(Stream.fromIterable([bytes]))) {
          out.addAll(c);
        }
      } catch (e) {
        err = e;
      }
      return (out, err);
    }

    test('streaming(type, maxDecompressedSize: small) enforces the cap', () async {
      for (final type in capped) {
        final comp = CodecFactory.codec(type).compress(data);
        final (_, err) = await decodeStream(
            CodecFactory.streaming(type, maxDecompressedSize: 1000), comp);
        expect(err, isA<CompressionFormatException>(), reason: '$type streaming cap');
      }
    });

    test('streaming(type, verified: true) round-trips valid data', () async {
      for (final type in [CodecType.gzip, CodecType.lz4, CodecType.zstd]) {
        final comp = CodecFactory.codec(type).compress(data);
        final (out, err) =
            await decodeStream(CodecFactory.streaming(type, verified: true), comp);
        expect(err, isNull, reason: '$type verified round-trip');
        expect(out, orderedEquals(data));
      }
    });

    test('an invalid factory limit fails fast', () {
      expect(() => CodecFactory.codec(CodecType.gzip, maxDecompressedSize: 0),
          throwsArgumentError);
    });
  });
}
