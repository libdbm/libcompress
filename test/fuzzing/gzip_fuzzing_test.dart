import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

/// Fuzzing tests for GZIP decoder hardening
///
/// These tests verify that the GZIP decoder handles malformed input gracefully,
/// throwing GzipFormatException rather than crashing with RangeError or other
/// unexpected exceptions.
void main() {
  final random = Random(42);
  final codec = GzipCodec();

  group('GZIP Fuzzing - Random noise', () {
    test('rejects pure random noise', () {
      for (var i = 0; i < 100; i++) {
        final noise = Uint8List.fromList(
          List.generate(random.nextInt(1000) + 1, (_) => random.nextInt(256)),
        );
        expect(
          () => codec.decompress(noise),
          throwsA(isA<GzipFormatException>()),
          reason: 'Random noise should be rejected',
        );
      }
    });

    test('rejects short random data', () {
      for (var length = 0; length < 20; length++) {
        final noise = Uint8List.fromList(
          List.generate(length, (_) => random.nextInt(256)),
        );
        expect(
          () => codec.decompress(noise),
          throwsA(isA<GzipFormatException>()),
          reason: 'Short random data ($length bytes) should be rejected',
        );
      }
    });
  });

  group('GZIP Fuzzing - Truncated data', () {
    late Uint8List validCompressed;

    setUpAll(() {
      final original = Uint8List.fromList(
        List.generate(1000, (i) => i % 256),
      );
      validCompressed = codec.compress(original);
    });

    test('rejects truncated at various positions', () {
      // Start from 1; empty returns empty (valid edge case)
      for (var cutoff = 1; cutoff < validCompressed.length; cutoff++) {
        final truncated = Uint8List.sublistView(validCompressed, 0, cutoff);
        expect(
          () => codec.decompress(truncated),
          throwsA(anyOf(
            isA<GzipFormatException>(),
            isA<DeflateFormatException>(),
          )),
          reason: 'Truncated at $cutoff should be rejected',
        );
      }
    });
  });

  group('GZIP Fuzzing - Invalid magic number', () {
    test('rejects data with wrong magic number', () {
      // GZIP magic is 0x1F 0x8B
      final wrongMagic = Uint8List.fromList([
        0x00, 0x00, // Wrong magic
        0x08, // Compression method
        0x00, // Flags
        0x00, 0x00, 0x00, 0x00, // MTIME
        0x00, // XFL
        0xFF, // OS
      ]);

      expect(
        () => codec.decompress(wrongMagic),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('rejects ID1 corrupted', () {
      final data = Uint8List.fromList([
        0x00, 0x8B, // ID1 wrong
        0x08, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0xFF,
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('rejects ID2 corrupted', () {
      final data = Uint8List.fromList([
        0x1F, 0x00, // ID2 wrong
        0x08, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0xFF,
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<GzipFormatException>()),
      );
    });
  });

  group('GZIP Fuzzing - Invalid compression method', () {
    test('rejects unsupported compression method', () {
      final data = Uint8List.fromList([
        0x1F, 0x8B, // Magic
        0x09, // CM = 9 (not 8/deflate)
        0x00, // Flags
        0x00, 0x00, 0x00, 0x00, // MTIME
        0x00, // XFL
        0xFF, // OS
      ]);

      expect(
        () => codec.decompress(data),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('rejects compression method 0', () {
      final data = Uint8List.fromList([
        0x1F, 0x8B, 0x00, // CM = 0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<GzipFormatException>()),
      );
    });
  });

  group('GZIP Fuzzing - Invalid flags', () {
    test('handles FEXTRA with truncated length', () {
      final data = Uint8List.fromList([
        0x1F, 0x8B, // Magic
        0x08, // CM
        0x04, // FLG = FEXTRA set
        0x00, 0x00, 0x00, 0x00, // MTIME
        0x00, 0xFF, // XFL, OS
        // Missing XLEN
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('handles FEXTRA with truncated data', () {
      final data = Uint8List.fromList([
        0x1F, 0x8B, 0x08,
        0x04, // FEXTRA
        0x00, 0x00, 0x00, 0x00,
        0x00, 0xFF,
        0x10, 0x00, // XLEN = 16
        0x01, 0x02, // Only 2 bytes, expected 16
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('handles FNAME without null terminator', () {
      final data = Uint8List.fromList([
        0x1F, 0x8B, 0x08,
        0x08, // FNAME
        0x00, 0x00, 0x00, 0x00,
        0x00, 0xFF,
        0x66, 0x69, 0x6C, 0x65, // "file" without null terminator
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('handles FCOMMENT without null terminator', () {
      final data = Uint8List.fromList([
        0x1F, 0x8B, 0x08,
        0x10, // FCOMMENT
        0x00, 0x00, 0x00, 0x00,
        0x00, 0xFF,
        0x74, 0x65, 0x73, 0x74, // "test" without null terminator
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('handles FHCRC with truncated checksum', () {
      final data = Uint8List.fromList([
        0x1F, 0x8B, 0x08,
        0x02, // FHCRC
        0x00, 0x00, 0x00, 0x00,
        0x00, 0xFF,
        0x00, // Only 1 byte of CRC16, expected 2
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<GzipFormatException>()),
      );
    });
  });

  group('GZIP Fuzzing - Invalid DEFLATE blocks', () {
    test('rejects invalid block type', () {
      final data = Uint8List.fromList([
        0x1F, 0x8B, 0x08, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0xFF,
        0x07, // Block header: BFINAL=1, BTYPE=11 (reserved/invalid)
        // CRC32 and ISIZE would follow
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(anyOf(
          isA<GzipFormatException>(),
          isA<DeflateFormatException>(),
        )),
      );
    });

    test('rejects stored block with wrong NLEN', () {
      final data = Uint8List.fromList([
        0x1F, 0x8B, 0x08, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0xFF,
        0x01, // Stored block, final
        0x05, 0x00, // LEN = 5
        0x00, 0x00, // NLEN wrong (should be 0xFFFA)
        0x48, 0x65, 0x6C, 0x6C, 0x6F, // "Hello"
        0x00, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00,
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(anyOf(
          isA<GzipFormatException>(),
          isA<DeflateFormatException>(),
        )),
      );
    });
  });

  group('GZIP Fuzzing - Checksum validation', () {
    late Uint8List validCompressed;
    late Uint8List original;

    setUpAll(() {
      original = Uint8List.fromList([1, 2, 3, 4, 5]);
      validCompressed = codec.compress(original);
    });

    test('rejects invalid CRC32', () {
      final corrupted = Uint8List.fromList(validCompressed);
      // CRC32 is in the last 8 bytes (4 bytes CRC + 4 bytes ISIZE)
      corrupted[corrupted.length - 5] ^= 0xFF;

      expect(
        () => codec.decompress(corrupted),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('rejects invalid ISIZE', () {
      final corrupted = Uint8List.fromList(validCompressed);
      // ISIZE is the last 4 bytes
      corrupted[corrupted.length - 1] ^= 0xFF;

      expect(
        () => codec.decompress(corrupted),
        throwsA(isA<GzipFormatException>()),
      );
    });
  });

  group('GZIP Fuzzing - Decompression bomb', () {
    test('handles maxDecompressedSize limit', () {
      final original = Uint8List.fromList(List.filled(10000, 0x41));
      final compressed = codec.compress(original);

      final restrictedCodec = GzipCodec(maxDecompressedSize: 1000);
      expect(
        () => restrictedCodec.decompress(compressed),
        throwsA(anyOf(
          isA<GzipFormatException>(),
          isA<DeflateFormatException>(),
        )),
      );
    });
  });

  group('GZIP Fuzzing - Corrupted data', () {
    late Uint8List validCompressed;

    setUpAll(() {
      final original = Uint8List.fromList(
        List.generate(5000, (i) => i % 256),
      );
      validCompressed = codec.compress(original);
    });

    test('handles single-byte corruptions in DEFLATE stream', () {
      // Skip header (10 bytes minimum), corrupt DEFLATE data
      for (var i = 10; i < min(60, validCompressed.length - 8); i++) {
        final corrupted = Uint8List.fromList(validCompressed);
        corrupted[i] ^= 0xFF;

        try {
          codec.decompress(corrupted);
          // If it doesn't throw, that's okay - corruption may not be detected
          // if it produces valid (but wrong) output
        } on GzipFormatException {
          // Expected
        } on DeflateFormatException {
          // Expected
        } on StateError {
          fail('Corrupted byte at $i leaked a StateError');
        } on RangeError {
          fail('Corrupted byte at $i caused RangeError');
        }
      }
    });
  });

  group('GZIP Fuzzing - Concatenated members', () {
    test('handles truncated second member', () {
      final original = Uint8List.fromList([1, 2, 3]);
      final member1 = codec.compress(original);

      // Add partial second member
      final partial = Uint8List.fromList([
        ...member1,
        0x1F, 0x8B, 0x08, 0x00, // Magic and partial header
      ]);

      expect(
        () => codec.decompress(partial),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('handles garbage after valid member', () {
      final original = Uint8List.fromList([1, 2, 3]);
      final compressed = codec.compress(original);

      // Add non-GZIP garbage
      final withGarbage = Uint8List.fromList([
        ...compressed,
        0x00, 0x01, 0x02, 0x03, // Garbage
      ]);

      expect(
        () => codec.decompress(withGarbage),
        throwsA(isA<GzipFormatException>()),
      );
    });
  });
}
