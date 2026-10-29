import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/src/util/xxh64.dart';
import 'package:libcompress/src/util/xxh64_web.dart' as web;

void main() {
  group('XXH64 web implementation', () {
    // The web version uses 32-bit halves; its masked arithmetic is exact on
    // the VM too, so it can be checked here against the native version.
    final data = Uint8List.fromList(
      List.generate(1100, (final i) => (i * 2654435761) >> 11 & 0xFF),
    );
    final seeds = [0, 1, 0x9E3779B1, 0x123456789AB, -1, -0x7FFFFFFFFFFF];

    test('matches the native hash at every length and seed', () {
      for (final seed in seeds) {
        for (final length in [
          ...List.generate(100, (final i) => i),
          1000,
          1100,
        ]) {
          final slice = Uint8List.sublistView(data, 0, length);
          expect(
            web.XXH64.hash(slice, seed),
            XXH64.hash(slice, seed),
            reason: 'length $length, seed $seed',
          );
          expect(
            web.XXH64.hashLow32(slice, seed),
            XXH64.hashLow32(slice, seed),
            reason: 'low 32, length $length, seed $seed',
          );
        }
      }
    });

    test('the sink matches the native hash for every chunking', () {
      for (final step in [1, 3, 7, 31, 32, 33, 100]) {
        final sink = web.Xxh64Sink(7);
        for (var start = 0; start < data.length; start += step) {
          final end = start + step < data.length ? start + step : data.length;
          sink.add(data, start, end - start);
        }
        expect(sink.digest(), XXH64.hash(data, 7), reason: 'step $step');
        expect(sink.digestLow32(), XXH64.hashLow32(data, 7));
      }
    });
  });

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
      final data = Uint8List.fromList(
        List.generate(100, (final i) => i & 0xFF),
      );
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
        final data = Uint8List.fromList(
          List.generate(length, (final i) => i & 0xFF),
        );
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
        List.generate(10000, (final i) => i & 0xFF),
      );
      final result = XXH64.hash(largeData, 0);
      expect(result, isA<int>());
    });
  });

  group('XXH64 reference vectors (xxhsum -H64)', () {
    // Prefixes of (i * 31 + 7) & 0xFF, covering every length class the
    // algorithm branches on: tail bytes, 4- and 8-byte tails, and 32-byte
    // stripes.
    final data = Uint8List.fromList(
      List.generate(1000, (final i) => (i * 31 + 7) & 0xFF),
    );
    const vectors = <int, int>{
      0: 0xef46db3751d8e999,
      1: 0xa96c7f0ce858bbb7,
      3: 0x56e6957632a487f9,
      4: 0xc60d15b1e3ff8f04,
      7: 0xafbefc3d6c6f9a8e,
      8: 0x3da5c7aa269683e0,
      31: 0x4a74f3a1a39ad4a1,
      32: 0x8d57d6a4671cc43d,
      33: 0x62c9fd21ed857664,
      63: 0x5c320a0d2707057f,
      64: 0x7bbabbc45729d17e,
      100: 0xefa0ad2d3e70c151,
      1000: 0x99594f4828043d35,
    };

    for (final entry in vectors.entries) {
      test('length ${entry.key}', () {
        final input = Uint8List.sublistView(data, 0, entry.key);
        expect(XXH64.hash(input), entry.value);
        expect(XXH64.hashLow32(input), entry.value & 0xFFFFFFFF);
        for (final piece in [1, 7, 32, 33]) {
          final sink = Xxh64Sink();
          for (var o = 0; o < input.length; o += piece) {
            final end = o + piece < input.length ? o + piece : input.length;
            sink.add(input, o, end - o);
          }
          expect(sink.digest(), entry.value, reason: 'pieces of $piece');
          expect(sink.digestLow32(), entry.value & 0xFFFFFFFF);
        }
      });
    }
  });
}
