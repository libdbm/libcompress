import 'dart:typed_data';
import '../compression_codec.dart';
import '../compression_options.dart';
import 'gzip_frame.dart';

/// Default maximum decompressed size for GZIP (256 MB)
const int gzipDefaultMaxDecompressedSize = 256 * 1024 * 1024;

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
class GzipCodec extends CompressionCodec {
  /// Compression level (1-9)
  final int level;

  /// Optional filename to embed in GZIP header
  final String? filename;

  /// Optional comment to embed in GZIP header
  final String? comment;

  /// Maximum decompressed size (prevents OOM on malicious input)
  /// Set to null for unlimited (not recommended for untrusted input)
  final int? maxDecompressedSize;

  /// Creates a GZIP codec with specified options
  ///
  /// [level] controls compression quality vs speed (1=fast, 9=best).
  /// [filename] and [comment] are optional metadata fields.
  /// [maxDecompressedSize] limits output to prevent OOM attacks.
  /// Throws [ArgumentError] if level is not between 1 and 9.
  GzipCodec({
    this.level = 6,
    this.filename,
    this.comment,
    this.maxDecompressedSize = gzipDefaultMaxDecompressedSize,
  }) {
    validateLevel(level, 1, 9);
    validateOptionalPositive(maxDecompressedSize, 'maxDecompressedSize');
  }

  /// Creates a GZIP codec from compression options
  factory GzipCodec.fromOptions(GzipOptions options) {
    return GzipCodec(
      level: options.level,
      filename: options.filename,
      comment: options.comment,
      maxDecompressedSize: options.maxDecompressedSize,
    );
  }

  @override
  Uint8List compress(Uint8List data) {
    return GzipFrame.compress(
      data,
      level: level,
      filename: filename,
      comment: comment,
    );
  }

  @override
  Uint8List decompress(Uint8List data) {
    return GzipFrame.decompress(data, maxSize: maxDecompressedSize);
  }

  @override
  String get name => 'GZIP';

  @override
  bool supports(final CodecMode mode) =>
      mode == CodecMode.block || mode == CodecMode.stream;
}

/// GZIP-specific compression options
class GzipOptions extends CompressionOptions {
  /// Optional filename to store in GZIP header
  final String? filename;

  /// Optional comment to store in GZIP header
  final String? comment;

  /// Creates GZIP options with specified parameters
  ///
  /// [level] must be between 1 and 9.
  /// Throws [ArgumentError] if level is not between 1 and 9.
  GzipOptions({
    super.level = 6,
    super.checksum = true,
    super.maxDecompressedSize,
    this.filename,
    this.comment,
  }) {
    if (level < 1 || level > 9) {
      throw ArgumentError.value(level, 'level', 'Must be between 1 and 9');
    }
  }
}

