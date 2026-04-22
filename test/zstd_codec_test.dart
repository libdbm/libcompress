import 'dart:typed_data';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:libcompress/src/zstd/zstd_codec.dart';
import 'package:libcompress/src/zstd/zstd_encoder.dart';
import 'package:libcompress/src/zstd/zstd_common.dart';
import 'test_utils.dart';
import 'web_test_utils.dart';

void main() {
  group('ZSTD decompression fixtures', () {
    for (final path in standardFixtures) {
      test('decompresses $path', () {
        final codec = ZstdCodec();
        final compressed = readCodecFixture('zstd', '$path.zst');
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
            codecExpression: 'ZstdCodec()',
            compressed: readCodecFixture('zstd', '$path.zst'),
            expected: readDataFixture(path),
          );
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );
    }
  });

  group('ZSTD round-trip compression', () {
    for (final path in standardFixtures) {
      test('round-trips $path', () {
        final codec = ZstdCodec();
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
            codecExpression: 'ZstdCodec()',
            data: readDataFixture(path),
          );
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );
    }
  });

  group('ZSTD Raw blocks', () {
    test('compresses and decompresses empty data', () {
      final codec = ZstdCodec();
      final data = Uint8List(0);
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('compresses and decompresses random-like data', () {
      final codec = ZstdCodec();
      final data = Uint8List.fromList(List.generate(1000, (i) => i % 256));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('compresses and decompresses large random data', () {
      final codec = ZstdCodec();
      final data = Uint8List.fromList(
        List.generate(256 * 1024, (i) => i % 256),
      );
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });
  });

  group('ZSTD Huffman-compressed blocks (decompression)', () {
    // CLI fixtures use Huffman compression - these test our decoder
    test('decompresses html with Huffman literals', () {
      final codec = ZstdCodec();
      final compressed = readCodecFixture('zstd', 'html.zst');
      final expected = readDataFixture('html');
      final actual = codec.decompress(compressed);
      expect(actual, orderedEquals(expected));
      // Verify it actually achieved compression (not raw blocks)
      expect(compressed.length, lessThan(expected.length ~/ 2));
    });

    test('decompresses alice29.txt with Huffman literals', () {
      final codec = ZstdCodec();
      final compressed = readCodecFixture('zstd', 'canterbury/alice29.txt.zst');
      final expected = readDataFixture('canterbury/alice29.txt');
      final actual = codec.decompress(compressed);
      expect(actual, orderedEquals(expected));
      // Verify compression ratio
      expect(compressed.length, lessThan(expected.length ~/ 2));
    });

    test('decompresses paper1 with Huffman literals', () {
      final codec = ZstdCodec();
      final compressed = readCodecFixture('zstd', 'calgary/paper1.zst');
      final expected = readDataFixture('calgary/paper1');
      final actual = codec.decompress(compressed);
      expect(actual, orderedEquals(expected));
      expect(compressed.length, lessThan(expected.length ~/ 2));
    });

    test('decompresses alphabet with varied symbol frequencies', () {
      final codec = ZstdCodec();
      final compressed = readCodecFixture(
        'zstd',
        'artificial/alphabet.txt.zst',
      );
      final expected = readDataFixture('artificial/alphabet.txt');
      final actual = codec.decompress(compressed);
      expect(actual, orderedEquals(expected));
    });

    test('handles single-stream Huffman literals', () {
      // Small data uses single-stream Huffman
      final codec = ZstdCodec();
      final compressed = readCodecFixture('zstd', 'artificial/aaa.txt.zst');
      final expected = readDataFixture('artificial/aaa.txt');
      final actual = codec.decompress(compressed);
      expect(actual, orderedEquals(expected));
    });

    test('handles 4-stream Huffman literals', () {
      // Large data uses 4-stream parallel Huffman
      final codec = ZstdCodec();
      final compressed = readCodecFixture('zstd', 'canterbury/alice29.txt.zst');
      final expected = readDataFixture('canterbury/alice29.txt');
      final actual = codec.decompress(compressed);
      expect(actual, orderedEquals(expected));
    });
  });

  group('ZSTD RLE blocks', () {
    test('compresses and decompresses highly repetitive data', () {
      final codec = ZstdCodec();
      final data = Uint8List.fromList(List.filled(10000, 65)); // All 'A'
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
      // RLE should compress very well
      expect(compressed.length, lessThan(100));
    });

    test('compresses single byte repeated', () {
      final codec = ZstdCodec();
      final data = Uint8List.fromList(List.filled(1000, 0));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
      expect(compressed.length, lessThan(50));
    });

    test('compresses blocks of repeated pattern', () {
      final codec = ZstdCodec(blockSize: 1000);
      // Create data with blocks of repeated bytes
      final data = Uint8List(3000);
      data.fillRange(0, 1000, 65); // 'A'
      data.fillRange(1000, 2000, 66); // 'B'
      data.fillRange(2000, 3000, 67); // 'C'
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
      // Should be well compressed with RLE
      expect(compressed.length, lessThan(200));
    });
  });

  group('ZSTD block size configuration', () {
    test('default block size (128K)', () {
      final codec = ZstdCodec();
      final data = readDataFixture('canterbury/alice29.txt');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });

    test('custom block size 1000', () {
      final codec = ZstdCodec(blockSize: 1000);
      final data = Uint8List.fromList(List.generate(2500, (i) => i % 256));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('small block size 100', () {
      final codec = ZstdCodec(blockSize: 100);
      final data = Uint8List.fromList(List.generate(250, (i) => i % 256));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('rejects block size exceeding maximum', () {
      expect(() => ZstdEncoder(blockSize: 129 * 1024), throwsArgumentError);
    });
  });

  group('ZSTD checksum options', () {
    test('with checksum enabled', () {
      final codec = ZstdCodec(enableChecksum: true);
      final data = readDataFixture('html');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });

    test('with checksum disabled (default)', () {
      final codec = ZstdCodec(enableChecksum: false);
      final data = readDataFixture('html');
      final compressed = codec.compress(data);
      final restored = codec.decompress(compressed);
      expect(restored, orderedEquals(data));
    });
  });

  group('ZSTD Frame format', () {
    test('includes correct magic number', () {
      final codec = ZstdCodec();
      final data = Uint8List.fromList([1, 2, 3]);
      final compressed = codec.compress(data);

      // Magic number: 0xFD2FB528 (little-endian)
      expect(compressed[0], equals(0x28));
      expect(compressed[1], equals(0xB5));
      expect(compressed[2], equals(0x2F));
      expect(compressed[3], equals(0xFD));
    });

    test('rejects invalid magic number', () {
      final badData = Uint8List.fromList([0x00, 0x00, 0x00, 0x00]);
      final codec = ZstdCodec();
      expect(
        () => codec.decompress(badData),
        throwsA(
          isA<ZstdFormatException>().having(
            (e) => e.message,
            'message',
            contains('Invalid Zstd magic number'),
          ),
        ),
      );
    });

    test('rejects incomplete frame', () {
      final badData = Uint8List.fromList([0x28, 0xB5, 0x2F, 0xFD]);
      final codec = ZstdCodec();
      expect(
        () => codec.decompress(badData),
        throwsA(isA<ZstdFormatException>()),
      );
    });

    test('handles multiple concatenated frames', () {
      final codec = ZstdCodec();
      final first = Uint8List.fromList(List.generate(32, (i) => i));
      final second = Uint8List.fromList(List.generate(48, (i) => 255 - i));

      final frameA = codec.compress(first);
      final frameB = codec.compress(second);

      final combined = Uint8List(frameA.length + frameB.length);
      combined.setRange(0, frameA.length, frameA);
      combined.setRange(frameA.length, combined.length, frameB);

      final decompressed = codec.decompress(combined);
      final expected = Uint8List.fromList([...first, ...second]);
      expect(decompressed, equals(expected));
    });

    test('skips skippable frames between valid frames', () {
      final codec = ZstdCodec();
      final payload = Uint8List.fromList(List.generate(16, (i) => i + 1));
      final frame = codec.compress(payload);

      final skippable = _buildSkippableFrame(zstdSkippableFrameMagicBase + 3, [
        0,
        1,
        2,
        3,
        4,
      ]);

      final combined = Uint8List(
        frame.length + skippable.length + frame.length,
      );
      var pos = 0;
      combined.setRange(pos, pos + frame.length, frame);
      pos += frame.length;
      combined.setRange(pos, pos + skippable.length, skippable);
      pos += skippable.length;
      combined.setRange(pos, pos + frame.length, frame);

      final decompressed = codec.decompress(combined);
      final expected = Uint8List.fromList([...payload, ...payload]);
      expect(decompressed, equals(expected));
    });

    test('handles skippable-only frames (returns empty)', () {
      final codec = ZstdCodec();

      // Build a stream with only skippable frames
      final skippable1 = _buildSkippableFrame(zstdSkippableFrameMagicBase, [
        1,
        2,
        3,
      ]);
      final skippable2 = _buildSkippableFrame(zstdSkippableFrameMagicBase + 5, [
        4,
        5,
        6,
        7,
        8,
      ]);

      final combined = Uint8List(skippable1.length + skippable2.length);
      combined.setRange(0, skippable1.length, skippable1);
      combined.setRange(skippable1.length, combined.length, skippable2);

      // Should return empty bytes, not throw
      final decompressed = codec.decompress(combined);
      expect(decompressed, isEmpty);
    });

    test('rejects frames that require a dictionary', () {
      final codec = ZstdCodec();
      final data = Uint8List.fromList([5, 4, 3, 2, 1]);
      final frame = codec.compress(data);
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
  });

  group('ZSTD edge cases', () {
    test('handles single byte', () {
      final codec = ZstdCodec();
      final data = Uint8List.fromList([42]);
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('handles data exactly at block boundary', () {
      final codec = ZstdCodec(blockSize: 1000);
      final data = Uint8List.fromList(List.generate(1000, (i) => i % 256));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('handles data spanning multiple blocks', () {
      final codec = ZstdCodec(blockSize: 500);
      final data = Uint8List.fromList(List.generate(1500, (i) => i % 256));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('handles all byte values', () {
      final codec = ZstdCodec();
      final data = Uint8List.fromList(List.generate(256, (i) => i));
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });
  });

  group('ZSTD compression efficiency', () {
    test('raw blocks do not expand much beyond original', () {
      final codec = ZstdCodec();
      // Random-like data that won't compress
      final data = Uint8List.fromList(
        List.generate(1000, (i) => (i * 31 + 17) % 256),
      );
      final compressed = codec.compress(data);
      // Overhead should be minimal (frame header + block headers)
      expect(compressed.length, lessThan(data.length + 50));
    });

    test('RLE achieves excellent compression on repetitive data', () {
      final codec = ZstdCodec();
      final data = Uint8List.fromList(List.filled(100000, 42));
      final compressed = codec.compress(data);
      // Should compress to tiny size with RLE
      expect(compressed.length, lessThan(200));
    });

    test('emits compressed block when matches are present', () {
      final codec = ZstdCodec(blockSize: 4096);
      final pattern = List<int>.generate(64, (i) => i);
      final data = Uint8List.fromList([
        ...pattern,
        for (var i = 0; i < 60; i++) ...pattern,
      ]);

      final compressed = codec.compress(data);
      final firstBlockType = _firstBlockType(compressed);
      expect(firstBlockType, equals(ZstdBlockType.compressed.index));

      final decoded = codec.decompress(compressed);
      expect(decoded, equals(data));
    });

    test('compressed block with text-like data', () {
      final codec = ZstdCodec();
      final text = 'The quick brown fox jumps over the lazy dog. ';
      final data = Uint8List.fromList(
        List.generate(50, (i) => text.codeUnits).expand((x) => x).toList(),
      );

      final compressed = codec.compress(data);
      final decoded = codec.decompress(compressed);
      expect(decoded, equals(data));
      // Should achieve good compression
      expect(compressed.length, lessThan(data.length ~/ 2));
    });

    test('round-trips large json with embedded base64 across blocks', () {
      final codec = ZstdCodec();
      final data = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'document': {'id': 'tpl'},
            'elements': List.generate(
              2000,
              (i) => {
                'id': 'e$i',
                'kind': 'image',
                'image': {
                  'source':
                      'data:image/png;base64,${base64Encode(List.generate(1024, (j) => (i + j) & 0xff))}',
                },
                'transform': {'x': i, 'y': i % 100, 'width': 20, 'height': 30},
              },
            ),
          }),
        ),
      );

      final compressed = codec.compress(data);
      final decoded = codec.decompress(compressed);
      expect(decoded, orderedEquals(data));
    });

    test(
      'round-trips large json with embedded base64 across blocks on web/js',
      () async {
        final data = Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'document': {'id': 'tpl'},
              'elements': List.generate(
                2000,
                (i) => {
                  'id': 'e$i',
                  'kind': 'image',
                  'image': {
                    'source':
                        'data:image/png;base64,${base64Encode(List.generate(1024, (j) => (i + j) & 0xff))}',
                  },
                  'transform': {
                    'x': i,
                    'y': i % 100,
                    'width': 20,
                    'height': 30,
                  },
                },
              ),
            }),
          ),
        );

        await expectWebRoundTrip(codecExpression: 'ZstdCodec()', data: data);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'round-trips large base64 literals with repeated markers on web/js',
      () async {
        const alphabet =
            'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        const marker =
            '--REPEATED-MATCH-MARKER-ABCDEFGHIJKLMNOPQRSTUVWXYZ-0123456789--';
        var state = 1;
        final buffer = StringBuffer();
        for (var chunk = 0; chunk < 32; chunk += 1) {
          for (var i = 0; i < 3000; i += 1) {
            state = (state * 1664525 + 1013904223) & 0xffffffff;
            buffer.write(alphabet[(state >> 16) & 63]);
          }
          buffer.write(marker);
        }
        final data = Uint8List.fromList(utf8.encode(buffer.toString()));

        await expectWebRoundTrip(codecExpression: 'ZstdCodec()', data: data);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test('round-trips utf8 json with high byte literals', () {
      final codec = ZstdCodec();
      final data = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'document': {'id': 'shipping_label', 'locale': 'zh-CN'},
            'elements': List.generate(
              2000,
              (i) => {
                'id': 'text_$i',
                'kind': 'text',
                'text': '目的地 台北 发货 标签 $i {{destination}} PLT-2048',
                'transform': {'x': i, 'y': i % 100, 'width': 90, 'height': 12},
              },
            ),
          }),
        ),
      );

      final compressed = codec.compress(data);
      final decoded = codec.decompress(compressed);
      expect(decoded, orderedEquals(data));
    });

    test('compressed block with varied literal lengths', () {
      final codec = ZstdCodec();
      // Create data with matches at varying distances
      final data = <int>[];
      for (var i = 0; i < 100; i++) {
        // Add literals of varying lengths
        for (var j = 0; j < (i % 10) + 1; j++) {
          data.add((i * 7 + j) % 256);
        }
        // Add a copy from earlier
        if (data.length > 100) {
          final copyLen = (i % 5) + 4;
          final offset = 50 + (i % 50);
          final src = data.length - offset;
          for (var k = 0; k < copyLen && src + k < data.length; k++) {
            data.add(data[src + k]);
          }
        }
      }

      final input = Uint8List.fromList(data);
      final compressed = codec.compress(input);
      final decoded = codec.decompress(compressed);
      expect(decoded, equals(input));
    });
  });

  group('ZSTD factory', () {
    test('creates codec from ZstdOptions', () {
      final options = ZstdOptions(
        level: 5,
        blockSize: 64 * 1024,
        checksum: true,
      );
      final codec = ZstdCodec.fromOptions(options);
      expect(codec.level, 5);
      expect(codec.blockSize, 64 * 1024);
      expect(codec.enableChecksum, true);
    });

    test('default options', () {
      final options = ZstdOptions();
      final codec = ZstdCodec.fromOptions(options);
      expect(codec.level, 3);
      expect(codec.blockSize, 128 * 1024);
      expect(codec.enableChecksum, false);
    });

    test('high compression levels (10-22) are supported', () {
      // Zstd supports levels 1-22, unlike other codecs limited to 1-9
      for (final level in [10, 15, 19, 22]) {
        final options = ZstdOptions(level: level);
        final codec = ZstdCodec.fromOptions(options);
        expect(codec.level, level);

        // Verify it actually compresses and decompresses correctly
        final data = Uint8List.fromList(
          List.generate(1000, (i) => 'Hello World! '.codeUnitAt(i % 13)),
        );
        final compressed = codec.compress(data);
        final restored = codec.decompress(compressed);
        expect(restored, equals(data));
      }
    });
  });

  group('ZSTD block validation', () {
    test('detects truncated compressed block', () {
      // Create valid compressed data, then truncate it
      final codec = ZstdCodec(maxDecompressedSize: null);
      final pattern = List<int>.generate(64, (i) => i);
      final data = Uint8List.fromList([
        ...pattern,
        for (var i = 0; i < 10; i++) ...pattern,
      ]);
      final compressed = codec.compress(data);

      // Truncate the compressed data (remove last 5 bytes)
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

    test('valid CLI-compressed data passes strict validation', () {
      // This tests that real zstd CLI output passes our stricter validation
      final codec = ZstdCodec(maxDecompressedSize: null);
      final compressed = readCodecFixture('zstd', 'html.zst');
      final expected = readDataFixture('html');

      // Should not throw with strict validation
      final decompressed = codec.decompress(compressed);
      expect(decompressed, orderedEquals(expected));
    });
  });

  group('ZSTD OOM hardening', () {
    test('rejects absurd contentSize in header', () {
      // Build a frame with a huge declared contentSize
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
      // Compress valid data, then try to decompress with tight limit
      // Frame includes contentSize, so early check throws ZstdFormatException
      final original = Uint8List.fromList(List.filled(1000, 65));
      final unlimited = ZstdCodec(maxDecompressedSize: null);
      final compressed = unlimited.compress(original);

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
      final data = Uint8List.fromList(List.filled(500, 66));
      final unlimited = ZstdCodec(maxDecompressedSize: null);
      final compressed = unlimited.compress(data);

      final limited = ZstdCodec(maxDecompressedSize: 1000);
      final decompressed = limited.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('unlimited mode works for trusted input', () {
      final data = Uint8List.fromList(List.generate(10000, (i) => i % 256));
      final codec = ZstdCodec(maxDecompressedSize: null);
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });

    test('default limit allows reasonable sizes', () {
      // Default is 256MB, test with small data
      final data = Uint8List.fromList(List.generate(1000, (i) => i % 256));
      final codec = ZstdCodec(); // Uses default limit
      final compressed = codec.compress(data);
      final decompressed = codec.decompress(compressed);
      expect(decompressed, equals(data));
    });
  });
}

Uint8List _buildSkippableFrame(final int magic, final List<int> payload) {
  final bytes = <int>[];
  bytes.addAll(_uint32LE(magic));
  bytes.addAll(_uint32LE(payload.length));
  bytes.addAll(payload);
  return Uint8List.fromList(bytes);
}

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
  final mutated = <int>[];
  mutated.addAll(frame.sublist(0, descriptorIndex));
  mutated.add(frame[descriptorIndex] | 0x01); // Set dictionaryIdFlag = 1
  mutated.add(0x42); // Fake dictionary ID byte
  mutated.addAll(frame.sublist(descriptorIndex + 1));
  return Uint8List.fromList(mutated);
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

  final sizeBytes = singleSegment
      ? [1, 2, 4, 8][contentSizeFlag]
      : [0, 2, 4, 8][contentSizeFlag];
  offset += sizeBytes;

  return offset;
}

/// Builds a minimal Zstd frame with a specified contentSize in header
/// Used to test OOM rejection of malicious headers
Uint8List _buildFrameWithContentSize(final int size) {
  final bytes = <int>[];

  // Magic number
  bytes.addAll(_uint32LE(zstdMagicNumber));

  // Frame header descriptor:
  // - single segment = 1 (bit 5)
  // - contentSizeFlag = 2 (4 bytes for size, bits 6-7)
  // Result: 0x20 | (2 << 6) = 0x20 | 0x80 = 0xA0
  bytes.add(0xA0);

  // Content size (4 bytes, little-endian)
  bytes.addAll(_uint32LE(size));

  // Empty last block header (raw block, size 0, last=true)
  // lastBlock=1, blockType=0 (raw), blockSize=0
  // header = 1 | (0 << 1) | (0 << 3) = 1
  bytes.add(0x01);
  bytes.add(0x00);
  bytes.add(0x00);

  return Uint8List.fromList(bytes);
}
