import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';
import 'package:libcompress/src/exceptions.dart';

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
          () => throw RangeError('oob'),
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
    });
  });
}

class _Bug extends Error {}
