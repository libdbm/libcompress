import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';
import 'web_test_utils.dart';

void main() {
  group('CodecFactory.get (block codecs)', () {
    test('returns NoopCodec for noop', () {
      final codec = CodecFactory.codec(CodecType.noop);
      expect(codec, isA<NoopCodec>());
    });

    test('returns SnappyCodec for snappy', () {
      final codec = CodecFactory.codec(CodecType.snappy);
      expect(codec, isA<SnappyCodec>());
    });

    test('returns GzipCodec for gzip', () {
      final codec = CodecFactory.codec(CodecType.gzip);
      expect(codec, isA<GzipCodec>());
    });

    test('returns Lz4Codec for lz4', () {
      final codec = CodecFactory.codec(CodecType.lz4);
      expect(codec, isA<Lz4Codec>());
    });

    test('returns ZstdCodec for zstd', () {
      final codec = CodecFactory.codec(CodecType.zstd);
      expect(codec, isA<ZstdCodec>());
    });
  });

  group('CodecType.parse', () {
    test('parses valid codec names', () {
      expect(CodecType.parse('noop'), CodecType.noop);
      expect(CodecType.parse('snappy'), CodecType.snappy);
      expect(CodecType.parse('gzip'), CodecType.gzip);
      expect(CodecType.parse('lz4'), CodecType.lz4);
      expect(CodecType.parse('zstd'), CodecType.zstd);
    });

    test('throws ArgumentError for unknown codec', () {
      expect(() => CodecType.parse('unknown'), throwsArgumentError);
    });

    test('throws ArgumentError for typo in codec name', () {
      expect(() => CodecType.parse('lz4 '), throwsArgumentError);
      expect(() => CodecType.parse(' snappy'), throwsArgumentError);
      expect(() => CodecType.parse('GZIP'), throwsArgumentError);
    });
  });

  group('CodecFactory.getStream (stream codecs)', () {
    test('returns NoopStreamCodec for noop', () {
      final codec = CodecFactory.streaming(CodecType.noop);
      expect(codec, isA<NoopStreamCodec>());
    });

    test('returns SnappyStreamCodec for snappy', () {
      final codec = CodecFactory.streaming(CodecType.snappy);
      expect(codec, isA<SnappyStreamCodec>());
    });

    test('returns GzipStreamCodec for gzip', () {
      final codec = CodecFactory.streaming(CodecType.gzip);
      expect(codec, isA<GzipStreamCodec>());
    });

    test('returns Lz4StreamCodec for lz4', () {
      final codec = CodecFactory.streaming(CodecType.lz4);
      expect(codec, isA<Lz4StreamCodec>());
    });

    test('returns ZstdStreamCodec for zstd', () {
      final codec = CodecFactory.streaming(CodecType.zstd);
      expect(codec, isA<ZstdStreamCodec>());
    });
  });

  group('CodecMode.supports', () {
    test('all codecs support block mode', () {
      for (final type in CodecFactory.types) {
        final codec = CodecFactory.codec(type);
        expect(
          codec.supports(CodecMode.block),
          isTrue,
          reason: '$type should support block mode',
        );
      }
    });

    test('all codecs support stream mode', () {
      for (final type in CodecFactory.types) {
        final codec = CodecFactory.codec(type);
        expect(
          codec.supports(CodecMode.stream),
          isTrue,
          reason: '$type should support stream mode',
        );
      }
    });

    test('CodecFactory.supports delegates to codec', () {
      expect(CodecFactory.supports(CodecType.lz4, CodecMode.block), isTrue);
      expect(CodecFactory.supports(CodecType.lz4, CodecMode.stream), isTrue);
      expect(CodecFactory.supports(CodecType.noop, CodecMode.block), isTrue);
      expect(CodecFactory.supports(CodecType.noop, CodecMode.stream), isTrue);
    });
  });

  group('NoopStreamCodec', () {
    test('passes data through unchanged in compress', () async {
      final codec = NoopStreamCodec();
      final data = [
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4, 5, 6]),
      ];
      final result = await codec.compress(Stream.fromIterable(data)).toList();
      expect(result, equals(data));
    });

    test('passes data through unchanged in decompress', () async {
      final codec = NoopStreamCodec();
      final data = [
        Uint8List.fromList([7, 8, 9]),
        Uint8List.fromList([10, 11, 12]),
      ];
      final result = await codec.decompress(Stream.fromIterable(data)).toList();
      expect(result, equals(data));
    });
  });

  group('CodecFactory.types', () {
    test('contains all expected codec types', () {
      expect(
        CodecFactory.types,
        containsAll([
          CodecType.noop,
          CodecType.snappy,
          CodecType.gzip,
          CodecType.lz4,
          CodecType.zstd,
        ]),
      );
    });

    test('all types are valid for get()', () {
      for (final type in CodecFactory.types) {
        expect(() => CodecFactory.codec(type), returnsNormally);
      }
    });

    test('all types are valid for getStream()', () {
      for (final type in CodecFactory.types) {
        expect(() => CodecFactory.streaming(type), returnsNormally);
      }
    });
  });

  group('Noop web/js round-trip', () {
    test(
      'passes bytes through unchanged on web/js',
      () async {
        await expectWebRoundTrip(
          codecExpression: 'NoopCodec()',
          data: Uint8List.fromList([1, 2, 3, 4, 5]),
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
