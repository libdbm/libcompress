import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

void main() {
  group('size limits', () {
    final data = Uint8List.fromList(
      List.generate(10000, (final i) => 'parquet page '.codeUnitAt(i % 13)),
    );
    Matcher limit(final int value) => throwsA(
      isA<LimitException>()
          .having((final e) => e.limit, 'limit', value)
          .having((final e) => e.message, 'message', contains('$value')),
    );

    final block = <String, CompressionCodec Function(int)>{
      'gzip': (final cap) => GzipCodec(maxSize: cap),
      'zstd': (final cap) => ZstdCodec(maxSize: cap),
      'lz4 frame': (final cap) => Lz4Codec(maxSize: cap),
      'lz4 raw': (final cap) => Lz4Codec(format: Lz4Format.raw, maxSize: cap),
      'lz4 hadoop': (final cap) =>
          Lz4Codec(format: Lz4Format.hadoop, maxSize: cap),
      'snappy raw': (final cap) => SnappyCodec(maxSize: cap),
      'snappy framed': (final cap) =>
          SnappyCodec(format: SnappyFormat.framed, maxSize: cap),
    };
    for (final entry in block.entries) {
      test('${entry.key}: exceeding maxSize names the cap', () {
        final compressed = entry.value(100000).compress(data);
        expect(() => entry.value(1000).decompress(compressed), limit(1000));
      });
    }

    final stream = <String, CompressionStreamCodec Function(int?, int)>{
      'gzip': (final cap, final buffer) =>
          GzipStreamCodec(maxSize: cap, maxBufferSize: buffer),
      'zstd': (final cap, final buffer) =>
          ZstdStreamCodec(maxSize: cap, maxBufferSize: buffer),
      'lz4': (final cap, final buffer) =>
          Lz4StreamCodec(maxSize: cap, maxBufferSize: buffer),
      'snappy': (final cap, final buffer) =>
          SnappyStreamCodec(maxSize: cap, maxBufferSize: buffer),
    };
    for (final entry in stream.entries) {
      test('${entry.key} stream: the cumulative cap is named, not the '
          'remaining budget', () async {
        final codec = entry.value(null, 1 << 20);
        final frame = Uint8List.fromList(
          (await codec.compress(Stream.value(data)).toList())
              .expand((final chunk) => chunk)
              .toList(),
        );
        // Two frames of 10000 bytes against a cap of 15000: the second frame
        // breaches with 5000 bytes of budget left.
        await expectLater(
          entry
              .value(15000, 1 << 20)
              .decompress(Stream.fromIterable([frame, frame]))
              .toList(),
          limit(15000),
        );
      });

      test('${entry.key} stream: exceeding maxBufferSize names it', () async {
        await expectLater(
          entry
              .value(null, 100)
              .decompress(Stream.value(Uint8List(1000)))
              .toList(),
          limit(100),
        );
      });
    }

    test('noop: a size mismatch is a LimitException', () {
      expect(
        () => NoopCodec().decompress(data, size: 10),
        throwsA(isA<LimitException>()),
      );
    });

    test('noop: input shorter than size is a NoopFormatException', () {
      expect(
        () => NoopCodec().decompress(Uint8List(5), size: 10),
        throwsA(isA<NoopFormatException>()),
      );
    });
  });

  group('decompress with an expected size', () {
    final data = Uint8List.fromList(
      List.generate(10000, (final i) => 'parquet page '.codeUnitAt(i % 13)),
    );
    final codecs = {
      for (final type in CodecFactory.types)
        type.name: CodecFactory.codec(type),
      'snappy framed': SnappyCodec(format: SnappyFormat.framed),
      // With raw Snappy, GZIP and Zstd above, the five Parquet codecs.
      'lz4 raw (Parquet LZ4_RAW)': Lz4Codec(format: Lz4Format.raw),
      'lz4 hadoop (Parquet LZ4)': Lz4Codec(format: Lz4Format.hadoop),
    };
    for (final entry in codecs.entries) {
      final codec = entry.value;
      final mismatch = throwsA(isA<CompressionFormatException>());

      test('${entry.key}: the right size decodes the same bytes', () {
        final compressed = codec.compress(data);
        expect(
          codec.decompress(compressed, size: data.length),
          orderedEquals(data),
        );
      });

      test('${entry.key}: a size off by one is rejected', () {
        final compressed = codec.compress(data);
        expect(
          () => codec.decompress(compressed, size: data.length - 1),
          mismatch,
        );
        expect(
          () => codec.decompress(compressed, size: data.length + 1),
          mismatch,
        );
      });

      if (entry.key != 'noop') {
        test('${entry.key}: decoding stops at a much smaller size', () {
          // The cap stops decoding at 100 bytes, so the error comes from the
          // limit rather than from the final length check.
          expect(
            () => codec.decompress(codec.compress(data), size: 100),
            throwsA(
              isA<CompressionFormatException>().having(
                (final e) => e.message,
                'message',
                isNot(contains('!= expected size')),
              ),
            ),
          );
        });
      }

      test('${entry.key}: a negative size is an argument error', () {
        expect(
          () => codec.decompress(codec.compress(data), size: -1),
          throwsA(isA<ArgumentError>()),
        );
      });
    }
  });

  group('CodecFactory.codec (block codecs)', () {
    test('returns NoopCodec for noop', () {
      final codec = CodecFactory.codec(CodecType.noop);
      expect(codec, isA<NoopCodec>());
    });

    test('noop is the one codec that decodes empty input to empty', () async {
      expect(NoopCodec().decompress(Uint8List(0)), isEmpty);
      final chunks = await NoopStreamCodec()
          .decompress(const Stream.empty())
          .toList();
      expect(chunks, isEmpty);
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
    });

    test('ignores case, so codec names round-trip', () {
      expect(CodecType.parse('GZIP'), CodecType.gzip);
      expect(CodecType.parse('Lz4'), CodecType.lz4);
      for (final type in CodecFactory.types) {
        expect(CodecType.parse(CodecFactory.codec(type).name), type);
        expect(CodecType.parse(CodecFactory.streaming(type).name), type);
      }
    });
  });

  group('CodecFactory.streaming (stream codecs)', () {
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

  group('result buffers', () {
    // A result should not keep a much larger backing buffer alive: 1 MB of
    // zeros compresses to a few KB, which must not pin a 1 MB allocation.
    // Decoded output may keep the slack of doubling growth (up to 2x).
    final data = Uint8List(1 << 20);
    final codecs = <String, CompressionCodec>{
      'lz4 frame': Lz4Codec(),
      'lz4 raw': Lz4Codec(format: Lz4Format.raw),
      'lz4 hadoop': Lz4Codec(format: Lz4Format.hadoop),
      'snappy raw': SnappyCodec(),
      'snappy framed': SnappyCodec(format: SnappyFormat.framed),
      'gzip': GzipCodec(),
      'zstd': ZstdCodec(),
    };
    for (final entry in codecs.entries) {
      test('${entry.key}: results do not pin oversized buffers', () {
        final packed = entry.value.compress(data);
        expect(
          packed.buffer.lengthInBytes,
          lessThanOrEqualTo(packed.length * 5 ~/ 4),
          reason: 'compressed ${packed.length} bytes',
        );
        final restored = entry.value.decompress(packed);
        expect(restored, hasLength(data.length));
        expect(
          restored.buffer.lengthInBytes,
          lessThanOrEqualTo(restored.length * 2),
          reason: 'decompressed',
        );
      });
    }
  });

  group('noop limits', () {
    final data = Uint8List(20);

    test('NoopCodec enforces maxSize, also through the factory', () {
      expect(
        () => NoopCodec(maxSize: 10).decompress(data),
        throwsA(
          isA<LimitException>().having((final e) => e.limit, 'limit', 10),
        ),
      );
      expect(
        () => CodecFactory.codec(CodecType.noop, maxSize: 10).decompress(data),
        throwsA(isA<LimitException>()),
      );
      expect(NoopCodec(maxSize: 20).decompress(data), hasLength(20));
    });

    test('NoopStreamCodec enforces cumulative maxSize', () async {
      await expectLater(
        CodecFactory.streaming(
          CodecType.noop,
          maxSize: 30,
        ).decompress(Stream.fromIterable([data, data])).toList(),
        throwsA(
          isA<LimitException>().having((final e) => e.limit, 'limit', 30),
        ),
      );
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

  group('size limit contract', () {
    test(
      'a configured cap breach is a LimitException for every codec',
      () async {
        // Random data, so every encoder stores it: the stored or uncompressed
        // path of each format meets the cap too.
        final random = Random(1);
        final data = Uint8List.fromList(
          List.generate(20000, (_) => random.nextInt(256)),
        );
        const cap = 1000;
        final cases =
            <
              String,
              (CompressionCodec, CompressionCodec, CompressionStreamCodec?)
            >{
              'noop': (
                NoopCodec(),
                NoopCodec(maxSize: cap),
                NoopStreamCodec(maxSize: cap),
              ),
              'snappy raw': (SnappyCodec(), SnappyCodec(maxSize: cap), null),
              'snappy framed': (
                SnappyCodec(format: SnappyFormat.framed),
                SnappyCodec(format: SnappyFormat.framed, maxSize: cap),
                SnappyStreamCodec(maxSize: cap),
              ),
              'gzip': (
                GzipCodec(),
                GzipCodec(maxSize: cap),
                GzipStreamCodec(maxSize: cap),
              ),
              'lz4 frame': (
                Lz4Codec(),
                Lz4Codec(maxSize: cap),
                Lz4StreamCodec(maxSize: cap),
              ),
              'lz4 raw': (
                Lz4Codec(format: Lz4Format.raw),
                Lz4Codec(format: Lz4Format.raw, maxSize: cap),
                null,
              ),
              'lz4 hadoop': (
                Lz4Codec(format: Lz4Format.hadoop),
                Lz4Codec(format: Lz4Format.hadoop, maxSize: cap),
                null,
              ),
              'zstd': (
                ZstdCodec(),
                ZstdCodec(maxSize: cap),
                ZstdStreamCodec(maxSize: cap),
              ),
            };
        for (final MapEntry(key: name, value: (encoder, block, stream))
            in cases.entries) {
          final packed = encoder.compress(data);
          expect(
            () => block.decompress(packed),
            throwsA(isA<LimitException>()),
            reason: '$name block',
          );
          if (stream != null) {
            await expectLater(
              stream.decompress(Stream.value(packed)).toList(),
              throwsA(isA<LimitException>()),
              reason: '$name stream',
            );
          }
        }
      },
    );
  });

  group('options carry every codec setting', () {
    test('stream codecs are created from options', () {
      final lz4 = Lz4StreamCodec.fromOptions(
        Lz4Options(
          level: 9,
          blockSize: lz4BlockSize64K,
          checksum: false,
          maxSize: 7,
        ),
      );
      expect(
        [lz4.level, lz4.blockSize, lz4.checksum, lz4.maxSize],
        [9, lz4BlockSize64K, false, 7],
      );
      expect(
        () => Lz4StreamCodec.fromOptions(Lz4Options(format: Lz4Format.raw)),
        throwsArgumentError,
      );
      final snappy = SnappyStreamCodec.fromOptions(
        SnappyOptions(maxSize: 7, chunkSize: 1000),
      );
      expect([snappy.maxSize, snappy.chunkSize], [7, 1000]);
      final gzip = GzipStreamCodec.fromOptions(
        GzipOptions(
          level: 9,
          maxSize: 7,
          mtime: 5,
          filename: 'f',
          comment: 'c',
        ),
      );
      expect(
        [gzip.level, gzip.maxSize, gzip.mtime, gzip.filename, gzip.comment],
        [9, 7, 5, 'f', 'c'],
      );
      final zstd = ZstdStreamCodec.fromOptions(
        ZstdOptions(
          level: 19,
          blockSize: 4096,
          checksum: true,
          maxSize: 7,
          strict: true,
        ),
      );
      expect(
        [zstd.level, zstd.blockSize, zstd.checksum, zstd.maxSize, zstd.strict],
        [19, 4096, true, 7, true],
      );
    });

    test('ZstdOptions carries onFallback', () {
      void hook(final Object error, final StackTrace stack) {}
      expect(
        ZstdCodec.fromOptions(ZstdOptions(onFallback: hook)).onFallback,
        hook,
      );
    });
  });

  group('options validation', () {
    test('options reject what their codecs reject, when constructed', () {
      for (final create in <Object Function()>[
        () => Lz4Options(blockSize: 0),
        () => Lz4Options(blockSize: lz4BlockSize4M + 1),
        () => ZstdOptions(blockSize: 1 << 20),
        () => SnappyOptions(chunkSize: 0),
        () => SnappyOptions(chunkSize: 65537),
        () => GzipOptions(mtime: -1),
        () => GzipOptions(filename: 'a\u0000b'),
        () => GzipOptions(comment: '\u0000'),
      ]) {
        expect(create, throwsArgumentError);
      }
    });
  });

  group('CodecFactory maxSize', () {
    final data = Uint8List.fromList(
      List.generate(200000, (final i) => (i * 31 + 7) % 256),
    );
    // Codecs that enforce a decompressed-size cap (noop passes through unbounded).
    final capped = [
      CodecType.snappy,
      CodecType.gzip,
      CodecType.lz4,
      CodecType.zstd,
    ];

    test('codec(type, maxSize: small) enforces the cap', () {
      for (final type in capped) {
        final comp = CodecFactory.codec(type).compress(data);
        expect(
          () => CodecFactory.codec(type, maxSize: 1000).decompress(comp),
          throwsA(isA<CompressionFormatException>()),
          reason: '$type should reject output beyond a 1000-byte cap',
        );
        // Default (no param) round-trips.
        expect(CodecFactory.codec(type).decompress(comp), orderedEquals(data));
        // Explicit null = unlimited round-trips.
        expect(
          CodecFactory.codec(type, maxSize: null).decompress(comp),
          orderedEquals(data),
        );
      }
    });

    Future<(List<int>, Object?)> decodeStream(
      final CompressionStreamCodec codec,
      final Uint8List bytes,
    ) async {
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

    test('streaming(type, maxSize: small) enforces the cap', () async {
      for (final type in capped) {
        final comp = CodecFactory.codec(type).compress(data);
        final (_, err) = await decodeStream(
          CodecFactory.streaming(type, maxSize: 1000),
          comp,
        );
        expect(
          err,
          isA<CompressionFormatException>(),
          reason: '$type streaming cap',
        );
      }
    });

    test('streaming(type, verified: true) round-trips valid data', () async {
      for (final type in [CodecType.gzip, CodecType.lz4, CodecType.zstd]) {
        final comp = CodecFactory.codec(type).compress(data);
        final (out, err) = await decodeStream(
          CodecFactory.streaming(type, verified: true),
          comp,
        );
        expect(err, isNull, reason: '$type verified round-trip');
        expect(out, orderedEquals(data));
      }
    });

    test('an invalid factory limit fails fast', () {
      expect(
        () => CodecFactory.codec(CodecType.gzip, maxSize: 0),
        throwsArgumentError,
      );
    });
  });
}
