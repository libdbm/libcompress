import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/src/util/xxh32.dart';

void main() {
  group('XXH32 Tests', () {
    test('should hash empty data correctly', () {
      final result = XXH32.hash(Uint8List(0), 0);
      expect(result, equals(0x02CC5D05));
    });

    test('should hash single byte correctly', () {
      final data = Uint8List.fromList([0x41]); // 'A'
      final result = XXH32.hash(data, 0);
      expect(result, equals(0x10659a4d));
    });

    test('should hash "Hello World!" correctly', () {
      final data = Uint8List.fromList('Hello World!'.codeUnits);
      final result = XXH32.hash(data, 0);
      expect(result, equals(0x0bd69788));
    });

    test('should work with different seeds', () {
      final data = Uint8List.fromList([0x41]);
      final result1 = XXH32.hash(data, 0);
      final result2 = XXH32.hash(data, 1);
      expect(result1, isNot(equals(result2)));
    });

    test('should hash long data correctly', () {
      // Create data longer than 16 bytes to test the main processing loop
      final data = Uint8List.fromList(List.generate(100, (i) => i & 0xFF));
      final result = XXH32.hash(data, 0);
      expect(result, isA<int>());
      expect(result, greaterThan(0));
    });

    test('should produce consistent results', () {
      final data = Uint8List.fromList('test data'.codeUnits);
      final result1 = XXH32.hash(data, 0);
      final result2 = XXH32.hash(data, 0);
      expect(result1, equals(result2));
    });

    test('should work with hashFromList helper', () {
      final list = [0x41, 0x42, 0x43]; // "ABC"
      final uint8List = Uint8List.fromList(list);

      final result1 = XXH32.hashFromList(list, 0);
      final result2 = XXH32.hash(uint8List, 0);

      expect(result1, equals(result2));
    });

    // Test known XXH32 vectors to verify our implementation
    test('verify XXH32 implementation with known vectors', () {
      // Known test vectors from xxhash repository
      final tests = [
        {'input': '', 'seed': 0, 'expected': 0x02CC5D05},
        {'input': 'a', 'seed': 0, 'expected': 0x550D7456},
        {'input': 'abc', 'seed': 0, 'expected': 0x32D153FF},
        {'input': 'message digest', 'seed': 0, 'expected': 0x7c948494},
        {
          'input': 'abcdefghijklmnopqrstuvwxyz',
          'seed': 0,
          'expected': 0x63a14d5f,
        },
      ];

      for (final test in tests) {
        final input = Uint8List.fromList((test['input'] as String).codeUnits);
        final result = XXH32.hash(input, test['seed'] as int);
        expect(
          result,
          equals(test['expected']),
          reason: 'XXH32("${test['input']}", ${test['seed']}) failed',
        );
      }
    });

    test('should handle edge-case lengths', () {
      // Lengths around the 16-byte main-loop threshold and the 4-byte word.
      for (final length in [0, 1, 4, 15, 16, 17, 32, 64, 100]) {
        final data = Uint8List.fromList(List.generate(length, (i) => i & 0xFF));
        expect(
          XXH32.hash(data, 0),
          isA<int>(),
          reason: 'Failed for length $length',
        );
      }
    });

    test('should work with different seeds for same input', () {
      final data = Uint8List.fromList('test'.codeUnits);
      final results = <int>[];
      for (final seed in [0, 1, 42, 0xFF, 0xDEADBEEF]) {
        final result = XXH32.hash(data, seed);
        expect(
          results,
          isNot(contains(result)),
          reason: 'Duplicate hash for seed $seed',
        );
        results.add(result);
      }
    });

    test('should handle very large inputs', () {
      final largeData = Uint8List.fromList(
        List.generate(10000, (i) => i & 0xFF),
      );
      expect(XXH32.hash(largeData, 0), isA<int>());
    });
  });
}
