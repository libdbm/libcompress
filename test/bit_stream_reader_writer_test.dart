import 'dart:typed_data';
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
      final reader = BitStreamReader(bytes);

      // Read the data back and verify it.
      for (final item in testData) {
        final value = item[0];
        final bitCount = item[1];
        final readValue = reader.readBits(bitCount);
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

      final reader = BitStreamReader(bytes);
      expect(reader.readBits(8), equals(0xAB));
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

      final reader = BitStreamReader(bytes);
      expect(reader.readBits(4), equals(0xF));
      expect(reader.readBits(8), equals(0xA5));
    });
  });

  group('BitStreamReader position and seek', () {
    test('position reports byte and bit offsets', () {
      final reader = BitStreamReader(Uint8List.fromList([0xAB, 0xCD]));
      expect(reader.position.byte, equals(0));
      expect(reader.position.bit, equals(0));
      reader.readBits(3);
      expect(reader.position.byte, equals(0));
      expect(reader.position.bit, equals(3));
      reader.readBits(8); // crosses into next byte
      expect(reader.position.byte, equals(1));
      expect(reader.position.bit, equals(3));
    });

    test('seek restores a captured position', () {
      final reader = BitStreamReader(Uint8List.fromList([0x5F, 0x0A, 0xC3]));
      reader.readBits(4);
      final mark = reader.position;
      final expected = reader.readBits(8);
      reader.seek(mark);
      expect(reader.readBits(8), equals(expected));
    });

    test('seek invalidates the peek-cache', () {
      final reader = BitStreamReader(Uint8List.fromList([0xFF, 0x00]));
      final mark = reader.position;
      reader.readBits(4, reuseLast: false); // populate cache
      reader.seek(mark);
      // After seek, a reuseLast read must reflect the real stream, not stale bits.
      expect(reader.readBits(4, reuseLast: true), equals(0xF));
    });

    test('seek out of range throws', () {
      final reader = BitStreamReader(Uint8List.fromList([0x01, 0x02]));
      expect(() => reader.seek(const BitPosition(3, 0)), throwsArgumentError);
      expect(() => reader.seek(const BitPosition(2, 1)), throwsArgumentError);
      expect(() => reader.seek(const BitPosition(0, 8)), throwsArgumentError);
    });
  });

  group('BitStreamReader window', () {
    test('reads only within [start, end) with relative positions', () {
      final data = Uint8List.fromList([0xFF, 0xAB, 0xCD, 0xFF]);
      final reader = BitStreamReader(data, start: 1, end: 3);
      expect(reader.position.byte, equals(0));
      expect(reader.readBits(8), equals(0xAB));
      expect(reader.readBits(8), equals(0xCD));
      expect(reader.isEndOfStream, isTrue);
    });

    test('reading past the window end throws', () {
      final data = Uint8List.fromList([0xAB, 0xCD]);
      final reader = BitStreamReader(data, start: 0, end: 1);
      expect(reader.readBits(8), equals(0xAB));
      expect(() => reader.readBits(1), throwsStateError);
    });

    test('reads a window over a plain List<int> without copying source', () {
      final List<int> data = [0x11, 0x5F, 0x0A, 0x22];
      final reader = BitStreamReader(data, start: 1, end: 3);
      expect(reader.readBits(4), equals(0xF));
      expect(reader.readBits(8), equals(0xA5));
    });
  });
}
