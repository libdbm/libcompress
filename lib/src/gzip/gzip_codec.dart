import 'dart:typed_data';
import '../compression_codec.dart';
import '../util/expected_size.dart';
import '../compression_options.dart';
import 'gzip_frame.dart';

/// GZIP compression codec (RFC 1952)
///
/// Pure Dart implementation of GZIP compression using DEFLATE algorithm.
/// Compatible with standard gzip command-line tools.
///
/// Example:
/// ```dart
/// final codec = GzipCodec();
/// final compressed = codec.compress(data);
/// final decompressed = codec.decompress(compressed);
/// ```
final class GzipCodec extends CompressionCodec {
  /// Compression level (1-9)
  final int level;

  /// Optional filename to embed in GZIP header
  final String? filename;

  /// Optional comment to embed in GZIP header
  final String? comment;

  /// MTIME written into the header, in seconds since the epoch (0 = not
  /// set). The default 0 makes output depend only on the input.
  final int mtime;

  /// Maximum decompressed size (prevents OOM on malicious input)
  /// Set to null for unlimited (not recommended for untrusted input)
  final int? maxSize;

  /// Creates a GZIP codec with specified options
  ///
  /// [level] controls compression quality vs speed (1=fast, 9=best).
  /// [filename] and [comment] are optional metadata fields; GZIP ends each at
  /// a NUL, so they may not contain one.
  /// [maxSize] limits output to prevent OOM attacks.
  /// Throws [ArgumentError] if level is not between 1 and 9, or [filename] or
  /// [comment] contains a NUL character.
  GzipCodec({
    this.level = 6,
    this.filename,
    this.comment,
    this.mtime = 0,
    this.maxSize = defaultMaxSize,
  }) {
    validateLevel(level, 1, 9);
    validateOptionalPositive(maxSize, 'maxSize');
    validateHeader(mtime, filename, comment);
  }

  /// Creates a GZIP codec from compression options
  factory GzipCodec.fromOptions(final GzipOptions options) {
    return GzipCodec(
      level: options.level,
      filename: options.filename,
      comment: options.comment,
      mtime: options.mtime,
      maxSize: options.maxSize,
    );
  }

  @override
  Uint8List compress(final Uint8List data) {
    return GzipFrame.compress(
      data,
      level: level,
      filename: filename,
      comment: comment,
      mtime: mtime,
    );
  }

  @override
  Uint8List decompress(final Uint8List data, {final int? size}) {
    return checkSize(
      GzipFrame.decompress(data, maxSize: capFor(maxSize, size)),
      size,
      GzipFormatException.new,
    );
  }

  @override
  String get name => 'GZIP';
}

/// GZIP-specific compression options
///
/// The inherited [checksum] setting is ignored: every GZIP member carries a
/// CRC-32 of its content.
class GzipOptions extends CompressionOptions {
  /// Optional filename to store in GZIP header
  final String? filename;

  /// Optional comment to store in GZIP header
  final String? comment;

  /// MTIME written into the header, in seconds since the epoch (0 = not
  /// set). The default 0 makes output depend only on the input.
  final int mtime;

  /// Creates GZIP options with specified parameters
  ///
  /// [level] must be between 1 and 9.
  /// Throws [ArgumentError] if level is not between 1 and 9.
  GzipOptions({
    super.level = 6,
    super.checksum = true,
    super.maxSize,
    this.filename,
    this.comment,
    this.mtime = 0,
  }) {
    validateLevel(level, 1, 9);
    validateHeader(mtime, filename, comment);
  }
}

/// Checks the header fields shared by [GzipCodec], [GzipOptions] and
/// `GzipStreamCodec`: MTIME fits 32 bits, and FNAME and FCOMMENT, which GZIP
/// ends at a NUL, contain none.
void validateHeader(
  final int mtime,
  final String? filename,
  final String? comment,
) {
  validateRange(mtime, 0, 0xFFFFFFFF, 'mtime');
  for (final (name, value) in [('filename', filename), ('comment', comment)]) {
    if (value != null && value.contains('\u0000')) {
      throw ArgumentError.value(value, name, 'Must not contain a NUL');
    }
  }
}
