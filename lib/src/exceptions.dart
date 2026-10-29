import 'util/output_limit.dart';

/// Base exception class for compression format errors
///
/// This is the common base class for all compression-related format exceptions.
/// Each codec has a specific subclass for codec-specific error handling:
/// - [Lz4FormatException] for LZ4 format errors
/// - [GzipFormatException] for GZIP format errors
/// - [ZstdFormatException] for Zstandard format errors
/// - [SnappyFormatException] for Snappy format errors
///
/// All subclasses extend [FormatException] for consistency with Dart's
/// standard library conventions.
///
/// Example:
/// ```dart
/// try {
///   final data = codec.decompress(compressed);
/// } on CompressionFormatException catch (e) {
///   print('Compression error: ${e.message}');
/// }
/// ```
abstract class CompressionFormatException extends FormatException {
  /// Creates a compression format exception with the given [message].
  const CompressionFormatException(super.message);
}

/// Thrown when decoding would exceed a configured size limit: the codec's
/// `maxSize` (cumulative across concatenated frames or members), an expected
/// `size` passed to `decompress`, or a stream's `maxBufferSize`.
///
/// It is a [CompressionFormatException], so existing handlers still catch it;
/// catch it first to tell a limit breach from corrupt data.
class LimitException extends CompressionFormatException {
  /// Creates a limit exception for the configured [limit] in bytes.
  LimitException(this.limit, [final String? message])
    : super(message ?? 'Decompressed size exceeds the limit of $limit bytes');

  /// The configured limit, in bytes, that decoding would have exceeded.
  final int limit;

  @override
  String toString() => 'LimitException: $message';
}

/// Runs [body], converting the *input-validation* errors a decoder throws on
/// malformed data into a codec-specific [CompressionFormatException] via [wrap]:
/// `StateError` (e.g. exhausted bit reader), `ArgumentError` other than
/// `RangeError`/`IndexError` (e.g. an out-of-window back-reference), and plain
/// `FormatException`.
///
/// A size-limit breach ([OutputLimitException], or a [LimitException] naming
/// the budget left) becomes a [LimitException] naming the configured [limit],
/// when one is given.
///
/// Other errors are NOT caught: `RangeError`/`IndexError` (an out-of-bounds
/// access is a decoder bug, since decoders check input bounds explicitly),
/// `TypeError`, `NoSuchMethodError`, `AssertionError`, generic `Error`, etc.
/// Masking them as "bad compressed data" would destroy the signal, so they
/// propagate unchanged for callers and observability to see.
T guardFormat<T>(
  final T Function() body,
  final CompressionFormatException Function(String message) wrap, {
  final int? limit,
}) {
  try {
    return body();
  } on LimitException {
    if (limit == null) rethrow;
    throw LimitException(limit);
  } on CompressionFormatException {
    rethrow;
  } on FormatException catch (e) {
    throw wrap(e.message.toString());
  } on RangeError {
    rethrow;
  } on ArgumentError catch (e) {
    throw wrap(e.message?.toString() ?? e.toString());
  } on StateError catch (e) {
    throw wrap(e.message);
  } on OutputLimitException catch (e) {
    throw limit == null ? wrap(e.message) : LimitException(limit);
  }
}

/// Exception thrown when invalid LZ4 data is encountered
class Lz4FormatException extends CompressionFormatException {
  /// Creates an LZ4 format exception with the given [message].
  const Lz4FormatException(super.message);

  @override
  String toString() => 'Lz4FormatException: $message';
}

/// Exception thrown when invalid GZIP data is encountered
class GzipFormatException extends CompressionFormatException {
  /// Creates a GZIP format exception with the given [message].
  const GzipFormatException(super.message);

  @override
  String toString() => 'GzipFormatException: $message';
}

/// Exception thrown during DEFLATE compression/decompression. DEFLATE is the
/// body of a GZIP member, so a DEFLATE error is also a [GzipFormatException].
class DeflateFormatException extends GzipFormatException {
  /// Creates a DEFLATE format exception with the given [message].
  const DeflateFormatException(super.message);

  @override
  String toString() => 'DeflateFormatException: $message';
}

/// Exception thrown when invalid Zstandard data is encountered
class ZstdFormatException extends CompressionFormatException {
  /// Creates a Zstandard format exception with the given [message].
  const ZstdFormatException(super.message);

  @override
  String toString() => 'ZstdFormatException: $message';
}

/// Exception thrown when invalid Snappy data is encountered
class SnappyFormatException extends CompressionFormatException {
  /// Creates a Snappy format exception with the given [message].
  const SnappyFormatException(super.message);

  @override
  String toString() => 'SnappyFormatException: $message';
}

/// Exception thrown when no-op "compressed" data does not have the expected
/// length.
class NoopFormatException extends CompressionFormatException {
  /// Creates a no-op format exception with the given [message].
  const NoopFormatException(super.message);

  @override
  String toString() => 'NoopFormatException: $message';
}
