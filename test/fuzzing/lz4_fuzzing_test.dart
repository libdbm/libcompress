import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';

/// Fuzzing tests for LZ4 decoder hardening
///
/// These tests verify that the LZ4 decoder handles malformed input gracefully,
/// throwing FormatException rather than crashing with RangeError or other
/// unexpected exceptions.
void main() {
  final random = Random(42); // Fixed seed for reproducibility
  final codec = Lz4Codec();

  group('LZ4 Fuzzing - Random noise', () {
    test('rejects pure random noise', () {
      for (var i = 0; i < 100; i++) {
        final noise = Uint8List.fromList(
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
      // Start from 1; empty input may return empty output
      for (var length = 1; length < 20; length++) {
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

    test('handles empty input gracefully', () {
      // Empty input returns empty output (valid edge case)
      final result = codec.decompress(Uint8List(0));
      expect(result, isEmpty);
    });
  });

  group('LZ4 Fuzzing - Truncated data', () {
    late Uint8List validCompressed;

    setUpAll(() {
      final original = Uint8List.fromList(
        List.generate(1000, (i) => i % 256),
      );
      validCompressed = codec.compress(original);
    });

    test('rejects truncated at various positions', () {
      // Start from 1; empty truncation returns empty output
      for (var cutoff = 1; cutoff < validCompressed.length; cutoff++) {
        final truncated = Uint8List.sublistView(validCompressed, 0, cutoff);
        expect(
          () => codec.decompress(truncated),
          throwsA(isA<CompressionFormatException>()),
          reason: 'Truncated at $cutoff should be rejected',
        );
      }
    });
  });

  group('LZ4 Fuzzing - Invalid magic number', () {
    test('rejects data with wrong magic number', () {
      // LZ4 frame magic is 0x184D2204 (little-endian)
      final wrongMagic = Uint8List.fromList([
        0x00, 0x00, 0x00, 0x00, // Wrong magic
        0x60, 0x40, 0x82, // Minimal frame header
        0x00, 0x00, 0x00, 0x00, // End mark
      ]);

      expect(
        () => codec.decompress(wrongMagic),
        throwsA(isA<Lz4FormatException>()),
      );
    });

    test('rejects each byte of magic corrupted', () {
      final validMagic = [0x04, 0x22, 0x4D, 0x18];
      for (var i = 0; i < 4; i++) {
        final corrupted = List<int>.from(validMagic);
        corrupted[i] ^= 0xFF;
        final data = Uint8List.fromList([
          ...corrupted,
          0x60, 0x40, 0x82,
          0x00, 0x00, 0x00, 0x00,
        ]);
        expect(
          () => codec.decompress(data),
          throwsA(isA<Lz4FormatException>()),
          reason: 'Corrupted magic byte $i should be rejected',
        );
      }
    });
  });

  group('LZ4 Fuzzing - Invalid frame descriptor', () {
    test('rejects invalid version in FLG', () {
      final data = Uint8List.fromList([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x70, // FLG with version != 01
        0x40, // BD
        0x00, // HC (wrong, but testing FLG first)
      ]);
      expect(
        () => codec.decompress(data),
        throwsA(isA<Lz4FormatException>()),
      );
    });

    test('rejects invalid block size code', () {
      final data = Uint8List.fromList([
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
  });

  group('LZ4 Fuzzing - Decompression bomb', () {
    test('rejects declared size exceeding limit', () {
      // Create frame with huge content size but small actual data
      final data = Uint8List.fromList([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x68, // FLG: version=01, content size present
        0x70, // BD: 4MB blocks
        // Content size: 1TB (way too big)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00,
        0x00, // HC (wrong but testing size limit first)
      ]);

      final restrictedCodec = Lz4Codec(maxDecompressedSize: 256 * 1024 * 1024);
      expect(
        () => restrictedCodec.decompress(data),
        throwsA(isA<Lz4FormatException>()),
      );
    });

    test('handles maxDecompressedSize limit', () {
      final original = Uint8List.fromList(List.filled(1000, 0x41));
      final compressed = codec.compress(original);

      // Should fail with small limit
      final restrictedCodec = Lz4Codec(maxDecompressedSize: 100);
      expect(
        () => restrictedCodec.decompress(compressed),
        throwsA(isA<CompressionFormatException>()),
      );
    });
  });

  group('LZ4 Fuzzing - Corrupted blocks', () {
    late Uint8List validCompressed;
    late Uint8List original;

    setUpAll(() {
      original = Uint8List.fromList(
        List.generate(5000, (i) => i % 256),
      );
      validCompressed = codec.compress(original);
    });

    test('rejects corrupted block data', () {
      // Skip header, corrupt middle of block
      final headerEnd = 7; // Approximate header size
      if (validCompressed.length > headerEnd + 10) {
        for (var i = headerEnd; i < min(headerEnd + 50, validCompressed.length - 4); i++) {
          final corrupted = Uint8List.fromList(validCompressed);
          corrupted[i] ^= 0xFF;

          // Should either decompress to wrong data or throw
          try {
            final result = codec.decompress(corrupted);
            // If it doesn't throw, verify it's different from original
            // (corruption should be detected)
            if (result.length == original.length) {
              var same = true;
              for (var j = 0; j < result.length && same; j++) {
                if (result[j] != original[j]) same = false;
              }
              // It's acceptable if corruption produces different output
              // The test is that it doesn't crash
            }
          } on CompressionFormatException {
            // Expected for detected corruption
          } catch (e) {
            fail('Corrupted byte at position $i threw $e '
                'instead of CompressionFormatException');
          }
        }
      }
    });

    test('handles block with zero size', () {
      final data = Uint8List.fromList([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x60, // FLG
        0x70, // BD
        0x73, // HC
        0x00, 0x00, 0x00, 0x00, // End mark (zero block = end)
      ]);

      // Zero block should be interpreted as end mark
      final result = codec.decompress(data);
      expect(result, isEmpty);
    });
  });

  group('LZ4 Fuzzing - Invalid back-references', () {
    test('rejects offset pointing before buffer start', () {
      // Craft a block with invalid back-reference offset
      // LZ4 block format: token (4 bits literal length, 4 bits match length)
      // followed by literals, then offset (2 bytes LE), then optional extra length

      final data = Uint8List.fromList([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x60, 0x70, 0x73, // Frame header
        0x10, 0x00, 0x00, 0x00, // Block size = 16 (uncompressed flag not set)
        // Block content with invalid offset
        0x10, // Token: 1 literal, 4+ match
        0x41, // Literal 'A'
        0xFF, 0xFF, // Offset 65535 - points way before buffer
        // This should fail because there's nothing at that offset
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

    test('rejects zero offset', () {
      final data = Uint8List.fromList([
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
  });

  group('LZ4 Fuzzing - Checksum validation', () {
    test('rejects invalid header checksum', () {
      final data = Uint8List.fromList([
        0x04, 0x22, 0x4D, 0x18, // Magic
        0x60, 0x70, // FLG, BD
        0xFF, // Wrong header checksum
        0x00, 0x00, 0x00, 0x00, // End mark
      ]);

      expect(
        () => codec.decompress(data),
        throwsA(isA<Lz4FormatException>()),
      );
    });

    test('rejects invalid content checksum when enabled', () {
      // Compress with checksum, then corrupt it
      final codecWithChecksum = Lz4Codec(enableContentChecksum: true);
      final original = Uint8List.fromList([1, 2, 3, 4, 5]);
      final compressed = codecWithChecksum.compress(original);

      // Corrupt the last 4 bytes (content checksum)
      final corrupted = Uint8List.fromList(compressed);
      corrupted[corrupted.length - 1] ^= 0xFF;

      expect(
        () => codecWithChecksum.decompress(corrupted),
        throwsA(isA<Lz4FormatException>()),
      );
    });
  });
}
