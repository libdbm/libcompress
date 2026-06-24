import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// Raw LZ4 block API (no frame) — the form used by Parquet `LZ4_RAW`.
void main() {
  group('LZ4 raw block', () {
    final cases = <String, Uint8List>{
      'empty': Uint8List(0),
      'tiny': bytes([1, 2, 3]),
      'text': bytes('the quick brown fox jumps over the lazy dog'.codeUnits),
      'all byte values': bytes(List.generate(256, (i) => i)),
      'incompressible 4k': pseudoRandom(4096),
      // Larger than the default frame block size: a single raw block must still
      // represent the whole input (the frame format would split into blocks).
      'repetitive 1M': bytes(
          List.generate(1 << 20, (i) => 'the quick '.codeUnitAt(i % 10))),
      'incompressible 2M': pseudoRandom(2 << 20, 0xABCDEF),
    };

    for (final entry in cases.entries) {
      test('round-trips ${entry.key}', () {
        final codec = Lz4Codec();
        final block = codec.compressBlock(entry.value);
        expect(codec.decompressBlock(block), orderedEquals(entry.value));
      });
    }

    test('round-trips with HC mode (level 9)', () {
      final codec = Lz4Codec(level: 9);
      final data = bytes(
          List.generate(50000, (i) => 'the quick brown '.codeUnitAt(i % 16)));
      final block = codec.compressBlock(data);
      expect(codec.decompressBlock(block), orderedEquals(data));
    });

    test('emits a bare block, not a frame', () {
      final block = Lz4Codec().compressBlock(bytes('hello world'.codeUnits));
      // No LZ4 frame magic (0x184D2204, little-endian) at the start.
      expect(block.length, greaterThanOrEqualTo(4));
      final notFrame = !(block[0] == 0x04 &&
          block[1] == 0x22 &&
          block[2] == 0x4d &&
          block[3] == 0x18);
      expect(notFrame, isTrue);
    });

    test('compresses repetitive data well', () {
      final data =
          bytes(List.generate(10000, (i) => 'ab'.codeUnitAt(i % 2)));
      final block = Lz4Codec().compressBlock(data);
      expect(block.length, lessThan(data.length));
    });

    test('decompressBlock enforces maxSize', () {
      final data =
          bytes(List.generate(10000, (i) => 'ab'.codeUnitAt(i % 2)));
      final block = Lz4Codec().compressBlock(data);
      expect(() => Lz4Codec().decompressBlock(block, maxSize: 16),
          throwsA(isA<Object>()));
    });

    test('empty input yields empty block and empty output', () {
      final codec = Lz4Codec();
      expect(codec.compressBlock(Uint8List(0)), isEmpty);
      expect(codec.decompressBlock(Uint8List(0)), isEmpty);
    });
  });
}
