import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';
import 'package:libcompress/src/gzip/deflate_common.dart';
import 'package:libcompress/src/gzip/deflate_decoder.dart';
import 'package:libcompress/src/gzip/deflate_encoder.dart';
import 'package:libcompress/src/util/bit_stream.dart';
import 'package:test/test.dart';

import 'support/differential_fuzz.dart';
import 'test_utils.dart';

/// Decodes [data] through a stream codec, feeding it in fixed-size chunks.
Future<Uint8List> decodeChunked(
  final CompressionStreamCodec codec,
  final Uint8List data, {
  final int chunk = 64,
}) async {
  final chunks = <Uint8List>[
    for (var i = 0; i < data.length; i += chunk)
      Uint8List.sublistView(
        data,
        i,
        (i + chunk) < data.length ? i + chunk : data.length,
      ),
  ];
  return collect(codec.decompress(Stream.fromIterable(chunks)));
}

void main() {
  group('GZIP block', () {
    test('decompresses stored fixtures', () {
      final codec = GzipCodec();
      for (final path in standardFixtures) {
        final original = readDataFixture(path);
        final compressed = readCodecFixture('gzip', '$path.gz');
        expect(
          codec.decompress(compressed),
          equals(original),
          reason: 'fixture $path',
        );
      }
    });

    test('round-trips standardFixtures', () {
      final codec = GzipCodec();
      for (final path in standardFixtures) {
        expectRoundTrip(codec, readDataFixture(path));
      }
    });

    test('round-trips standard edge cases', () {
      final codec = GzipCodec();
      standardEdgeCases().forEach((final name, final data) {
        expect(
          codec.decompress(codec.compress(data)),
          orderedEquals(data),
          reason: 'edge case: $name',
        );
      });
    });

    test('compresses highly compressible data well', () {
      final codec = GzipCodec();
      final data = bytes(List.filled(10000, 0x42));
      final compressed = codec.compress(data);
      expect(codec.decompress(compressed), equals(data));
      expect(compressed.length, lessThan(data.length ~/ 10));
    });

    group('levels', () {
      test('all levels 1-9 round-trip', () {
        final data = readDataFixture('html');
        for (var level = 1; level <= 9; level++) {
          final codec = GzipCodec(level: level);
          expect(
            codec.decompress(codec.compress(data)),
            equals(data),
            reason: 'level $level',
          );
        }
      });

      test('higher levels achieve better or equal compression on text', () {
        final data = readDataFixture('canterbury/alice29.txt');
        final fast = GzipCodec(level: 1).compress(data);
        final best = GzipCodec(level: 9).compress(data);
        expect(best.length, lessThanOrEqualTo(fast.length));
      });

      test('level 9 compresses at least as well as level 6', () {
        for (final name in [
          'large/world192.txt',
          'large/bible.txt',
          'geo.protodata',
        ]) {
          final data = readDataFixture(name);
          final six = GzipCodec(level: 6).compress(data).length;
          final nine = GzipCodec(level: 9).compress(data).length;
          expect(nine, lessThanOrEqualTo(six), reason: '$name: $six, $nine');
        }
      });

      test('matches reach back across 64 KB block boundaries', () {
        // Five copies of 20 KB of noise: every copy after the first is one
        // match chain, including those after the 64 KB block boundary.
        final noise = pseudoRandom(20000, 5);
        final data = bytes([for (var i = 0; i < 5; i++) ...noise]);
        for (var level = 1; level <= 9; level++) {
          final compressed = GzipCodec(level: level).compress(data);
          expect(compressed.length, lessThan(24000), reason: 'level $level');
        }
      });

      test(
        'incompressible data is stored: 1 MB of noise grows < 0.1%',
        () async {
          final data = pseudoRandom(1 << 20, 3);
          for (var level = 1; level <= 9; level++) {
            final block = GzipCodec(level: level).compress(data);
            final stream = await collect(
              GzipStreamCodec(level: level).compress(
                Stream.fromIterable([
                  for (var i = 0; i < data.length; i += 65536)
                    Uint8List.sublistView(data, i, i + 65536),
                ]),
              ),
            );
            for (final (mode, out) in [('block', block), ('stream', stream)]) {
              expect(
                out.length,
                lessThan(data.length * 1.001),
                reason: '$mode level $level',
              );
              expect(GzipCodec().decompress(out), equals(data));
            }
          }
        },
      );

      test('short input uses fixed Huffman, as gzip does', () {
        // 3 literals and an end of block in a fixed block take 5 bytes; a
        // dynamic block's code tables alone take more.
        final out = GzipCodec().compress(bytes('abc'.codeUnits));
        expect(out.length, 23);
        expect(GzipCodec().decompress(out), equals('abc'.codeUnits));
      });

      test('levels use dynamic Huffman for better compression', () {
        final data = bytes(List.filled(10000, 65));
        final one = GzipCodec(level: 1).compress(data);
        final six = GzipCodec(level: 6).compress(data);
        expect(one.length, lessThan(data.length / 10));
        expect(six.length, lessThan(data.length / 10));
      });
    });

    group('metadata', () {
      test('stores filename in header', () {
        final codec = GzipCodec(filename: 'test.txt');
        final data = bytes([1, 2, 3, 4, 5]);
        expect(codec.decompress(codec.compress(data)), equals(data));
      });

      test('stores comment in header', () {
        final codec = GzipCodec(comment: 'Test file');
        final data = bytes([1, 2, 3, 4, 5]);
        expect(codec.decompress(codec.compress(data)), equals(data));
      });

      test('stores both filename and comment', () {
        final codec = GzipCodec(filename: 'data.bin', comment: 'Test data');
        final data = bytes([1, 2, 3, 4, 5]);
        expect(codec.decompress(codec.compress(data)), equals(data));
      });

      test('empty filename is allowed', () {
        final codec = GzipCodec(filename: '');
        final data = bytes([1, 2, 3]);
        expect(codec.decompress(codec.compress(data)), equals(data));
      });

      test('unicode filename is allowed', () {
        final codec = GzipCodec(filename: 'テスト.txt');
        final data = bytes([1, 2, 3]);
        expect(codec.decompress(codec.compress(data)), equals(data));
      });

      test('unicode comment is allowed', () {
        final codec = GzipCodec(comment: 'コメント');
        final data = bytes([1, 2, 3]);
        expect(codec.decompress(codec.compress(data)), equals(data));
      });
    });

    group('concatenated members (RFC 1952)', () {
      test('two members decode to the concatenation', () {
        final codec = GzipCodec();
        final first = bytes('Hello, '.codeUnits);
        final second = bytes('World!'.codeUnits);
        final concatenated = bytes([
          ...codec.compress(first),
          ...codec.compress(second),
        ]);
        expect(
          codec.decompress(concatenated),
          equals(bytes([...first, ...second])),
        );
      });

      test('multiple members decode to the concatenation', () {
        final codec = GzipCodec();
        final parts = ['one', 'two', 'three', 'four', 'five'];
        final builder = BytesBuilder(copy: false);
        for (final part in parts) {
          builder.add(codec.compress(bytes(part.codeUnits)));
        }
        expect(
          String.fromCharCodes(codec.decompress(builder.takeBytes())),
          equals(parts.join()),
        );
      });

      test('respects maxSize across members', () {
        final first = bytes('12345'.codeUnits); // 5 bytes
        final second = bytes('67890'.codeUnits); // 5 bytes
        final third = bytes('ABCDE'.codeUnits); // 5 bytes

        final compressed1 = GzipCodec().compress(first);
        final compressed2 = GzipCodec().compress(second);
        final compressed3 = GzipCodec().compress(third);

        // Limit of 10: two members (10 bytes) decode successfully.
        final two = bytes([...compressed1, ...compressed2]);
        expect(GzipCodec(maxSize: 10).decompress(two).length, equals(10));

        // Limit of 12: three members (15 bytes) exceed the cumulative limit.
        final three = bytes([...compressed1, ...compressed2, ...compressed3]);
        expect(
          () => GzipCodec(maxSize: 12).decompress(three),
          throwsA(anything),
        );
      });
    });

    group('dart:io interop', () {
      test('output is readable by dart:io gzip decoder', () {
        final codec = GzipCodec();
        final data = bytes(List.generate(256, (final i) => i));
        expect(bytes(gzip.decode(codec.compress(data))), equals(data));
      });
    });

    // Deterministic compression-ratio regression gate (machine-independent):
    // floors sit a few points below measured savings so an algorithmic
    // regression trips while routine byte-shifting tweaks do not.
    test('meets compression-ratio floors on the corpus', () {
      const floors = <String, double>{
        'canterbury/alice29.txt': 58,
        'calgary/paper1': 61,
        'large/bible.txt': 65,
      };
      floors.forEach((final file, final floor) {
        final path = 'test/fixtures/data/$file';
        if (!File(path).existsSync()) {
          markTestSkipped('fixture missing: $path');
          return;
        }
        final data = readDataFixture(file);
        final compressed = GzipCodec().compress(data);
        final savings = (data.length - compressed.length) * 100.0 / data.length;
        expect(
          savings,
          greaterThanOrEqualTo(floor),
          reason:
              '$file: ${savings.toStringAsFixed(1)}% savings fell below the '
              '$floor% floor — compression-ratio regression',
        );
      });
    });
  });

  group('GZIP streaming', () {
    test('a large input chunk is decoded in bounded output chunks', () async {
      final data = readDataFixture('large/bible.txt');
      final compressed = GzipCodec().compress(data);
      final sizes = <int>[];
      final output = BytesBuilder(copy: false);
      await for (final chunk in GzipStreamCodec().decompress(
        Stream.value(compressed),
      )) {
        sizes.add(chunk.length);
        output.add(chunk);
      }
      expect(output.takeBytes(), orderedEquals(data));
      // One 64 KB drain interval plus at most one 258-byte match.
      expect(sizes.reduce(max), lessThanOrEqualTo(65536 + 258));
    });

    test('stream output does not depend on how the input is chunked', () async {
      final data = readDataFixture('canterbury/alice29.txt');
      Future<Uint8List> compress(final int size) => collect(
        GzipStreamCodec().compress(
          Stream.fromIterable([
            for (var i = 0; i < data.length; i += size)
              Uint8List.sublistView(data, i, min(i + size, data.length)),
          ]),
        ),
      );
      final whole = await compress(data.length);
      for (final size in [1, 300, 4096, 70000]) {
        expect(await compress(size), equals(whole), reason: 'chunks of $size');
      }
      expect(GzipCodec().decompress(whole), equals(data));
      // Blocks of 64 KB match across block boundaries like the one-shot codec.
      expect(whole.length, lessThan(GzipCodec().compress(data).length * 1.01));
    });

    test(
      'the stream codec writes filename and comment like GzipCodec',
      () async {
        final data = bytes('payload '.codeUnits);
        final block = GzipCodec(
          filename: 'a.txt',
          comment: 'note',
        ).compress(data);
        final stream = await collect(
          GzipStreamCodec(
            filename: 'a.txt',
            comment: 'note',
          ).compress(Stream.value(data)),
        );
        const header = 10 + 6 + 5; // fixed part, 'a.txt' + NUL, 'note' + NUL
        expect(stream.sublist(0, header), equals(block.sublist(0, header)));
        expect(GzipCodec().decompress(stream), equals(data));
        expect(() => GzipStreamCodec(filename: 'a\u0000'), throwsArgumentError);
      },
    );

    test('a header with FNAME and FCOMMENT parses at every split', () async {
      final data = bytes('payload '.codeUnits);
      final member = GzipCodec(
        filename: 'name.txt',
        comment: 'a comment here',
      ).compress(data);
      for (var split = 1; split < member.length; split++) {
        final out = await collect(
          GzipStreamCodec().decompress(
            Stream.fromIterable([
              Uint8List.sublistView(member, 0, split),
              Uint8List.sublistView(member, split),
            ]),
          ),
        );
        expect(out, equals(data), reason: 'split at $split');
      }
    });

    test(
      'a long FNAME split across many chunks parses in linear time',
      () async {
        final name = String.fromCharCodes(List.filled(8 << 20, 0x61));
        final compressed = GzipCodec(filename: name).compress(bytes([1, 2, 3]));
        const size = 4096;
        final chunks = [
          for (var start = 0; start < compressed.length; start += size)
            Uint8List.sublistView(
              compressed,
              start,
              min(start + size, compressed.length),
            ),
        ];
        final watch = Stopwatch()..start();
        final restored = await collect(
          GzipStreamCodec().decompress(Stream.fromIterable(chunks)),
        );
        watch.stop();
        expect(restored, orderedEquals([1, 2, 3]));
        // Rescanning the header from the start on every chunk takes seconds.
        expect(watch.elapsedMilliseconds, lessThan(500));
      },
    );

    test('round-trips multi-chunk input', () async {
      final chunks = [
        bytes('the quick brown fox '.codeUnits),
        bytes(List.generate(5000, (final i) => i % 256)),
        bytes('jumps over the lazy dog '.codeUnits),
        bytes(List.generate(3000, (final i) => (i * 7) % 13)),
      ];
      await expectStreamRoundTrip(GzipStreamCodec(), chunks);
      // Block decoder must also read the streamed output.
      final compressed = await collect(
        GzipStreamCodec().compress(Stream.fromIterable(chunks)),
      );
      expect(
        GzipCodec().decompress(compressed),
        orderedEquals(bytes(chunks.expand((final c) => c))),
      );
    });

    test('output is a single GZIP member', () async {
      final data = bytes(List.generate(40000, (final i) => (i * 3) % 251));
      final compressed = await collect(
        GzipStreamCodec().compress(Stream.value(data)),
      );
      expect(compressed[0], 0x1f);
      expect(compressed[1], 0x8b);
      // Decodes as a single member via the block decoder.
      expect(GzipCodec().decompress(compressed), orderedEquals(data));
    });

    test('cross-chunk history compresses repeated chunks well', () async {
      // The same 8 KB block sent as 8 separate chunks: with cross-chunk
      // history, chunks 2..8 are long back-references into chunk 1, so the
      // total is far smaller than 8x a single block.
      final block = bytes(List.generate(8192, (final i) => (i * 31 + 7) % 256));
      final chunks = List.generate(8, (_) => block);
      final compressed = await collect(
        GzipStreamCodec().compress(Stream.fromIterable(chunks)),
      );
      final singleBlock = await collect(
        GzipStreamCodec().compress(Stream.value(block)),
      );
      expect(
        compressed.length,
        lessThan(singleBlock.length * 2),
        reason: '8 identical chunks should not cost ~8x one chunk',
      );
      final restored = await collect(
        GzipStreamCodec().decompress(Stream.value(compressed)),
      );
      expect(restored, orderedEquals(bytes(chunks.expand((final c) => c))));
    });

    test('round-trips empty stream', () async {
      final compressed = await collect(
        GzipStreamCodec().compress(const Stream.empty()),
      );
      expect(GzipCodec().decompress(compressed), isEmpty);
      final restored = await collect(
        GzipStreamCodec().decompress(Stream.value(compressed)),
      );
      expect(restored, isEmpty);
    });

    test('any chunking decodes like the block decoder', () async {
      // Native-gzip fixtures plus our own output at each strategy, fed in
      // chunk sizes that split symbols, block headers and trailers.
      final members = <String, Uint8List>{
        for (final path in standardFixtures)
          'gzip CLI $path': readCodecFixture('gzip', '$path.gz'),
        for (final level in [1, 6, 9])
          'level $level alice29': GzipCodec(
            level: level,
          ).compress(readDataFixture('canterbury/alice29.txt')),
      };
      for (final entry in members.entries) {
        final expected = GzipCodec().decompress(entry.value);
        for (final chunk in [1, 7, 13, 4093]) {
          final actual = await decodeChunked(
            GzipStreamCodec(),
            entry.value,
            chunk: chunk,
          );
          expect(actual, equals(expected), reason: '${entry.key} @ $chunk');
        }
      }
    });

    test('fragmented 1-byte round-trips compressible text', () async {
      const pattern = 'the quick brown fox jumps over the lazy dog. ';
      final data = bytes(
        List.generate(
          8 * 1024,
          (final i) => pattern.codeUnitAt(i % pattern.length),
        ),
      );
      await expectFragmentedRoundTrip(GzipStreamCodec(), data);
    });

    test(
      'fragmented 1-byte round-trips incompressible (stored-block) data',
      () async {
        // Pseudo-random, incompressible -> DEFLATE stored blocks.
        await expectFragmentedRoundTrip(
          GzipStreamCodec(),
          pseudoRandom(4 * 1024),
        );
      },
    );

    test('fragmented 1-byte round-trips a corpus file', () async {
      await expectFragmentedRoundTrip(
        GzipStreamCodec(),
        readDataFixture('canterbury/alice29.txt'),
      );
    });

    test('truncated member fed fragmented is rejected', () async {
      final data = bytes(List.generate(4096, (final i) => i % 256));
      final compressed = GzipCodec().compress(data);
      final truncated = Uint8List.sublistView(
        compressed,
        0,
        compressed.length - 4,
      );
      final oneByte = [
        for (var i = 0; i < truncated.length; i++)
          Uint8List.sublistView(truncated, i, i + 1),
      ];
      expect(
        () =>
            collect(GzipStreamCodec().decompress(Stream.fromIterable(oneByte))),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('verified mode round-trips valid data', () async {
      final data = bytes(List.generate(20000, (final i) => (i * 5) % 97));
      final codec = GzipStreamCodec(verified: true);
      final compressed = await collect(codec.compress(Stream.value(data)));
      final restored = await collect(
        codec.decompress(Stream.value(compressed)),
      );
      expect(restored, orderedEquals(data));
    });

    test(
      'verified mode withholds all output when a trailer CRC is corrupt',
      () async {
        final payload = bytes(
          List.generate(5000, (final i) => (i * 31 + 7) % 256),
        );
        final comp = bytes(GzipCodec().compress(payload));
        comp[comp.length - 5] ^= 0xFF; // flip a CRC32 trailer byte
        final out = <int>[];
        Object? err;
        try {
          await for (final chunk in GzipStreamCodec(
            verified: true,
          ).decompress(Stream.value(comp))) {
            out.addAll(chunk);
          }
        } catch (e) {
          err = e;
        }
        expect(err, isA<CompressionFormatException>());
        expect(
          out,
          isEmpty,
          reason:
              'verified mode must not emit bytes from a member that fails CRC',
        );
      },
    );
  });

  group('GZIP limits & validation', () {
    test('a filename or comment containing NUL is rejected', () {
      expect(() => GzipCodec(filename: 'a\u0000b'), throwsArgumentError);
      expect(() => GzipCodec(comment: '\u0000'), throwsArgumentError);
      final codec = GzipCodec(filename: 'a.txt', comment: 'ok');
      expect(codec.decompress(codec.compress(bytes([1, 2]))), [1, 2]);
    });

    test('maxSize holds for literals at the end of the input', () {
      // Mostly literals, so the last ones are decoded after the fast loop.
      final random = Random(7);
      for (final size in [5000, 9000, 20000]) {
        final data = bytes(List.generate(size, (_) => 97 + random.nextInt(40)));
        final packed = GzipCodec().compress(data);
        for (final limit in [size - 1, size - 10]) {
          expect(
            () => GzipCodec(maxSize: limit).decompress(packed),
            throwsA(isA<LimitException>()),
            reason: '$size bytes, maxSize $limit',
          );
        }
        expect(GzipCodec(maxSize: size).decompress(packed), equals(data));
      }
    });

    test('rejects empty input in block and stream mode', () async {
      await expectEmptyRejected<GzipFormatException>(
        GzipCodec(),
        GzipStreamCodec(),
      );
    });

    test('maxSize rejects oversized output', () {
      final data = bytes(List.filled(10000, 0x41));
      final compressed = GzipCodec().compress(data);
      expect(
        () => GzipCodec(maxSize: 1000).decompress(compressed),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('maxSize is enforced cumulatively across members', () {
      final first = GzipCodec().compress(bytes(List.filled(600, 0x41)));
      final second = GzipCodec().compress(bytes(List.filled(600, 0x42)));
      final concatenated = bytes([...first, ...second]);
      // Each member (600) fits under 1000, but the sum (1200) does not.
      expect(
        () => GzipCodec(maxSize: 1000).decompress(concatenated),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('fromOptions preserves and enforces the limit', () {
      final options = GzipOptions(maxSize: 1000);
      final codec = GzipCodec.fromOptions(options);
      expect(codec.maxSize, 1000);
      final compressed = GzipCodec().compress(bytes(List.filled(10000, 0x41)));
      expect(
        () => codec.decompress(compressed),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('fromOptions preserves level/filename/comment', () {
      final options = GzipOptions(
        level: 9,
        filename: 'test.txt',
        comment: 'Test comment',
      );
      final codec = GzipCodec.fromOptions(options);
      expect(codec.level, 9);
      expect(codec.filename, 'test.txt');
      expect(codec.comment, 'Test comment');
    });

    test('fromOptions defaults', () {
      final codec = GzipCodec.fromOptions(GzipOptions());
      expect(codec.level, 6);
      expect(codec.filename, isNull);
      expect(codec.comment, isNull);
    });

    test('rejects level below 1', () {
      expect(() => GzipCodec(level: 0), throwsArgumentError);
    });

    test('rejects level above 9', () {
      expect(() => GzipCodec(level: 10), throwsArgumentError);
    });

    test('rejects non-positive maxSize', () {
      expect(() => GzipCodec(maxSize: 0), throwsArgumentError);
      expect(() => GzipCodec(maxSize: -1), throwsArgumentError);
    });

    test('stream codec rejects out-of-range constructor params', () {
      expect(() => GzipStreamCodec(level: 0), throwsArgumentError);
      expect(() => GzipStreamCodec(maxBufferSize: 0), throwsArgumentError);
      expect(() => GzipStreamCodec(maxSize: 0), throwsArgumentError);
    });

    test('stream maxBufferSize rejects an oversized chunk before buffering', () {
      // Incompressible payload so the compressed blob stays well over the cap.
      final blob = GzipCodec().compress(
        bytes(List.generate(5000, (final i) => (i * 131 + 7) % 256)),
      );
      expect(blob.length, greaterThan(64));
      // Whole compressed blob arrives as ONE chunk, far over the tiny cap.
      final out = GzipStreamCodec(
        maxBufferSize: 64,
      ).decompress(Stream.value(blob));
      expect(out.toList(), throwsA(isA<CompressionFormatException>()));
    });

    test('stream maxSize is enforced cumulatively across members', () {
      final payload = bytes(List.filled(1000, 65)); // 1000 'A'
      final member = GzipCodec().compress(payload);
      // Five members decode to 5000 bytes; each is under the cap, the sum is not.
      final five = bytes([for (var i = 0; i < 5; i++) ...member]);
      expect(
        decodeChunked(GzipStreamCodec(maxSize: 2500), five),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('stream maxSize allows cumulative output up to the cap', () async {
      final payload = bytes(List.filled(1000, 65));
      final member = GzipCodec().compress(payload);
      final two = bytes([...member, ...member]); // 2000 out
      final out = await decodeChunked(GzipStreamCodec(maxSize: 5000), two);
      expect(out.length, 2000);
    });

    for (final chunk in [65536, 1]) {
      test('stream maxSize breach reports the limit ($chunk-byte chunks)', () {
        // A member far larger than the cap must fail as a size-limit error,
        // not be mistaken for truncated input.
        final size = chunk == 1 ? 20000 : 300000;
        final member = GzipCodec().compress(
          bytes(
            List.generate(size, (final i) => 'limit test '.codeUnitAt(i % 11)),
          ),
        );
        expect(
          decodeChunked(GzipStreamCodec(maxSize: 5000), member, chunk: chunk),
          throwsA(
            isA<LimitException>().having(
              (final e) => e.message,
              'message',
              contains('exceeds the limit'),
            ),
          ),
        );
      });
    }
  });

  group('GZIP CLI compatibility', () {
    test('decompresses CLI-generated fixtures', () {
      final codec = GzipCodec();
      for (final path in standardFixtures) {
        final original = readDataFixture(path);
        final compressed = readCodecFixture('gzip', '$path.gz');
        expect(
          codec.decompress(compressed),
          equals(original),
          reason: 'fixture $path',
        );
      }
    });

    test('all levels output readable by gzip CLI', () async {
      if (!await cliAvailableCached('gzip')) return;
      final original = readDataFixture('html');
      for (var level = 1; level <= 9; level++) {
        final compressed = GzipCodec(level: level).compress(original);
        final path = '/tmp/libcompress_gzip_level$level.gz';
        try {
          await File(path).writeAsBytes(compressed);
          final result = await Process.run('gzip', [
            '-d',
            '-k',
            '-c',
            path,
          ], stdoutEncoding: null);
          expect(
            result.exitCode,
            0,
            reason: 'gzip failed at level $level: ${result.stderr}',
          );
          expect(
            result.stdout as List<int>,
            equals(original),
            reason: 'level $level',
          );
        } finally {
          await cleanup([path]);
        }
      }
    });

    test(
      'levels 6 and 9 are within 5% of gzip, and gzip -t accepts every level',
      () async {
        if (!await cliAvailableCached('gzip')) return;
        final dir = Directory.systemTemp.createTempSync('libcompress_gzip');
        try {
          for (final name in [
            'large/world192.txt',
            'large/bible.txt',
            'geo.protodata',
          ]) {
            final source = 'test/fixtures/data/$name';
            final original = readDataFixture(name);
            for (var level = 1; level <= 9; level++) {
              final compressed = GzipCodec(level: level).compress(original);
              final path = '${dir.path}/l$level.gz';
              File(path).writeAsBytesSync(compressed);
              final check = await Process.run('gzip', ['-t', path]);
              expect(check.exitCode, 0, reason: '$name $level ${check.stderr}');
              if (level != 6 && level != 9) continue;

              final reference = await Process.run('gzip', [
                '-$level',
                '-c',
                source,
              ], stdoutEncoding: null);
              final theirs = (reference.stdout as List<int>).length;
              final stream = await collect(
                GzipStreamCodec(level: level).compress(
                  Stream.fromIterable([
                    for (var i = 0; i < original.length; i += 65536)
                      Uint8List.sublistView(
                        original,
                        i,
                        min(i + 65536, original.length),
                      ),
                  ]),
                ),
              );
              for (final (mode, ours) in [
                ('block', compressed.length),
                ('stream', stream.length),
              ]) {
                expect(
                  ours,
                  lessThanOrEqualTo(theirs * 1.05),
                  reason: '$name $mode level $level: $ours vs gzip $theirs',
                );
              }
            }
          }
        } finally {
          dir.deleteSync(recursive: true);
        }
      },
    );

    test('filename header output readable by gzip CLI', () async {
      if (!await cliAvailableCached('gzip')) return;
      final compressed = GzipCodec(
        filename: 'test.txt',
      ).compress(readDataFixture('html'));
      final original = readDataFixture('html');
      final path = '/tmp/libcompress_gzip_name.gz';
      try {
        await File(path).writeAsBytes(compressed);
        final result = await Process.run('gzip', [
          '-d',
          '-k',
          '-c',
          path,
        ], stdoutEncoding: null);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stdout as List<int>, equals(original));
      } finally {
        await cleanup([path]);
      }
    });

    test('comment header output readable by gzip CLI', () async {
      if (!await cliAvailableCached('gzip')) return;
      final compressed = GzipCodec(
        comment: 'Test comment',
      ).compress(readDataFixture('html'));
      final original = readDataFixture('html');
      final path = '/tmp/libcompress_gzip_comment.gz';
      try {
        await File(path).writeAsBytes(compressed);
        final result = await Process.run('gzip', [
          '-d',
          '-k',
          '-c',
          path,
        ], stdoutEncoding: null);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stdout as List<int>, equals(original));
      } finally {
        await cleanup([path]);
      }
    });

    test('all fixtures round-trip through gzip CLI', () async {
      if (!await cliAvailableCached('gzip')) return;
      final codec = GzipCodec();
      for (final fixture in standardFixtures) {
        final original = readDataFixture(fixture);
        final compressed = codec.compress(original);
        final path =
            '/tmp/libcompress_gzip_rt_${fixture.replaceAll('/', '_')}.gz';
        try {
          await File(path).writeAsBytes(compressed);
          final result = await Process.run('gzip', [
            '-d',
            '-k',
            '-c',
            path,
          ], stdoutEncoding: null);
          expect(result.exitCode, 0, reason: 'CLI failed for $fixture');
          expect(
            result.stdout as List<int>,
            equals(original),
            reason: 'round-trip mismatch for $fixture',
          );
        } finally {
          await cleanup([path]);
        }
      }
    });

    test('bidirectional: lib->CLI->CLI->lib', () async {
      if (!await cliAvailableCached('gzip')) return;
      final codec = GzipCodec();
      final original = readDataFixture('calgary/paper1');
      final libCompressed = codec.compress(original);

      final path = '/tmp/libcompress_gzip_bidir.gz';
      final out = '/tmp/libcompress_gzip_bidir.out';
      final cliPath = '/tmp/libcompress_gzip_cli.gz';
      try {
        // Library compress -> CLI decompress.
        await File(path).writeAsBytes(libCompressed);
        final result = await Process.run('gzip', [
          '-d',
          '-k',
          '-f',
          '-c',
          path,
        ], stdoutEncoding: null);
        expect(result.exitCode, 0);
        final cliOut = result.stdout as List<int>;
        expect(cliOut, equals(original));

        // CLI compress -> library decompress.
        await File(out).writeAsBytes(cliOut);
        final result2 = await Process.run('gzip', [
          '-k',
          '-f',
          '-c',
          out,
        ], stdoutEncoding: null);
        expect(result2.exitCode, 0);
        await File(cliPath).writeAsBytes(result2.stdout as List<int>);
        final cliCompressed = await File(cliPath).readAsBytes();
        expect(codec.decompress(bytes(cliCompressed)), equals(original));
      } finally {
        await cleanup([path, out, cliPath]);
      }
    });
  });

  defineDifferentialFuzz(
    title: 'GZIP',
    reference: const Reference('gzip', ['-d', '-c']),
    frames: {
      for (final level in [1, 6, 9])
        'gzip CLI -$level': () => const Reference(
          'gzip',
          [],
        ).encode(['-c', '-$level'], readDataFixture('canterbury/alice29.txt')),
      'libcompress encoder': () async =>
          GzipCodec().compress(readDataFixture('canterbury/alice29.txt')),
    },
    block: GzipCodec().decompress,
    stream: GzipStreamCodec().decompress,
  );

  group('GZIP fuzzing / malformed input', () {
    final random = Random(42);
    final codec = GzipCodec();

    test('rejects pure random noise', () {
      for (var i = 0; i < 100; i++) {
        final noise = bytes(
          List.generate(random.nextInt(1000) + 1, (_) => random.nextInt(256)),
        );
        expect(
          () => codec.decompress(noise),
          throwsA(isA<GzipFormatException>()),
        );
      }
    });

    test('rejects short random data', () {
      for (var length = 0; length < 20; length++) {
        final noise = bytes(List.generate(length, (_) => random.nextInt(256)));
        expect(
          () => codec.decompress(noise),
          throwsA(isA<GzipFormatException>()),
          reason: 'short random data ($length bytes)',
        );
      }
    });

    test('rejects truncation at various positions', () {
      final valid = codec.compress(
        bytes(List.generate(1000, (final i) => i % 256)),
      );
      for (var cutoff = 1; cutoff < valid.length; cutoff++) {
        final truncated = Uint8List.sublistView(valid, 0, cutoff);
        expect(
          () => codec.decompress(truncated),
          throwsA(isA<CompressionFormatException>()),
          reason: 'truncated at $cutoff',
        );
      }
    });

    test('rejects wrong magic number', () {
      final data = bytes([
        0x00,
        0x00,
        0x08,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0xFF,
      ]);
      expect(() => codec.decompress(data), throwsA(isA<GzipFormatException>()));
    });

    test('rejects corrupted ID1', () {
      final data = bytes([
        0x00,
        0x8B,
        0x08,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0xFF,
      ]);
      expect(() => codec.decompress(data), throwsA(isA<GzipFormatException>()));
    });

    test('rejects corrupted ID2', () {
      final data = bytes([
        0x1F,
        0x00,
        0x08,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0xFF,
      ]);
      expect(() => codec.decompress(data), throwsA(isA<GzipFormatException>()));
    });

    test('rejects unsupported compression method', () {
      final data = bytes([
        0x1F,
        0x8B,
        0x09,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0xFF,
      ]);
      expect(() => codec.decompress(data), throwsA(isA<GzipFormatException>()));
    });

    test('rejects compression method 0', () {
      final data = bytes([
        0x1F,
        0x8B,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0xFF,
      ]);
      expect(() => codec.decompress(data), throwsA(isA<GzipFormatException>()));
    });

    test('rejects FEXTRA with truncated length', () {
      final data = bytes([
        0x1F,
        0x8B,
        0x08,
        0x04,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0xFF,
      ]);
      expect(() => codec.decompress(data), throwsA(isA<GzipFormatException>()));
    });

    test('rejects FEXTRA with truncated data', () {
      final data = bytes([
        0x1F, 0x8B, 0x08, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
        0x10, 0x00, // XLEN = 16
        0x01, 0x02, // only 2 bytes
      ]);
      expect(() => codec.decompress(data), throwsA(isA<GzipFormatException>()));
    });

    test('rejects FNAME without null terminator', () {
      final data = bytes([
        0x1F, 0x8B, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
        0x66, 0x69, 0x6C, 0x65, // "file"
      ]);
      expect(() => codec.decompress(data), throwsA(isA<GzipFormatException>()));
    });

    test('rejects FCOMMENT without null terminator', () {
      final data = bytes([
        0x1F, 0x8B, 0x08, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
        0x74, 0x65, 0x73, 0x74, // "test"
      ]);
      expect(() => codec.decompress(data), throwsA(isA<GzipFormatException>()));
    });

    test('rejects FHCRC with truncated checksum', () {
      final data = bytes([
        0x1F, 0x8B, 0x08, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
        0x00, // only 1 byte of CRC16
      ]);
      expect(() => codec.decompress(data), throwsA(isA<GzipFormatException>()));
    });

    test('rejects invalid DEFLATE block type', () {
      final data = bytes([
        0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
        0x07, // BFINAL=1, BTYPE=11 (reserved)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects stored block with wrong NLEN', () {
      final data = bytes([
        0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
        0x01, // stored block, final
        0x05, 0x00, // LEN = 5
        0x00, 0x00, // NLEN wrong
        0x48, 0x65, 0x6C, 0x6C, 0x6F, // "Hello"
        0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects invalid CRC32', () {
      final corrupted = bytes(codec.compress(bytes([1, 2, 3, 4, 5])));
      corrupted[corrupted.length - 5] ^= 0xFF;
      expect(
        () => codec.decompress(corrupted),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('rejects invalid ISIZE', () {
      final corrupted = bytes(codec.compress(bytes([1, 2, 3, 4, 5])));
      corrupted[corrupted.length - 1] ^= 0xFF;
      expect(
        () => codec.decompress(corrupted),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('rejects decompression bomb via maxSize', () {
      final compressed = codec.compress(bytes(List.filled(10000, 0x41)));
      expect(
        () => GzipCodec(maxSize: 1000).decompress(compressed),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('single-byte corruptions never leak StateError/RangeError', () {
      final valid = codec.compress(
        bytes(List.generate(5000, (final i) => i % 256)),
      );
      for (var i = 10; i < min(60, valid.length - 8); i++) {
        final corrupted = bytes(valid);
        corrupted[i] ^= 0xFF;
        try {
          codec.decompress(corrupted);
          // Undetected corruption (valid-but-wrong output) is acceptable.
        } on CompressionFormatException {
          // Expected.
        } on StateError {
          fail('corrupted byte at $i leaked a StateError');
        } on RangeError {
          fail('corrupted byte at $i caused RangeError');
        }
      }
    });

    test('rejects truncated second member', () {
      final member1 = codec.compress(bytes([1, 2, 3]));
      final partial = bytes([...member1, 0x1F, 0x8B, 0x08, 0x00]);
      expect(
        () => codec.decompress(partial),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('rejects garbage after valid member', () {
      final compressed = codec.compress(bytes([1, 2, 3]));
      final withGarbage = bytes([...compressed, 0x00, 0x01, 0x02, 0x03]);
      expect(
        () => codec.decompress(withGarbage),
        throwsA(isA<GzipFormatException>()),
      );
    });
  });

  group('DEFLATE decoding', () {
    test('many dynamic blocks with 15-bit codes decode within 3x zlib', () {
      // 20,000 dynamic blocks whose literal code reaches 15 bits, each
      // holding only an end-of-block code: table building dominates.
      final bits = _Bits();
      for (var i = 0; i < 20000; i++) {
        _deepBlock(bits, last: i == 19999);
      }
      final deflate = bits.finish();
      final member = bytes([
        0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3, //
        ...deflate,
        0, 0, 0, 0, 0, 0, 0, 0, // CRC32 and ISIZE of empty output
      ]);
      int time(final void Function() run) {
        final watch = Stopwatch()..start();
        run();
        return watch.elapsedMicroseconds;
      }

      expect(GzipCodec().decompress(member), isEmpty);
      GZipCodec().decode(member); // warm up
      // Alternate the two so both see the same load from parallel tests.
      var ours = 1 << 30;
      var zlib = 1 << 30;
      for (var i = 0; i < 10; i++) {
        ours = min(ours, time(() => GzipCodec().decompress(member)));
        zlib = min(zlib, time(() => GZipCodec().decode(member)));
      }
      expect(
        ours,
        lessThanOrEqualTo(zlib * 3),
        reason: 'ours $ours us, zlib $zlib us',
      );
    }, retry: 2);

    // Raw DEFLATE body of a GZIP member (10-byte header, 8-byte trailer).
    Uint8List body(final Uint8List member) =>
        Uint8List.sublistView(member, 10, member.length - 8);

    final text = bytes(
      List.generate(
        3000,
        (final i) => 'deflate edge cases '.codeUnitAt(i % 19),
      ),
    );

    test('stored blocks of maximum and zero length decode', () {
      final first = bytes(List.generate(65535, (final i) => (i * 7) & 0xFF));
      final last = bytes(List.generate(1000, (final i) => (i * 13) & 0xFF));
      final writer = BitStreamWriter();
      void stored(final Uint8List data, {required final bool last}) {
        writer.writeBits(last ? 1 : 0, 1);
        writer.writeBits(0, 2);
        writer.flushToByte();
        writer.writeBits(data.length, 16);
        writer.writeBits(~data.length & 0xFFFF, 16);
        for (final byte in data) {
          writer.writeBits(byte, 8);
        }
      }

      stored(first, last: false);
      stored(Uint8List(0), last: false);
      stored(last, last: true);
      expect(
        DeflateDecoder().decompress(writer.toBytes()),
        equals([...first, ...last]),
      );
    });

    for (final distance in [30, 31]) {
      test('fixed block rejects unassigned distance code $distance', () {
        // BFINAL=1, BTYPE=01, literal 'A', length code 257, distance code.
        // Fixed Huffman codes are written MSB-first, so reverse them.
        int reverse(final int code, final int length) {
          var result = 0;
          for (var i = 0; i < length; i++) {
            result = (result << 1) | ((code >> i) & 1);
          }
          return result;
        }

        final writer = BitStreamWriter()
          ..writeBits(1, 1)
          ..writeBits(1, 2)
          ..writeBits(reverse(0x30 + 0x41, 8), 8)
          ..writeBits(reverse(1, 7), 7)
          ..writeBits(reverse(distance, 5), 5)
          ..writeBits(0, 16);
        expect(
          () => DeflateDecoder().decompress(writer.toBytes()),
          throwsA(isA<DeflateFormatException>()),
        );
      });
    }

    for (final level in [1, 6]) {
      test('every truncation fails cleanly (level $level)', () {
        final deflate = body(GzipCodec(level: level).compress(text));
        expect(DeflateDecoder().decompress(deflate), equals(text));
        for (var length = 0; length < deflate.length; length++) {
          expect(
            () => DeflateDecoder().decompress(
              Uint8List.sublistView(deflate, 0, length),
            ),
            throwsA(isA<DeflateFormatException>()),
            reason: 'prefix of $length bytes',
          );
        }
      });
    }
  });

  group('GZIP format', () {
    group('MTIME', () {
      final text = bytes('reproducible'.codeUnits);
      List<int> mtime(final Uint8List member) => member.sublist(4, 8);

      test('defaults to 0, so identical input gives identical bytes', () async {
        expect(mtime(GzipCodec().compress(text)), orderedEquals([0, 0, 0, 0]));
        final streamed = await collect(
          GzipStreamCodec().compress(Stream.value(text)),
        );
        expect(mtime(streamed), orderedEquals([0, 0, 0, 0]));
      });

      test('a given mtime is written little-endian', () async {
        const value = 0x12345678;
        final little = [0x78, 0x56, 0x34, 0x12];
        expect(mtime(GzipCodec(mtime: value).compress(text)), little);
        expect(
          mtime(
            GzipCodec.fromOptions(GzipOptions(mtime: value)).compress(text),
          ),
          little,
        );
        final streamed = await collect(
          GzipStreamCodec(mtime: value).compress(Stream.value(text)),
        );
        expect(mtime(streamed), little);
      });

      test('rejects an mtime outside 32 bits', () {
        expect(() => GzipCodec(mtime: -1), throwsArgumentError);
        expect(() => GzipCodec(mtime: 1 << 32), throwsArgumentError);
      });
    });

    test('dynamic block with a deep Huffman tree stays decodable', () async {
      // Fibonacci literal frequencies push the unconstrained tree past 15
      // bits, so the encoder must limit code lengths without over-subscribing
      // the code space.
      final frequencies = <int>[1, 1];
      while (frequencies.length < 26) {
        frequencies.add(
          frequencies[frequencies.length - 1] +
              frequencies[frequencies.length - 2],
        );
      }
      final tokens = <Token>[];
      final literals = <int>[];
      for (var symbol = 0; symbol < frequencies.length; symbol++) {
        for (var i = 0; i < frequencies[symbol]; i++) {
          tokens.add(LiteralToken(symbol));
          literals.add(symbol);
        }
      }
      final writer = BitStreamWriter();
      DeflateEncoder().writeDynamicBlock(writer, tokens, isFinal: true);
      final deflate = writer.toBytes();
      expect(DeflateDecoder().decompress(deflate), equals(literals));

      if (!await cliAvailableCached('gzip')) return;
      final original = bytes(literals);
      final crc = Crc32.hash(original);
      final member = bytes([
        0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, //
        ...deflate,
        crc & 0xFF, (crc >> 8) & 0xFF, (crc >> 16) & 0xFF, crc >> 24, //
        original.length & 0xFF, (original.length >> 8) & 0xFF,
        (original.length >> 16) & 0xFF, original.length >> 24,
      ]);
      final path = '/tmp/libcompress_gzip_deep_tree.gz';
      try {
        await File(path).writeAsBytes(member);
        final result = await Process.run('gzip', [
          '-d',
          '-c',
          path,
        ], stdoutEncoding: null);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stdout as List<int>, equals(original));
      } finally {
        await cleanup([path]);
      }
    });

    test('header has correct magic and method', () {
      final compressed = GzipCodec().compress(
        bytes('Hello, GZIP world!'.codeUnits),
      );
      expect(compressed[0], equals(0x1F));
      expect(compressed[1], equals(0x8B));
      expect(compressed[2], equals(0x08)); // DEFLATE
    });

    test('rejects FHCRC header CRC16 mismatch', () {
      // A header CRC16 (FHCRC, FLG bit 1) must be honored if present.
      final body = GzipCodec().compress(bytes([0x48, 0x49]));
      final withFhcrc = bytes([
        0x1F, 0x8B, 0x08, 0x02, // FLG = FHCRC
        0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
        0x00, 0x00, // wrong CRC16
        ...body.sublist(10),
      ]);
      expect(
        () => GzipCodec().decompress(withFhcrc),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('trailer carries CRC32 and ISIZE', () {
      final data = bytes('trailer test'.codeUnits);
      final compressed = GzipCodec().compress(data);
      final isize =
          compressed[compressed.length - 4] |
          (compressed[compressed.length - 3] << 8) |
          (compressed[compressed.length - 2] << 16) |
          (compressed[compressed.length - 1] << 24);
      expect(isize, equals(data.length));
      // Corrupting the CRC32 (4 bytes before ISIZE) is rejected.
      final corrupted = bytes(compressed);
      corrupted[corrupted.length - 5] ^= 0xFF;
      expect(
        () => GzipCodec().decompress(corrupted),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('rejects reserved FLG bits set', () {
      final body = GzipCodec().compress(bytes([1, 2, 3]));
      final withReserved = bytes([
        0x1F, 0x8B, 0x08, 0xE0, // FLG reserved bits 5,6,7 set
        ...body.sublist(4),
      ]);
      expect(
        () => GzipCodec().decompress(withReserved),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('rejects reserved FLG bits on both block and stream paths', () {
      final withReserved = bytes([
        0x1F, 0x8B, 0x08, 0xE0, // magic, CM, FLG with reserved bits set
        0, 0, 0, 0, 0, 3, // mtime, xfl, os
        0x03, 0x00,
      ]);
      expect(
        () => GzipCodec().decompress(withReserved),
        throwsA(isA<CompressionFormatException>()),
      );
      expect(
        decodeChunked(GzipStreamCodec(), withReserved),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('stream rejects a member with an invalid header CRC16', () {
      // FLG=FHCRC (0x02) with a deliberately wrong 2-byte header CRC.
      final data = bytes([
        0x1F, 0x8B, 0x08, 0x02, // magic, CM=deflate, FLG=FHCRC
        0, 0, 0, 0, // mtime
        0, 3, // xfl, os
        0xFF, 0xFF, // wrong header CRC16
        0x03, 0x00, // (some DEFLATE bytes; never reached)
      ]);
      expect(
        decodeChunked(GzipStreamCodec(), data),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test(
      'corrupt DEFLATE body surfaces as GzipFormatException (block + stream)',
      () {
        final good = bytes(GzipCodec().compress(bytes(List.filled(300, 65))));
        for (var i = 12; i < good.length - 8; i++) {
          good[i] ^= 0xFF; // corrupt the DEFLATE body, leave framing intact
        }
        expect(
          () => GzipCodec().decompress(good),
          throwsA(isA<GzipFormatException>()),
        );
        expect(
          decodeChunked(GzipStreamCodec(), good),
          throwsA(isA<GzipFormatException>()),
        );
      },
    );
  });
}

/// LSB-first bit writer for hand-built DEFLATE streams.
class _Bits {
  final _bytes = <int>[];
  var _pending = 0;
  var _count = 0;

  void write(final int value, final int count) {
    for (var i = 0; i < count; i++) {
      _pending |= ((value >> i) & 1) << _count;
      if (++_count == 8) {
        _bytes.add(_pending);
        _pending = 0;
        _count = 0;
      }
    }
  }

  /// Writes a Huffman [code] of [length] bits, most significant bit first.
  void code(final int code, final int length) {
    for (var i = length - 1; i >= 0; i--) {
      write((code >> i) & 1, 1);
    }
  }

  List<int> finish() {
    if (_count > 0) _bytes.add(_pending);
    return _bytes;
  }
}

/// One dynamic block: literal lengths 1..14 for symbols 0..13 and 15 for
/// symbol 14 and end-of-block (a complete code), one 1-bit distance code, and
/// only the end-of-block symbol as content.
void _deepBlock(final _Bits bits, {required final bool last}) {
  bits
    ..write(last ? 1 : 0, 1)
    ..write(2, 2)
    ..write(0, 5) // HLIT 257
    ..write(0, 5) // HDIST 1
    ..write(15, 4); // HCLEN 19
  // Code-length code: symbols 1..15 and 18 get length 4 (16 codes, complete).
  const order = [
    16,
    17,
    18,
    0,
    8,
    7,
    9,
    6,
    10,
    5,
    11,
    4,
    12,
    3,
    13,
    2,
    14,
    1,
    15,
  ];
  for (final symbol in order) {
    bits.write((symbol >= 1 && symbol <= 15) || symbol == 18 ? 4 : 0, 3);
  }
  final codes = <int, int>{};
  var next = 0;
  for (final symbol in [
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    18,
  ]) {
    codes[symbol] = next++;
  }
  for (var length = 1; length <= 14; length++) {
    bits.code(codes[length]!, 4); // symbols 0..13
  }
  bits
    ..code(codes[15]!, 4) // symbol 14: length 15
    ..code(codes[18]!, 4)
    ..write(138 - 11, 7) // symbols 15..152: unused
    ..code(codes[18]!, 4)
    ..write(103 - 11, 7) // symbols 153..255: unused
    ..code(codes[15]!, 4) // end-of-block: length 15
    ..code(codes[1]!, 4) // distance code 0: length 1
    ..code(0x7FFF, 15); // end-of-block
}
