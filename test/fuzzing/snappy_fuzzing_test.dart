import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';
import 'package:libcompress/src/snappy/snappy_decoder.dart';

/// Fuzzing tests for Snappy decoder hardening
///
/// These tests verify that the Snappy decoder handles malformed input gracefully,
/// throwing SnappyFormatException rather than crashing with RangeError or other
/// unexpected exceptions.
void main() {
  final random = Random(42);
  final codec = SnappyCodec();

  group('Snappy Fuzzing - Random noise', () {
    test('rejects pure random noise', () {
      for (var i = 0; i < 100; i++) {
        final noise = Uint8List.fromList(
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
        final noise = Uint8List.fromList(
          List.generate(length, (_) => random.nextInt(256)),
        );
        expect(
          () => codec.decompress(noise),
          throwsA(isA<SnappyFormatException>()),
          reason: 'Short random data ($length bytes) should be rejected',
        );
      }
    });

    test('rejects empty input', () {
      // Empty input is not valid Snappy data (compressed empty is [0])
      expect(
        () => codec.decompress(Uint8List(0)),
        throwsA(isA<SnappyFormatException>()),
      );
    });
  });

  group('Snappy Fuzzing - Truncated data', () {
    late Uint8List validCompressed;

    setUpAll(() {
      final original = Uint8List.fromList(
        List.generate(1000, (i) => i % 256),
      );
      validCompressed = codec.compress(original);
    });

    test('rejects truncated at various positions', () {
      // Start from 1; empty truncation returns empty output (valid edge case)
      for (var cutoff = 1; cutoff < validCompressed.length; cutoff++) {
        final truncated = Uint8List.sublistView(validCompressed, 0, cutoff);
        expect(
          () => codec.decompress(truncated),
          throwsA(isA<SnappyFormatException>()),
          reason: 'Truncated at $cutoff should be rejected',
        );
      }
    });
  });

  group('Snappy Fuzzing - Invalid varint length', () {
    test('rejects varint claiming more than maxSize', () {
      // Encode 1GB as varint
      final malicious = Uint8List.fromList([
        0x80, 0x80, 0x80, 0x80, 0x04, // 1GB
        0x00, // Tag byte
      ]);

      expect(
        () => SnappyDecoder.decompress(malicious),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects incomplete varint', () {
      // Varint with continuation bit but no following byte
      final incomplete = Uint8List.fromList([0x80]);
      expect(
        () => SnappyDecoder.decompress(incomplete),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects very long varint', () {
      // More than 10 continuation bytes (invalid for 64-bit varint)
      final tooLong = Uint8List.fromList([
        0x80, 0x80, 0x80, 0x80, 0x80,
        0x80, 0x80, 0x80, 0x80, 0x80,
        0x80, 0x01, // 11 bytes
      ]);
      expect(
        () => SnappyDecoder.decompress(tooLong),
        throwsA(isA<SnappyFormatException>()),
      );
    });
  });

  group('Snappy Fuzzing - Invalid literal tags', () {
    test('rejects literal extending past input end', () {
      // Claim 5 bytes uncompressed, then literal claiming 10 bytes
      final data = Uint8List.fromList([
        0x05, // Uncompressed length = 5
        0x24, // Literal tag: length = (0x24 >> 2) + 1 = 10
        0x01, 0x02, 0x03, // Only 3 bytes of data
      ]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 2-byte literal length with truncated length', () {
      final data = Uint8List.fromList([
        0x10, // Uncompressed length = 16
        0xF0, // Literal tag with 2-byte length (60-63 range)
        // Missing length bytes
      ]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 3-byte literal length with truncated length', () {
      final data = Uint8List.fromList([
        0x80, 0x01, // Uncompressed length = 128
        0xF4, // Literal tag with 3-byte length
        0x10, // Only 1 of 2 length bytes
      ]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 4-byte literal length with truncated length', () {
      final data = Uint8List.fromList([
        0x80, 0x08, // Uncompressed length = 1024
        0xF8, // Literal tag with 4-byte length
        0x10, 0x00, // Only 2 of 3 length bytes
      ]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 5-byte literal length with truncated length', () {
      final data = Uint8List.fromList([
        0x80, 0x40, // Uncompressed length = 8192
        0xFC, // Literal tag with 5-byte length
        0x10, 0x00, 0x00, // Only 3 of 4 length bytes
      ]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });
  });

  group('Snappy Fuzzing - Invalid copy tags', () {
    test('rejects 1-byte copy with offset pointing before buffer', () {
      final data = Uint8List.fromList([
        0x05, // Uncompressed length = 5
        0x00, // Literal: 1 byte
        0x41, // 'A'
        0x01, // 1-byte copy: length=4, offset from high bits
              // offset = (0x01 >> 5) << 8 = 0, length = 4 + (0x01 & 0x03) = 4
              // But offset 0 is invalid
      ]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 2-byte copy with offset too large', () {
      final data = Uint8List.fromList([
        0x05, // Uncompressed length = 5
        0x00, // Literal: 1 byte
        0x41, // 'A'
        0x02, // 2-byte copy tag
        0xFF, // Offset byte (large offset into non-existent data)
      ]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 2-byte copy with truncated offset', () {
      final data = Uint8List.fromList([
        0x05, // Uncompressed length = 5
        0x00, 0x41, // Literal 'A'
        0x02, // 2-byte copy (needs 1 more byte for offset)
      ]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 4-byte copy with offset too large', () {
      final data = Uint8List.fromList([
        0x0A, // Uncompressed length = 10
        0x00, 0x41, // Literal 'A'
        0x03, // 4-byte copy tag
        0xFF, 0xFF, 0xFF, 0x7F, // Huge offset
      ]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects 4-byte copy with truncated offset', () {
      final data = Uint8List.fromList([
        0x10, // Uncompressed length = 16
        0x00, 0x41, // Literal 'A'
        0x03, // 4-byte copy (needs 4 more bytes)
        0x01, 0x00, // Only 2 of 4 offset bytes
      ]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects copy with zero offset', () {
      // Build a stream with a valid literal followed by copy with offset 0
      final data = Uint8List.fromList([
        0x08, // Uncompressed length = 8
        0x00, // Literal tag: 1 byte
        0x41, // 'A'
        0x05, // 1-byte copy: length=4+1=5, but offset = (0x05 >> 5) << 8 | next = 0
              // This creates offset 0 which is invalid
      ]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });
  });

  group('Snappy Fuzzing - Size mismatch', () {
    test('rejects when output shorter than declared', () {
      final data = Uint8List.fromList([
        0x10, // Claims 16 bytes output
        0x04, // Literal: 2 bytes
        0x41, 0x42, // 'AB' - only 2 bytes
      ]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects when output would exceed declared size', () {
      final data = Uint8List.fromList([
        0x02, // Claims only 2 bytes output
        0x08, // Literal: 3 bytes
        0x41, 0x42, 0x43, // 'ABC' - 3 bytes, exceeds declared 2
      ]);
      expect(
        () => SnappyDecoder.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });
  });

  group('Snappy Fuzzing - Framing format', () {
    // Use SnappyCodec with framing: true for framing format tests
    final framingCodec = SnappyCodec(framing: true);

    test('rejects random noise in framing format', () {
      for (var i = 0; i < 50; i++) {
        final noise = Uint8List.fromList(
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
      // Start with compressed chunk instead of stream identifier
      final data = Uint8List.fromList([
        0x00, // Compressed chunk type
        0x05, 0x00, 0x00, // Length
        0x00, 0x00, 0x00, 0x00, // CRC
        0x00, // Data
      ]);
      expect(
        () => framingCodec.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects invalid stream identifier content', () {
      final data = Uint8List.fromList([
        0xFF, // Stream identifier type
        0x06, 0x00, 0x00, // Length = 6
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // Wrong content
      ]);
      expect(
        () => framingCodec.decompress(data),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects truncated chunk header', () {
      final validIdentifier = Uint8List.fromList([
        0xFF, 0x06, 0x00, 0x00,
        0x73, 0x4E, 0x61, 0x50, 0x70, 0x59, // "sNaPpY"
      ]);
      final truncated = Uint8List.fromList([
        ...validIdentifier,
        0x00, 0x05, // Incomplete chunk header (missing third length byte)
      ]);
      expect(
        () => framingCodec.decompress(truncated),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('rejects invalid CRC in compressed chunk', () {
      // Create valid compressed data, then corrupt CRC
      final original = Uint8List.fromList([1, 2, 3, 4, 5]);
      final compressed = framingCodec.compress(original);

      // Find compressed chunk and corrupt its CRC
      // Stream identifier is first 10 bytes, then compressed chunk
      if (compressed.length > 14) {
        final corrupted = Uint8List.fromList(compressed);
        corrupted[14] ^= 0xFF; // Corrupt CRC
        expect(
          () => framingCodec.decompress(corrupted),
          throwsA(isA<SnappyFormatException>()),
        );
      }
    });
  });

  group('Snappy Fuzzing - Decompression bomb', () {
    test('respects maxUncompressedSize in decoder', () {
      // Create stream claiming huge size
      final bomb = Uint8List.fromList([
        0x80, 0x80, 0x80, 0x80, 0x04, // 1GB varint
        0x00, // Tag
      ]);

      expect(
        () => SnappyDecoder.decompress(bomb, maxUncompressedSize: 1024),
        throwsA(isA<SnappyFormatException>()),
      );
    });

    test('respects maxSize in codec', () {
      final original = Uint8List.fromList(List.filled(10000, 0x41));
      final compressed = codec.compress(original);

      final restrictedCodec = SnappyCodec(maxSize: 1000);
      expect(
        () => restrictedCodec.decompress(compressed),
        throwsA(isA<SnappyFormatException>()),
      );
    });
  });

  group('Snappy Fuzzing - Corrupted valid data', () {
    late Uint8List validCompressed;
    late Uint8List original;

    setUpAll(() {
      original = Uint8List.fromList(
        List.generate(5000, (i) => i % 256),
      );
      validCompressed = codec.compress(original);
    });

    test('handles single-byte corruptions', () {
      for (var i = 0; i < min(100, validCompressed.length); i++) {
        final corrupted = Uint8List.fromList(validCompressed);
        corrupted[i] ^= 0xFF;

        try {
          codec.decompress(corrupted);
          // If it doesn't throw, that's acceptable
        } on SnappyFormatException {
          // Expected
        } on RangeError {
          fail('Corrupted byte at $i caused RangeError instead of SnappyFormatException');
        }
      }
    });
  });
}
