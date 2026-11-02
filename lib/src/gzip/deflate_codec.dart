import 'dart:typed_data';
import '../compression_codec.dart';
import '../compression_options.dart';
import '../exceptions.dart';
import '../util/expected_size.dart';
import 'deflate_decoder.dart';
import 'deflate_encoder.dart';

/// Raw DEFLATE compression codec (RFC 1951)
///
/// DEFLATE blocks with no header or trailer: the form ZIP entries, PNG's
/// zlib payload (after its two-byte header) and HTTP's raw `deflate` use.
/// For a GZIP member, with its CRC-32, use [GzipCodec].
///
/// Raw DEFLATE carries no checksum, so corruption that still decodes is not
/// detected here; check the container's checksum, such as a ZIP entry's
/// CRC-32, against [Crc32]. Bytes after the final block are rejected.
///
/// Example:
/// ```dart
/// final codec = DeflateCodec();
/// final compressed = codec.compress(data);
/// final decompressed = codec.decompress(compressed, size: data.length);
/// ```
final class DeflateCodec extends CompressionCodec {
  /// Compression level (1-9)
  final int level;

  /// Maximum decompressed size (prevents OOM on malicious input)
  /// Set to null for unlimited (not recommended for untrusted input)
  final int? maxSize;

  /// Creates a raw DEFLATE codec with specified options
  ///
  /// [level] controls compression quality vs speed (1=fast, 9=best).
  /// [maxSize] limits output to prevent OOM attacks.
  /// Throws [ArgumentError] if level is not between 1 and 9.
  DeflateCodec({this.level = 6, this.maxSize = defaultMaxSize}) {
    validateLevel(level, 1, 9);
    validateOptionalPositive(maxSize, 'maxSize');
  }

  /// Creates a raw DEFLATE codec from compression options
  factory DeflateCodec.fromOptions(final DeflateOptions options) {
    return DeflateCodec(level: options.level, maxSize: options.maxSize);
  }

  @override
  Uint8List compress(final Uint8List data) {
    return DeflateEncoder(level: level).compress(data);
  }

  @override
  Uint8List decompress(final Uint8List data, {final int? size}) {
    final decoder = DeflateDecoder(maxSize: capFor(maxSize, size), hint: size);
    final (output, consumed) = decoder.decompressWithPosition(data);
    if (consumed != data.length) {
      throw DeflateFormatException(
        '${data.length - consumed} bytes after the final DEFLATE block',
      );
    }
    return checkSize(output, size, DeflateFormatException.new);
  }

  @override
  String get name => 'DEFLATE';
}

/// Raw DEFLATE compression options
///
/// The inherited [checksum] setting is ignored: raw DEFLATE has no checksum.
class DeflateOptions extends CompressionOptions {
  /// Creates raw DEFLATE options with specified parameters
  ///
  /// [level] must be between 1 and 9.
  /// Throws [ArgumentError] if level is not between 1 and 9.
  DeflateOptions({super.level = 6, super.checksum = false, super.maxSize}) {
    validateLevel(level, 1, 9);
  }
}
