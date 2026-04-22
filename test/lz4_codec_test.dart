import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/src/lz4/lz4_codec.dart';
import 'package:libcompress/src/lz4/lz4_common.dart';
import 'test_utils.dart';
import 'web_test_utils.dart';

void main() {
  group('LZ4 decompression fixtures', () {
    for (final path in standardFixtures) {
      test('decompresses $path', () {
        final codec = Lz4Codec();
        final compressed = readCodecFixture('lz4', '$path.lz4');
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
            codecExpression: 'Lz4Codec()',
            compressed: readCodecFixture('lz4', '$path.lz4'),
            expected: readDataFixture(path),
          );
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );
    }
  });

  group('LZ4 round-trip compression', () {
    for (final path in standardFixtures) {
      test('round-trips $path', () {
        final codec = Lz4Codec();
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
            codecExpression: 'Lz4Codec()',
            data: readDataFixture(path),
          );
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );
    }
  });

  group('LZ4 compression levels', () {
    test('level 1 (fast) compresses and decompresses', () {
      final codec = Lz4Codec(level: 1);
      final data = readDataFixture('canterbury/alice29.txt');
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, orderedEquals(data));
    });

    test('level 9 (HC) compresses and decompresses', () {
      final codec = Lz4Codec(level: 9);
      final data = readDataFixture('canterbury/alice29.txt');
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, orderedEquals(data));
    });

    test('higher levels achieve better compression on text', () {
      final data = readDataFixture('canterbury/alice29.txt');
      final fast = Lz4Codec(level: 1).compress(data);
      final hc = Lz4Codec(level: 9).compress(data);
      // HC should achieve better or equal compression
      expect(hc.length, lessThanOrEqualTo(fast.length));
    });

    test('all levels 1-9 work correctly', () {
      final data = readDataFixture('html');
      for (var level = 1; level <= 9; level++) {
        final codec = Lz4Codec(level: level);
        final compressed = codec.compress(data);
        final restored = codec.decompress(compressed);
        expect(restored, orderedEquals(data), reason: 'level $level failed');
      }
    });
  });

  group('LZ4 block sizes', () {
    test('64K block size', () {
      final codec = Lz4Codec(blockSize: lz4BlockSize64K);
      final data = readDataFixture('canterbury/alice29.txt');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });

    test('256K block size', () {
      final codec = Lz4Codec(blockSize: lz4BlockSize256K);
      final data = readDataFixture('canterbury/alice29.txt');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });

    test('1M block size', () {
      final codec = Lz4Codec(blockSize: lz4BlockSize1M);
      final data = readDataFixture('canterbury/alice29.txt');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });

    test('4M block size (default)', () {
      final codec = Lz4Codec(blockSize: lz4BlockSize4M);
      final data = readDataFixture('canterbury/alice29.txt');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });
  });

  group('LZ4 checksum options', () {
    test('with content checksum enabled (default)', () {
      final codec = Lz4Codec(enableContentChecksum: true);
      final data = readDataFixture('html');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });

    test('with content checksum disabled', () {
      final codec = Lz4Codec(enableContentChecksum: false);
      final data = readDataFixture('html');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });
  });

  group('LZ4 edge cases', () {
    test('compresses and decompresses empty data', () {
      final codec = Lz4Codec();
      final empty = Uint8List(0);
      final compressed = codec.compress(empty);
      final decompressed = codec.decompress(compressed);
      expect(decompressed.length, 0);
    });

    test('compresses and decompresses single byte', () {
      final codec = Lz4Codec();
      final data = Uint8List.fromList([42]);
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, orderedEquals(data));
    });

    test('compresses and decompresses highly compressible data', () {
      final codec = Lz4Codec();
      final data = Uint8List.fromList(List.filled(10000, 65)); // All 'A's
      final compressed = codec.compress(data);
      expect(compressed.length, lessThan(data.length ~/ 2));
      final decompressed = codec.decompress(compressed);
      expect(decompressed, orderedEquals(data));
    });

    test('compresses and decompresses random-like data', () {
      final codec = Lz4Codec();
      final data = Uint8List.fromList(
        List.generate(1000, (i) => (i * 7 + 13) % 256),
      );
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, orderedEquals(data));
    });

    test('handles data exactly at block boundary', () {
      final codec = Lz4Codec(blockSize: lz4BlockSize64K);
      final data = Uint8List.fromList(List.generate(65536, (i) => i % 256));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, orderedEquals(data));
    });

    test('HC handles 64K block boundary', () {
      final codec = Lz4Codec(level: 9, blockSize: lz4BlockSize64K);
      final data = Uint8List.fromList(List.generate(65536, (i) => i % 256));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, orderedEquals(data));
    });

    test('handles data spanning multiple blocks', () {
      final codec = Lz4Codec(blockSize: lz4BlockSize64K);
      final data = Uint8List.fromList(List.generate(200000, (i) => i % 256));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, orderedEquals(data));
    });
  });

  group('LZ4 factory', () {
    test('creates codec from Lz4Options', () {
      final options = Lz4Options(
        level: 9,
        blockSize: lz4BlockSize256K,
        checksum: false,
      );
      final codec = Lz4Codec.fromOptions(options);
      expect(codec.level, 9);
      expect(codec.blockSize, lz4BlockSize256K);
      expect(codec.enableContentChecksum, false);
    });
  });
}
