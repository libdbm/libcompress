import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/src/snappy/snappy_codec.dart';
import 'package:libcompress/src/snappy/snappy_decoder.dart';
import 'package:libcompress/src/snappy/snappy_stream_encoder.dart';
import 'test_utils.dart';
import 'web_test_utils.dart';

void main() {
  group('Snappy decompression fixtures', () {
    for (final path in standardFixtures) {
      test('decompresses $path', () {
        final codec = SnappyCodec();
        final compressed = readCodecFixture('snappy', '$path.snappy');
        final expected = readDataFixture(path);
        final actual = codec.decompress(compressed);
        expect(actual, orderedEquals(expected));
      });
    }

    for (final path in standardFixtures) {
      test(
        'decompresses $path on web/js',
        () async {
          await expectWebDecompresses(
            codecExpression: 'SnappyCodec(framing: false)',
            compressed: readCodecFixture('snappy', '$path.snappy'),
            expected: readDataFixture(path),
          );
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );
    }
  });

  group('Snappy round-trip compression (raw block)', () {
    for (final path in standardFixtures) {
      test('round-trips $path', () {
        final codec = SnappyCodec(framing: false);
        final original = readDataFixture(path);
        final compressed = codec.compress(original);
        final restored = codec.decompress(compressed);
        expect(restored, orderedEquals(original));
      });
    }

    for (final path in standardFixtures) {
      test(
        'round-trips $path on web/js',
        () async {
          await expectWebRoundTrip(
            codecExpression: 'SnappyCodec(framing: false)',
            data: readDataFixture(path),
          );
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );
    }
  });

  group('Snappy round-trip compression (framing)', () {
    for (final path in standardFixtures) {
      test('round-trips $path with framing', () {
        final codec = SnappyCodec(framing: true);
        final original = readDataFixture(path);
        final compressed = codec.compress(original);
        final restored = codec.decompress(compressed);
        expect(restored, orderedEquals(original));
      });
    }

    for (final path in standardFixtures) {
      test(
        'round-trips $path with framing on web/js',
        () async {
          await expectWebRoundTrip(
            codecExpression: 'SnappyCodec(framing: true)',
            data: readDataFixture(path),
          );
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );
    }
  });

  group('Snappy format modes', () {
    test('raw block format (default)', () {
      final codec = SnappyCodec(framing: false);
      final data = readDataFixture('html');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });

    test('framing format', () {
      final codec = SnappyCodec(framing: true);
      final data = readDataFixture('html');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });

    test('framing format has stream identifier header', () {
      final codec = SnappyCodec(framing: true);
      final data = readDataFixture('html');
      final compressed = codec.compress(data);
      // Stream identifier chunk: 0xFF followed by stream magic
      expect(compressed[0], 0xFF);
    });

    test('raw format starts with varint length', () {
      final codec = SnappyCodec(framing: false);
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final compressed = codec.compress(data);
      // First byte is varint for uncompressed length (5)
      expect(compressed[0], 5);
    });
  });

  group('Snappy chunk sizes (framing)', () {
    test('default max chunk size', () {
      final codec = SnappyCodec(
        framing: true,
        chunkSize: SnappyStreamEncoder.maxChunkSize,
      );
      final data = readDataFixture('canterbury/alice29.txt');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });

    test('small chunk size', () {
      final codec = SnappyCodec(framing: true, chunkSize: 1024);
      final data = readDataFixture('canterbury/alice29.txt');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });

    test('chunk size of 4096', () {
      final codec = SnappyCodec(framing: true, chunkSize: 4096);
      final data = readDataFixture('html');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });
  });

  group('Snappy max size', () {
    test('default max size allows normal data', () {
      final codec = SnappyCodec();
      final data = readDataFixture('canterbury/alice29.txt');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });

    test('custom max size', () {
      final codec = SnappyCodec(maxSize: 1024 * 1024);
      final data = readDataFixture('html');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });

    test('rejects data exceeding max size', () {
      final codec = SnappyCodec(maxSize: 100);
      final largeData = Uint8List.fromList(List.filled(1000, 65));
      final compressed = SnappyCodec().compress(largeData);
      expect(() => codec.decompress(compressed), throwsA(isA<Exception>()));
    });
  });

  group('Snappy edge cases', () {
    test('compresses and decompresses empty data', () {
      final codec = SnappyCodec();
      final empty = Uint8List(0);
      final compressed = codec.compress(empty);
      expect(compressed.length, 1); // Just the varint 0
      expect(compressed[0], 0);
      final decompressed = codec.decompress(compressed);
      expect(decompressed.length, 0);
    });

    test('compresses and decompresses single byte', () {
      final codec = SnappyCodec();
      final data = Uint8List.fromList([42]);
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, orderedEquals(data));
    });

    test('compresses and decompresses highly compressible data', () {
      final codec = SnappyCodec();
      final data = Uint8List.fromList(List.filled(10000, 65)); // All 'A's
      final compressed = codec.compress(data);
      expect(compressed.length, lessThan(data.length ~/ 2));
      final decompressed = codec.decompress(compressed);
      expect(decompressed, orderedEquals(data));
    });

    test('compresses and decompresses random-like data', () {
      final codec = SnappyCodec();
      final data = Uint8List.fromList(
        List.generate(1000, (i) => (i * 7 + 13) % 256),
      );
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, orderedEquals(data));
    });

    test('framing empty data', () {
      final codec = SnappyCodec(framing: true);
      final empty = Uint8List(0);
      final compressed = codec.compress(empty);
      final decompressed = codec.decompress(compressed);
      expect(decompressed.length, 0);
    });

    test('handles data at chunk boundary', () {
      final codec = SnappyCodec(framing: true, chunkSize: 1000);
      final data = Uint8List.fromList(List.generate(1000, (i) => i % 256));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, orderedEquals(data));
    });

    test('handles data spanning multiple chunks', () {
      final codec = SnappyCodec(framing: true, chunkSize: 500);
      final data = Uint8List.fromList(List.generate(2500, (i) => i % 256));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, orderedEquals(data));
    });
  });

  group('Snappy factory', () {
    test('creates codec from SnappyOptions', () {
      final options = SnappyOptions(
        framing: true,
        chunkSize: 4096,
        maxSize: 1024 * 1024,
      );
      final codec = SnappyCodec.fromOptions(options);
      expect(codec.framing, true);
      expect(codec.chunkSize, 4096);
      expect(codec.maxSize, 1024 * 1024);
    });

    test('default options', () {
      final options = SnappyOptions();
      final codec = SnappyCodec.fromOptions(options);
      expect(codec.framing, false);
      expect(codec.maxSize, SnappyDecoder.defaultMaxSize);
    });
  });
}
