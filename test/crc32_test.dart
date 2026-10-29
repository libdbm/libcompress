import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/src/util/crc32.dart';

void main() {
  group('CRC32', () {
    test('empty data', () {
      final data = Uint8List(0);
      final crc = Crc32.hash(data);
      expect(crc, equals(0));
    });

    test('single byte', () {
      final data = Uint8List.fromList([0x61]); // 'a'
      final crc = Crc32.hash(data);
      expect(crc, equals(0xE8B7BE43));
    });

    test('hello world', () {
      final data = Uint8List.fromList('hello world'.codeUnits);
      final crc = Crc32.hash(data);
      // Known CRC32 value for "hello world"
      expect(crc, equals(0x0D4A1185));
    });

    test('sequential bytes', () {
      final data = Uint8List.fromList(List.generate(256, (final i) => i));
      final crc = Crc32.hash(data);
      // Known CRC32 value for 0x00-0xFF
      expect(crc, equals(0x29058C73));
    });

    test('repeated pattern', () {
      final data = Uint8List.fromList(List.filled(100, 0x42)); // 'B' repeated
      final crc = Crc32.hash(data);
      expect(crc, isNonZero);
    });

    test('all zeros', () {
      final data = Uint8List(1000);
      final crc = Crc32.hash(data);
      // CRC32 of 1000 zero bytes
      expect(crc, isNonZero);
    });

    test('hashFromList', () {
      final list = [72, 101, 108, 108, 111]; // "Hello"
      final crc = Crc32.hashFromList(list);
      expect(crc, equals(0xF7D18982));
    });

    test('incremental update', () {
      final data1 = Uint8List.fromList('hello'.codeUnits);
      final data2 = Uint8List.fromList(' world'.codeUnits);

      // Compute in one go
      final combined = Uint8List.fromList('hello world'.codeUnits);
      final expected = Crc32.hash(combined);

      // Compute incrementally
      var crc = 0xFFFFFFFF;
      crc = Crc32.update(data1, crc);
      crc = Crc32.update(data2, crc);
      final result = crc ^ 0xFFFFFFFF;

      expect(result, equals(expected));
    });

    test('update multiple chunks', () {
      final chunks = [
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4, 5, 6]),
        Uint8List.fromList([7, 8, 9]),
      ];

      // Compute incrementally
      var crc = 0xFFFFFFFF;
      for (final chunk in chunks) {
        crc = Crc32.update(chunk, crc);
      }
      final incremental = crc ^ 0xFFFFFFFF;

      // Compute in one go
      final all = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9]);
      final direct = Crc32.hash(all);

      expect(incremental, equals(direct));
    });

    test('deterministic', () {
      final data = Uint8List.fromList('test data'.codeUnits);
      final crc1 = Crc32.hash(data);
      final crc2 = Crc32.hash(data);
      expect(crc1, equals(crc2));
    });

    test('different data produces different crc', () {
      final data1 = Uint8List.fromList('data1'.codeUnits);
      final data2 = Uint8List.fromList('data2'.codeUnits);
      final crc1 = Crc32.hash(data1);
      final crc2 = Crc32.hash(data2);
      expect(crc1, isNot(equals(crc2)));
    });

    test('large data', () {
      final data = Uint8List(1024 * 1024); // 1MB
      for (var i = 0; i < data.length; i++) {
        data[i] = i & 0xFF;
      }
      final crc = Crc32.hash(data);
      expect(crc, isNonZero);
    });
  });
}
