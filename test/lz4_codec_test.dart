import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';
import 'package:libcompress/src/util/xxh32.dart';
import 'package:test/test.dart';

import 'support/differential_fuzz.dart';
import 'support/parquet_pages.dart';
import 'test_utils.dart';

/// Compress [chunks] through the streaming codec, returning the full output.
Future<Uint8List> streamCompress(
  final Lz4StreamCodec codec,
  final List<Uint8List> chunks,
) => collect(codec.compress(Stream.fromIterable(chunks)));

/// Decompress [compressed] through the streaming codec fed in [chunkSize]-byte
/// chunks, returning the concatenated output.
Future<Uint8List> streamDecompress(
  final Lz4StreamCodec codec,
  final Uint8List compressed, {
  final int chunkSize = 1,
}) {
  final chunks = <Uint8List>[];
  for (var i = 0; i < compressed.length; i += chunkSize) {
    final end = (i + chunkSize) < compressed.length
        ? i + chunkSize
        : compressed.length;
    chunks.add(Uint8List.sublistView(compressed, i, end));
  }
  return collect(codec.decompress(Stream.fromIterable(chunks)));
}

void main() {
  group('LZ4 block', () {
    group('decompress stored fixtures', () {
      for (final path in standardFixtures) {
        test('decompresses $path', () {
          final compressed = readCodecFixture('lz4', '$path.lz4');
          final expected = readDataFixture(path);
          expect(Lz4Codec().decompress(compressed), orderedEquals(expected));
        });
      }
    });

    group('round-trips standard fixtures', () {
      for (final path in standardFixtures) {
        test('round-trips $path', () {
          expectRoundTrip(Lz4Codec(), readDataFixture(path));
        });
      }
    });

    group('round-trips standard edge cases', () {
      standardEdgeCases().forEach((final name, final data) {
        test('round-trips $name', () {
          expectRoundTrip(Lz4Codec(), data);
        });
      });
    });

    group('compression levels', () {
      test('all levels 1-9 round-trip', () {
        final data = readDataFixture('html');
        for (var level = 1; level <= 9; level++) {
          expectRoundTrip(Lz4Codec(level: level), data);
        }
      });

      test(
        'level 9 (HC) achieves better-or-equal compression than level 1',
        () {
          final data = readDataFixture('canterbury/alice29.txt');
          final fast = Lz4Codec(level: 1).compress(data);
          final hc = Lz4Codec(level: 9).compress(data);
          expect(hc.length, lessThanOrEqualTo(fast.length));
        },
      );

      test('ratio improves monotonically from level 1 to 9', () {
        for (final name in ['large/world192.txt', 'geo.protodata']) {
          final data = readDataFixture(name);
          final sizes = [
            for (var level = 1; level <= 9; level++)
              Lz4Codec(level: level).compress(data).length,
          ];
          for (var i = 1; i < sizes.length; i++) {
            expect(
              sizes[i],
              lessThanOrEqualTo(sizes[i - 1]),
              reason: '$name level ${i + 1}: $sizes',
            );
          }
          expect(sizes.last, lessThan(sizes.first), reason: '$name $sizes');
        }
      });

      test('HC reaches a match at offset 65535', () {
        Uint8List build(final int distance) {
          final repeat = pseudoRandom(64, 7);
          return bytes([
            ...repeat,
            ...pseudoRandom(distance - 64, 11),
            ...repeat,
            ...pseudoRandom(64, 13),
          ]);
        }

        for (var level = 2; level <= 9; level++) {
          final codec = Lz4Codec(level: level, format: Lz4Format.raw);
          final near = codec.compress(build(65535));
          final far = codec.compress(build(65536));
          expect(near.length, lessThan(far.length - 50), reason: '$level');
          expectRoundTrip(codec, build(65535));
        }
      });

      test('HC handles 64K block boundary', () {
        final data = bytes(List.generate(65536, (final i) => i % 256));
        expectRoundTrip(Lz4Codec(level: 9, blockSize: lz4BlockSize64K), data);
      });

      test('highly compressible data shrinks substantially', () {
        final data = bytes(List.filled(10000, 65));
        final compressed = Lz4Codec().compress(data);
        expect(compressed.length, lessThan(data.length ~/ 2));
        expect(Lz4Codec().decompress(compressed), orderedEquals(data));
      });
    });

    group('block sizes', () {
      final data = readDataFixture('canterbury/alice29.txt');
      for (final entry in {
        '64K': lz4BlockSize64K,
        '256K': lz4BlockSize256K,
        '1M': lz4BlockSize1M,
        '4M': lz4BlockSize4M,
      }.entries) {
        test('${entry.key} block size round-trips', () {
          expectRoundTrip(Lz4Codec(blockSize: entry.value), data);
        });
      }

      test('data exactly at 64K block boundary', () {
        final data = bytes(List.generate(65536, (final i) => i % 256));
        expectRoundTrip(Lz4Codec(blockSize: lz4BlockSize64K), data);
      });

      test('data spanning multiple 64K blocks', () {
        final data = bytes(List.generate(200000, (final i) => i % 256));
        expectRoundTrip(Lz4Codec(blockSize: lz4BlockSize64K), data);
      });
    });

    group('content checksum', () {
      final data = readDataFixture('html');
      test('enabled (default) round-trips', () {
        expectRoundTrip(Lz4Codec(checksum: true), data);
      });
      test('disabled round-trips', () {
        expectRoundTrip(Lz4Codec(checksum: false), data);
      });
    });

    group('concatenated frames', () {
      final a = bytes(List.generate(3000, (final i) => (i * 7) % 251));
      final b = bytes(List.generate(2000, (final i) => (i * 13 + 5) % 251));

      test('two appended frames decode to the concatenation', () {
        final cat = bytes([
          ...Lz4Codec().compress(a),
          ...Lz4Codec().compress(b),
        ]);
        expect(Lz4Codec().decompress(cat), orderedEquals([...a, ...b]));
      });

      test('maxSize is enforced cumulatively across frames', () {
        final cat = bytes([
          ...Lz4Codec().compress(a),
          ...Lz4Codec().compress(b),
        ]); // 5000 bytes total; each frame < 4000.
        expect(
          () => Lz4Codec(maxSize: 4000).decompress(cat),
          throwsA(isA<CompressionFormatException>()),
        );
      });

      test('a frame after the limit is used up exactly is rejected', () {
        // The first frame leaves no budget: the second may not slip through
        // in the buffer's starting capacity.
        final cat = bytes([
          ...Lz4Codec().compress(pseudoRandom(100, 1)),
          ...Lz4Codec().compress(pseudoRandom(900, 2)),
        ]);
        expect(
          () => Lz4Codec(maxSize: 100).decompress(cat),
          throwsA(isA<LimitException>()),
        );
      });
    });

    // Deterministic compression-ratio regression gate (machine-independent):
    // floors sit a few points below measured savings so an algorithmic
    // regression trips while routine byte-shifting tweaks do not.
    test('meets compression-ratio floors on the corpus', () {
      const floors = <String, double>{
        'canterbury/alice29.txt': 39,
        'calgary/paper1': 43,
        'large/bible.txt': 46,
      };
      floors.forEach((final file, final floor) {
        final path = 'test/fixtures/data/$file';
        if (!File(path).existsSync()) {
          markTestSkipped('fixture missing: $path');
          return;
        }
        final data = readDataFixture(file);
        final compressed = Lz4Codec().compress(data);
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

  group('LZ4 streaming', () {
    test('round-trips a 4 MB block with no matches', () async {
      // A multiplicative 16-bit counter written as 2 bytes per step: no
      // 4-byte sequence repeats within the 64 KB window, so the block is all
      // literals, the worst case for the encoder's output buffer.
      final data = Uint8List(4 << 20);
      for (var i = 0; i < data.length ~/ 2; i++) {
        final value = (i * 40503) & 0xFFFF;
        data[2 * i] = value >> 8;
        data[2 * i + 1] = value & 0xFF;
      }
      await expectStreamRoundTrip(Lz4StreamCodec(), [data]);
    });

    test('honours the level', () async {
      final data = readDataFixture('large/world192.txt');
      final chunks = [
        for (var i = 0; i < data.length; i += 65536)
          Uint8List.sublistView(data, i, min(i + 65536, data.length)),
      ];
      final fast = await streamCompress(Lz4StreamCodec(), chunks);
      final best = await streamCompress(Lz4StreamCodec(level: 9), chunks);
      expect(best.length, lessThan(fast.length * 0.8));
      await expectStreamRoundTrip(Lz4StreamCodec(level: 9), chunks);
    });

    test('small chunks are buffered into whole blocks', () async {
      final data = readDataFixture('large/world192.txt');
      final chunks = [
        for (var i = 0; i < data.length; i += 1024)
          Uint8List.sublistView(data, i, min(i + 1024, data.length)),
      ];
      final codec = Lz4StreamCodec();
      final whole = await streamCompress(codec, [data]);
      await streamCompress(codec, chunks);
      final watch = Stopwatch()..start();
      final split = await streamCompress(codec, chunks);
      watch.stop();
      expect(split, orderedEquals(whole));
      expect(watch.elapsedMilliseconds, lessThan(100));
    }, retry: 2);

    test('round-trips multi-chunk input', () async {
      final chunks = [
        bytes(List.generate(5000, (final i) => i % 256)),
        bytes('the quick brown fox '.codeUnits),
        bytes(List.generate(9000, (final i) => (i * 7) % 13)),
      ];
      await expectStreamRoundTrip(Lz4StreamCodec(blockSize: 65536), chunks);
    });

    test('cross-chunk history compresses repeated chunks well', () async {
      final block = bytes(List.generate(8192, (final i) => (i * 31 + 7) % 256));
      final chunks = List.generate(8, (_) => block);
      final codec = Lz4StreamCodec(blockSize: 65536);
      final compressed = await streamCompress(codec, chunks);
      final single = await streamCompress(codec, [block]);
      expect(
        compressed.length,
        lessThan(single.length * 4),
        reason: '8 identical chunks should be far less than 8x one chunk',
      );
      expect(
        await streamDecompress(codec, compressed),
        orderedEquals(bytes(chunks.expand((final c) => c))),
      );
    });

    test('round-trips empty stream', () async {
      final compressed = await streamCompress(Lz4StreamCodec(), []);
      expect(Lz4Codec().decompress(compressed), isEmpty);
      expect(await streamDecompress(Lz4StreamCodec(), compressed), isEmpty);
    });

    test(
      'output frame uses linked blocks (independent-blocks flag cleared)',
      () async {
        final compressed = await streamCompress(
          Lz4StreamCodec(blockSize: 65536),
          [bytes(List.generate(20000, (final i) => (i * 3) % 97))],
        );
        // FLG byte at offset 4; bit 0x20 = independent blocks, must be clear.
        expect(compressed[4] & 0x20, equals(0));
      },
    );

    test('fragmented (1-byte) round-trip on small data', () async {
      await expectFragmentedRoundTrip(
        Lz4StreamCodec(),
        bytes('Hello, LZ4 streaming!'.codeUnits),
      );
    });

    test('fragmented (1-byte) round-trip on a corpus file', () async {
      await expectFragmentedRoundTrip(
        Lz4StreamCodec(blockSize: 65536),
        readDataFixture('canterbury/alice29.txt'),
      );
    });

    test('fragmented multi-block compressible data round-trips', () async {
      const pattern = 'the quick brown fox jumps over the lazy dog. ';
      final original = bytes(
        List.generate(
          200 * 1024,
          (final i) => pattern.codeUnitAt(i % pattern.length),
        ),
      );
      final codec = Lz4StreamCodec(blockSize: 65536);
      final compressed = await streamCompress(codec, [original]);
      expect(
        await streamDecompress(codec, compressed),
        orderedEquals(original),
      );
    });

    test(
      'fragmented incompressible (uncompressed-block) data round-trips',
      () async {
        final original = pseudoRandom(150 * 1024);
        final codec = Lz4StreamCodec(blockSize: 65536);
        final compressed = await streamCompress(codec, [original]);
        expect(
          await streamDecompress(codec, compressed),
          orderedEquals(original),
        );
      },
    );

    test('fragmented concatenated frames round-trip', () async {
      final a = bytes(List.generate(5000, (final i) => i % 7));
      final b = bytes(List.generate(7000, (final i) => (i * 3) % 11));
      final codec = Lz4StreamCodec();
      final compressed = bytes([
        ...await streamCompress(codec, [a]),
        ...await streamCompress(codec, [b]),
      ]);
      expect(
        await streamDecompress(codec, compressed),
        orderedEquals(bytes([...a, ...b])),
      );
    });

    test('whole-input and 1-byte-chunk decoding agree', () async {
      const pattern = 'abcabcabcdefdefdef0123456789';
      final original = bytes(
        List.generate(
          180 * 1024,
          (final i) => pattern.codeUnitAt(i % pattern.length),
        ),
      );
      final codec = Lz4StreamCodec(blockSize: 65536);
      final compressed = await streamCompress(codec, [original]);
      final whole = await streamDecompress(
        codec,
        compressed,
        chunkSize: compressed.length,
      );
      final fragmented = await streamDecompress(codec, compressed);
      expect(fragmented, orderedEquals(whole));
      expect(whole, orderedEquals(original));
    });

    test('truncated frame fed fragmented errors at end of stream', () async {
      final original = bytes(List.generate(40000, (final i) => i % 256));
      final codec = Lz4StreamCodec(blockSize: 65536);
      final compressed = await streamCompress(codec, [original]);
      final truncated = Uint8List.sublistView(
        compressed,
        0,
        compressed.length - 6,
      );
      expect(
        () => streamDecompress(codec, truncated),
        throwsA(isA<Lz4FormatException>()),
      );
    });

    test('verified mode round-trips valid data', () async {
      final original = bytes(
        List.generate(50000, (final i) => (i * 5 + 1) % 256),
      );
      final plain = Lz4StreamCodec(blockSize: 65536);
      final verified = Lz4StreamCodec(blockSize: 65536, verified: true);
      final compressed = await streamCompress(plain, [original]);
      expect(
        await streamDecompress(verified, compressed),
        orderedEquals(original),
      );
    });

    test(
      'verified mode emits nothing when the content checksum is corrupted',
      () async {
        final payload = bytes(
          List.generate(5000, (final i) => (i * 31 + 7) % 256),
        );
        final corrupted = Uint8List.fromList(Lz4Codec().compress(payload));
        corrupted[corrupted.length - 1] ^= 0xFF; // flip a content-checksum byte
        final emitted = <int>[];
        Object? error;
        try {
          await for (final chunk in Lz4StreamCodec(
            verified: true,
          ).decompress(Stream.value(corrupted))) {
            emitted.addAll(chunk);
          }
        } catch (e) {
          error = e;
        }
        expect(error, isA<CompressionFormatException>());
        expect(
          emitted,
          isEmpty,
          reason:
              'verified mode must not emit bytes from a frame that fails checksum',
        );
      },
    );

    test('garbage byte stream surfaces CompressionFormatException', () {
      final garbage = bytes(List.generate(80, (final i) => (i * 7 + 3) & 0xFF));
      expect(
        streamDecompress(Lz4StreamCodec(), garbage),
        throwsA(isA<CompressionFormatException>()),
      );
    });
  });

  group('LZ4 limits & validation', () {
    test('independent blocks may not match into earlier blocks', () {
      // Block 1: 100 bytes stored. Block 2: one literal, then a 4-byte match
      // 50 bytes back (into block 1), then five literals.
      Uint8List frame(final int flag) {
        const bd = 0x40; // 64 KB blocks
        final first = pseudoRandom(100, 4);
        final second = [0x10, 0x78, 50, 0, 0x50, 1, 2, 3, 4, 5];
        return bytes([
          0x04, 0x22, 0x4D, 0x18, flag, bd, //
          (XXH32.hash(bytes([flag, bd])) >> 8) & 0xFF,
          100, 0, 0, 0x80, ...first, //
          second.length, 0, 0, 0, ...second,
          0, 0, 0, 0,
        ]);
      }

      expect(
        () => Lz4Codec().decompress(frame(0x60)),
        throwsA(isA<Lz4FormatException>()),
      );
      expect(
        collect(Lz4StreamCodec().decompress(Stream.value(frame(0x60)))),
        throwsA(isA<Lz4FormatException>()),
      );
      expect(Lz4Codec().decompress(frame(0x40)), hasLength(110));
    });

    test('small frames without a content size decode quickly', () {
      // A frame with no content size used to allocate its Block Maximum Size
      // (4 MB by default) for output: about 140 us per 1 KB frame, against a
      // few microseconds once the buffer starts small.
      final page = Uint8List.sublistView(
        readDataFixture('large/world192.txt'),
        0,
        1024,
      );
      final frame = Lz4Codec().compress(page);
      final codec = Lz4Codec();
      for (var i = 0; i < 200; i++) {
        codec.decompress(frame);
      }
      final watch = Stopwatch()..start();
      for (var i = 0; i < 2000; i++) {
        codec.decompress(frame);
      }
      expect(watch.elapsedMilliseconds, lessThan(100));
      expect(codec.decompress(frame), orderedEquals(page));
    }, retry: 2);

    test('rejects empty input in block and stream mode', () async {
      await expectEmptyRejected<Lz4FormatException>(
        Lz4Codec(),
        Lz4StreamCodec(),
      );
    });

    group('Block Maximum Size', () {
      // A frame with 64 KB blocks (BD 0x40), independent blocks and no
      // checksums, holding one compressed block that decodes to [size] bytes:
      // one literal, a match at offset 1, then 5 trailing literals.
      Uint8List frame(final int size) {
        const descriptor = [0x60, 0x40];
        final check = (XXH32.hashFromList(descriptor) >> 8) & 0xFF;
        var extension = size - 1 - 5 - 4 - 15;
        final block = <int>[0x1F, 0x61, 0x01, 0x00];
        while (extension >= 255) {
          block.add(255);
          extension -= 255;
        }
        block
          ..add(extension)
          ..addAll([0x50, ...'bcdef'.codeUnits]);
        final length = block.length;
        return bytes([
          0x04,
          0x22,
          0x4D,
          0x18,
          ...descriptor,
          check,
          length & 0xFF,
          (length >> 8) & 0xFF,
          length >> 16,
          0,
          ...block,
          0,
          0,
          0,
          0,
        ]);
      }

      test('accepts a block that decodes to exactly the maximum', () async {
        final data = frame(65536);
        expect(Lz4Codec().decompress(data).length, 65536);
        expect(
          (await collect(
            Lz4StreamCodec().decompress(Stream.value(data)),
          )).length,
          65536,
        );
      });

      test('rejects a block that decodes past the maximum', () async {
        final data = frame(65537);
        expect(
          () => Lz4Codec().decompress(data),
          throwsA(isA<Lz4FormatException>()),
        );
        await expectLater(
          collect(Lz4StreamCodec().decompress(Stream.value(data))),
          throwsA(isA<Lz4FormatException>()),
        );
      });
    });

    test('maxSize rejects oversized output', () {
      final original = bytes(List.filled(1000, 0x41));
      final compressed = Lz4Codec().compress(original);
      expect(
        () => Lz4Codec(maxSize: 100).decompress(compressed),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('fromOptions preserves and enforces the limit', () {
      final options = Lz4Options(
        level: 9,
        blockSize: lz4BlockSize256K,
        checksum: false,
        maxSize: 100,
      );
      final codec = Lz4Codec.fromOptions(options);
      expect(codec.level, 9);
      expect(codec.blockSize, lz4BlockSize256K);
      expect(codec.checksum, false);
      expect(codec.maxSize, 100);

      final compressed = Lz4Codec().compress(bytes(List.filled(1000, 0x41)));
      expect(
        () => codec.decompress(compressed),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('constructor rejects out-of-range level', () {
      expect(() => Lz4Codec(level: 0), throwsArgumentError);
      expect(() => Lz4Codec(level: 10), throwsArgumentError);
    });

    test('constructor rejects out-of-range block size', () {
      expect(() => Lz4Codec(blockSize: 0), throwsArgumentError);
      expect(
        () => Lz4Codec(blockSize: lz4BlockSize4M + 1),
        throwsArgumentError,
      );
    });

    test('stream constructor rejects out-of-range params', () {
      expect(() => Lz4StreamCodec(level: 10), throwsArgumentError);
      expect(
        () => Lz4StreamCodec(blockSize: 8 * 1024 * 1024),
        throwsArgumentError,
      );
      expect(() => Lz4StreamCodec(maxBufferSize: 0), throwsArgumentError);
    });

    test('stream maxBufferSize rejects an oversized single chunk', () {
      // Incompressible payload so the compressed blob stays well over the cap.
      final blob = Lz4Codec().compress(
        bytes(List.generate(5000, (final i) => (i * 131 + 7) % 256)),
      );
      expect(blob.length, greaterThan(64));
      final out = Lz4StreamCodec(
        maxBufferSize: 64,
      ).decompress(Stream.value(blob));
      expect(out.toList(), throwsA(isA<CompressionFormatException>()));
    });

    test('stream maxSize is enforced cumulatively across frames', () {
      final payload = bytes(List.filled(1000, 0x41));
      final frame = Lz4Codec().compress(payload);
      final concat = bytes([for (var i = 0; i < 5; i++) ...frame]);
      // Each frame (1000 bytes) is under the cap; the cumulative total is not.
      expect(
        streamDecompress(Lz4StreamCodec(maxSize: 2500), concat),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('stream maxSize breach reports the limit', () {
      final frame = Lz4Codec().compress(bytes(List.filled(300000, 0x41)));
      expect(
        streamDecompress(Lz4StreamCodec(maxSize: 5000), frame),
        throwsA(
          isA<LimitException>().having(
            (final e) => e.message,
            'message',
            contains('exceeds the limit'),
          ),
        ),
      );
    });
  });

  group('LZ4 CLI compatibility', () {
    test('fast compression output readable by lz4 CLI', () async {
      if (!await cliAvailableCached('lz4')) {
        markTestSkipped('lz4 CLI tool not available');
        return;
      }
      final original = readDataFixture('html');
      final compressed = Lz4Codec(level: 1).compress(original);
      final path = '/tmp/libcompress_lz4_fast.lz4';
      final out = '/tmp/libcompress_lz4_fast.out';
      try {
        await File(path).writeAsBytes(compressed);
        final result = await Process.run('lz4', ['-d', '-f', path, out]);
        expect(
          result.exitCode,
          0,
          reason: 'lz4 decompression failed: ${result.stderr}',
        );
        expect(await File(out).readAsBytes(), equals(original));
      } finally {
        await cleanup([path, out]);
      }
    });

    test('HC compression output readable by lz4 CLI', () async {
      if (!await cliAvailableCached('lz4')) {
        markTestSkipped('lz4 CLI tool not available');
        return;
      }
      final original = readDataFixture('canterbury/alice29.txt');
      final compressed = Lz4Codec(level: 9).compress(original);
      final path = '/tmp/libcompress_lz4_hc.lz4';
      final out = '/tmp/libcompress_lz4_hc.out';
      try {
        await File(path).writeAsBytes(compressed);
        final result = await Process.run('lz4', ['-d', '-f', path, out]);
        expect(
          result.exitCode,
          0,
          reason: 'lz4 decompression failed: ${result.stderr}',
        );
        expect(await File(out).readAsBytes(), equals(original));
      } finally {
        await cleanup([path, out]);
      }
    });

    test('64K block size output readable by lz4 CLI', () async {
      if (!await cliAvailableCached('lz4')) {
        markTestSkipped('lz4 CLI tool not available');
        return;
      }
      final original = readDataFixture('canterbury/alice29.txt');
      final compressed = Lz4Codec(
        blockSize: lz4BlockSize64K,
      ).compress(original);
      final path = '/tmp/libcompress_lz4_64k.lz4';
      final out = '/tmp/libcompress_lz4_64k.out';
      try {
        await File(path).writeAsBytes(compressed);
        final result = await Process.run('lz4', ['-d', '-f', path, out]);
        expect(
          result.exitCode,
          0,
          reason: 'lz4 decompression failed: ${result.stderr}',
        );
        expect(await File(out).readAsBytes(), equals(original));
      } finally {
        await cleanup([path, out]);
      }
    });

    test('no checksum output readable by lz4 CLI', () async {
      if (!await cliAvailableCached('lz4')) {
        markTestSkipped('lz4 CLI tool not available');
        return;
      }
      final original = readDataFixture('html');
      final compressed = Lz4Codec(checksum: false).compress(original);
      final path = '/tmp/libcompress_lz4_nocheck.lz4';
      final out = '/tmp/libcompress_lz4_nocheck.out';
      try {
        await File(path).writeAsBytes(compressed);
        final result = await Process.run('lz4', ['-d', '-f', path, out]);
        expect(
          result.exitCode,
          0,
          reason: 'lz4 decompression failed: ${result.stderr}',
        );
        expect(await File(out).readAsBytes(), equals(original));
      } finally {
        await cleanup([path, out]);
      }
    });

    test('bidirectional round-trip (library<->CLI)', () async {
      if (!await cliAvailableCached('lz4')) {
        markTestSkipped('lz4 CLI tool not available');
        return;
      }
      final codec = Lz4Codec();
      final original = readDataFixture('calgary/paper1');
      final libCompressed = codec.compress(original);
      final path = '/tmp/libcompress_lz4_bidir.lz4';
      final out = '/tmp/libcompress_lz4_bidir.out';
      final cliPath = '/tmp/libcompress_lz4_cli.lz4';
      try {
        await File(path).writeAsBytes(libCompressed);
        final result = await Process.run('lz4', ['-d', '-f', path, out]);
        expect(result.exitCode, 0);
        expect(await File(out).readAsBytes(), equals(original));

        final result2 = await Process.run('lz4', ['-f', out, cliPath]);
        expect(result2.exitCode, 0);
        final cliCompressed = await File(cliPath).readAsBytes();
        expect(
          codec.decompress(Uint8List.fromList(cliCompressed)),
          equals(original),
        );
      } finally {
        await cleanup([path, out, cliPath]);
      }
    });

    test(
      'every level decodes with lz4 -d; level 9 is within 5% of lz4 -9',
      () async {
        if (!await cliAvailableCached('lz4')) {
          markTestSkipped('lz4 CLI tool not available');
          return;
        }
        final dir = Directory.systemTemp.createTempSync('libcompress_lz4_hc');
        try {
          for (final name in ['large/world192.txt', 'geo.protodata']) {
            final source = 'test/fixtures/data/$name';
            final original = readDataFixture(name);
            for (var level = 1; level <= 9; level++) {
              final path = '${dir.path}/l$level.lz4';
              File(
                path,
              ).writeAsBytesSync(Lz4Codec(level: level).compress(original));
              final result = await Process.run('lz4', [
                '-d',
                '-c',
                path,
              ], stdoutEncoding: null);
              expect(
                result.exitCode,
                0,
                reason: '$name $level ${result.stderr}',
              );
              expect(result.stdout, equals(original), reason: '$name $level');
            }
            final reference = await Process.run('lz4', [
              '-9',
              '-c',
              source,
            ], stdoutEncoding: null);
            final ours = Lz4Codec(level: 9).compress(original).length;
            final theirs = (reference.stdout as List<int>).length;
            expect(
              ours,
              lessThanOrEqualTo(theirs * 1.05),
              reason: '$name: $ours vs lz4 -9 $theirs',
            );
          }
        } finally {
          dir.deleteSync(recursive: true);
        }
      },
    );

    test('linked HC stream blocks decode with lz4 -d', () async {
      if (!await cliAvailableCached('lz4')) {
        markTestSkipped('lz4 CLI tool not available');
        return;
      }
      final original = readDataFixture('large/world192.txt');
      final chunks = [
        for (var i = 0; i < original.length; i += 1024)
          Uint8List.sublistView(original, i, min(i + 1024, original.length)),
      ];
      final compressed = await streamCompress(
        Lz4StreamCodec(level: 9, blockSize: lz4BlockSize64K),
        chunks,
      );
      final dir = Directory.systemTemp.createTempSync('libcompress_lz4_link');
      try {
        final path = '${dir.path}/linked.lz4';
        File(path).writeAsBytesSync(compressed);
        final result = await Process.run('lz4', [
          '-d',
          '-c',
          path,
        ], stdoutEncoding: null);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stdout, equals(original));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('HC bidirectional round-trip with CLI', () async {
      if (!await cliAvailableCached('lz4')) {
        markTestSkipped('lz4 CLI tool not available');
        return;
      }
      final codec = Lz4Codec(level: 9);
      final original = readDataFixture('canterbury/alice29.txt');
      final libCompressed = codec.compress(original);
      final path = '/tmp/libcompress_lz4_hc_bidir.lz4';
      final out = '/tmp/libcompress_lz4_hc_bidir.out';
      final cliPath = '/tmp/libcompress_lz4_hc_cli.lz4';
      try {
        await File(path).writeAsBytes(libCompressed);
        final result = await Process.run('lz4', ['-d', '-f', path, out]);
        expect(result.exitCode, 0);
        expect(await File(out).readAsBytes(), equals(original));

        final result2 = await Process.run('lz4', ['-9', '-f', out, cliPath]);
        expect(result2.exitCode, 0);
        final cliCompressed = await File(cliPath).readAsBytes();
        expect(
          codec.decompress(Uint8List.fromList(cliCompressed)),
          equals(original),
        );
      } finally {
        await cleanup([path, out, cliPath]);
      }
    });

    group('all fixtures round-trip through CLI', () {
      for (final path in standardFixtures) {
        test('full round-trip for $path', () async {
          if (!await cliAvailableCached('lz4')) {
            markTestSkipped('lz4 CLI tool not available');
            return;
          }
          final original = readDataFixture(path);
          final libCompressed = Lz4Codec().compress(original);
          final tmpPath =
              '/tmp/libcompress_lz4_rt_${path.replaceAll('/', '_')}.lz4';
          final tmpOut =
              '/tmp/libcompress_lz4_rt_${path.replaceAll('/', '_')}.out';
          try {
            await File(tmpPath).writeAsBytes(libCompressed);
            final result = await Process.run('lz4', [
              '-d',
              '-f',
              tmpPath,
              tmpOut,
            ]);
            expect(
              result.exitCode,
              0,
              reason: 'CLI decompression failed for $path',
            );
            expect(
              await File(tmpOut).readAsBytes(),
              equals(original),
              reason: 'Round-trip mismatch for $path',
            );
          } finally {
            await cleanup([tmpPath, tmpOut]);
          }
        });
      }
    });
  });

  defineDifferentialFuzz(
    title: 'LZ4',
    reference: const Reference('lz4', ['-d', '-q', '-c']),
    frames: {
      // No content checksum, so only block validation can catch a corrupt
      // mutant. -B4 -BD gives 64 KB linked blocks.
      for (final options in [
        ['-1'],
        ['-9'],
        ['-1', '-B4', '-BD'],
      ])
        'lz4 CLI ${options.join(' ')}': () => const Reference('lz4', []).encode(
          ['-q', '-c', '--no-frame-crc', ...options],
          readDataFixture('canterbury/alice29.txt'),
        ),
      'libcompress encoder': () async => Lz4Codec(
        checksum: false,
      ).compress(readDataFixture('canterbury/alice29.txt')),
    },
    block: Lz4Codec().decompress,
    stream: Lz4StreamCodec().decompress,
  );

  group('LZ4 fuzzing / malformed input', () {
    final random = Random(42); // Fixed seed for reproducibility.
    final codec = Lz4Codec();

    test('rejects pure random noise', () {
      for (var i = 0; i < 100; i++) {
        final noise = bytes(
          List.generate(random.nextInt(1000) + 1, (_) => random.nextInt(256)),
        );
        expect(
          () => codec.decompress(noise),
          throwsA(isA<Lz4FormatException>()),
          reason: 'Random noise should be rejected',
        );
      }
    });

    test('rejects short random data', () {
      for (var length = 1; length < 20; length++) {
        final noise = bytes(List.generate(length, (_) => random.nextInt(256)));
        expect(
          () => codec.decompress(noise),
          throwsA(isA<CompressionFormatException>()),
          reason: 'Short random data ($length bytes) should be rejected',
        );
      }
    });

    test('rejects truncated data at various positions', () {
      final valid = codec.compress(
        bytes(List.generate(1000, (final i) => i % 256)),
      );
      for (var cutoff = 1; cutoff < valid.length; cutoff++) {
        final truncated = Uint8List.sublistView(valid, 0, cutoff);
        expect(
          () => codec.decompress(truncated),
          throwsA(isA<CompressionFormatException>()),
          reason: 'Truncated at $cutoff should be rejected',
        );
      }
    });

    test('rejects wrong magic number', () {
      final wrongMagic = bytes([
        0x00, 0x00, 0x00, 0x00, // Wrong magic
        0x60, 0x40, 0x82, // Minimal frame header
        0x00, 0x00, 0x00, 0x00, // End mark
      ]);
      expect(
        () => codec.decompress(wrongMagic),
        throwsA(isA<Lz4FormatException>()),
      );
    });

    test('rejects each corrupted byte of magic', () {
      final validMagic = [0x04, 0x22, 0x4D, 0x18];
      for (var i = 0; i < 4; i++) {
        final corrupted = List<int>.from(validMagic);
        corrupted[i] ^= 0xFF;
        final data = bytes([
          ...corrupted,
          0x60,
          0x40,
          0x82,
          0x00,
          0x00,
          0x00,
          0x00,
        ]);
        expect(
          () => codec.decompress(data),
          throwsA(isA<Lz4FormatException>()),
          reason: 'Corrupted magic byte $i should be rejected',
        );
      }
    });

    test('rejects invalid version in FLG', () {
      final data = bytes([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x70, // FLG with version != 01
        0x40, // BD
        0x00, // HC
      ]);
      expect(() => codec.decompress(data), throwsA(isA<Lz4FormatException>()));
    });

    test('rejects invalid block size code', () {
      final data = bytes([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x60, // FLG
        0x00, // BD with invalid block size (code 0)
        0x00, // HC
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects declared size exceeding limit (decompression bomb)', () {
      final data = bytes([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x68, // FLG: version=01, content size present
        0x70, // BD: 4MB blocks
        // Content size: 1TB (way too big)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00,
        0xEC, // HC
      ]);
      expect(
        () => Lz4Codec(maxSize: 256 * 1024 * 1024).decompress(data),
        throwsA(isA<LimitException>()),
      );
    });

    test('enforces maxSize limit', () {
      final compressed = codec.compress(bytes(List.filled(1000, 0x41)));
      expect(
        () => Lz4Codec(maxSize: 100).decompress(compressed),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('corrupted block data never crashes unexpectedly', () {
      final original = bytes(List.generate(5000, (final i) => i % 256));
      final valid = codec.compress(original);
      const headerEnd = 7;
      if (valid.length > headerEnd + 10) {
        for (
          var i = headerEnd;
          i < min(headerEnd + 50, valid.length - 4);
          i++
        ) {
          final corrupted = Uint8List.fromList(valid);
          corrupted[i] ^= 0xFF;
          try {
            codec.decompress(corrupted);
            // Acceptable if corruption produces different output without throwing.
          } on CompressionFormatException {
            // Expected for detected corruption.
          } catch (e) {
            fail(
              'Corrupted byte at position $i threw $e '
              'instead of CompressionFormatException',
            );
          }
        }
      }
    });

    test('zero-size block is treated as end mark', () {
      final data = bytes([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x60, // FLG
        0x70, // BD
        0x73, // HC
        0x00, 0x00, 0x00, 0x00, // End mark (zero block = end)
      ]);
      expect(codec.decompress(data), isEmpty);
    });

    test('rejects offset pointing before buffer start', () {
      final data = bytes([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x60, 0x70, 0x73, // Frame header
        0x10, 0x00, 0x00, 0x00, // Block size = 16 (uncompressed flag not set)
        0x10, // Token: 1 literal, 4+ match
        0x41, // Literal 'A'
        0xFF, 0xFF, // Offset 65535 - points way before buffer
        0x00, 0x00, 0x00, 0x00, // Padding
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, // End mark
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects zero offset back-reference', () {
      final data = bytes([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x60, 0x70, 0x73, // Frame header
        0x08, 0x00, 0x00, 0x00, // Block size = 8
        0x10, // Token: 1 literal, 4+ match
        0x41, // Literal
        0x00, 0x00, // Offset = 0 (invalid)
        0x00, 0x00, 0x00, 0x00, // Padding
        0x00, 0x00, 0x00, 0x00, // End mark
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects invalid header checksum', () {
      final data = bytes([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x60, 0x70, // FLG, BD
        0xFF, // Wrong header checksum
        0x00, 0x00, 0x00, 0x00, // End mark
      ]);
      expect(() => codec.decompress(data), throwsA(isA<Lz4FormatException>()));
    });

    test('rejects invalid content checksum when enabled', () {
      final codecWithChecksum = Lz4Codec(checksum: true);
      final compressed = codecWithChecksum.compress(bytes([1, 2, 3, 4, 5]));
      final corrupted = Uint8List.fromList(compressed);
      corrupted[corrupted.length - 1] ^= 0xFF;
      expect(
        () => codecWithChecksum.decompress(corrupted),
        throwsA(isA<Lz4FormatException>()),
      );
    });
  });

  group('LZ4 format', () {
    final codec = Lz4Codec();

    group('Hadoop', () {
      // Parquet's legacy LZ4 codec: outer blocks of [big-endian u32 total]
      // followed by inner chunks of [big-endian u32 length][raw LZ4 block].
      final hadoop = Lz4Codec(format: Lz4Format.hadoop);
      final raw = Lz4Codec(format: Lz4Format.raw);

      List<int> u32(final int value) => [
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];
      List<int> chunk(final String text) {
        final block = raw.compress(bytes(text.codeUnits));
        return [...u32(block.length), ...block];
      }

      for (final entry in standardEdgeCases().entries) {
        test('round-trips ${entry.key}', () {
          expect(
            hadoop.decompress(hadoop.compress(entry.value)),
            orderedEquals(entry.value),
          );
        });
      }

      test('writes one outer block with one inner chunk, as Arrow does', () {
        final frame = hadoop.compress(bytes('hello hello hello'.codeUnits));
        final block = raw.compress(bytes('hello hello hello'.codeUnits));
        expect(
          frame,
          orderedEquals([...u32(17), ...u32(block.length), ...block]),
        );
      });

      test('decodes several inner chunks in one outer block', () {
        final frame = bytes([
          ...u32(11),
          ...chunk('hello'),
          ...chunk(' world'),
        ]);
        expect(
          hadoop.decompress(frame),
          orderedEquals('hello world'.codeUnits),
        );
      });

      test('decodes several outer blocks', () {
        final frame = bytes([
          ...u32(5),
          ...chunk('hello'),
          ...u32(6),
          ...chunk(' world'),
        ]);
        expect(
          hadoop.decompress(frame),
          orderedEquals('hello world'.codeUnits),
        );
      });

      final invalid = {
        'empty input': <int>[],
        'a truncated total': [0, 0, 1],
        'a missing chunk length': u32(5),
        'a chunk length past the end': [...u32(5), ...u32(100), 0x50],
        'chunks that decode past the total': [...u32(4), ...chunk('hello')],
        'chunks that decode short of the total': [...u32(6), ...chunk('hello')],
        'trailing bytes': [...u32(5), ...chunk('hello'), 0, 0],
      };
      for (final entry in invalid.entries) {
        test('rejects ${entry.key}', () {
          expect(
            () => hadoop.decompress(bytes(entry.value)),
            throwsA(isA<Lz4FormatException>()),
          );
        });
      }

      test('a chunk cannot reference an earlier chunk', () {
        // 'hello' then a chunk that is only a match at offset 5, length 5.
        final match = [0x01, 0x05, 0x00, 0x50, ...'bcdef'.codeUnits];
        final frame = bytes([
          ...u32(15),
          ...chunk('hello'),
          ...u32(match.length),
          ...match,
        ]);
        expect(
          () => hadoop.decompress(frame),
          throwsA(isA<Lz4FormatException>()),
        );
      });

      test('mutants raise only Lz4FormatException', () {
        final frame = hadoop.compress(
          readDataFixture('canterbury/alice29.txt'),
        );
        final random = Random(7);
        for (var i = 0; i < 2000; i++) {
          final mutant = Uint8List.fromList(frame);
          mutant[random.nextInt(mutant.length)] ^= 1 << random.nextInt(8);
          try {
            hadoop.decompress(mutant);
          } on Lz4FormatException {
            // Expected for most mutants.
          }
        }
      });
    });

    group('skippable and legacy frames', () {
      // Magic 0x184D2A53 (one of the 16 skippable values) and a 5-byte body.
      final skippable = bytes([
        0x53,
        0x2A,
        0x4D,
        0x18,
        5,
        0,
        0,
        0,
        1,
        2,
        3,
        4,
        5,
      ]);

      Future<Uint8List> streamed(final Uint8List data) =>
          streamDecompress(Lz4StreamCodec(), data);

      test('a skippable frame between two frames is ignored', () async {
        final data = bytes([
          ...codec.compress(bytes('hello'.codeUnits)),
          ...skippable,
          ...codec.compress(bytes(' world'.codeUnits)),
        ]);
        expect(codec.decompress(data), orderedEquals('hello world'.codeUnits));
        expect(await streamed(data), orderedEquals('hello world'.codeUnits));
      });

      test('a truncated skippable frame is rejected', () async {
        final data = Uint8List.sublistView(skippable, 0, skippable.length - 1);
        expect(
          () => codec.decompress(data),
          throwsA(isA<Lz4FormatException>()),
        );
        await expectLater(streamed(data), throwsA(isA<Lz4FormatException>()));
      });

      test('a legacy frame is rejected with a clear message', () async {
        final legacy = isA<Lz4FormatException>().having(
          (final e) => e.message,
          'message',
          contains('legacy LZ4 frame format is not supported'),
        );
        final data = bytes([0x02, 0x21, 0x4C, 0x18, 4, 0, 0, 0, 0x40, 0x61]);
        expect(() => codec.decompress(data), throwsA(legacy));
        await expectLater(streamed(data), throwsA(legacy));
      });
    });

    test('frame magic number is 0x184D2204 (little-endian)', () {
      final compressed = codec.compress(bytes([1, 2, 3, 4, 5]));
      expect(compressed.sublist(0, 4), orderedEquals([0x04, 0x22, 0x4D, 0x18]));
    });

    test('rejects FLG with a non-01 version field', () {
      final data = bytes([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x70, // FLG version bits != 01
        0x40, // BD
        0x00, // HC
      ]);
      expect(() => codec.decompress(data), throwsA(isA<Lz4FormatException>()));
    });

    test('rejects invalid BD block size code (reserved)', () {
      final data = bytes([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x60, // FLG
        0x00, // BD reserved/invalid block size code
        0x00, // HC
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects invalid header checksum (HC byte)', () {
      final data = bytes([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x60, 0x70, // FLG, BD
        0xFF, // Wrong header checksum
        0x00, 0x00, 0x00, 0x00, // End mark
      ]);
      expect(() => codec.decompress(data), throwsA(isA<Lz4FormatException>()));
    });
  });

  // Raw LZ4 blocks (no frame), `Lz4Format.raw`: the form used by Parquet
  // `LZ4_RAW`.
  group('LZ4 raw block', () {
    final raw = Lz4Codec(format: Lz4Format.raw);

    final cases = <String, Uint8List>{
      'empty': Uint8List(0),
      'tiny': bytes([1, 2, 3]),
      'text': bytes('the quick brown fox jumps over the lazy dog'.codeUnits),
      'all byte values': bytes(List.generate(256, (final i) => i)),
      'incompressible 4k': pseudoRandom(4096),
      // Larger than the default frame block size: a single raw block must still
      // represent the whole input (the frame format would split into blocks).
      'repetitive 1M': bytes(
        List.generate(1 << 20, (final i) => 'the quick '.codeUnitAt(i % 10)),
      ),
      'incompressible 2M': pseudoRandom(2 << 20, 0xABCDEF),
    };

    for (final entry in cases.entries) {
      test('round-trips ${entry.key}', () {
        final block = raw.compress(entry.value);
        expect(raw.decompress(block), orderedEquals(entry.value));
      });
    }

    test('round-trips with HC mode (level 9)', () {
      final codec = Lz4Codec(format: Lz4Format.raw, level: 9);
      final data = bytes(
        List.generate(
          50000,
          (final i) => 'the quick brown '.codeUnitAt(i % 16),
        ),
      );
      final block = codec.compress(data);
      expect(codec.decompress(block), orderedEquals(data));
    });

    test('emits a bare block, not a frame', () {
      final block = raw.compress(bytes('hello world'.codeUnits));
      // No LZ4 frame magic (0x184D2204, little-endian) at the start.
      expect(block.length, greaterThanOrEqualTo(4));
      final notFrame =
          !(block[0] == 0x04 &&
              block[1] == 0x22 &&
              block[2] == 0x4d &&
              block[3] == 0x18);
      expect(notFrame, isTrue);
    });

    test('compresses repetitive data well', () {
      final data = bytes(
        List.generate(10000, (final i) => 'ab'.codeUnitAt(i % 2)),
      );
      final block = raw.compress(data);
      expect(block.length, lessThan(data.length));
    });

    test('enforces maxSize', () {
      final data = bytes(
        List.generate(10000, (final i) => 'ab'.codeUnitAt(i % 2)),
      );
      final block = raw.compress(data);
      expect(
        () => Lz4Codec(format: Lz4Format.raw, maxSize: 16).decompress(block),
        throwsA(isA<LimitException>()),
      );
    });

    test('decoding with size agrees with decoding without it', () {
      // The size path decodes straight into an exact buffer; on every mutant
      // it must give the same bytes as the general path when that path
      // produces exactly `size` bytes, and reject the mutant otherwise.
      final data = readDataFixture('canterbury/alice29.txt');
      for (final level in [1, 9]) {
        final codec = Lz4Codec(format: Lz4Format.raw, level: level);
        final block = codec.compress(data);
        final random = Random(level);
        for (var i = 0; i < 1500; i++) {
          final mutant = Uint8List.fromList(block);
          mutant[random.nextInt(mutant.length)] ^= 1 << random.nextInt(8);
          final cut = random.nextInt(8) == 0
              ? 1 + random.nextInt(mutant.length - 1)
              : mutant.length;
          final input = Uint8List.sublistView(mutant, 0, cut);
          Uint8List? general;
          try {
            general = codec.decompress(input);
          } on CompressionFormatException {
            general = null;
          }
          if (general != null && general.length == data.length) {
            expect(
              codec.decompress(input, size: data.length),
              orderedEquals(general),
              reason: 'mutant $i',
            );
          } else {
            expect(
              () => codec.decompress(input, size: data.length),
              throwsA(isA<CompressionFormatException>()),
              reason: 'mutant $i',
            );
          }
        }
      }
    });

    test('frame is the default format', () {
      expect(Lz4Codec().format, Lz4Format.frame);
      final frame = Lz4Codec().compress(bytes('hello'.codeUnits));
      expect(frame.sublist(0, 4), orderedEquals([0x04, 0x22, 0x4D, 0x18]));
    });

    test('options carry the format', () {
      final codec = Lz4Codec.fromOptions(Lz4Options(format: Lz4Format.raw));
      expect(codec.format, Lz4Format.raw);
    });

    test('empty data encodes to one token; an empty block is rejected', () {
      // As LZ4_compress_default: a single token with no literals.
      final block = raw.compress(Uint8List(0));
      expect(block, orderedEquals([0x00]));
      expect(raw.decompress(block), isEmpty);
      expect(
        () => raw.decompress(Uint8List(0)),
        throwsA(isA<Lz4FormatException>()),
      );
    });
  });

  // Pages of real Parquet files (test/fixtures/parquet): sizes and CRC-32s are
  // from the LZ4 reference library.
  group('Parquet LZ4 pages', () {
    const hadoop = 5; // CompressionCodec.LZ4
    const raw = 7; // CompressionCodec.LZ4_RAW
    final files = <String, (Lz4Format, int, List<(int, int)>)>{
      'hadoop_lz4_compressed': (
        Lz4Format.hadoop,
        hadoop,
        [
          (16, 0x548961ae),
          (3, 0xdc18accd),
          (14, 0x7d631fc6),
          (3, 0x357b09f8),
          (24, 0x8bce8185),
          (10, 0x4a658545),
        ],
      ),
      'hadoop_lz4_compressed_larger': (
        Lz4Format.hadoop,
        hadoop,
        [(400000, 0x1a4a4a70)],
      ),
      'lz4_raw_compressed': (
        Lz4Format.raw,
        raw,
        [(32, 0x0f572674), (28, 0xbe669e80), (38, 0x932c5b96)],
      ),
      'lz4_raw_compressed_larger': (Lz4Format.raw, raw, [(400000, 0x1a4a4a70)]),
      // Old parquet-cpp wrote the LZ4 codec as bare blocks.
      'non_hadoop_lz4_compressed': (
        Lz4Format.raw,
        hadoop,
        [
          (16, 0x548961ae),
          (9, 0x636a6553),
          (14, 0x7d631fc6),
          (9, 0x8a09c066),
          (24, 0x8bce8185),
          (10, 0x9f92cbe7),
        ],
      ),
    };

    for (final MapEntry(key: name, value: (format, codec, expected))
        in files.entries) {
      test('$name decodes with ${format.name}', () {
        final pages = parquetPages(
          readFixture('test/fixtures/parquet/$name.parquet'),
        );
        expect(pages.map((final page) => page.codec), everyElement(codec));
        final decoder = Lz4Codec(format: format);
        final actual = [
          for (final page in pages)
            (
              page.size,
              Crc32.hash(decoder.decompress(page.data, size: page.size)),
            ),
        ];
        expect(actual, equals(expected));
        // Without the size, the Hadoop framing still yields the same bytes.
        if (format == Lz4Format.hadoop) {
          for (final page in pages) {
            expect(
              decoder.decompress(page.data),
              equals(decoder.decompress(page.data, size: page.size)),
            );
          }
        }
      });
    }

    test('a Hadoop block declaring 0 bytes may not decode any', () {
      final block = Lz4Codec(
        format: Lz4Format.raw,
      ).compress(pseudoRandom(500, 3));
      final data = bytes([
        0, 0, 0, 0, // Outer block: 0 bytes uncompressed.
        (block.length >> 24) & 255, (block.length >> 16) & 255,
        (block.length >> 8) & 255, block.length & 255,
        ...block,
      ]);
      expect(
        () => Lz4Codec(format: Lz4Format.hadoop).decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('bare-block LZ4 pages are rejected as Hadoop framing', () {
      final pages = parquetPages(
        readFixture('test/fixtures/parquet/non_hadoop_lz4_compressed.parquet'),
      );
      for (final page in pages) {
        expect(
          () => Lz4Codec(
            format: Lz4Format.hadoop,
          ).decompress(page.data, size: page.size),
          throwsA(isA<CompressionFormatException>()),
        );
      }
    });
  });
}
