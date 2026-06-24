import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';
import 'package:libcompress/src/snappy/snappy_decoder.dart';
import 'package:libcompress/src/snappy/snappy_stream_encoder.dart';
import 'package:libcompress/src/snappy/snappy_stream_decoder.dart';

import 'test_utils.dart';

/// Valid Snappy framing stream identifier (0xff, len=6, "sNaPpY").
final _streamId = bytes([
  0xff, 0x06, 0x00, 0x00, //
  0x73, 0x4e, 0x61, 0x50, 0x70, 0x59,
]);

void main() {
  group('Snappy block', () {
    group('decompresses stored fixtures', () {
      for (final path in standardFixtures) {
        test('decompresses $path', () {
          final codec = SnappyCodec();
          final compressed = readCodecFixture('snappy', '$path.snappy');
          final expected = readDataFixture(path);
          expect(codec.decompress(compressed), orderedEquals(expected));
        });
      }
    });

    group('round-trips standardFixtures (raw block)', () {
      for (final path in standardFixtures) {
        test('round-trips $path', () {
          expectRoundTrip(SnappyCodec(framing: false), readDataFixture(path));
        });
      }
    });

    group('round-trips standardFixtures (framing)', () {
      for (final path in standardFixtures) {
        test('round-trips $path', () {
          expectRoundTrip(SnappyCodec(framing: true), readDataFixture(path));
        });
      }
    });

    group('edge cases (raw block)', () {
      standardEdgeCases().forEach((label, data) {
        test(label, () {
          expectRoundTrip(SnappyCodec(framing: false), data);
        });
      });
    });

    group('edge cases (framing)', () {
      standardEdgeCases().forEach((label, data) {
        test(label, () {
          expectRoundTrip(SnappyCodec(framing: true), data);
        });
      });
    });

    group('knobs', () {
      test('raw block round-trips', () {
        expectRoundTrip(SnappyCodec(framing: false), readDataFixture('html'));
      });

      test('framing round-trips', () {
        expectRoundTrip(SnappyCodec(framing: true), readDataFixture('html'));
      });

      test('default max chunk size (framing)', () {
        expectRoundTrip(
          SnappyCodec(
            framing: true,
            chunkSize: SnappyStreamEncoder.maxChunkSize,
          ),
          readDataFixture('canterbury/alice29.txt'),
        );
      });

      test('small chunk size 1024 (framing)', () {
        expectRoundTrip(
          SnappyCodec(framing: true, chunkSize: 1024),
          readDataFixture('canterbury/alice29.txt'),
        );
      });

      test('chunk size 4096 (framing)', () {
        expectRoundTrip(
          SnappyCodec(framing: true, chunkSize: 4096),
          readDataFixture('html'),
        );
      });

      test('data exactly at chunk boundary', () {
        expectRoundTrip(
          SnappyCodec(framing: true, chunkSize: 1000),
          bytes(List.generate(1000, (i) => i % 256)),
        );
      });

      test('data spanning multiple chunks', () {
        expectRoundTrip(
          SnappyCodec(framing: true, chunkSize: 500),
          bytes(List.generate(2500, (i) => i % 256)),
        );
      });

      test('empty data (raw block) is just varint 0', () {
        final compressed = SnappyCodec().compress(Uint8List(0));
        expect(compressed.length, 1);
        expect(compressed[0], 0);
        expect(SnappyCodec().decompress(compressed).length, 0);
      });

      test('empty data (framing) round-trips', () {
        final codec = SnappyCodec(framing: true);
        expect(codec.decompress(codec.compress(Uint8List(0))).length, 0);
      });

      test('highly compressible shrinks below half', () {
        final codec = SnappyCodec();
        final data = bytes(List.filled(10000, 65));
        final compressed = codec.compress(data);
        expect(compressed.length, lessThan(data.length ~/ 2));
        expect(codec.decompress(compressed), orderedEquals(data));
      });
    });

    // Raw-block Snappy has no concatenation; the framing format does support
    // multiple concatenated framed streams / multiple stream identifiers.
    group('concatenation (framing only)', () {
      test('decodes two concatenated framed streams', () {
        final codec = SnappyCodec(framing: true);
        final a = bytes('Hello, '.codeUnits);
        final b = bytes('Snappy!'.codeUnits);
        final concatenated = bytes([
          ...codec.compress(a),
          ...codec.compress(b),
        ]);
        expect(
          codec.decompress(concatenated),
          orderedEquals(bytes([...a, ...b])),
        );
      });

      test('handles multiple stream identifiers (second ignored)', () {
        final data = bytes([..._streamId, ..._streamId]);
        expect(SnappyCodec(framing: true).decompress(data).length, 0);
      });
    });

    // Deterministic compression-ratio regression gate (machine-independent):
    // floors sit a few points below measured savings so an algorithmic
    // regression trips while routine byte-shifting tweaks do not.
    test('meets compression-ratio floors on the corpus', () {
      const floors = <String, double>{
        'canterbury/alice29.txt': 38,
        'calgary/paper1': 43,
        'large/bible.txt': 47,
      };
      floors.forEach((file, floor) {
        final path = 'test/fixtures/data/$file';
        if (!File(path).existsSync()) {
          markTestSkipped('fixture missing: $path');
          return;
        }
        final data = readDataFixture(file);
        final compressed = SnappyCodec(framing: true).compress(data);
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

  group('Snappy streaming', () {
    test('stream identifier header bytes', () {
      final compressed = SnappyStreamEncoder().compress(Uint8List(0));
      expect(compressed.length, greaterThanOrEqualTo(10));
      expect(compressed.sublist(0, 10), orderedEquals(_streamId));
    });

    test('multi-chunk stream round-trip', () async {
      await expectStreamRoundTrip(SnappyStreamCodec(chunkSize: 1024), [
        bytes('Hello, '.codeUnits),
        bytes('Snappy '.codeUnits),
        bytes(List.generate(5000, (i) => i & 0xff)),
      ]);
    });

    test('fragmented (1-byte) round-trip: small input', () async {
      await expectFragmentedRoundTrip(
        SnappyStreamCodec(chunkSize: 64),
        bytes('Test data for fragmented decode'.codeUnits),
      );
    });

    test('fragmented (1-byte) round-trip: corpus file', () async {
      await expectFragmentedRoundTrip(
        SnappyStreamCodec(chunkSize: 1024),
        readDataFixture('canterbury/alice29.txt'),
      );
    });

    test('round-trips data exactly at chunk boundary (65536)', () {
      final encoder = SnappyStreamEncoder();
      final decoder = SnappyStreamDecoder();
      final original = bytes(List.generate(65536, (i) => i & 0xff));
      expect(
        decoder.decompress(encoder.compress(original)),
        orderedEquals(original),
      );
    });

    test('round-trips data larger than one chunk', () {
      final encoder = SnappyStreamEncoder();
      final decoder = SnappyStreamDecoder();
      final original = bytes(List.generate(100 * 1024, (i) => i & 0xff));
      expect(
        decoder.decompress(encoder.compress(original)),
        orderedEquals(original),
      );
    });

    test('highly compressible stream compresses well', () {
      final encoder = SnappyStreamEncoder();
      final decoder = SnappyStreamDecoder();
      final original = bytes(
        List.generate(100 * 1024, (i) => (i % 256) & 0xff),
      );
      final compressed = encoder.compress(original);
      expect(decoder.decompress(compressed), orderedEquals(original));
      expect(compressed.length, lessThan(original.length));
    });

    group('structural rejection / handling', () {
      test('rejects invalid stream identifier', () {
        final invalid = bytes([
          0xff, 0x06, 0x00, 0x00, //
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]);
        expect(
          () => SnappyStreamDecoder().decompress(invalid),
          throwsFormatException,
        );
      });

      test('rejects data without stream identifier', () {
        final invalid = bytes([
          0x00, 0x04, 0x00, 0x00, //
          0x00, 0x00, 0x00, 0x00,
        ]);
        expect(
          () => SnappyStreamDecoder().decompress(invalid),
          throwsFormatException,
        );
      });

      test('rejects chunk with invalid checksum', () {
        final invalid = BytesBuilder();
        invalid.add(_streamId);
        invalid.addByte(0x01); // Uncompressed chunk
        invalid.addByte(0x05); // Length = 5
        invalid.addByte(0x00);
        invalid.addByte(0x00);
        invalid.add([0xFF, 0xFF, 0xFF, 0xFF]); // Wrong checksum
        invalid.addByte(0x42); // Data byte
        expect(
          () => SnappyStreamDecoder().decompress(bytes(invalid.toBytes())),
          throwsFormatException,
        );
      });

      test('rejects unskippable reserved chunk', () {
        final invalid = BytesBuilder();
        invalid.add(_streamId);
        invalid.addByte(0x02); // Reserved unskippable
        invalid.addByte(0x00);
        invalid.addByte(0x00);
        invalid.addByte(0x00);
        expect(
          () => SnappyStreamDecoder().decompress(bytes(invalid.toBytes())),
          throwsFormatException,
        );
      });

      test('skips reserved skippable chunks', () {
        final data = BytesBuilder();
        data.add(_streamId);
        data.addByte(0x80); // Skippable
        data.addByte(0x04); // Length = 4
        data.addByte(0x00);
        data.addByte(0x00);
        data.add([0xDE, 0xAD, 0xBE, 0xEF]);
        expect(
          SnappyStreamDecoder().decompress(bytes(data.toBytes())).length,
          0,
        );
      });

      test('handles padding chunks', () {
        final data = BytesBuilder();
        data.add(_streamId);
        data.addByte(0xfe); // Padding
        data.addByte(0x08); // Length = 8
        data.addByte(0x00);
        data.addByte(0x00);
        data.add(List.filled(8, 0));
        expect(
          SnappyStreamDecoder().decompress(bytes(data.toBytes())).length,
          0,
        );
      });

      test('rejects invalid chunk size at construction', () {
        expect(() => SnappyStreamEncoder(chunkSize: 0), throwsArgumentError);
        expect(
          () => SnappyStreamEncoder(chunkSize: 65537),
          throwsArgumentError,
        );
      });
    });
  });

  group('Snappy limits & validation', () {
    final data = bytes(List.generate(200000, (i) => (i * 31 + 7) % 256));

    test('default maxSize is 256MB; null means unlimited', () {
      expect(SnappyCodec().maxSize, 256 * 1024 * 1024);
      expect(SnappyStreamCodec().maxSize, 256 * 1024 * 1024);
      expect(SnappyCodec(maxSize: null).maxSize, isNull);
    });

    test('block: small limit rejects, null allows', () {
      final compressed = SnappyCodec().compress(data);
      expect(
        () => SnappyCodec(maxSize: 1000).decompress(compressed),
        throwsA(isA<CompressionFormatException>()),
      );
      expect(
        SnappyCodec(maxSize: null).decompress(compressed),
        orderedEquals(data),
      );
    });

    test('framed: small limit rejects, null allows', () {
      final compressed = SnappyCodec(framing: true).compress(data);
      expect(
        () => SnappyCodec(framing: true, maxSize: 1000).decompress(compressed),
        throwsA(isA<CompressionFormatException>()),
      );
      expect(
        SnappyCodec(framing: true, maxSize: null).decompress(compressed),
        orderedEquals(data),
      );
    });

    test('rejects ~1GB declared uncompressed size', () {
      // Varint for 1GB (0x40000000) followed by a tag byte.
      final malicious = bytes([
        0x80, 0x80, 0x80, 0x80, 0x04, //
        0x00,
      ]);
      expect(
        () => SnappyDecoder.decompress(malicious),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('exceeds maximum'),
          ),
        ),
      );
      expect(
        () => SnappyCodec().decompress(malicious),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('fromOptions preserves maxSize / framing / chunkSize', () {
      final codec = SnappyCodec.fromOptions(
        SnappyOptions(framing: true, chunkSize: 4096, maxSize: 1024 * 1024),
      );
      expect(codec.framing, true);
      expect(codec.chunkSize, 4096);
      expect(codec.maxSize, 1024 * 1024);
    });

    test('default options preserve defaults', () {
      final codec = SnappyCodec.fromOptions(SnappyOptions());
      expect(codec.framing, false);
      expect(codec.maxSize, 256 * 1024 * 1024);
    });

    test('constructor fails fast for invalid maxSize / chunkSize', () {
      expect(() => SnappyCodec(maxSize: 0), throwsArgumentError);
      expect(() => SnappyCodec(maxSize: -1), throwsArgumentError);
      expect(() => SnappyStreamCodec(maxSize: -1), throwsArgumentError);
      expect(() => SnappyCodec(chunkSize: 0), throwsArgumentError);
      expect(() => SnappyCodec(chunkSize: 65537), throwsArgumentError);
    });

    test('stream codec fails fast for invalid maxSize / maxBufferSize', () {
      expect(() => SnappyStreamCodec(maxSize: 0), throwsArgumentError);
      expect(() => SnappyStreamCodec(maxBufferSize: 0), throwsArgumentError);
      expect(SnappyStreamCodec(), isNotNull);
    });

    test('maxBufferSize preflight rejects oversized whole blob', () {
      final big = bytes(List.generate(5000, (i) => (i * 131 + 7) % 256));
      final framed = SnappyCodec(framing: true).compress(big);
      expect(framed.length, greaterThan(64));
      expect(
        _decodeStream(
          SnappyStreamCodec(maxBufferSize: 64),
          framed,
          chunk: framed.length,
        ),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('cumulative cap via stream codec rejects ~400KB', () {
      // ~400 KB -> multiple <=64 KB framing chunks, each under the 100 KB cap
      // but cumulatively over it.
      final big = bytes(List.generate(400 * 1024, (i) => (i * 31 + 7) % 256));
      final framed = SnappyCodec(framing: true).compress(big);
      expect(
        _decodeStream(SnappyStreamCodec(maxSize: 100 * 1024), framed),
        throwsA(isA<CompressionFormatException>()),
      );
      expect(
        () =>
            SnappyCodec(framing: true, maxSize: 100 * 1024).decompress(framed),
        throwsA(isA<CompressionFormatException>()),
      );
    });
  });

  group('Snappy CLI compatibility', () {
    test('framing output readable by snzip', () async {
      if (!await cliAvailableCached('snzip')) {
        markTestSkipped('snzip CLI tool not available');
        return;
      }
      final original = readDataFixture('html');
      final compressed = SnappyCodec(framing: true).compress(original);
      final path = '/tmp/libcompress_snappy_test.sz';
      try {
        await File(path).writeAsBytes(compressed);
        final result = await Process.run('snzip', [
          '-d',
          '-c',
          path,
        ], stdoutEncoding: null);
        expect(
          result.exitCode,
          0,
          reason: 'snzip decompression failed: ${result.stderr}',
        );
        expect(result.stdout as List<int>, equals(original));
      } finally {
        await _cleanup([path]);
      }
    });

    test('small chunk size readable by snzip', () async {
      if (!await cliAvailableCached('snzip')) {
        markTestSkipped('snzip CLI tool not available');
        return;
      }
      final original = readDataFixture('canterbury/alice29.txt');
      final compressed = SnappyCodec(
        framing: true,
        chunkSize: 4096,
      ).compress(original);
      final path = '/tmp/libcompress_snappy_small.sz';
      try {
        await File(path).writeAsBytes(compressed);
        final result = await Process.run('snzip', [
          '-d',
          '-c',
          path,
        ], stdoutEncoding: null);
        expect(
          result.exitCode,
          0,
          reason: 'snzip decompression failed: ${result.stderr}',
        );
        expect(result.stdout as List<int>, equals(original));
      } finally {
        await _cleanup([path]);
      }
    });

    test('bidirectional round-trip through snzip', () async {
      if (!await cliAvailableCached('snzip')) {
        markTestSkipped('snzip CLI tool not available');
        return;
      }
      final codec = SnappyCodec(framing: true);
      final original = readDataFixture('calgary/paper1');
      final libCompressed = codec.compress(original);
      final path = '/tmp/libcompress_snappy_bidir.sz';
      final out = '/tmp/libcompress_snappy_bidir.out';
      try {
        await File(path).writeAsBytes(libCompressed);
        final result = await Process.run('snzip', [
          '-d',
          '-c',
          path,
        ], stdoutEncoding: null);
        expect(
          result.exitCode,
          0,
          reason: 'snzip decompression failed: ${result.stderr}',
        );
        final cliOut = result.stdout as List<int>;
        expect(cliOut, equals(original));

        await File(out).writeAsBytes(cliOut);
        final result2 = await Process.run('snzip', [
          '-c',
          out,
        ], stdoutEncoding: null);
        expect(
          result2.exitCode,
          0,
          reason: 'snzip compression failed: ${result2.stderr}',
        );
        final cliCompressed = result2.stdout as List<int>;
        expect(codec.decompress(bytes(cliCompressed)), equals(original));
      } finally {
        await _cleanup([path, out]);
      }
    });

    group('all fixtures round-trip through snzip', () {
      for (final path in standardFixtures) {
        test('full round-trip for $path', () async {
          if (!await cliAvailableCached('snzip')) {
            markTestSkipped('snzip CLI tool not available');
            return;
          }
          final original = readDataFixture(path);
          final libCompressed = SnappyCodec(framing: true).compress(original);
          final tmpPath =
              '/tmp/libcompress_snappy_rt_${path.replaceAll('/', '_')}.sz';
          try {
            await File(tmpPath).writeAsBytes(libCompressed);
            final result = await Process.run('snzip', [
              '-d',
              '-c',
              tmpPath,
            ], stdoutEncoding: null);
            expect(
              result.exitCode,
              0,
              reason: 'CLI decompression failed for $path',
            );
            expect(
              result.stdout as List<int>,
              equals(original),
              reason: 'Round-trip mismatch for $path',
            );
          } finally {
            await _cleanup([tmpPath]);
          }
        });
      }
    });
  });

  group('Snappy fuzzing / malformed input', () {
    final random = Random(42);
    final codec = SnappyCodec();

    test('rejects pure random noise', () {
      for (var i = 0; i < 100; i++) {
        final noise = bytes(
          List.generate(random.nextInt(1000) + 1, (_) => random.nextInt(256)),
        );
        expect(
          () => codec.decompress(noise),
          throwsA(isA<SnappyFormatException>()),
          reason: 'Random noise iteration $i should be rejected',
        );
      }
    });

    test('rejects short random data', () {
      for (var length = 1; length < 20; length++) {
        final noise = bytes(List.generate(length, (_) => random.nextInt(256)));
        expect(
          () => codec.decompress(noise),
          throwsA(isA<SnappyFormatException>()),
          reason: 'Short random data ($length bytes) should be rejected',
        );
      }
    });

    test('rejects empty input', () {
      expect(
        () => codec.decompress(Uint8List(0)),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects truncated data at various positions', () {
      final valid = codec.compress(bytes(List.generate(1000, (i) => i % 256)));
      for (var cutoff = 1; cutoff < valid.length; cutoff++) {
        final truncated = Uint8List.sublistView(valid, 0, cutoff);
        expect(
          () => codec.decompress(truncated),
          throwsA(isA<SnappyFormatException>()),
          reason: 'Truncated at $cutoff should be rejected',
        );
      }
    });

    test('rejects varint claiming more than maxSize', () {
      final malicious = bytes([0x80, 0x80, 0x80, 0x80, 0x04, 0x00]);
      expect(
        () => SnappyDecoder.decompress(malicious),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects incomplete varint', () {
      expect(
        () => SnappyDecoder.decompress(bytes([0x80])),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects very long varint', () {
      final tooLong = bytes([
        0x80, 0x80, 0x80, 0x80, 0x80, //
        0x80, 0x80, 0x80, 0x80, 0x80,
        0x80, 0x01,
      ]);
      expect(
        () => SnappyDecoder.decompress(tooLong),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects literal extending past input end', () {
      final data = bytes([0x05, 0x24, 0x01, 0x02, 0x03]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 2-byte literal length with truncated length', () {
      expect(
        () => SnappyDecoder.decompress(bytes([0x10, 0xF0])),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 3-byte literal length with truncated length', () {
      expect(
        () => SnappyDecoder.decompress(bytes([0x80, 0x01, 0xF4, 0x10])),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 4-byte literal length with truncated length', () {
      expect(
        () => SnappyDecoder.decompress(bytes([0x80, 0x08, 0xF8, 0x10, 0x00])),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 5-byte literal length with truncated length', () {
      expect(
        () => SnappyDecoder.decompress(
          bytes([0x80, 0x40, 0xFC, 0x10, 0x00, 0x00]),
        ),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 1-byte copy with offset pointing before buffer', () {
      final data = bytes([0x05, 0x00, 0x41, 0x01]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 2-byte copy with offset too large', () {
      final data = bytes([0x05, 0x00, 0x41, 0x02, 0xFF]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 2-byte copy with truncated offset', () {
      final data = bytes([0x05, 0x00, 0x41, 0x02]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 4-byte copy with offset too large', () {
      final data = bytes([0x0A, 0x00, 0x41, 0x03, 0xFF, 0xFF, 0xFF, 0x7F]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 4-byte copy with truncated offset', () {
      final data = bytes([0x10, 0x00, 0x41, 0x03, 0x01, 0x00]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects copy with zero offset', () {
      final data = bytes([0x08, 0x00, 0x41, 0x05]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects output shorter than declared', () {
      final data = bytes([0x10, 0x04, 0x41, 0x42]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects output exceeding declared size', () {
      final data = bytes([0x02, 0x08, 0x41, 0x42, 0x43]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    group('framing malformations', () {
      final framingCodec = SnappyCodec(framing: true);

      test('rejects random noise in framing format', () {
        for (var i = 0; i < 50; i++) {
          final noise = bytes(
            List.generate(random.nextInt(500) + 1, (_) => random.nextInt(256)),
          );
          expect(
            () => framingCodec.decompress(noise),
            throwsA(isA<SnappyFormatException>()),
            reason: 'Random noise should be rejected in framing format',
          );
        }
      });

      test('rejects missing stream identifier', () {
        final data = bytes([
          0x00, 0x05, 0x00, 0x00, //
          0x00, 0x00, 0x00, 0x00,
          0x00,
        ]);
        expect(
          () => framingCodec.decompress(data),
          throwsA(isA<SnappyFormatException>()),
        );
      });

      test('rejects invalid stream identifier content', () {
        final data = bytes([
          0xFF, 0x06, 0x00, 0x00, //
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]);
        expect(
          () => framingCodec.decompress(data),
          throwsA(isA<SnappyFormatException>()),
        );
      });

      test('rejects truncated chunk header', () {
        final truncated = bytes([..._streamId, 0x00, 0x05]);
        expect(
          () => framingCodec.decompress(truncated),
          throwsA(isA<SnappyFormatException>()),
        );
      });

      test('rejects invalid CRC in compressed chunk', () {
        final compressed = framingCodec.compress(bytes([1, 2, 3, 4, 5]));
        expect(compressed.length, greaterThan(14));
        final corrupted = bytes(compressed);
        corrupted[14] ^= 0xFF; // Corrupt CRC
        expect(
          () => framingCodec.decompress(corrupted),
          throwsA(isA<SnappyFormatException>()),
        );
      });
    });

    test('respects maxUncompressedSize in decoder (decompression bomb)', () {
      final bomb = bytes([0x80, 0x80, 0x80, 0x80, 0x04, 0x00]);
      expect(
        () => SnappyDecoder.decompress(bomb, maxUncompressedSize: 1024),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('respects maxSize in codec (decompression bomb)', () {
      final compressed = codec.compress(bytes(List.filled(10000, 0x41)));
      expect(
        () => SnappyCodec(maxSize: 1000).decompress(compressed),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('single-byte corruptions never cause RangeError', () {
      final original = bytes(List.generate(5000, (i) => i % 256));
      final valid = codec.compress(original);
      for (var i = 0; i < min(100, valid.length); i++) {
        final corrupted = bytes(valid);
        corrupted[i] ^= 0xFF;
        try {
          codec.decompress(corrupted);
        } on SnappyFormatException {
          // Expected.
        } on RangeError {
          fail(
            'Corrupted byte at $i caused RangeError, not '
            'SnappyFormatException',
          );
        }
      }
    });
  });

  group('Snappy format', () {
    test('framing output starts with stream identifier byte', () {
      final compressed = SnappyCodec(
        framing: true,
      ).compress(readDataFixture('html'));
      expect(compressed[0], 0xFF);
    });

    test('raw output starts with varint length preamble', () {
      final compressed = SnappyCodec(
        framing: false,
      ).compress(bytes([1, 2, 3, 4, 5]));
      expect(compressed[0], 5);
    });

    test('decodes a hand-built literal block', () {
      // Uncompressed length 5, literal tag (len-1)<<2 = 0x10, then "hello".
      final data = bytes([0x05, 0x10, ...'hello'.codeUnits]);
      final result = SnappyDecoder.decompress(data);
      expect(result, orderedEquals(bytes('hello'.codeUnits)));
    });

    test('zero-length block decodes to empty output', () {
      expect(SnappyDecoder.decompress(bytes([0x00])).length, 0);
    });

    test('rejects framed stream without leading identifier', () {
      // A lone padding chunk (type 0xfe), no stream identifier.
      final noId = bytes([0xfe, 0x01, 0x00, 0x00, 0x00]);
      expect(
        () => SnappyCodec(framing: true).decompress(noId),
        throwsA(isA<CompressionFormatException>()),
      );
      expect(
        _decodeStream(SnappyStreamCodec(), noId),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects empty framed input via stream codec', () {
      expect(
        _decodeStream(SnappyStreamCodec(), Uint8List(0)),
        throwsA(isA<CompressionFormatException>()),
      );
    });
  });
}

/// Decodes [data] through a stream codec, feeding it in [chunk]-sized pieces.
Future<Uint8List> _decodeStream(
  final SnappyStreamCodec codec,
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

/// Remove temporary CLI test files, ignoring errors.
Future<void> _cleanup(final List<String> paths) async {
  for (final path in paths) {
    try {
      await File(path).delete();
    } catch (_) {}
  }
}
