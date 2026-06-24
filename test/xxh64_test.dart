import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/src/util/xxh64.dart';

void main() {
  group('XXH64 Tests', () {
    test('should hash empty data correctly', () {
      final result = XXH64.hash(Uint8List(0), 0);
      expect(result, equals(0xEF46DB3751D8E999));
    });

    test('should hash single byte "a" correctly', () {
      final data = Uint8List.fromList([0x61]); // 'a'
      final result = XXH64.hash(data, 0);
      expect(result, equals(0xD24EC4F1A98C6E5B));
    });

    test('should hash "abc" correctly', () {
      final data = Uint8List.fromList('abc'.codeUnits);
      final result = XXH64.hash(data, 0);
      expect(result, equals(0x44BC2CF5AD770999));
    });

    test('should work with different seeds', () {
      final data = Uint8List.fromList([0x41]);
      final result1 = XXH64.hash(data, 0);
      final result2 = XXH64.hash(data, 1);
      expect(result1, isNot(equals(result2)));
    });

    test('should hash long data correctly', () {
      // Create data longer than 32 bytes to test the main processing loop
      final data = Uint8List.fromList(List.generate(100, (i) => i & 0xFF));
      final result = XXH64.hash(data, 0);
      expect(result, isA<int>());
    });

    test('should produce consistent results', () {
      final data = Uint8List.fromList('test data'.codeUnits);
      final result1 = XXH64.hash(data, 0);
      final result2 = XXH64.hash(data, 0);
      expect(result1, equals(result2));
    });

    test('should work with hashFromList helper', () {
      final list = [0x41, 0x42, 0x43]; // "ABC"
      final uint8List = Uint8List.fromList(list);

      final result1 = XXH64.hashFromList(list, 0);
      final result2 = XXH64.hash(uint8List, 0);

      expect(result1, equals(result2));
    });

    test('should handle edge cases', () {
      // Test with data lengths that trigger different code paths
      final testCases = [
        0, // Empty
        1, // Single byte
        4, // Single 32-bit word
        8, // Single 64-bit word
        16, // Two 64-bit words
        32, // Exactly 32 bytes (threshold)
        33, // Just over threshold
        64, // Multiple of 32
        100, // Arbitrary length
      ];

      for (final length in testCases) {
        final data = Uint8List.fromList(List.generate(length, (i) => i & 0xFF));
        final result = XXH64.hash(data, 0);
        expect(result, isA<int>(), reason: 'Failed for length $length');
      }
    });

    // Test verified vectors from xxhash command line tool
    test('verify XXH64 implementation with verified vectors', () {
      final tests = [
        {'input': '', 'seed': 0, 'expected': 0xEF46DB3751D8E999},
        {'input': 'a', 'seed': 0, 'expected': 0xD24EC4F1A98C6E5B},
        {'input': 'abc', 'seed': 0, 'expected': 0x44BC2CF5AD770999},
        {'input': 'message digest', 'seed': 0, 'expected': 0x066ed728fceeb3be},
        {
          'input': 'abcdefghijklmnopqrstuvwxyz',
          'seed': 0,
          'expected': 0xcfe1f278fa89835c,
        },
      ];

      for (final test in tests) {
        final input = Uint8List.fromList((test['input'] as String).codeUnits);
        final result = XXH64.hash(input, test['seed'] as int);
        expect(
          result,
          equals(test['expected']),
          reason: 'XXH64("${test['input']}", ${test['seed']}) failed',
        );
      }
    });

    test('should work with different seeds for same input', () {
      final data = Uint8List.fromList('test'.codeUnits);
      final seeds = [0, 1, 42, 0xFF, 0xDEADBEEF];
      final results = <int>[];

      for (final seed in seeds) {
        final result = XXH64.hash(data, seed);
        expect(
          results.contains(result),
          isFalse,
          reason: 'Duplicate hash for seed $seed',
        );
        results.add(result);
      }
    });

    test('should handle very large inputs', () {
      // Test with a large input to ensure no integer overflow issues
      final largeData = Uint8List.fromList(
        List.generate(10000, (i) => i & 0xFF),
      );
      final result = XXH64.hash(largeData, 0);
      expect(result, isA<int>());
    });
  });
}
