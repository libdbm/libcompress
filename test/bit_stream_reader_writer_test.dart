import 'dart:typed_data';
import 'package:libcompress/src/gzip/deflate_common.dart';
import 'package:libcompress/src/gzip/deflate_reader.dart';
import 'package:libcompress/src/gzip/huffman_tables.dart';
import 'package:libcompress/src/util/bit_stream.dart';
import 'package:test/test.dart';

void main() {
  group('BitStream', () {
    test('round-trip test with various bit lengths', () {
      final writer = BitStreamWriter();

      // A list of (value, bitCount) pairs to write.
      final testData = [
        [5, 3], // 101
        [10, 4], // 1010
        [2, 2], // 10
        [31, 5], // 11111
        [0, 1], // 0
        [1, 1], // 1
        [12345, 14],
        [67890, 17],
      ];

      // Write all test data to the stream.
      for (final item in testData) {
        writer.writeBits(item[0], item[1]);
      }

      final Uint8List bytes = writer.toBytes();
      final reader = DeflateReader(bytes);

      // Read the data back and verify it (reads are at most 16 bits).
      for (final item in testData) {
        final value = item[0];
        final bitCount = item[1];
        final readValue = bitCount > 16
            ? reader.read(16) | (reader.read(bitCount - 16) << 16)
            : reader.read(bitCount);
        expect(
          readValue,
          equals(value),
          reason: 'Failed on $bitCount-bit value $value',
        );
      }
    });

    test('write and read a single byte', () {
      final writer = BitStreamWriter();
      writer.writeBits(0xAB, 8);

      final bytes = writer.toBytes();
      expect(bytes, equals(Uint8List.fromList([0xAB])));

      final reader = DeflateReader(bytes);
      expect(reader.read(8), equals(0xAB));
    });

    test('write and read across byte boundaries', () {
      final writer = BitStreamWriter();
      // Write 4 bits, then 8 bits. The 8-bit value will cross a byte boundary.
      writer.writeBits(0xF, 4); // 1111
      writer.writeBits(0xA5, 8); // 10100101

      final bytes = writer.toBytes();
      // Expected bytes:
      // First byte: lower 4 bits of 0xA5 + 4 bits of 0xF -> 01011111 -> 0x5F
      // Second byte: upper 4 bits of 0xA5 -> 1010 -> 0x0A
      expect(bytes, equals(Uint8List.fromList([0x5F, 0x0A])));

      final reader = DeflateReader(bytes);
      expect(reader.read(4), equals(0xF));
      expect(reader.read(8), equals(0xA5));
    });
  });

  group('DeflateReader', () {
    test('rewind restores a checkpoint, including a bit offset', () {
      final reader = DeflateReader(Uint8List.fromList([0x5F, 0x0A, 0xC3]));
      expect(reader.read(3), 0x7);
      final mark = reader.consumed;
      expect(mark, 3);
      final first = reader.read(9);
      reader.read(5);
      reader.rewind(mark);
      expect(reader.read(9), first);
    });

    test('starts at a byte and bit offset within a larger buffer', () {
      final data = Uint8List.fromList([0xFF, 0x5F, 0x0A]);
      final reader = DeflateReader(data, start: 1, bit: 4);
      expect(reader.read(8), 0xA5);
      expect(reader.consumed, 12);
    });

    test('running out is a format error for complete input', () {
      final reader = DeflateReader(Uint8List.fromList([0xAB]));
      reader.read(4);
      expect(() => reader.read(8), throwsA(isA<DeflateFormatException>()));
    });

    test('running out signals more input for partial input', () {
      final reader = DeflateReader(Uint8List.fromList([0xAB]), partial: true);
      reader.read(4);
      expect(() => reader.read(8), throwsStateError);
    });

    test('a code split across the available input waits for more', () {
      // Literal 0xFF has the 9-bit fixed code 111111111; give only 8 bits.
      final reader = DeflateReader(Uint8List.fromList([0xFF]), partial: true);
      expect(() => reader.decode(fixedLiteralDecoder), throwsStateError);
      final whole = DeflateReader(Uint8List.fromList([0xFF, 0x01]));
      expect(whole.decode(fixedLiteralDecoder), 0xFF);
    });

    test('take returns aligned bytes and rejects overruns', () {
      final reader = DeflateReader(Uint8List.fromList([1, 2, 3, 4]));
      reader.read(3);
      reader.align();
      expect(reader.take(2), [2, 3]);
      expect(reader.available, 1);
      expect(() => reader.take(2), throwsA(isA<DeflateFormatException>()));
    });
  });
}
