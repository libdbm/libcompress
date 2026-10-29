import 'package:libcompress/src/util/huffman.dart';
import 'package:test/test.dart';

/// Fibonacci frequencies: the worst case for code length, giving an
/// unconstrained Huffman tree of depth `count - 1`.
List<int> fibonacci(final int count) {
  final values = <int>[1, 1];
  while (values.length < count) {
    values.add(values[values.length - 1] + values[values.length - 2]);
  }
  return values.sublist(0, count);
}

/// Sum of 2^(maxBits - length) over coded symbols; equals 2^maxBits exactly
/// for a complete prefix code, and exceeds it for an over-subscribed one.
int kraft(final List<int> lengths, final int maxBits) {
  var sum = 0;
  for (final length in lengths) {
    if (length > 0) sum += 1 << (maxBits - length);
  }
  return sum;
}

void main() {
  group('computeLimitedCodeLengths', () {
    for (final maxBits in [7, 11, 15]) {
      test('complete and within $maxBits bits for deep trees', () {
        for (var count = 16; count <= 40; count++) {
          final lengths = HuffmanTreeBuilder.computeLimitedCodeLengths(
            fibonacci(count),
            maxBits,
          );
          expect(
            lengths.every((final length) => length > 0 && length <= maxBits),
            isTrue,
            reason: 'count $count',
          );
          expect(kraft(lengths, maxBits), 1 << maxBits, reason: 'count $count');
        }
      });
    }

    test('keeps the optimal lengths when no limiting is needed', () {
      final lengths = HuffmanTreeBuilder.computeLimitedCodeLengths([
        8,
        4,
        2,
        1,
        1,
      ], 15);
      expect(lengths, [1, 2, 3, 4, 4]);
    });

    test('leaves unused symbols at length 0', () {
      final lengths = HuffmanTreeBuilder.computeLimitedCodeLengths([
        0,
        5,
        0,
        3,
        0,
      ], 15);
      expect(lengths, [0, 1, 0, 1, 0]);
    });

    test('gives a single symbol a 1-bit code', () {
      expect(HuffmanTreeBuilder.computeLimitedCodeLengths([0, 9, 0], 15), [
        0,
        1,
        0,
      ]);
    });

    test('rejects an alphabet that cannot fit in maxBits', () {
      expect(
        () => HuffmanTreeBuilder.computeLimitedCodeLengths(
          List<int>.filled(9, 1),
          3,
        ),
        throwsArgumentError,
      );
    });
  });
}
