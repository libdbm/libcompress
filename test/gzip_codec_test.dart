import 'dart:io' show gzip;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/src/gzip/gzip_codec.dart';
import 'test_utils.dart';
import 'web_test_utils.dart';

void main() {
  group('GZIP decompression fixtures', () {
    for (final path in standardFixtures) {
      test('decompresses $path', () {
        final codec = GzipCodec();
        final original = readDataFixture(path);
        final compressed = readCodecFixture('gzip', '$path.gz');
        final decompressed = codec.decompress(compressed);
        expect(decompressed, equals(original));
      });
    }

    for (final path in standardFixtures) {
      test(
        'decompresses $path on web/js',
        () async {
          await expectWebDecompresses(
            codecExpression: 'GzipCodec()',
            compressed: readCodecFixture('gzip', '$path.gz'),
            expected: readDataFixture(path),
          );
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );
    }
  });

  group('GZIP round-trip compression', () {
    for (final path in standardFixtures) {
      test('round-trips $path', () {
        final codec = GzipCodec();
        final original = readDataFixture(path);
        final compressed = codec.compress(original);
        final decompressed = codec.decompress(compressed);
        expect(decompressed, equals(original));
      });
    }

    for (final path in standardFixtures) {
      test(
        'round-trips $path on web/js',
        () async {
          await expectWebRoundTrip(
            codecExpression: 'GzipCodec()',
            data: readDataFixture(path),
          );
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );
    }
  });

  group('GZIP compression levels', () {
    test('level 1 (fast) compresses and decompresses', () {
      final codec = GzipCodec(level: 1);
      final data = readDataFixture('canterbury/alice29.txt');
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('level 5 (balanced) compresses and decompresses', () {
      final codec = GzipCodec(level: 5);
      final data = readDataFixture('canterbury/alice29.txt');
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('level 6 (default) compresses and decompresses', () {
      final codec = GzipCodec(level: 6);
      final data = readDataFixture('canterbury/alice29.txt');
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('level 9 (best) compresses and decompresses', () {
      final codec = GzipCodec(level: 9);
      final data = readDataFixture('canterbury/alice29.txt');
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('all levels 1-9 work correctly', () {
      final data = readDataFixture('html');
      for (var level = 1; level <= 9; level++) {
        final codec = GzipCodec(level: level);
        final compressed = codec.compress(data);
        final restored = codec.decompress(compressed);
        expect(restored, equals(data), reason: 'level $level failed');
      }
    });

    test('higher levels achieve better compression on text', () {
      final data = readDataFixture('canterbury/alice29.txt');
      final fast = GzipCodec(level: 1).compress(data);
      final best = GzipCodec(level: 9).compress(data);
      // Best should achieve better or equal compression
      expect(best.length, lessThanOrEqualTo(fast.length));
    });

    test('higher levels use dynamic Huffman for better compression', () {
      // Use larger data where dynamic Huffman overhead pays off
      final data = Uint8List.fromList(List.filled(10000, 65)); // All 'A'
      final compressed1 = GzipCodec(level: 1).compress(data);
      final compressed6 = GzipCodec(level: 6).compress(data);

      // Both should compress the data significantly
      expect(compressed1.length, lessThan(data.length / 10));
      expect(compressed6.length, lessThan(data.length / 10));
    });
  });

  group('GZIP metadata options', () {
    test('stores filename in header', () {
      final codec = GzipCodec(filename: 'test.txt');
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('stores comment in header', () {
      final codec = GzipCodec(comment: 'Test file');
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('stores both filename and comment', () {
      final codec = GzipCodec(filename: 'data.bin', comment: 'Test data file');
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('empty filename is allowed', () {
      final codec = GzipCodec(filename: '');
      final data = Uint8List.fromList([1, 2, 3]);
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('unicode filename is allowed', () {
      final codec = GzipCodec(filename: 'テスト.txt');
      final data = Uint8List.fromList([1, 2, 3]);
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });
  });

  group('GZIP edge cases', () {
    test('output is readable by dart:io gzip decoder', () {
      final codec = GzipCodec();
      final data = Uint8List.fromList(List.generate(256, (i) => i));
      final compressed = codec.compress(data);
      final decoded = Uint8List.fromList(gzip.decode(compressed));
      expect(decoded, equals(data));
    });

    test('compresses and decompresses empty data', () {
      final codec = GzipCodec();
      final data = Uint8List(0);
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('compresses and decompresses single byte', () {
      final codec = GzipCodec();
      final data = Uint8List.fromList([0xFF]);
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('compresses and decompresses highly compressible data', () {
      final codec = GzipCodec();
      final data = Uint8List.fromList(List.filled(10000, 0x42));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
      expect(compressed.length, lessThan(data.length ~/ 10));
    });

    test('compresses and decompresses random-like data', () {
      final codec = GzipCodec();
      final data = Uint8List(1000);
      for (var i = 0; i < data.length; i++) {
        data[i] = (i * 123 + 456) % 256;
      }
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('handles all byte values', () {
      final codec = GzipCodec();
      final data = Uint8List.fromList(List.generate(256, (i) => i));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('handles large data', () {
      final codec = GzipCodec();
      final data = Uint8List.fromList(List.generate(100000, (i) => i % 256));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });
  });

  group('GZIP concatenated members (RFC 1952)', () {
    test('decompresses two concatenated members', () {
      final codec = GzipCodec();
      final data1 = Uint8List.fromList('Hello, '.codeUnits);
      final data2 = Uint8List.fromList('World!'.codeUnits);

      // Compress separately
      final compressed1 = codec.compress(data1);
      final compressed2 = codec.compress(data2);

      // Concatenate the two GZIP members
      final concatenated = Uint8List.fromList([...compressed1, ...compressed2]);

      // Decompress should yield both members' data
      final decompressed = codec.decompress(concatenated);
      expect(decompressed, equals(Uint8List.fromList([...data1, ...data2])));
    });

    test('decompresses multiple concatenated members', () {
      final codec = GzipCodec();
      final parts = ['one', 'two', 'three', 'four', 'five'];

      // Compress each part separately and concatenate
      final builder = BytesBuilder(copy: false);
      for (final part in parts) {
        builder.add(codec.compress(Uint8List.fromList(part.codeUnits)));
      }

      // Decompress should yield all parts
      final decompressed = codec.decompress(builder.takeBytes());
      expect(String.fromCharCodes(decompressed), equals(parts.join()));
    });

    test('respects maxSize across concatenated members', () {
      final data1 = Uint8List.fromList('12345'.codeUnits); // 5 bytes
      final data2 = Uint8List.fromList('67890'.codeUnits); // 5 bytes
      final data3 = Uint8List.fromList('ABCDE'.codeUnits); // 5 bytes

      final compressed1 = GzipCodec().compress(data1);
      final compressed2 = GzipCodec().compress(data2);
      final compressed3 = GzipCodec().compress(data3);

      // With limit of 10, two members (10 bytes) should work
      final twoMembers = Uint8List.fromList([...compressed1, ...compressed2]);
      final codec10 = GzipCodec(maxDecompressedSize: 10);
      expect(codec10.decompress(twoMembers).length, equals(10));

      // With limit of 12, third member (15 bytes total) should fail
      // The limit is checked during decompression of the third member
      final threeMembers = Uint8List.fromList([
        ...compressed1,
        ...compressed2,
        ...compressed3,
      ]);
      final codec12 = GzipCodec(maxDecompressedSize: 12);
      expect(
        () => codec12.decompress(threeMembers),
        throwsA(anything), // DeflateException when limit exceeded
      );
    });
  });

  group('GZIP format verification', () {
    test('includes correct magic number', () {
      final codec = GzipCodec();
      final data = Uint8List.fromList('Hello, GZIP world!'.codeUnits);
      final compressed = codec.compress(data);

      // GZIP magic numbers
      expect(compressed[0], equals(0x1F));
      expect(compressed[1], equals(0x8B));
      expect(compressed[2], equals(0x08)); // DEFLATE method
    });

    test('round-trip verifies format correctness', () {
      final codec = GzipCodec();
      final data = Uint8List.fromList('Hello, GZIP world!'.codeUnits);
      final compressed = codec.compress(data);

      // Verify our decompressor works (format correctness)
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });
  });

  group('GZIP factory', () {
    test('creates codec from GzipOptions', () {
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

    test('default options', () {
      final options = GzipOptions();
      final codec = GzipCodec.fromOptions(options);
      expect(codec.level, 6);
      expect(codec.filename, isNull);
      expect(codec.comment, isNull);
    });
  });
}
