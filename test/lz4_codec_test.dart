import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';
import 'package:test/test.dart';

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
      standardEdgeCases().forEach((name, data) {
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

      test('HC handles 64K block boundary', () {
        final data = bytes(List.generate(65536, (i) => i % 256));
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
        final data = bytes(List.generate(65536, (i) => i % 256));
        expectRoundTrip(Lz4Codec(blockSize: lz4BlockSize64K), data);
      });

      test('data spanning multiple 64K blocks', () {
        final data = bytes(List.generate(200000, (i) => i % 256));
        expectRoundTrip(Lz4Codec(blockSize: lz4BlockSize64K), data);
      });
    });

    group('content checksum', () {
      final data = readDataFixture('html');
      test('enabled (default) round-trips', () {
        expectRoundTrip(Lz4Codec(enableContentChecksum: true), data);
      });
      test('disabled round-trips', () {
        expectRoundTrip(Lz4Codec(enableContentChecksum: false), data);
      });
    });

    group('concatenated frames', () {
      final a = bytes(List.generate(3000, (i) => (i * 7) % 251));
      final b = bytes(List.generate(2000, (i) => (i * 13 + 5) % 251));

      test('two appended frames decode to the concatenation', () {
        final cat = bytes([
          ...Lz4Codec().compress(a),
          ...Lz4Codec().compress(b),
        ]);
        expect(Lz4Codec().decompress(cat), orderedEquals([...a, ...b]));
      });

      test('maxDecompressedSize is enforced cumulatively across frames', () {
        final cat = bytes([
          ...Lz4Codec().compress(a),
          ...Lz4Codec().compress(b),
        ]); // 5000 bytes total; each frame < 4000.
        expect(
          () => Lz4Codec(maxDecompressedSize: 4000).decompress(cat),
          throwsA(isA<CompressionFormatException>()),
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
      floors.forEach((file, floor) {
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
    test('round-trips multi-chunk input', () async {
      final chunks = [
        bytes(List.generate(5000, (i) => i % 256)),
        bytes('the quick brown fox '.codeUnits),
        bytes(List.generate(9000, (i) => (i * 7) % 13)),
      ];
      await expectStreamRoundTrip(Lz4StreamCodec(blockSize: 65536), chunks);
    });

    test('cross-chunk history compresses repeated chunks well', () async {
      final block = bytes(List.generate(8192, (i) => (i * 31 + 7) % 256));
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
        orderedEquals(bytes(chunks.expand((c) => c))),
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
          [bytes(List.generate(20000, (i) => (i * 3) % 97))],
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
          (i) => pattern.codeUnitAt(i % pattern.length),
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
      final a = bytes(List.generate(5000, (i) => i % 7));
      final b = bytes(List.generate(7000, (i) => (i * 3) % 11));
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
          (i) => pattern.codeUnitAt(i % pattern.length),
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
      final original = bytes(List.generate(40000, (i) => i % 256));
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
      final original = bytes(List.generate(50000, (i) => (i * 5 + 1) % 256));
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
        final payload = bytes(List.generate(5000, (i) => (i * 31 + 7) % 256));
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
      final garbage = bytes(List.generate(80, (i) => (i * 7 + 3) & 0xFF));
      expect(
        streamDecompress(Lz4StreamCodec(), garbage),
        throwsA(isA<CompressionFormatException>()),
      );
    });
  });

  group('LZ4 limits & validation', () {
    test('maxDecompressedSize rejects oversized output', () {
      final original = bytes(List.filled(1000, 0x41));
      final compressed = Lz4Codec().compress(original);
      expect(
        () => Lz4Codec(maxDecompressedSize: 100).decompress(compressed),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('fromOptions preserves and enforces the limit', () {
      final options = Lz4Options(
        level: 9,
        blockSize: lz4BlockSize256K,
        checksum: false,
        maxDecompressedSize: 100,
      );
      final codec = Lz4Codec.fromOptions(options);
      expect(codec.level, 9);
      expect(codec.blockSize, lz4BlockSize256K);
      expect(codec.enableContentChecksum, false);
      expect(codec.maxDecompressedSize, 100);

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
        bytes(List.generate(5000, (i) => (i * 131 + 7) % 256)),
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
      final compressed = Lz4Codec(
        enableContentChecksum: false,
      ).compress(original);
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

    test('handles empty input gracefully', () {
      expect(codec.decompress(Uint8List(0)), isEmpty);
    });

    test('rejects truncated data at various positions', () {
      final valid = codec.compress(bytes(List.generate(1000, (i) => i % 256)));
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
        0x00, // HC
      ]);
      expect(
        () => Lz4Codec(maxDecompressedSize: 256 * 1024 * 1024).decompress(data),
        throwsA(isA<Lz4FormatException>()),
      );
    });

    test('enforces maxDecompressedSize limit', () {
      final compressed = codec.compress(bytes(List.filled(1000, 0x41)));
      expect(
        () => Lz4Codec(maxDecompressedSize: 100).decompress(compressed),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('corrupted block data never crashes unexpectedly', () {
      final original = bytes(List.generate(5000, (i) => i % 256));
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
      final codecWithChecksum = Lz4Codec(enableContentChecksum: true);
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
}
