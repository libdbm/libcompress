import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';
import 'package:libcompress/src/util/lz77_common.dart';
import 'package:libcompress/src/util/varint.dart';
import 'package:libcompress/src/snappy/snappy_decoder.dart';
import 'package:libcompress/src/snappy/snappy_stream_encoder.dart';
import 'package:libcompress/src/snappy/snappy_stream_decoder.dart';

import 'support/differential_fuzz.dart';
import 'test_utils.dart';

/// Valid Snappy framing stream identifier (0xff, len=6, "sNaPpY").
final _streamId = bytes([
  0xff, 0x06, 0x00, 0x00, //
  0x73, 0x4e, 0x61, 0x50, 0x70, 0x59,
]);

void main() {
  group('Snappy block', () {
    test('a small result does not hold the worst-case buffer', () {
      // Zeros compress to a few bytes; the result may share a buffer only
      // when that buffer is at most twice its length.
      final compressed = SnappyCodec().compress(Uint8List(1 << 20));
      expect(
        compressed.buffer.lengthInBytes,
        lessThanOrEqualTo(2 * compressed.length),
      );
    });

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
          expectRoundTrip(
            SnappyCodec(format: SnappyFormat.raw),
            readDataFixture(path),
          );
        });
      }
    });

    group('round-trips standardFixtures (framing)', () {
      for (final path in standardFixtures) {
        test('round-trips $path', () {
          expectRoundTrip(
            SnappyCodec(format: SnappyFormat.framed),
            readDataFixture(path),
          );
        });
      }
    });

    group('edge cases (raw block)', () {
      standardEdgeCases().forEach((final label, final data) {
        test(label, () {
          expectRoundTrip(SnappyCodec(format: SnappyFormat.raw), data);
        });
      });
    });

    group('edge cases (framing)', () {
      standardEdgeCases().forEach((final label, final data) {
        test(label, () {
          expectRoundTrip(SnappyCodec(format: SnappyFormat.framed), data);
        });
      });
    });

    group('copies', () {
      test('a 66-byte copy is split 60 + 6, not 64 + 2', () {
        // 20 bytes of noise repeated to 86 bytes: a length byte, a 20-byte
        // literal (1 + 20), then a 3-byte copy of 60 and a 2-byte copy of 6
        // (the reference split, leaving at least 4; 64 + 2 takes 6 bytes).
        final noise = pseudoRandom(20, 9);
        final data = bytes([for (var i = 0; i < 86; i++) noise[i % 20]]);
        final compressed = SnappyCodec().compress(data);
        expect(compressed.length, 1 + 21 + 5);
        expect(SnappyCodec().decompress(compressed), equals(data));
      });

      test('long copies round-trip at every split', () {
        for (var length = 60; length < 200; length++) {
          final half = pseudoRandom(length, length);
          final data = bytes([...half, ...half, ...pseudoRandom(20, 1)]);
          expectRoundTrip(SnappyCodec(), data);
        }
      });
    });

    group('knobs', () {
      test('raw block round-trips', () {
        expectRoundTrip(
          SnappyCodec(format: SnappyFormat.raw),
          readDataFixture('html'),
        );
      });

      test('framing round-trips', () {
        expectRoundTrip(
          SnappyCodec(format: SnappyFormat.framed),
          readDataFixture('html'),
        );
      });

      test('default max chunk size (framing)', () {
        expectRoundTrip(
          SnappyCodec(
            format: SnappyFormat.framed,
            chunkSize: SnappyStreamEncoder.maxChunkSize,
          ),
          readDataFixture('canterbury/alice29.txt'),
        );
      });

      test('small chunk size 1024 (framing)', () {
        expectRoundTrip(
          SnappyCodec(format: SnappyFormat.framed, chunkSize: 1024),
          readDataFixture('canterbury/alice29.txt'),
        );
      });

      test('chunk size 4096 (framing)', () {
        expectRoundTrip(
          SnappyCodec(format: SnappyFormat.framed, chunkSize: 4096),
          readDataFixture('html'),
        );
      });

      test('data exactly at chunk boundary', () {
        expectRoundTrip(
          SnappyCodec(format: SnappyFormat.framed, chunkSize: 1000),
          bytes(List.generate(1000, (final i) => i % 256)),
        );
      });

      test('data spanning multiple chunks', () {
        expectRoundTrip(
          SnappyCodec(format: SnappyFormat.framed, chunkSize: 500),
          bytes(List.generate(2500, (final i) => i % 256)),
        );
      });

      test('empty data (raw block) is just varint 0', () {
        final compressed = SnappyCodec().compress(Uint8List(0));
        expect(compressed.length, 1);
        expect(compressed[0], 0);
        expect(SnappyCodec().decompress(compressed).length, 0);
      });

      test('empty data (framing) round-trips', () {
        final codec = SnappyCodec(format: SnappyFormat.framed);
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
        final codec = SnappyCodec(format: SnappyFormat.framed);
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
        expect(
          SnappyCodec(format: SnappyFormat.framed).decompress(data).length,
          0,
        );
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
      floors.forEach((final file, final floor) {
        final path = 'test/fixtures/data/$file';
        if (!File(path).existsSync()) {
          markTestSkipped('fixture missing: $path');
          return;
        }
        final data = readDataFixture(file);
        final compressed = SnappyCodec(
          format: SnappyFormat.framed,
        ).compress(data);
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
        bytes(List.generate(5000, (final i) => i & 0xff)),
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
      final original = bytes(List.generate(65536, (final i) => i & 0xff));
      expect(
        decoder.decompress(encoder.compress(original)),
        orderedEquals(original),
      );
    });

    test('round-trips data larger than one chunk', () {
      final encoder = SnappyStreamEncoder();
      final decoder = SnappyStreamDecoder();
      final original = bytes(List.generate(100 * 1024, (final i) => i & 0xff));
      expect(
        decoder.decompress(encoder.compress(original)),
        orderedEquals(original),
      );
    });

    test('highly compressible stream compresses well', () {
      final encoder = SnappyStreamEncoder();
      final decoder = SnappyStreamDecoder();
      final original = bytes(
        List.generate(100 * 1024, (final i) => (i % 256) & 0xff),
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
    test('rejects empty input in block and stream mode', () async {
      await expectEmptyRejected<SnappyFormatException>(
        SnappyCodec(),
        SnappyStreamCodec(),
      );
      await expectEmptyRejected<SnappyFormatException>(
        SnappyCodec(format: SnappyFormat.framed),
        SnappyStreamCodec(),
      );
    });

    final data = bytes(List.generate(200000, (final i) => (i * 31 + 7) % 256));

    test('default maxSize is 256MB; null means unlimited', () {
      expect(SnappyCodec().maxSize, 256 * 1024 * 1024);
      expect(SnappyStreamCodec().maxSize, 256 * 1024 * 1024);
      expect(SnappyCodec(maxSize: null).maxSize, isNull);
    });

    test('decoders share the 256MB default', () {
      expect(SnappyStreamDecoder().maxUncompressedSize, 256 * 1024 * 1024);
      expect(SnappyDecoder.defaultMaxSize, 256 * 1024 * 1024);
    });

    test('rejects a declared length beyond the maximum expansion', () {
      // A varint preamble declaring 200 MB followed by a single byte: no
      // Snappy body of 1 byte can expand that far, so decoding must refuse
      // before allocating the declared output.
      final bomb = bytes([0x80, 0x80, 0x80, 0x60, 0x00]);
      expect(
        () => SnappyCodec().decompress(bomb),
        throwsA(
          isA<SnappyFormatException>().having(
            (final e) => e.message,
            'message',
            contains('maximum expansion'),
          ),
        ),
      );
    });

    test('decodes a stream at the maximum expansion ratio', () {
      // One literal byte, then 3-byte copies of 64 bytes at offset 1: the
      // highest output-per-input ratio the format allows.
      const copies = 2000;
      final declared = 1 + 64 * copies;
      final preamble = <int>[];
      for (var value = declared; ; value >>= 7) {
        if (value < 0x80) {
          preamble.add(value);
          break;
        }
        preamble.add((value & 0x7F) | 0x80);
      }
      final stream = bytes([
        ...preamble,
        0x00, 0x41, // literal 'A'
        for (var i = 0; i < copies; i++) ...[0xFE, 0x01, 0x00], // copy 64 @ 1
      ]);
      expect(
        SnappyCodec().decompress(stream),
        equals(List<int>.filled(declared, 0x41)),
      );
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
      final compressed = SnappyCodec(
        format: SnappyFormat.framed,
      ).compress(data);
      expect(
        () => SnappyCodec(
          format: SnappyFormat.framed,
          maxSize: 1000,
        ).decompress(compressed),
        throwsA(isA<CompressionFormatException>()),
      );
      expect(
        SnappyCodec(
          format: SnappyFormat.framed,
          maxSize: null,
        ).decompress(compressed),
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
            (final e) => e.message,
            'message',
            contains('exceeds the limit'),
          ),
        ),
      );
      expect(
        () => SnappyCodec().decompress(malicious),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('fromOptions preserves maxSize / format / chunkSize', () {
      final codec = SnappyCodec.fromOptions(
        SnappyOptions(
          format: SnappyFormat.framed,
          chunkSize: 4096,
          maxSize: 1024 * 1024,
        ),
      );
      expect(codec.format, SnappyFormat.framed);
      expect(codec.chunkSize, 4096);
      expect(codec.maxSize, 1024 * 1024);
    });

    test('default options preserve defaults', () {
      final codec = SnappyCodec.fromOptions(SnappyOptions());
      expect(codec.format, SnappyFormat.raw);
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
      final big = bytes(List.generate(5000, (final i) => (i * 131 + 7) % 256));
      final framed = SnappyCodec(format: SnappyFormat.framed).compress(big);
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
      final big = bytes(
        List.generate(400 * 1024, (final i) => (i * 31 + 7) % 256),
      );
      final framed = SnappyCodec(format: SnappyFormat.framed).compress(big);
      expect(
        _decodeStream(SnappyStreamCodec(maxSize: 100 * 1024), framed),
        throwsA(isA<CompressionFormatException>()),
      );
      expect(
        () => SnappyCodec(
          format: SnappyFormat.framed,
          maxSize: 100 * 1024,
        ).decompress(framed),
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
      final compressed = SnappyCodec(
        format: SnappyFormat.framed,
      ).compress(original);
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

    test('ratio is within 5% of snzip', () async {
      if (!await cliAvailableCached('snzip')) {
        markTestSkipped('snzip CLI tool not available');
        return;
      }
      for (final name in ['geo.protodata', 'large/world192.txt', 'html']) {
        final result = await Process.run('snzip', [
          '-c',
          'test/fixtures/data/$name',
        ], stdoutEncoding: null);
        final theirs = (result.stdout as List<int>).length;
        final ours = SnappyCodec(
          format: SnappyFormat.framed,
        ).compress(readDataFixture(name)).length;
        expect(
          ours,
          lessThanOrEqualTo(theirs * 1.05),
          reason: '$name: $ours vs snzip $theirs',
        );
      }
    });

    test('small chunk size readable by snzip', () async {
      if (!await cliAvailableCached('snzip')) {
        markTestSkipped('snzip CLI tool not available');
        return;
      }
      final original = readDataFixture('canterbury/alice29.txt');
      final compressed = SnappyCodec(
        format: SnappyFormat.framed,
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
      final codec = SnappyCodec(format: SnappyFormat.framed);
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
          final libCompressed = SnappyCodec(
            format: SnappyFormat.framed,
          ).compress(original);
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

  defineDifferentialFuzz(
    title: 'Snappy framed',
    reference: const Reference('snzip', ['-d', '-c', '-t', 'framing2']),
    frames: {
      'snzip CLI': () => const Reference('snzip', []).encode([
        '-c',
        '-t',
        'framing2',
      ], readDataFixture('canterbury/alice29.txt')),
      'libcompress encoder': () async => SnappyCodec(
        format: SnappyFormat.framed,
      ).compress(readDataFixture('canterbury/alice29.txt')),
    },
    block: SnappyCodec(format: SnappyFormat.framed).decompress,
    stream: SnappyStreamCodec().decompress,
  );

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
          throwsA(isA<CompressionFormatException>()),
          reason: 'Random noise iteration $i should be rejected',
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

    test('rejects empty input', () {
      expect(
        () => codec.decompress(Uint8List(0)),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects truncated data at various positions', () {
      final valid = codec.compress(
        bytes(List.generate(1000, (final i) => i % 256)),
      );
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
        throwsA(isA<LimitException>()),
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
      test('no chunk may come before the stream identifier', () {
        final framed = SnappyCodec(
          format: SnappyFormat.framed,
        ).compress(bytes('hello'.codeUnits));
        for (final type in [0xfe, 0x80, 0xfd]) {
          final data = bytes([type, 2, 0, 0, 0, 0, ...framed]);
          expect(
            () => SnappyCodec(format: SnappyFormat.framed).decompress(data),
            throwsA(isA<SnappyFormatException>()),
            reason: 'type 0x${type.toRadixString(16)}',
          );
        }
      });

      test('an uncompressed chunk over 64 KB is a format error', () {
        final payload = Uint8List(70000);
        final crc = Crc32c.mask(Crc32c.hash(payload));
        final size = payload.length + 4;
        final data = bytes([
          0xff, 6, 0, 0, ...'sNaPpY'.codeUnits, //
          0x01, size & 255, (size >> 8) & 255, size >> 16,
          crc & 255, (crc >> 8) & 255, (crc >> 16) & 255, crc >> 24,
          ...payload,
        ]);
        expect(
          () => SnappyCodec(format: SnappyFormat.framed).decompress(data),
          throwsA(isA<SnappyFormatException>()),
        );
      });

      test('a chunk over 64 KB is a format error, not a size limit', () {
        final block = SnappyCodec().compress(Uint8List(70000));
        final data = bytes([
          0xff, 6, 0, 0, ...'sNaPpY'.codeUnits, //
          0, (block.length + 4) & 255, (block.length + 4) >> 8, 0,
          0, 0, 0, 0, ...block,
        ]);
        expect(
          () => SnappyCodec(format: SnappyFormat.framed).decompress(data),
          throwsA(isA<SnappyFormatException>()),
        );
      });

      final framingCodec = SnappyCodec(format: SnappyFormat.framed);

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
        throwsA(isA<LimitException>()),
      );
    });

    test('respects maxSize in codec (decompression bomb)', () {
      final compressed = codec.compress(bytes(List.filled(10000, 0x41)));
      expect(
        () => SnappyCodec(maxSize: 1000).decompress(compressed),
        throwsA(isA<LimitException>()),
      );
    });

    test('single-byte corruptions never cause RangeError', () {
      final original = bytes(List.generate(5000, (final i) => i % 256));
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

  group('CRC32C', () {
    test('matches the RFC 3720 known answers', () {
      // RFC 3720 Appendix B.4, and the common "123456789" check value.
      expect(Crc32c.hash(Uint8List(32)), 0x8A9136AA);
      expect(Crc32c.hash(Uint8List(32)..fillRange(0, 32, 0xFF)), 0x62A8AB43);
      expect(Crc32c.hash(bytes(List.generate(32, (final i) => i))), 0x46DD794E);
      expect(
        Crc32c.hash(bytes(List.generate(32, (final i) => 31 - i))),
        0x113FDB5C,
      );
      expect(Crc32c.hash(bytes('123456789'.codeUnits)), 0xE3069283);
    });

    test('agrees with the byte-wise form at every length and split', () {
      final data = pseudoRandom(64, 99);
      for (var length = 0; length <= 40; length++) {
        final slice = Uint8List.sublistView(data, 0, length);
        final expected = Crc32c.hashFromList(slice);
        expect(Crc32c.hash(slice), expected, reason: 'length $length');
        for (var split = 0; split <= length; split++) {
          final first = Crc32c.update(
            Uint8List.sublistView(slice, 0, split),
            0xFFFFFFFF,
          );
          final whole = Crc32c.update(
            Uint8List.sublistView(slice, split),
            first,
          );
          expect(whole ^ 0xFFFFFFFF, expected, reason: '$length at $split');
        }
      }
    });
  });

  group('Snappy format', () {
    group('formats', () {
      final text = bytes('hello hello hello'.codeUnits);

      test('raw is the default format: a varint length, then the block', () {
        expect(SnappyCodec().format, SnappyFormat.raw);
        expect(SnappyCodec().compress(text).first, text.length);
      });

      test('framed output starts with the stream identifier', () {
        final framed = SnappyCodec(format: SnappyFormat.framed).compress(text);
        expect(
          framed.sublist(0, 10),
          orderedEquals([0xFF, 0x06, 0x00, 0x00, ...'sNaPpY'.codeUnits]),
        );
      });

      test('options carry the format', () {
        final codec = SnappyCodec.fromOptions(
          SnappyOptions(format: SnappyFormat.framed),
        );
        expect(codec.format, SnappyFormat.framed);
      });
    });

    test('framing output starts with stream identifier byte', () {
      final compressed = SnappyCodec(
        format: SnappyFormat.framed,
      ).compress(readDataFixture('html'));
      expect(compressed[0], 0xFF);
    });

    test('raw output starts with varint length preamble', () {
      final compressed = SnappyCodec(
        format: SnappyFormat.raw,
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
        () => SnappyCodec(format: SnappyFormat.framed).decompress(noId),
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

  group('Snappy regressions', () {
    test('hash keeps the top bits of the product, as the reference', () {
      // 0xFFFFFFFF * 0x1e35a7bd is 0xE1CA5843 modulo 2^32.
      final word = bytes([0xFF, 0xFF, 0xFF, 0xFF]);
      expect(LZ77Hash.snappyHash(word, 0, 18), 0xE1CA5843 >> 18);
      expect(LZ77Hash.snappyHash(word, 0, 24), 0xE1CA5843 >> 24);
    });

    test(
      'raw compressed result does not retain the input-sized allocation',
      () {
        final encoded = SnappyCodec().compress(Uint8List(1 << 20));
        expect(encoded.buffer.lengthInBytes, encoded.length);
      },
    );

    test(
      'copy tags preserve overlapping patterns at every offset and length',
      () {
        final codec = SnappyCodec();
        for (var offset = 1; offset <= 64; offset++) {
          for (var length = 1; length <= 64; length++) {
            final seed = List.generate(offset, (final i) => i + 1);
            final packed = bytes([
              ...Varint.encode(offset + length),
              if (offset <= 60) (offset - 1) << 2 else ...[60 << 2, offset - 1],
              ...seed,
              ((length - 1) << 2) | 2,
              offset,
              0,
            ]);
            expect(
              codec.decompress(packed),
              orderedEquals([
                ...seed,
                for (var i = 0; i < length; i++) seed[i % offset],
              ]),
              reason: 'offset=$offset length=$length',
            );
          }
        }
      },
    );

    test('multi-block matching never leaks history from a previous block', () {
      final data = bytes([
        ...pseudoRandom(65536),
        ...Uint8List(65536),
        ...pseudoRandom(65536, 123),
        ...List.generate(65537, (final i) => i % 7),
      ]);
      for (final format in SnappyFormat.values) {
        expectRoundTrip(SnappyCodec(format: format), data);
      }
    });
  });

  // The decoder takes a fast loop while far from both ends of its buffers and
  // a checked path near them. Each case is built so its elements fall in the
  // fast loop (noise before and after), and again at the end of the output
  // (the checked path); both must agree with a byte-at-a-time decoder.
  group('Snappy fast decode loop', () {
    final before = pseudoRandom(200, 5);
    final after = pseudoRandom(200, 6);

    void agree(final List<List<int>> elements, {final String reason = ''}) {
      for (final middle in [true, false]) {
        final data = _block([
          _literal(before),
          ...elements,
          if (middle) _literal(after),
        ]);
        final expected = _reference(data);
        expect(expected, isA<Uint8List>(), reason: reason);
        expect(
          _outcome(data),
          orderedEquals(expected as Uint8List),
          reason: '$reason ${middle ? 'in the fast loop' : 'at the end'}',
        );
      }
    }

    test('copies of every kind, offset 1 to 72 and length 1 to 64', () {
      for (var offset = 1; offset <= 72; offset++) {
        for (var length = 1; length <= 64; length++) {
          agree([
            _copy2(offset, length),
          ], reason: 'copy2 offset=$offset length=$length');
          agree([
            _copy4(offset, length),
          ], reason: 'copy4 offset=$offset length=$length');
          if (length >= 4 && length <= 11) {
            agree([
              _copy1(offset, length),
            ], reason: 'copy1 offset=$offset length=$length');
          }
        }
      }
    });

    test('overlapping copies repeat their pattern, back to back', () {
      for (var offset = 1; offset <= 8; offset++) {
        agree([
          for (var length = 1; length <= 64; length++) _copy2(offset, length),
          for (var length = 4; length <= 11; length++) _copy1(offset, length),
        ], reason: 'offset=$offset');
      }
    });

    test('copies around 64 KiB back', () {
      final noise = pseudoRandom(70000, 7);
      for (final offset in [2047, 2048, 65535, 65536, 65537, 69999]) {
        for (final length in [1, 4, 8, 9, 63, 64]) {
          final copies = [
            if (offset < 2048 && length >= 4 && length <= 11)
              _copy1(offset, length),
            if (offset < 65536) _copy2(offset, length),
            _copy4(offset, length),
          ];
          for (final copy in copies) {
            final data = _block([_literal(noise), copy, _literal(after)]);
            final decoded = _outcome(data) as Uint8List;
            final start = noise.length - offset;
            expect(
              decoded.sublist(noise.length, noise.length + length),
              orderedEquals([
                for (var i = 0; i < length; i++) noise[start + i % offset],
              ]),
              reason: 'offset=$offset length=$length tag=${copy.first & 3}',
            );
            expect(decoded, orderedEquals(_reference(data) as Uint8List));
          }
        }
      }
    });

    test('literals of every length encoding', () {
      for (final length in [
        1, 2, 7, 8, 9, 15, 16, 17, 59, 60, 61, 64, 65, 255, 256, 257, //
        1000, 65535, 65536, 65537, 70000,
      ]) {
        final data = pseudoRandom(length, length);
        agree([_literal(data)], reason: 'length=$length');
        // Each wider form the length fits: one, two, three or four bytes.
        for (var extra = 1; extra <= 4; extra++) {
          if (length - 1 < 1 << (8 * extra)) {
            agree([
              _literal(data, extra: extra),
            ], reason: 'length=$length extra=$extra');
          }
        }
      }
    });

    test('literals and copies in alternation', () {
      final random = Random(11);
      for (var round = 0; round < 50; round++) {
        agree(_elements(random, 400), reason: 'round=$round');
      }
    });

    test('round-trips the encoder at every size to 600 and beyond', () {
      final codec = SnappyCodec();
      final text = bytes(
        List.generate(3000, (final i) => 'abcab cabbage '.codeUnitAt(i % 14)),
      );
      for (var size = 0; size <= 600; size++) {
        expectRoundTrip(codec, Uint8List.sublistView(text, 0, size));
        expectRoundTrip(codec, pseudoRandom(size, size));
      }
      for (final size in [4096, 65536, 65537, 300000]) {
        expectRoundTrip(
          codec,
          bytes([
            ...pseudoRandom(size ~/ 2, size),
            ...List.generate(size ~/ 2, (final i) => (i * i) % 251 % 9),
          ]),
        );
      }
    });

    test('an offset before the start fails in the fast loop', () {
      for (final copy in [_copy1(201, 4), _copy2(201, 8), _copy4(201, 8)]) {
        final data = _block([_literal(before), copy, _literal(after)]);
        expect(
          _outcome(data),
          'SnappyFormatException: Invalid offset: 201 at position 200',
        );
      }
      final zero = _block([_literal(before), _copy2(0, 8), _literal(after)]);
      expect(
        _outcome(zero),
        'SnappyFormatException: Invalid offset: 0 at position 200',
      );
    });

    test('a declared length the elements overrun fails as before', () {
      // Every declared length short of the output, so that some copy starts
      // at each distance from the declared end, with input to spare after it.
      // A copy of 64 at offset 1 or 7 writes its last word furthest past it.
      for (final (offset, length) in [(100, 50), (1, 64), (7, 64), (3, 58)]) {
        final elements = [
          _literal(before),
          for (var i = 0; i < 60; i++) _copy2(offset, length),
        ];
        final produced = 200 + 60 * length;
        for (var declared = 201; declared < produced; declared++) {
          final data = _block(elements, length: declared);
          expect(
            _outcome(data),
            'SnappyFormatException: Copy write exceeds output buffer',
            reason: 'offset=$offset length=$length declared=$declared',
          );
        }
      }
      final elements = [
        _literal(before),
        for (var i = 0; i < 60; i++) _copy2(100, 50),
      ];
      const produced = 200 + 60 * 50;
      final literal = _block([_literal(before), _literal(after)], length: 300);
      expect(
        _outcome(literal),
        'SnappyFormatException: Literal write exceeds output buffer',
      );
      final long = _block(elements, length: produced + 1);
      expect(
        _outcome(long),
        'SnappyFormatException: Decompressed size mismatch: expected '
        '${produced + 1}, got $produced',
      );
    });

    test('a declared length past the output fails at the input end', () {
      // Short literals at or near the end of the input, far from the
      // declared end: a literal's last word is read up to 64 bytes past its
      // tag.
      final tails = [
        <List<int>>[],
        [_copy1(1, 4)],
        [_copy2(1, 1)],
        [_copy2(1, 1), _copy1(1, 4)],
      ];
      for (var size = 1; size <= 60; size++) {
        for (final tail in tails) {
          final elements = [
            _literal(before),
            _literal(pseudoRandom(size, size)),
            ...tail,
          ];
          final produced = _produced(
            bytes([for (final element in elements) ...element]),
          );
          for (final extra in [1, 8, 70, 71, 72, 200]) {
            final data = _block(elements, length: produced + extra);
            expect(
              _outcome(data),
              'SnappyFormatException: Decompressed size mismatch: expected '
              '${produced + extra}, got $produced',
              reason: 'size=$size tail=${tail.length} extra=$extra',
            );
          }
        }
      }
    });

    test('every truncation fails as the byte-at-a-time decoder does', () {
      final sources = [
        SnappyCodec().compress(
          bytes([
            ...pseudoRandom(3000, 3),
            ...List.generate(3000, (final i) => i % 13),
          ]),
        ),
        _block(_elements(Random(5), 3000)),
      ];
      for (final data in sources) {
        for (var length = 1; length < data.length; length++) {
          final cut = Uint8List.sublistView(data, 0, length);
          expect(_outcome(cut), _reference(cut), reason: 'length=$length');
        }
      }
    });

    test('corrupt bodies fail or decode as the byte-at-a-time decoder', () {
      final random = Random(17);
      final sources = [
        SnappyCodec().compress(readDataFixture('geo.protodata')),
        _block(_elements(Random(3), 2000)),
      ];
      for (final source in sources) {
        final header = Varint.decode(source, 0).bytesRead;
        for (var round = 0; round < 400; round++) {
          final data = bytes(source);
          for (var flips = 1 + random.nextInt(4); flips > 0; flips--) {
            final at = header + random.nextInt(data.length - header);
            data[at] = random.nextInt(256);
          }
          expect(_outcome(data), _reference(data), reason: 'round=$round');
        }
      }
    });
  });
}

/// A Snappy block: the varint of [length] (by default the length the
/// elements produce), then [elements].
Uint8List _block(final List<List<int>> elements, {final int? length}) {
  final body = bytes([for (final element in elements) ...element]);
  return bytes([...Varint.encode(length ?? _produced(body)), ...body]);
}

/// The output length of a well-formed block [body], read from its tags.
int _produced(final Uint8List body) {
  var source = 0;
  var total = 0;
  while (source < body.length) {
    final tag = body[source];
    if (tag & 3 == 0) {
      var length = tag >> 2;
      source++;
      if (length >= 60) {
        final extra = length - 59;
        length = 0;
        for (var i = 0; i < extra; i++) {
          length |= body[source + i] << (8 * i);
        }
        source += extra;
      }
      source += length + 1;
      total += length + 1;
    } else {
      total += tag & 3 == 1 ? 4 + ((tag >> 2) & 7) : (tag >> 2) + 1;
      source += const [0, 2, 3, 5][tag & 3];
    }
  }
  return total;
}

/// A literal element; [extra] forces that many length bytes (1 to 4).
List<int> _literal(final List<int> data, {final int? extra}) {
  final length = data.length - 1;
  final count = extra ?? (length < 60 ? 0 : (length.bitLength + 7) ~/ 8);
  return [
    if (count == 0)
      length << 2
    else ...[
      (59 + count) << 2,
      for (var i = 0; i < count; i++) (length >> (8 * i)) & 0xFF,
    ],
    ...data,
  ];
}

/// A copy with a 1-byte offset: [length] 4 to 11, [offset] below 2048.
List<int> _copy1(final int offset, final int length) => [
  ((offset >> 8) << 5) | ((length - 4) << 2) | 1,
  offset & 0xFF,
];

/// A copy with a 2-byte offset: [length] 1 to 64.
List<int> _copy2(final int offset, final int length) => [
  ((length - 1) << 2) | 2,
  offset & 0xFF,
  offset >> 8,
];

/// A copy with a 4-byte offset: [length] 1 to 64.
List<int> _copy4(final int offset, final int length) => [
  ((length - 1) << 2) | 3,
  offset & 0xFF,
  (offset >> 8) & 0xFF,
  (offset >> 16) & 0xFF,
  offset >> 24,
];

/// Random literals and copies (offsets within what precedes them, a short
/// one half the time) producing at least [size] bytes.
List<List<int>> _elements(final Random random, final int size) {
  final elements = <List<int>>[_literal(pseudoRandom(16, random.nextInt(99)))];
  var total = 16;
  while (total < size) {
    final kind = random.nextInt(4);
    if (kind == 0) {
      final length = 1 + random.nextInt(random.nextBool() ? 8 : 80);
      elements.add(_literal(pseudoRandom(length, random.nextInt(1 << 20))));
      total += length;
      continue;
    }
    final offset =
        1 + random.nextInt(random.nextBool() ? min(total, 9) : total);
    if (kind == 1 && offset < 2048) {
      final length = 4 + random.nextInt(8);
      elements.add(_copy1(offset, length));
      total += length;
    } else {
      final length = 1 + random.nextInt(64);
      elements.add(kind == 3 ? _copy4(offset, length) : _copy2(offset, length));
      total += length;
    }
  }
  return elements;
}

/// The decoder's output for [data], or its exception's type and message.
Object _outcome(final Uint8List data) {
  try {
    return SnappyDecoder.decompress(data);
  } on CompressionFormatException catch (error) {
    return '${error.runtimeType}: ${error.message}';
  }
}

/// A byte-at-a-time Snappy block decoder with the decoder's checks, in its
/// order and with its messages, under the default size limit: the output, or
/// the exception's type and message as [_outcome] gives them.
Object _reference(final Uint8List data) {
  String fail(final String message) => 'SnappyFormatException: $message';
  if (data.isEmpty) return fail('Cannot decompress empty input');
  final VarintResult header;
  try {
    header = Varint.decode(data, 0, maxBytes: 5);
  } on FormatException catch (error) {
    return fail('Invalid Snappy length prefix: ${error.message}');
  }
  final length = header.value;
  if (length > SnappyDecoder.defaultMaxSize) {
    final limit = LimitException(SnappyDecoder.defaultMaxSize);
    return '${limit.runtimeType}: ${limit.message}';
  }
  var source = header.bytesRead;
  final expansion = (data.length - source) * 64 ~/ 3;
  if (length > expansion) {
    return fail(
      'Declared length $length exceeds the maximum expansion ($expansion) '
      'of ${data.length - source} bytes',
    );
  }
  final output = Uint8List(length);
  var target = 0;
  while (source < data.length) {
    final tag = data[source];
    if (tag & 3 == 0) {
      var size = tag >> 2;
      source++;
      if (size >= 60) {
        final extra = size - 59;
        if (source + extra > data.length) {
          return fail('Truncated literal length at offset $source');
        }
        size = 0;
        for (var i = 0; i < extra; i++) {
          size |= data[source + i] << (8 * i);
        }
        source += extra;
      }
      size++;
      if (source + size > data.length) {
        return fail('Literal extends past end of input');
      }
      if (target + size > length) {
        return fail('Literal write exceeds output buffer');
      }
      for (var i = 0; i < size; i++) {
        output[target++] = data[source++];
      }
      continue;
    }
    final width = const [0, 2, 3, 5][tag & 3];
    if (source + width > data.length) {
      return fail('Truncated copy tag at offset $source');
    }
    final size = tag & 3 == 1 ? 4 + ((tag >> 2) & 7) : (tag >> 2) + 1;
    var offset = 0;
    if (tag & 3 == 1) {
      offset = ((tag & 0xe0) << 3) | data[source + 1];
    } else {
      for (var i = 1; i < width; i++) {
        offset |= data[source + i] << (8 * (i - 1));
      }
    }
    source += width;
    if (offset == 0 || offset > target) {
      return fail('Invalid offset: $offset at position $target');
    }
    if (target + size > length) {
      return fail('Copy write exceeds output buffer');
    }
    for (var i = 0; i < size; i++, target++) {
      output[target] = output[target - offset];
    }
  }
  if (target != length) {
    return fail('Decompressed size mismatch: expected $length, got $target');
  }
  return output;
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
