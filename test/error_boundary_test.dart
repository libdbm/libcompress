import 'package:test/test.dart';
import 'package:libcompress/src/exceptions.dart';
import 'package:libcompress/src/util/output_limit.dart';

void main() {
  group('guardFormat error allowlist', () {
    test('wraps input-validation errors as CompressionFormatException', () {
      expect(
        () => guardFormat<void>(
          () => throw StateError('eof'),
          GzipFormatException.new,
        ),
        throwsA(isA<GzipFormatException>()),
      );
      expect(
        () => guardFormat<void>(
          () => throw ArgumentError('bad'),
          GzipFormatException.new,
        ),
        throwsA(isA<GzipFormatException>()),
      );
      expect(
        () => guardFormat<void>(
          () => throw const FormatException('bad'),
          GzipFormatException.new,
        ),
        throwsA(isA<GzipFormatException>()),
      );
    });

    test('rethrows an existing CompressionFormatException unchanged', () {
      expect(
        () => guardFormat<void>(
          () => throw const Lz4FormatException('x'),
          GzipFormatException.new,
        ),
        throwsA(isA<Lz4FormatException>()),
      );
    });

    test('lets genuine library bugs propagate unwrapped', () {
      // An unexpected error (not an input-validation signal) must NOT be masked
      // as bad compressed data.
      expect(
        () => guardFormat<void>(
          () => throw UnimplementedError('bug'),
          GzipFormatException.new,
        ),
        throwsA(isA<UnimplementedError>()),
      );
      expect(
        () => guardFormat<void>(() => throw _Bug(), GzipFormatException.new),
        throwsA(isA<_Bug>()),
      );
      // An out-of-bounds access is a bug in the decoder, not bad input.
      expect(
        () => guardFormat<void>(
          () => throw RangeError('oob'),
          GzipFormatException.new,
        ),
        throwsA(isA<RangeError>()),
      );
      expect(
        () => guardFormat<void>(
          () => throw IndexError.withLength(5, 3),
          GzipFormatException.new,
        ),
        throwsA(isA<IndexError>()),
      );
    });

    test('a limit breach becomes a LimitException naming the cap', () {
      final named = isA<LimitException>()
          .having((final e) => e.limit, 'limit', 1000)
          .having((final e) => e.message, 'message', contains('1000'));
      // A buffer that ran out of remaining budget (here 400 of 1000).
      expect(
        () => guardFormat<void>(
          () => throw const OutputLimitException('exceeds maximum 400'),
          GzipFormatException.new,
          limit: 1000,
        ),
        throwsA(named),
      );
      // An inner check that named the remaining budget.
      expect(
        () => guardFormat<void>(
          () => throw LimitException(400),
          GzipFormatException.new,
          limit: 1000,
        ),
        throwsA(named),
      );
    });

    test('DEFLATE errors are GZIP errors', () {
      expect(const DeflateFormatException('x'), isA<GzipFormatException>());
    });
  });
}

class _Bug extends Error {}
