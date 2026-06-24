import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';
// Internal encoders are imported only for the healthy-zero-fallbacks guard,
// which inspects the `fallbacks` getter not exposed on the public codecs.
import 'package:libcompress/src/zstd/zstd_encoder.dart';
import 'package:libcompress/src/zstd/streaming_zstd_encoder.dart';

import 'test_utils.dart';

void main() {
  group('Zstd block', () {
    test('decompresses stored fixtures', () {
      final codec = ZstdCodec();
      for (final path in standardFixtures) {
        final compressed = readCodecFixture('zstd', '$path.zst');
        final expected = readDataFixture(path);
        expect(
          codec.decompress(compressed),
          orderedEquals(expected),
          reason: path,
        );
      }
    });

    test('round-trips standard fixtures', () {
      final codec = ZstdCodec();
      for (final path in standardFixtures) {
        expectRoundTrip(codec, readDataFixture(path));
      }
    });

    test('round-trips standard edge cases', () {
      final codec = ZstdCodec();
      standardEdgeCases().forEach((name, data) {
        expect(
          codec.decompress(codec.compress(data)),
          orderedEquals(data),
          reason: name,
        );
      });
    });

    test('handles all 256 byte values', () {
      final codec = ZstdCodec();
      final data = bytes(List.generate(256, (i) => i));
      expectRoundTrip(codec, data);
    });

    test('handles data exactly at block boundary', () {
      final codec = ZstdCodec(blockSize: 1000);
      expectRoundTrip(codec, bytes(List.generate(1000, (i) => i % 256)));
    });

    test('handles data spanning multiple blocks', () {
      final codec = ZstdCodec(blockSize: 500);
      expectRoundTrip(codec, bytes(List.generate(1500, (i) => i % 256)));
    });

    group('compression levels 1-22', () {
      for (final level in [1, 3, 5, 9, 10, 15, 19, 22]) {
        test('level $level round-trips and decodes', () {
          final codec = ZstdCodec(level: level);
          expect(codec.level, level);
          final data = bytes(
            List.generate(2000, (i) => 'Hello World! '.codeUnitAt(i % 13)),
          );
          expectRoundTrip(codec, data);
        });
      }
    });

    group('block sizes', () {
      for (final size in [64 * 1024, 128 * 1024]) {
        test('block size $size round-trips alice29', () {
          final codec = ZstdCodec(blockSize: size);
          expectRoundTrip(codec, readDataFixture('canterbury/alice29.txt'));
        });
      }
    });

    group('block-type coverage', () {
      test('raw block on incompressible data', () {
        final codec = ZstdCodec();
        final data = pseudoRandom(1000);
        expectRoundTrip(codec, data);
        // Overhead minimal: frame header + block headers.
        final compressed = codec.compress(data);
        expect(compressed.length, lessThan(data.length + 50));
      });

      test('RLE block on highly repetitive data', () {
        final codec = ZstdCodec();
        final data = bytes(List.filled(10000, 65));
        final compressed = codec.compress(data);
        expect(codec.decompress(compressed), orderedEquals(data));
        expect(compressed.length, lessThan(100));
      });

      test('RLE block on single byte repeated', () {
        final codec = ZstdCodec();
        final data = bytes(List.filled(1000, 0));
        final compressed = codec.compress(data);
        expect(codec.decompress(compressed), orderedEquals(data));
        expect(compressed.length, lessThan(50));
      });

      test('RLE blocks of repeated pattern across blocks', () {
        final codec = ZstdCodec(blockSize: 1000);
        final data = Uint8List(3000)
          ..fillRange(0, 1000, 65)
          ..fillRange(1000, 2000, 66)
          ..fillRange(2000, 3000, 67);
        final compressed = codec.compress(data);
        expect(codec.decompress(compressed), orderedEquals(data));
        expect(compressed.length, lessThan(200));
      });

      test('emits a compressed block when matches are present', () {
        final codec = ZstdCodec(blockSize: 4096);
        final pattern = List<int>.generate(64, (i) => i);
        final data = bytes([
          ...pattern,
          for (var i = 0; i < 60; i++) ...pattern,
        ]);
        final compressed = codec.compress(data);
        expect(_firstBlockType(compressed), ZstdBlockType.compressed.index);
        expect(codec.decompress(compressed), orderedEquals(data));
      });

      test('compressed block on text-like data achieves ratio', () {
        final codec = ZstdCodec();
        const text = 'The quick brown fox jumps over the lazy dog. ';
        final data = bytes(
          List.generate(50, (_) => text.codeUnits).expand((x) => x),
        );
        final compressed = codec.compress(data);
        expect(codec.decompress(compressed), orderedEquals(data));
        expect(compressed.length, lessThan(data.length ~/ 2));
      });

      test('compressed block with varied literal lengths', () {
        final data = <int>[];
        for (var i = 0; i < 100; i++) {
          for (var j = 0; j < (i % 10) + 1; j++) {
            data.add((i * 7 + j) % 256);
          }
          if (data.length > 100) {
            final copyLen = (i % 5) + 4;
            final offset = 50 + (i % 50);
            final src = data.length - offset;
            for (var k = 0; k < copyLen && src + k < data.length; k++) {
              data.add(data[src + k]);
            }
          }
        }
        expectRoundTrip(ZstdCodec(), bytes(data));
      });

      test('decodes single-stream Huffman literals (small fixture)', () {
        final codec = ZstdCodec();
        final compressed = readCodecFixture('zstd', 'artificial/aaa.txt.zst');
        final expected = readDataFixture('artificial/aaa.txt');
        expect(codec.decompress(compressed), orderedEquals(expected));
      });

      test('decodes 4-stream Huffman literals (large fixture)', () {
        final codec = ZstdCodec();
        final compressed = readCodecFixture(
          'zstd',
          'canterbury/alice29.txt.zst',
        );
        final expected = readDataFixture('canterbury/alice29.txt');
        expect(codec.decompress(compressed), orderedEquals(expected));
        expect(compressed.length, lessThan(expected.length ~/ 2));
      });

      test('decodes Huffman-compressed html with good ratio', () {
        final codec = ZstdCodec();
        final compressed = readCodecFixture('zstd', 'html.zst');
        final expected = readDataFixture('html');
        expect(codec.decompress(compressed), orderedEquals(expected));
        expect(compressed.length, lessThan(expected.length ~/ 2));
      });

      test('decodes Huffman-compressed paper1 with good ratio', () {
        final codec = ZstdCodec();
        final compressed = readCodecFixture('zstd', 'calgary/paper1.zst');
        final expected = readDataFixture('calgary/paper1');
        expect(codec.decompress(compressed), orderedEquals(expected));
        expect(compressed.length, lessThan(expected.length ~/ 2));
      });

      test('decodes varied symbol frequencies (alphabet)', () {
        final codec = ZstdCodec();
        final compressed = readCodecFixture(
          'zstd',
          'artificial/alphabet.txt.zst',
        );
        final expected = readDataFixture('artificial/alphabet.txt');
        expect(codec.decompress(compressed), orderedEquals(expected));
      });
    });

    group('multi-block', () {
      // Regression: the encoder must not emit repeat-offset codes, whose state
      // is frame-stateful across blocks. With a small block size, compressible
      // data spans many blocks; rep-code emission corrupted later blocks.
      test('round-trips compressible data across many small blocks', () {
        final codec = ZstdCodec(blockSize: 1024);
        const pattern = 'the quick brown fox jumps over the lazy dog. ';
        final original = bytes(
          List.generate(
            64 * 1024,
            (i) => pattern.codeUnitAt(i % pattern.length),
          ),
        );
        expectRoundTrip(codec, original);
      });

      test('round-trips repetitive binary across many small blocks', () {
        final codec = ZstdCodec(blockSize: 512);
        expectRoundTrip(
          codec,
          bytes(List.generate(32 * 1024, (i) => (i ~/ 7) % 13)),
        );
      });
    });

    group('concatenated frames', () {
      test('multiple frames decode to the concatenation', () {
        final codec = ZstdCodec();
        final first = bytes(List.generate(32, (i) => i));
        final second = bytes(List.generate(48, (i) => 255 - i));
        final combined = bytes([
          ...codec.compress(first),
          ...codec.compress(second),
        ]);
        expect(
          codec.decompress(combined),
          orderedEquals([...first, ...second]),
        );
      });

      test('skippable frames between valid frames are skipped', () {
        final codec = ZstdCodec();
        final payload = bytes(List.generate(16, (i) => i + 1));
        final frame = codec.compress(payload);
        final skippable = _buildSkippableFrame(
          zstdSkippableFrameMagicBase + 3,
          [0, 1, 2, 3, 4],
        );
        final combined = bytes([...frame, ...skippable, ...frame]);
        expect(
          codec.decompress(combined),
          orderedEquals([...payload, ...payload]),
        );
      });

      test('skippable-only stream decodes to empty', () {
        final codec = ZstdCodec();
        final s1 = _buildSkippableFrame(zstdSkippableFrameMagicBase, [1, 2, 3]);
        final s2 = _buildSkippableFrame(zstdSkippableFrameMagicBase + 5, [
          4,
          5,
          6,
          7,
          8,
        ]);
        expect(codec.decompress(bytes([...s1, ...s2])), isEmpty);
      });
    });

    test('rejects frames that require a dictionary', () {
      final codec = ZstdCodec();
      final frame = codec.compress(bytes([5, 4, 3, 2, 1]));
      final mutated = _injectDictionaryFlag(frame);
      expect(
        () => codec.decompress(mutated),
        throwsA(
          isA<ZstdFormatException>().having(
            (e) => e.message,
            'message',
            contains('Dictionary compression'),
          ),
        ),
      );
    });

    // Deterministic compression-ratio regression gate (machine-independent):
    // floors sit a few points below measured savings so an algorithmic
    // regression trips while routine byte-shifting tweaks do not.
    test('meets compression-ratio floors on the corpus', () {
      const floors = <String, double>{
        'canterbury/alice29.txt': 54,
        'calgary/paper1': 56,
        'large/bible.txt': 63,
      };
      floors.forEach((file, floor) {
        final path = 'test/fixtures/data/$file';
        if (!File(path).existsSync()) {
          markTestSkipped('fixture missing: $path');
          return;
        }
        final data = readDataFixture(file);
        final compressed = ZstdCodec().compress(data);
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

  group('Zstd streaming', () {
    test('round-trips multi-chunk input', () async {
      final codec = ZstdStreamCodec();
      await expectStreamRoundTrip(codec, [
        bytes(List.generate(5000, (i) => i % 256)),
        bytes('the quick brown fox '.codeUnits),
        bytes(List.generate(9000, (i) => (i * 7) % 13)),
      ]);
    });

    test('round-trips empty stream', () async {
      final compressed = await collect(
        ZstdStreamCodec().compress(const Stream.empty()),
      );
      expect(ZstdCodec().decompress(compressed), isEmpty);
    });

    test('round-trips with content checksum', () async {
      final codec = ZstdStreamCodec(checksum: true);
      final repeated = bytes(List.generate(40000, (i) => (i * 31 + 7) % 251));
      await expectStreamRoundTrip(codec, [repeated, repeated]);
    });

    test('cross-chunk history compresses repeated chunks well', () async {
      final codec = ZstdStreamCodec();
      final block = bytes(List.generate(8192, (i) => (i * 31 + 7) % 256));
      final many = await collect(
        codec.compress(Stream.fromIterable(List.generate(8, (_) => block))),
      );
      final single = await collect(codec.compress(Stream.value(block)));
      expect(
        many.length,
        lessThan(single.length * 4),
        reason: '8 identical chunks should be far less than 8x one chunk',
      );
      final restored = await collect(codec.decompress(Stream.value(many)));
      expect(
        restored,
        orderedEquals(bytes(List.generate(8, (_) => block).expand((c) => c))),
      );
    });

    test('uses a window descriptor (not single-segment)', () async {
      final compressed = await collect(
        ZstdStreamCodec().compress(
          Stream.value(bytes(List.generate(20000, (i) => (i * 3) % 97))),
        ),
      );
      // Descriptor byte at offset 4; single-segment bit (0x20) must be clear.
      expect(compressed[4] & 0x20, 0);
    });

    test(
      'honours a non-default blockSize via window descriptor byte',
      () async {
        final chunks = [
          bytes(List.generate(40000, (i) => (i * 31 + 7) % 251)),
          bytes(List.generate(40000, (i) => (i * 17 + 3) % 251)),
        ];
        final original = bytes(chunks.expand((c) => c));
        // 64 KB blocks -> 128 KB window -> descriptor byte 0x38;
        // 16 KB blocks -> 40 KB window -> 0x28.
        for (final entry in {64 * 1024: 0x38, 16 * 1024: 0x28}.entries) {
          final compressed = await collect(
            ZstdStreamCodec(
              blockSize: entry.key,
            ).compress(Stream.fromIterable(chunks)),
          );
          expect(
            compressed[5],
            entry.value,
            reason: 'window descriptor byte for blockSize ${entry.key}',
          );
          expect(ZstdCodec().decompress(compressed), orderedEquals(original));
        }
      },
    );

    group('fragmented (1-byte) input', () {
      test('round-trips small data', () async {
        await expectFragmentedRoundTrip(
          ZstdStreamCodec(),
          bytes('Hello, Zstd streaming!'.codeUnits),
        );
      });

      test('round-trips multi-block compressible data', () async {
        final codec = ZstdStreamCodec(blockSize: 16384);
        const pattern = 'the quick brown fox jumps over the lazy dog. ';
        final original = bytes(
          List.generate(
            120 * 1024,
            (i) => pattern.codeUnitAt(i % pattern.length),
          ),
        );
        await _expectFragmented(codec, original);
      });

      test('round-trips with content checksum', () async {
        final codec = ZstdStreamCodec(blockSize: 16384, checksum: true);
        await _expectFragmented(
          codec,
          bytes(List.generate(80 * 1024, (i) => (i * 31 + 7) % 251)),
        );
      });

      test('round-trips concatenated frames', () async {
        final codec = ZstdStreamCodec();
        final a = bytes(List.generate(6000, (i) => i % 7));
        final b = bytes(List.generate(9000, (i) => (i * 3) % 11));
        final compressed = bytes([
          ...await collect(codec.compress(Stream.value(a))),
          ...await collect(codec.compress(Stream.value(b))),
        ]);
        final restored = await _decodeFragmented(codec, compressed);
        expect(restored, orderedEquals([...a, ...b]));
      });

      test('decodes native-CLI .zst fixtures', () async {
        final codec = ZstdStreamCodec();
        for (final path in standardFixtures) {
          final compressed = readCodecFixture('zstd', '$path.zst');
          final expected = readDataFixture(path);
          expect(
            await _decodeFragmented(codec, compressed),
            orderedEquals(expected),
            reason: path,
          );
        }
      });

      test('whole-input and 1-byte-chunk decoding agree', () async {
        final codec = ZstdStreamCodec(blockSize: 16384);
        const pattern = 'abcabcabcdefdefdef0123456789';
        final original = bytes(
          List.generate(
            100 * 1024,
            (i) => pattern.codeUnitAt(i % pattern.length),
          ),
        );
        final compressed = await collect(
          codec.compress(Stream.value(original)),
        );
        final whole = await collect(codec.decompress(Stream.value(compressed)));
        final fragmented = await _decodeFragmented(codec, compressed);
        expect(whole, orderedEquals(original));
        expect(fragmented, orderedEquals(whole));
      });

      test('truncated frame fed fragmented errors at end of stream', () async {
        final codec = ZstdStreamCodec(blockSize: 16384);
        final original = bytes(List.generate(40000, (i) => i % 256));
        final compressed = await collect(
          codec.compress(Stream.value(original)),
        );
        final truncated = Uint8List.sublistView(
          compressed,
          0,
          compressed.length - 5,
        );
        expect(
          () => _decodeFragmented(codec, truncated),
          throwsA(isA<ZstdFormatException>()),
        );
      });
    });

    test('verified mode round-trips', () async {
      final codec = ZstdStreamCodec(verified: true, checksum: true);
      await expectStreamRoundTrip(codec, [
        bytes(List.generate(20000, (i) => (i * 13 + 5) % 211)),
        bytes(List.generate(20000, (i) => (i * 7 + 3) % 211)),
      ]);
    });

    test('verified mode withholds all output on a corrupt checksum', () async {
      final payload = bytes(List.generate(5000, (i) => (i * 31 + 7) % 256));
      final compressed = Uint8List.fromList(
        ZstdCodec(enableChecksum: true).compress(payload),
      );
      compressed[compressed.length - 1] ^= 0xFF; // flip content-checksum byte
      final (output, error) = await _decodeCollect(
        ZstdStreamCodec(verified: true),
        compressed,
      );
      expect(error, isA<CompressionFormatException>());
      expect(
        output,
        isEmpty,
        reason: 'verified mode must not emit bytes from a frame that fails',
      );
    });

    test('garbage byte stream surfaces CompressionFormatException', () {
      final garbage = bytes(List.generate(80, (i) => (i * 7 + 3) & 0xFF));
      expect(
        collect(ZstdStreamCodec().decompress(Stream.value(garbage))),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    group('stream constructor fail-fast', () {
      test('rejects level out of 1-22', () {
        expect(() => ZstdStreamCodec(level: 23), throwsArgumentError);
      });

      test('rejects oversized block size', () {
        expect(
          () => ZstdStreamCodec(blockSize: 256 * 1024),
          throwsArgumentError,
        );
      });

      test('rejects non-positive max buffer size', () {
        expect(() => ZstdStreamCodec(maxBufferSize: 0), throwsArgumentError);
      });

      test('accepts valid construction', () {
        expect(ZstdStreamCodec(level: 1, blockSize: 16 * 1024), isNotNull);
      });
    });

    test('healthy streaming compression: zero fallbacks and compresses', () {
      final data = _healthyData();
      final encoder = StreamingZstdEncoder(level: 3);
      final body = encoder.addChunk(data);
      encoder.finish();
      expect(
        encoder.fallbacks,
        0,
        reason: 'a silent FSE/Huffman regression would raise this',
      );
      expect(body.length, lessThan(data.length));
    });
  });

  group('Zstd limits & validation', () {
    test('rejects absurd declared contentSize in header', () {
      final codec = ZstdCodec(maxDecompressedSize: 1024);
      final frame = _buildFrameWithContentSize(0xFFFFFFFF); // 4GB declared
      expect(
        () => codec.decompress(frame),
        throwsA(
          isA<ZstdFormatException>().having(
            (e) => e.message,
            'message',
            contains('exceeds maximum allowed size'),
          ),
        ),
      );
    });

    test('enforces max size during decompression', () {
      final compressed = ZstdCodec(
        maxDecompressedSize: null,
      ).compress(bytes(List.filled(1000, 65)));
      final limited = ZstdCodec(maxDecompressedSize: 500);
      expect(
        () => limited.decompress(compressed),
        throwsA(
          isA<ZstdFormatException>().having(
            (e) => e.message,
            'message',
            contains('exceeds maximum allowed size'),
          ),
        ),
      );
    });

    test('allows decompression within limit', () {
      final data = bytes(List.filled(500, 66));
      final compressed = ZstdCodec(maxDecompressedSize: null).compress(data);
      expect(
        ZstdCodec(maxDecompressedSize: 1000).decompress(compressed),
        orderedEquals(data),
      );
    });

    test('unlimited mode works for trusted input', () {
      final codec = ZstdCodec(maxDecompressedSize: null);
      expectRoundTrip(codec, bytes(List.generate(10000, (i) => i % 256)));
    });

    test('default limit allows reasonable sizes', () {
      expectRoundTrip(ZstdCodec(), bytes(List.generate(1000, (i) => i % 256)));
    });

    group('fromOptions', () {
      test('preserves options', () {
        final codec = ZstdCodec.fromOptions(
          ZstdOptions(level: 5, blockSize: 64 * 1024, checksum: true),
        );
        expect(codec.level, 5);
        expect(codec.blockSize, 64 * 1024);
        expect(codec.enableChecksum, true);
      });

      test('applies defaults', () {
        final codec = ZstdCodec.fromOptions(ZstdOptions());
        expect(codec.level, 3);
        expect(codec.blockSize, 128 * 1024);
        expect(codec.enableChecksum, false);
      });

      test('preserves and enforces maxDecompressedSize', () {
        final options = ZstdOptions(maxDecompressedSize: 500);
        final codec = ZstdCodec.fromOptions(options);
        expect(codec.maxDecompressedSize, 500);
        final compressed = ZstdCodec(
          maxDecompressedSize: null,
        ).compress(bytes(List.filled(1000, 65)));
        expect(
          () => codec.decompress(compressed),
          throwsA(isA<ZstdFormatException>()),
        );
      });
    });

    group('constructor fail-fast', () {
      test('rejects level out of 1-22', () {
        expect(() => ZstdCodec(level: 0), throwsArgumentError);
        expect(() => ZstdCodec(level: 23), throwsArgumentError);
      });

      test('rejects non-positive block size', () {
        expect(() => ZstdCodec(blockSize: 0), throwsArgumentError);
        expect(() => ZstdCodec(blockSize: -1), throwsArgumentError);
        expect(() => ZstdEncoder(blockSize: 0), throwsArgumentError);
        expect(() => ZstdEncoder(blockSize: -1), throwsArgumentError);
      });

      test('rejects oversized block size', () {
        expect(() => ZstdCodec(blockSize: 129 * 1024), throwsArgumentError);
        expect(() => ZstdEncoder(blockSize: 129 * 1024), throwsArgumentError);
      });
    });

    test('detects truncated compressed block', () {
      final codec = ZstdCodec(maxDecompressedSize: null);
      final pattern = List<int>.generate(64, (i) => i);
      final data = bytes([...pattern, for (var i = 0; i < 10; i++) ...pattern]);
      final compressed = codec.compress(data);
      final truncated = Uint8List.sublistView(
        compressed,
        0,
        compressed.length - 5,
      );
      expect(
        () => codec.decompress(truncated),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('stream maxBufferSize preflight rejects an oversized chunk', () {
      final blob = ZstdCodec().compress(
        bytes(List.generate(5000, (i) => (i * 131 + 7) % 256)),
      );
      expect(blob.length, greaterThan(64));
      expect(
        collect(
          ZstdStreamCodec(maxBufferSize: 64).decompress(Stream.value(blob)),
        ),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('stream maxSize caps cumulative output across frames', () {
      final codec = ZstdCodec();
      final payload = bytes(List.filled(1000, 65));
      final frame = codec.compress(payload);
      final concat = bytes([for (var i = 0; i < 5; i++) ...frame]); // 5000 out
      // Each frame (1000) is under the cap, but the cumulative total is not.
      expect(
        collect(
          ZstdStreamCodec(maxSize: 2500).decompress(Stream.value(concat)),
        ),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test(
      'healthy block compression: zero fallbacks and actually compresses',
      () {
        final data = _healthyData();
        final encoder = ZstdEncoder(level: 3);
        final out = encoder.compress(data);
        expect(
          encoder.fallbacks,
          0,
          reason: 'a silent FSE/Huffman regression would raise this',
        );
        expect(out.length, lessThan(data.length));
      },
    );
  });

  group('Zstd CLI compatibility', () {
    test('library output (RLE) readable by zstd CLI', () async {
      if (!await cliAvailableCached('zstd')) {
        markTestSkipped('zstd CLI tool not available');
        return;
      }
      await _expectCliReads(ZstdCodec(), readDataFixture('artificial/aaa.txt'));
    });

    test('library output (zeros RLE) readable by zstd CLI', () async {
      if (!await cliAvailableCached('zstd')) {
        markTestSkipped('zstd CLI tool not available');
        return;
      }
      await _expectCliReads(ZstdCodec(), readDataFixture('zeros.bin'));
    });

    test('library output (raw) readable by zstd CLI', () async {
      if (!await cliAvailableCached('zstd')) {
        markTestSkipped('zstd CLI tool not available');
        return;
      }
      await _expectCliReads(ZstdCodec(), readDataFixture('random.bin'));
    });

    test('library output (checksum) readable by zstd CLI', () async {
      if (!await cliAvailableCached('zstd')) {
        markTestSkipped('zstd CLI tool not available');
        return;
      }
      await _expectCliReads(
        ZstdCodec(enableChecksum: true),
        readDataFixture('html'),
      );
    });

    test('library output (small block) readable by zstd CLI', () async {
      if (!await cliAvailableCached('zstd')) {
        markTestSkipped('zstd CLI tool not available');
        return;
      }
      await _expectCliReads(
        ZstdCodec(blockSize: 1000),
        bytes(List.generate(2500, (i) => i % 256)),
      );
    });

    test('bidirectional: lib -> CLI -> CLI -> lib', () async {
      if (!await cliAvailableCached('zstd')) {
        markTestSkipped('zstd CLI tool not available');
        return;
      }
      final codec = ZstdCodec();
      final original = bytes(List.filled(10000, 65));
      final path = '/tmp/libcompress_zstd_bidir.zst';
      final out = '/tmp/libcompress_zstd_bidir.out';
      final cliPath = '/tmp/libcompress_zstd_cli.zst';
      try {
        await File(path).writeAsBytes(codec.compress(original));
        final r1 = await Process.run('zstd', ['-d', '-f', '-o', out, path]);
        expect(r1.exitCode, 0, reason: 'zstd CLI decompression failed');
        expect(await File(out).readAsBytes(), equals(original));
        final r2 = await Process.run('zstd', ['-f', '-o', cliPath, out]);
        expect(r2.exitCode, 0);
        final cliCompressed = await File(cliPath).readAsBytes();
        expect(
          codec.decompress(Uint8List.fromList(cliCompressed)),
          equals(original),
        );
      } finally {
        await cleanup([path, out, cliPath]);
      }
    });

    test('all fixtures: lib compress -> CLI decompress', () async {
      if (!await cliAvailableCached('zstd')) {
        markTestSkipped('zstd CLI tool not available');
        return;
      }
      final codec = ZstdCodec();
      for (final path in standardFixtures) {
        final original = readDataFixture(path);
        final safe = path.replaceAll('/', '_');
        final tmpPath = '/tmp/libcompress_zstd_rt_$safe.zst';
        final tmpOut = '/tmp/libcompress_zstd_rt_$safe.out';
        try {
          await File(tmpPath).writeAsBytes(codec.compress(original));
          final result = await Process.run('zstd', [
            '-d',
            '-f',
            '-o',
            tmpOut,
            tmpPath,
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
      }
    });

    test('library decompresses CLI Huffman at various levels', () async {
      if (!await cliAvailableCached('zstd')) {
        markTestSkipped('zstd CLI tool not available');
        return;
      }
      final codec = ZstdCodec();
      final original = readDataFixture('html');
      final tmpIn = '/tmp/libcompress_zstd_huffman_in.txt';
      final tmpOut = '/tmp/libcompress_zstd_huffman.zst';
      try {
        await File(tmpIn).writeAsBytes(original);
        for (final level in [1, 3, 9, 19]) {
          final result = await Process.run('zstd', [
            '-$level',
            '-f',
            '-o',
            tmpOut,
            tmpIn,
          ]);
          expect(
            result.exitCode,
            0,
            reason: 'CLI compression failed at $level',
          );
          final compressed = await File(tmpOut).readAsBytes();
          expect(
            codec.decompress(Uint8List.fromList(compressed)),
            equals(original),
            reason: 'Decompression failed at level $level',
          );
        }
      } finally {
        await cleanup([tmpIn, tmpOut]);
      }
    });

    test('handles 4-stream Huffman from CLI', () async {
      if (!await cliAvailableCached('zstd')) {
        markTestSkipped('zstd CLI tool not available');
        return;
      }
      await _expectCliCompressReads(
        ZstdCodec(),
        readDataFixture('canterbury/alice29.txt'),
        '4stream',
      );
    });

    test('handles single-stream Huffman from CLI', () async {
      if (!await cliAvailableCached('zstd')) {
        markTestSkipped('zstd CLI tool not available');
        return;
      }
      await _expectCliCompressReads(
        ZstdCodec(),
        bytes(
          'Hello, World! This is a small test string for Huffman encoding.'
              .codeUnits,
        ),
        '1stream',
      );
    });

    test('decompresses CLI-compressed html with strong ratio', () {
      final codec = ZstdCodec();
      final compressed = readCodecFixture('zstd', 'html.zst');
      final expected = readDataFixture('html');
      expect(codec.decompress(compressed), equals(expected));
      expect(compressed.length, lessThan(expected.length ~/ 4));
    });

    test('valid CLI-compressed data passes strict block validation', () {
      final codec = ZstdCodec(maxDecompressedSize: null);
      final compressed = readCodecFixture('zstd', 'html.zst');
      expect(
        codec.decompress(compressed),
        orderedEquals(readDataFixture('html')),
      );
    });
  });

  group('Zstd fuzzing / malformed input', () {
    final random = Random(42);
    final codec = ZstdCodec();

    test('rejects pure random noise', () {
      for (var i = 0; i < 100; i++) {
        final noise = bytes(
          List.generate(random.nextInt(1000) + 1, (_) => random.nextInt(256)),
        );
        expect(
          () => codec.decompress(noise),
          throwsA(isA<ZstdFormatException>()),
          reason: 'random noise iteration $i',
        );
      }
    });

    test('rejects short random data', () {
      for (var length = 0; length < 20; length++) {
        final noise = bytes(List.generate(length, (_) => random.nextInt(256)));
        expect(
          () => codec.decompress(noise),
          throwsA(isA<CompressionFormatException>()),
          reason: 'short random data ($length bytes)',
        );
      }
    });

    test('rejects truncation at every position', () {
      final valid = codec.compress(bytes(List.generate(1000, (i) => i % 256)));
      for (var cutoff = 0; cutoff < valid.length; cutoff++) {
        final truncated = Uint8List.sublistView(valid, 0, cutoff);
        expect(
          () => codec.decompress(truncated),
          throwsA(isA<CompressionFormatException>()),
          reason: 'truncated at $cutoff',
        );
      }
    });

    test('rejects wrong magic number', () {
      expect(
        () => codec.decompress(bytes([0, 0, 0, 0, 0])),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('rejects each corrupted byte of the magic', () {
      final magic = [0x28, 0xB5, 0x2F, 0xFD];
      for (var i = 0; i < 4; i++) {
        final corrupted = List<int>.from(magic)..[i] ^= 0xFF;
        expect(
          () => codec.decompress(bytes([...corrupted, 0x00])),
          throwsA(isA<ZstdFormatException>()),
          reason: 'corrupted magic byte $i',
        );
      }
    });

    test('rejects invalid frame header descriptor', () {
      expect(
        () => codec.decompress(bytes([0x28, 0xB5, 0x2F, 0xFD, 0xFF])),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects truncated window descriptor', () {
      expect(
        () => codec.decompress(bytes([0x28, 0xB5, 0x2F, 0xFD, 0x00])),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects truncated content size', () {
      expect(
        () =>
            codec.decompress(bytes([0x28, 0xB5, 0x2F, 0xFD, 0x60, 0x00, 0x10])),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects invalid dictionary ID size', () {
      expect(
        () => codec.decompress(
          bytes([0x28, 0xB5, 0x2F, 0xFD, 0x23, 0x00, 0x01, 0x02]),
        ),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects invalid (reserved) block type', () {
      expect(
        () => codec.decompress(
          bytes([0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x00, 0x06, 0x00, 0x00]),
        ),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('rejects block size exceeding maximum', () {
      expect(
        () => codec.decompress(
          bytes([0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x00, 0x01, 0x00, 0x10]),
        ),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects truncated block data', () {
      expect(
        () => codec.decompress(
          bytes([
            0x28,
            0xB5,
            0x2F,
            0xFD,
            0x20,
            0x05,
            0x29,
            0x00,
            0x00,
            0x01,
            0x02,
          ]),
        ),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects compressed block with invalid literals header', () {
      expect(
        () => codec.decompress(
          bytes([0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x05, 0x05, 0x00, 0x00, 0xFF]),
        ),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects block with too many sequences', () {
      expect(
        () => codec.decompress(
          bytes([
            0x28,
            0xB5,
            0x2F,
            0xFD,
            0x20,
            0x80,
            0x01,
            0x15,
            0x00,
            0x00,
            0x00,
            0xFF,
            0xFF,
            0x00,
          ]),
        ),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects corrupted content checksum', () {
      final checksummed = ZstdCodec(enableChecksum: true);
      final compressed = checksummed.compress(bytes([1, 2, 3, 4, 5]));
      final corrupted = Uint8List.fromList(compressed)
        ..[compressed.length - 1] ^= 0xFF;
      expect(
        () => checksummed.decompress(corrupted),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('rejects truncated checksum', () {
      final checksummed = ZstdCodec(enableChecksum: true);
      final compressed = checksummed.compress(bytes([1, 2, 3, 4, 5]));
      final truncated = Uint8List.sublistView(
        compressed,
        0,
        compressed.length - 2,
      );
      expect(
        () => checksummed.decompress(truncated),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects decompression bomb (declared size exceeds limit)', () {
      final data = bytes([
        0x28, 0xB5, 0x2F, 0xFD, 0xE0, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, // 1TB content size
        0x01, 0x00, 0x00,
      ]);
      final restricted = ZstdCodec(maxDecompressedSize: 256 * 1024 * 1024);
      expect(
        () => restricted.decompress(data),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('enforces maxDecompressedSize on valid data', () {
      final compressed = codec.compress(bytes(List.filled(10000, 0x41)));
      final restricted = ZstdCodec(maxDecompressedSize: 1000);
      expect(
        () => restricted.decompress(compressed),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects content-size mismatch (output differs from declared)', () {
      final data = bytes([
        0x28,
        0xB5,
        0x2F,
        0xFD,
        0x20,
        0x0A,
        0x29,
        0x00,
        0x00,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
      ]);
      expect(() => codec.decompress(data), throwsA(isA<ZstdFormatException>()));
    });

    test(
      'tolerates single-byte corruptions (throws or wrong, never crashes)',
      () {
        final valid = codec.compress(
          bytes(List.generate(5000, (i) => i % 256)),
        );
        for (var i = 4; i < min(100, valid.length); i++) {
          final corrupted = Uint8List.fromList(valid)..[i] ^= 0xFF;
          try {
            codec.decompress(corrupted);
          } on CompressionFormatException {
            // Expected for detected corruption.
          } catch (e) {
            fail(
              'corrupted byte at $i threw $e instead of '
              'CompressionFormatException',
            );
          }
        }
      },
    );

    test('rejects truncated second frame', () {
      final frame1 = codec.compress(bytes([1, 2, 3]));
      final partial = bytes([...frame1, 0x28, 0xB5, 0x2F, 0xFD]);
      expect(
        () => codec.decompress(partial),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('decompresses multiple valid frames', () {
      final frame1 = codec.compress(bytes([1, 2, 3]));
      final frame2 = codec.compress(bytes([4, 5, 6]));
      expect(
        codec.decompress(bytes([...frame1, ...frame2])),
        equals([1, 2, 3, 4, 5, 6]),
      );
    });
  });

  group('Zstd format', () {
    final codec = ZstdCodec();

    test('emits the correct magic number', () {
      final compressed = codec.compress(bytes([1, 2, 3]));
      // Magic number 0xFD2FB528 (little-endian).
      expect(compressed.sublist(0, 4), [0x28, 0xB5, 0x2F, 0xFD]);
    });

    test('rejects invalid magic number with a clear message', () {
      expect(
        () => codec.decompress(bytes([0x00, 0x00, 0x00, 0x00])),
        throwsA(
          isA<ZstdFormatException>().having(
            (e) => e.message,
            'message',
            contains('Invalid Zstd magic number'),
          ),
        ),
      );
    });

    test('rejects incomplete frame (magic only)', () {
      expect(
        () => codec.decompress(bytes([0x28, 0xB5, 0x2F, 0xFD])),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('window descriptor present in streaming frame', () async {
      final compressed = await collect(
        ZstdStreamCodec().compress(
          Stream.value(bytes(List.generate(20000, (i) => i % 251))),
        ),
      );
      expect(compressed[4] & 0x20, 0, reason: 'single-segment bit clear');
    });

    test('first block header carries a valid block type', () {
      final compressed = codec.compress(bytes(List.filled(1000, 65)));
      final type = _firstBlockType(compressed);
      expect(type, inInclusiveRange(0, 2));
    });

    test('content checksum (XXH64 low 32) round-trips', () {
      final checksummed = ZstdCodec(enableChecksum: true);
      final data = readDataFixture('html');
      expect(
        checksummed.decompress(checksummed.compress(data)),
        orderedEquals(data),
      );
    });

    test('decodes a valid RLE block built by hand', () {
      final data = bytes([
        0x28,
        0xB5,
        0x2F,
        0xFD,
        0x20,
        0x05,
        0x2B,
        0x00,
        0x00,
        0x41,
      ]);
      expect(codec.decompress(data), equals([0x41, 0x41, 0x41, 0x41, 0x41]));
    });

    test('handles skippable frame followed by a valid frame', () {
      final valid = codec.compress(bytes([1, 2, 3]));
      final data = bytes([
        0x50, 0x2A, 0x4D, 0x18, // Skippable magic (0x184D2A50)
        0x04, 0x00, 0x00, 0x00, // Size = 4
        0xDE, 0xAD, 0xBE, 0xEF, // Skipped data
        ...valid,
      ]);
      expect(codec.decompress(data), equals([1, 2, 3]));
    });

    test('rejects truncated skippable frame', () {
      final data = bytes([
        0x50,
        0x2A,
        0x4D,
        0x18,
        0x10,
        0x00,
        0x00,
        0x00,
        0x01,
        0x02,
        0x03,
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });
  });
}

// --- streaming fragmented helpers ---

/// Decodes [data] through [codec], accumulating output and capturing any error,
/// so a test can assert that a failure emits zero bytes (all-or-nothing).
Future<(List<int>, Object?)> _decodeCollect(
  final ZstdStreamCodec codec,
  final Uint8List data,
) async {
  final output = <int>[];
  Object? error;
  try {
    await for (final chunk in codec.decompress(Stream.value(data))) {
      output.addAll(chunk);
    }
  } catch (e) {
    error = e;
  }
  return (output, error);
}

Future<void> _expectFragmented(
  final ZstdStreamCodec codec,
  final Uint8List data,
) async {
  final compressed = await collect(codec.compress(Stream.value(data)));
  expect(
    await _decodeFragmented(codec, compressed),
    orderedEquals(data),
    reason: 'fragmented (1-byte) round-trip (${data.length} bytes)',
  );
}

Future<Uint8List> _decodeFragmented(
  final ZstdStreamCodec codec,
  final Uint8List compressed,
) async {
  final oneByte = [
    for (var i = 0; i < compressed.length; i++)
      Uint8List.sublistView(compressed, i, i + 1),
  ];
  return collect(codec.decompress(Stream.fromIterable(oneByte)));
}

// --- CLI helpers ---

Future<void> _expectCliReads(
  final CompressionCodec codec,
  final Uint8List original,
) async {
  final path = '/tmp/libcompress_zstd_cli_in.zst';
  final out = '/tmp/libcompress_zstd_cli_out.bin';
  try {
    await File(path).writeAsBytes(codec.compress(original));
    final result = await Process.run('zstd', ['-d', '-f', '-o', out, path]);
    expect(
      result.exitCode,
      0,
      reason: 'zstd decompression failed: ${result.stderr}',
    );
    expect(await File(out).readAsBytes(), equals(original));
  } finally {
    await cleanup([path, out]);
  }
}

Future<void> _expectCliCompressReads(
  final ZstdCodec codec,
  final Uint8List original,
  final String tag,
) async {
  final tmpIn = '/tmp/libcompress_zstd_${tag}_in.txt';
  final tmpOut = '/tmp/libcompress_zstd_$tag.zst';
  try {
    await File(tmpIn).writeAsBytes(original);
    final result = await Process.run('zstd', ['-f', '-o', tmpOut, tmpIn]);
    expect(result.exitCode, 0);
    final compressed = await File(tmpOut).readAsBytes();
    expect(codec.decompress(Uint8List.fromList(compressed)), equals(original));
  } finally {
    await cleanup([tmpIn, tmpOut]);
  }
}

// --- fallbacks guard fixture ---

/// Real, compressible text. Falls back to a repetitive synthetic buffer (which
/// also compresses well via FSE/Huffman) when the corpus file is absent.
Uint8List _healthyData() {
  const path = 'test/fixtures/data/canterbury/alice29.txt';
  return File(path).existsSync()
      ? Uint8List.fromList(File(path).readAsBytesSync())
      : bytes(
          List.generate(
            200000,
            (i) => 'the quick brown fox '.codeUnitAt(i % 20),
          ),
        );
}

// --- raw-frame builders ---

Uint8List _buildSkippableFrame(final int magic, final List<int> payload) =>
    bytes([..._uint32LE(magic), ..._uint32LE(payload.length), ...payload]);

List<int> _uint32LE(final int value) => [
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
];

Uint8List _injectDictionaryFlag(final Uint8List frame) {
  if (frame.length <= 5) {
    return frame;
  }
  const descriptorIndex = 4;
  return bytes([
    ...frame.sublist(0, descriptorIndex),
    frame[descriptorIndex] | 0x01, // Set dictionaryIdFlag = 1
    0x42, // Fake dictionary ID byte
    ...frame.sublist(descriptorIndex + 1),
  ]);
}

int _firstBlockType(final Uint8List frame) {
  final headerOffset = _frameHeaderSize(frame);
  if (headerOffset + 3 > frame.length) {
    throw StateError('Frame too short to contain block header');
  }
  final blockHeader =
      frame[headerOffset] |
      (frame[headerOffset + 1] << 8) |
      (frame[headerOffset + 2] << 16);
  return (blockHeader >> 1) & 0x03;
}

int _frameHeaderSize(final Uint8List frame) {
  if (frame.length < 5) {
    throw StateError('Frame too short to contain header');
  }
  var offset = 4; // Skip magic
  final descriptor = frame[offset++];
  final singleSegment = (descriptor & 0x20) != 0;
  final contentSizeFlag = (descriptor >> 6) & 0x03;
  final dictionaryIdFlag = descriptor & 0x03;
  if (!singleSegment) {
    offset += 1; // Window descriptor byte
  }
  if (dictionaryIdFlag > 0) {
    offset += 1 << (dictionaryIdFlag - 1);
  }
  offset += singleSegment
      ? [1, 2, 4, 8][contentSizeFlag]
      : [0, 2, 4, 8][contentSizeFlag];
  return offset;
}

/// Builds a minimal Zstd frame with a specified declared contentSize, used to
/// test OOM rejection of malicious headers.
Uint8List _buildFrameWithContentSize(final int size) => bytes([
  ..._uint32LE(zstdMagicNumber),
  0xA0, // single segment + contentSizeFlag=2 (4-byte size)
  ..._uint32LE(size),
  0x01, 0x00, 0x00, // empty last raw block
]);
