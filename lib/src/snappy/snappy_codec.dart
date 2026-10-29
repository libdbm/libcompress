import 'dart:typed_data';
import '../compression_codec.dart';
import '../util/expected_size.dart';
import '../compression_options.dart';
import 'snappy_encoder.dart';
import 'snappy_decoder.dart';
import 'snappy_stream_encoder.dart';
import 'snappy_stream_decoder.dart';

/// How Snappy data is packaged.
enum SnappyFormat {
  /// A single block with a varint length prefix and no checksum (Parquet
  /// `SNAPPY`).
  raw,

  /// The Snappy framing format: a stream identifier and CRC32C-checksummed
  /// chunks of at most 64 KB, compatible with snzip.
  framed,
}

/// Snappy compression codec
/// Native Dart implementation based on the Snappy specification
///
/// Supports the two formats of [SnappyFormat], chosen by [format]:
/// - [SnappyFormat.raw] (default): a single compressed block with a
///   varint-encoded size. Minimal overhead, suitable for small data.
/// - [SnappyFormat.framed]: a stream of checksummed chunks, compatible with
///   snzip and other tools. Better for large data.
///
/// Note: This is a synchronous codec that operates on complete byte arrays.
/// For stream-based processing, use [SnappyStreamCodec] instead.
final class SnappyCodec extends CompressionCodec {
  /// Maximum allowed uncompressed size for decompression
  final int? maxSize;

  /// How the data is packaged: a raw block or the framing format.
  final SnappyFormat format;

  /// Chunk size for the framed format (max 65536 per spec)
  final int chunkSize;

  /// Creates a Snappy codec. [format] selects a raw block (default) or the
  /// framing format, whose chunks hold at most [chunkSize] bytes of input.
  /// [maxSize] limits the decompressed output.
  SnappyCodec({
    this.maxSize = defaultMaxSize,
    this.format = SnappyFormat.raw,
    this.chunkSize = SnappyStreamEncoder.maxChunkSize,
  }) {
    validateOptionalPositive(maxSize, 'maxSize');
    validateRange(chunkSize, 1, SnappyStreamEncoder.maxChunkSize, 'chunkSize');
  }

  /// Creates a Snappy codec from compression options
  factory SnappyCodec.fromOptions(final SnappyOptions options) {
    return SnappyCodec(
      maxSize: options.maxSize,
      format: options.format,
      chunkSize: options.chunkSize,
    );
  }

  @override
  Uint8List compress(final Uint8List data) => switch (format) {
    SnappyFormat.raw => SnappyEncoder.compress(data),
    SnappyFormat.framed => SnappyStreamEncoder(
      chunkSize: chunkSize,
    ).compress(data),
  };

  @override
  Uint8List decompress(final Uint8List data, {final int? size}) {
    final cap = capFor(maxSize, size);
    final output = switch (format) {
      SnappyFormat.raw => SnappyDecoder.decompress(
        data,
        maxUncompressedSize: cap,
      ),
      SnappyFormat.framed => SnappyStreamDecoder(
        maxUncompressedSize: cap,
      ).decompress(data),
    };
    return checkSize(output, size, SnappyFormatException.new);
  }

  @override
  String get name => 'SNAPPY';
}

/// Snappy-specific compression options
///
/// ## Checksum Behavior
///
/// The inherited [checksum] setting is ignored: the framed format
/// ([SnappyFormat.framed]) always carries CRC32C checksums, as its
/// specification requires, and the raw format ([SnappyFormat.raw]) has none.
///
/// ## Compression Levels
///
/// Snappy does not support compression levels - it uses a fixed fast algorithm.
/// The [level] parameter is accepted for API consistency but is ignored.
class SnappyOptions extends CompressionOptions {
  /// How the data is packaged: a raw block (varint length + data, compact,
  /// no checksums) or the framing format (CRC32C-checksummed chunks,
  /// compatible with snzip).
  final SnappyFormat format;

  /// Chunk size for the framed format (max 65536 per spec)
  ///
  /// Only used for [SnappyFormat.framed]. Larger chunks are more efficient
  /// but use more memory. Default is the maximum (65536 bytes).
  final int chunkSize;

  /// Creates Snappy options with specified parameters
  SnappyOptions({
    super.level = 1, // Snappy has no levels - ignored
    super.checksum = true, // Ignored: see the class documentation
    super.maxSize = defaultMaxSize,
    this.format = SnappyFormat.raw,
    this.chunkSize = SnappyStreamEncoder.maxChunkSize,
  }) {
    validateRange(chunkSize, 1, SnappyStreamEncoder.maxChunkSize, 'chunkSize');
  }
}
