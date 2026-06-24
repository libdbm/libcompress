import 'dart:typed_data';
import '../compression_codec.dart';
import '../compression_options.dart';
import 'snappy_encoder.dart';
import 'snappy_decoder.dart';
import 'snappy_stream_encoder.dart';
import 'snappy_stream_decoder.dart';

/// Snappy compression codec
/// Native Dart implementation based on the Snappy specification
///
/// Supports two output formats controlled by the [framing] parameter:
/// - Raw block format (framing: false): Single compressed block with
///   varint-encoded size. Minimal overhead, suitable for small data.
/// - Framing format (framing: true): Stream of chunks with checksums,
///   compatible with snzip and other tools. Better for large data.
///
/// Note: This is a synchronous codec that operates on complete byte arrays.
/// For stream-based processing, use [SnappyStreamCodec] instead.
class SnappyCodec extends CompressionCodec {
  /// Maximum allowed uncompressed size for decompression
  final int? maxSize;

  /// Use framing format instead of raw block format
  ///
  /// When true, output uses the Snappy framing format (stream identifier +
  /// checksummed chunks), compatible with snzip CLI and other tools.
  /// When false, output uses raw Snappy block format (just compressed data).
  final bool framing;

  /// Chunk size for framing format (max 65536 per spec)
  final int chunkSize;

  SnappyCodec({
    this.maxSize = snappyDefaultMaxDecompressedSize,
    this.framing = false,
    this.chunkSize = SnappyStreamEncoder.maxChunkSize,
  }) {
    validateOptionalPositive(maxSize, 'maxSize');
    validateRange(chunkSize, 1, SnappyStreamEncoder.maxChunkSize, 'chunkSize');
  }

  /// Creates a Snappy codec from compression options
  factory SnappyCodec.fromOptions(final SnappyOptions options) {
    return SnappyCodec(
      maxSize: options.maxSize,
      framing: options.framing,
      chunkSize: options.chunkSize,
    );
  }

  @override
  Uint8List compress(final Uint8List data) {
    if (framing) {
      final encoder = SnappyStreamEncoder(chunkSize: chunkSize);
      return encoder.compress(data);
    }
    return SnappyEncoder.compress(data);
  }

  @override
  Uint8List decompress(final Uint8List data) {
    if (framing) {
      final decoder = SnappyStreamDecoder(maxUncompressedSize: maxSize);
      return decoder.decompress(data);
    }
    return SnappyDecoder.decompress(data, maxUncompressedSize: maxSize);
  }

  @override
  String get name => 'SNAPPY';

  @override
  bool supports(final CodecMode mode) =>
      mode == CodecMode.block || mode == CodecMode.stream;
}

/// Snappy-specific compression options
///
/// ## Checksum Behavior
///
/// The inherited [checksum] parameter from [CompressionOptions] only affects
/// the **framing format** (`framing: true`). When using framing format,
/// checksums (CRC32C) are always included per the Snappy framing specification.
///
/// For **raw block format** (`framing: false`), no checksums are included
/// regardless of the [checksum] setting - this is inherent to the raw format.
///
/// ## Compression Levels
///
/// Snappy does not support compression levels - it uses a fixed fast algorithm.
/// The [level] parameter is accepted for API consistency but is ignored.
class SnappyOptions extends CompressionOptions {
  /// Maximum allowed uncompressed size for decompression
  ///
  /// Protects against decompression bombs. Defaults to 256MB.
  /// Set lower for untrusted input.
  final int? maxSize;

  /// Use framing format instead of raw block format
  ///
  /// When true, output uses the Snappy framing format with CRC32C checksums,
  /// stream identifiers, and chunk headers. Compatible with snzip CLI.
  ///
  /// When false, output uses raw Snappy block format (varint length + data).
  /// More compact but no checksums or tool compatibility.
  final bool framing;

  /// Chunk size for framing format (max 65536 per spec)
  ///
  /// Only used when [framing] is true. Larger chunks are more efficient
  /// but use more memory. Default is the maximum (65536 bytes).
  final int chunkSize;

  /// Creates Snappy options with specified parameters
  SnappyOptions({
    super.level = 1, // Snappy has no levels - ignored
    super.checksum = true, // Only affects framing format
    this.maxSize = snappyDefaultMaxDecompressedSize,
    this.framing = false,
    this.chunkSize = SnappyStreamEncoder.maxChunkSize,
  });
}
