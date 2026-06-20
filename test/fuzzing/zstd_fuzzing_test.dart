import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

/// Fuzzing tests for Zstandard decoder hardening
///
/// These tests verify that the Zstd decoder handles malformed input gracefully,
/// throwing ZstdFormatException rather than crashing with RangeError or other
/// unexpected exceptions.
void main() {
  final random = Random(42);
  final codec = ZstdCodec();

  group('Zstd Fuzzing - Random noise', () {
    test('rejects pure random noise', () {
      for (var i = 0; i < 100; i++) {
        final noise = Uint8List.fromList(
          List.generate(random.nextInt(1000) + 1, (_) => random.nextInt(256)),
        );
        expect(
          () => codec.decompress(noise),
          throwsA(isA<ZstdFormatException>()),
          reason: 'Random noise iteration $i should be rejected',
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
          throwsA(isA<CompressionFormatException>()),
          reason: 'Short random data ($length bytes) should be rejected',
        );
      }
    });
  });

  group('Zstd Fuzzing - Truncated data', () {
    late Uint8List validCompressed;

    setUpAll(() {
      final original = Uint8List.fromList(
        List.generate(1000, (i) => i % 256),
      );
      validCompressed = codec.compress(original);
    });

    test('rejects truncated at various positions', () {
      for (var cutoff = 0; cutoff < validCompressed.length; cutoff++) {
        final truncated = Uint8List.sublistView(validCompressed, 0, cutoff);
        expect(
          () => codec.decompress(truncated),
          throwsA(isA<CompressionFormatException>()),
          reason: 'Truncated at $cutoff should be rejected',
        );
      }
    });
  });

  group('Zstd Fuzzing - Invalid magic number', () {
    test('rejects wrong magic number', () {
      // Zstd magic is 0xFD2FB528 (little-endian: 28 B5 2F FD)
      final wrongMagic = Uint8List.fromList([
        0x00, 0x00, 0x00, 0x00, // Wrong magic
        0x00, // Frame header
      ]);

      expect(
        () => codec.decompress(wrongMagic),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('rejects each byte of magic corrupted', () {
      final validMagic = [0x28, 0xB5, 0x2F, 0xFD];
      for (var i = 0; i < 4; i++) {
        final corrupted = List<int>.from(validMagic);
        corrupted[i] ^= 0xFF;
        final data = Uint8List.fromList([
          ...corrupted,
          0x00, // Minimal header
        ]);
        expect(
          () => codec.decompress(data),
          throwsA(isA<ZstdFormatException>()),
          reason: 'Corrupted magic byte $i should be rejected',
        );
      }
    });
  });

  group('Zstd Fuzzing - Invalid frame header', () {
    test('rejects invalid frame header descriptor', () {
      final data = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, // Magic
        0xFF, // Invalid frame header descriptor (reserved bits set)
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects truncated window descriptor', () {
      final data = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, // Magic
        0x00, // FHD: single segment = 0, need window descriptor
        // Missing window descriptor
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects truncated content size', () {
      final data = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, // Magic
        0x60, // FHD: content size = 2 bytes expected
        0x00, // Window descriptor
        0x10, // Only 1 byte of content size, expected 2
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects invalid dictionary ID size', () {
      final data = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, // Magic
        0x23, // FHD: dictionary ID = 4 bytes
        0x00, // Window
        0x01, 0x02, // Only 2 bytes of dict ID, expected 4
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });
  });

  group('Zstd Fuzzing - Invalid block header', () {
    test('rejects invalid block type', () {
      final data = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, // Magic
        0x20, // FHD: single segment
        0x00, // Content size = 0
        0x06, 0x00, 0x00, // Block: type=3 (reserved), size=0, last=0
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('rejects block size exceeding maximum', () {
      // Max block size is 128KB
      final data = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, // Magic
        0x20, // FHD
        0x00, // Content size
        // Block header claiming 1MB raw block
        0x01, 0x00, 0x10, // Type=raw, size=1MB, last=1
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects truncated block data', () {
      final data = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, // Magic
        0x20, // FHD
        0x05, // Content size = 5
        0x29, 0x00, 0x00, // Block: raw, size=5, last=1
        0x01, 0x02, // Only 2 bytes, expected 5
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });
  });

  group('Zstd Fuzzing - Invalid compressed block', () {
    test('rejects compressed block with invalid literals header', () {
      final data = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, // Magic
        0x20, // FHD
        0x05, // Content size
        0x05, 0x00, 0x00, // Block: compressed, size=1, last=1
        0xFF, // Invalid literals section header
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('rejects block with too many sequences', () {
      // Create a block claiming many sequences but with insufficient data
      final data = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, // Magic
        0x20, // FHD
        0x80, 0x01, // Content size = 128
        0x15, 0x00, 0x00, // Block: compressed, size=5, last=1
        0x00, // Literals: raw, size=0
        0xFF, 0xFF, // Sequence count = 65535 (way too many)
        0x00, // Sequence mode
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });
  });

  group('Zstd Fuzzing - Checksum validation', () {
    test('rejects invalid content checksum', () {
      // Create with checksum enabled, then corrupt it
      final codecWithChecksum = ZstdCodec(enableChecksum: true);
      final original = Uint8List.fromList([1, 2, 3, 4, 5]);
      final compressed = codecWithChecksum.compress(original);

      // Corrupt the last 4 bytes (XXH64 low 32 bits)
      final corrupted = Uint8List.fromList(compressed);
      corrupted[corrupted.length - 1] ^= 0xFF;

      expect(
        () => codecWithChecksum.decompress(corrupted),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('rejects truncated checksum', () {
      final codecWithChecksum = ZstdCodec(enableChecksum: true);
      final original = Uint8List.fromList([1, 2, 3, 4, 5]);
      final compressed = codecWithChecksum.compress(original);

      // Remove last 2 bytes of checksum
      final truncated = Uint8List.sublistView(
        compressed, 0, compressed.length - 2
      );

      expect(
        () => codecWithChecksum.decompress(truncated),
        throwsA(isA<CompressionFormatException>()),
      );
    });
  });

  group('Zstd Fuzzing - Decompression bomb', () {
    test('rejects declared size exceeding limit', () {
      // Create frame with huge content size
      final data = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, // Magic
        0xE0, // FHD: content size = 8 bytes
        0x00, // Window
        // 1TB content size
        0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00,
        0x01, 0x00, 0x00, // Block header
      ]);

      final restrictedCodec = ZstdCodec(maxDecompressedSize: 256 * 1024 * 1024);
      expect(
        () => restrictedCodec.decompress(data),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('handles maxDecompressedSize limit', () {
      final original = Uint8List.fromList(List.filled(10000, 0x41));
      final compressed = codec.compress(original);

      final restrictedCodec = ZstdCodec(maxDecompressedSize: 1000);
      expect(
        () => restrictedCodec.decompress(compressed),
        throwsA(isA<CompressionFormatException>()),
      );
    });
  });

  group('Zstd Fuzzing - RLE blocks', () {
    test('handles RLE block with invalid size', () {
      // RLE block should have size 1 (the byte to repeat)
      final data = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, // Magic
        0x20, // FHD
        0x05, // Content size = 5
        0x0B, 0x00, 0x00, // Block: RLE, size=2 (invalid, should be 1), last=1
        0x41, 0x42, // Two bytes (wrong)
      ]);
      // Behavior depends on implementation - may work or fail
      try {
        codec.decompress(data);
      } on CompressionFormatException {
        // Expected
      } catch (e) {
        fail('Expected CompressionFormatException, got $e');
      }
    });

    test('handles valid RLE block', () {
      // Valid RLE block
      final data = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, // Magic
        0x20, // FHD
        0x05, // Content size = 5
        0x2B, 0x00, 0x00, // Block: RLE, size=5, last=1
        0x41, // Byte to repeat
      ]);
      final result = codec.decompress(data);
      expect(result, equals(Uint8List.fromList([0x41, 0x41, 0x41, 0x41, 0x41])));
    });
  });

  group('Zstd Fuzzing - Skippable frames', () {
    test('handles skippable frame followed by valid frame', () {
      final validFrame = codec.compress(Uint8List.fromList([1, 2, 3]));
      final data = Uint8List.fromList([
        0x50, 0x2A, 0x4D, 0x18, // Skippable magic (0x184D2A50)
        0x04, 0x00, 0x00, 0x00, // Size = 4
        0xDE, 0xAD, 0xBE, 0xEF, // Skipped data
        ...validFrame,
      ]);
      final result = codec.decompress(data);
      expect(result, equals(Uint8List.fromList([1, 2, 3])));
    });

    test('rejects truncated skippable frame', () {
      final data = Uint8List.fromList([
        0x50, 0x2A, 0x4D, 0x18, // Skippable magic
        0x10, 0x00, 0x00, 0x00, // Size = 16
        0x01, 0x02, 0x03, // Only 3 bytes, expected 16
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<CompressionFormatException>()),
      );
    });
  });

  group('Zstd Fuzzing - Content size mismatch', () {
    test('rejects when output size differs from declared', () {
      // Frame claims 10 bytes but raw block has 5
      final data = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, // Magic
        0x20, // FHD: single segment, content size present
        0x0A, // Content size = 10
        0x29, 0x00, 0x00, // Block: raw, size=5, last=1
        0x01, 0x02, 0x03, 0x04, 0x05, // Only 5 bytes
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<ZstdFormatException>()),
      );
    });
  });

  group('Zstd Fuzzing - Corrupted valid data', () {
    late Uint8List validCompressed;

    setUpAll(() {
      final original = Uint8List.fromList(
        List.generate(5000, (i) => i % 256),
      );
      validCompressed = codec.compress(original);
    });

    test('handles single-byte corruptions', () {
      // Skip magic (first 4 bytes)
      for (var i = 4; i < min(100, validCompressed.length); i++) {
        final corrupted = Uint8List.fromList(validCompressed);
        corrupted[i] ^= 0xFF;

        try {
          codec.decompress(corrupted);
          // May succeed with wrong output
        } on CompressionFormatException {
          // Expected for detected corruption
        } catch (e) {
          fail('Corrupted byte at position $i threw $e '
              'instead of CompressionFormatException');
        }
      }
    });
  });

  group('Zstd Fuzzing - Multiple frames', () {
    test('handles truncated second frame', () {
      final frame1 = codec.compress(Uint8List.fromList([1, 2, 3]));
      final partial = Uint8List.fromList([
        ...frame1,
        0x28, 0xB5, 0x2F, 0xFD, // Magic only
      ]);
      expect(
        () => codec.decompress(partial),
        throwsA(isA<CompressionFormatException>()),
      );
    });

    test('decompresses multiple valid frames', () {
      final frame1 = codec.compress(Uint8List.fromList([1, 2, 3]));
      final frame2 = codec.compress(Uint8List.fromList([4, 5, 6]));
      final concatenated = Uint8List.fromList([...frame1, ...frame2]);

      final result = codec.decompress(concatenated);
      expect(result, equals(Uint8List.fromList([1, 2, 3, 4, 5, 6])));
    });
  });
}
