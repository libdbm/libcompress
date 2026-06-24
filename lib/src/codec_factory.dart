import 'compression_codec.dart';
import 'compression_stream_codec.dart';
import 'noop/noop_codec.dart';
import 'noop/noop_stream_codec.dart';
import 'snappy/snappy_codec.dart';
import 'snappy/snappy_stream_codec.dart';
import 'gzip/gzip_codec.dart';
import 'gzip/gzip_stream_codec.dart';
import 'lz4/lz4_codec.dart';
import 'lz4/lz4_stream_codec.dart';
import 'zstd/zstd_codec.dart';
import 'zstd/zstd_stream_codec.dart';

/// Supported compression codec types
enum CodecType {
  noop,
  snappy,
  gzip,
  lz4,
  zstd;

  /// Parse a string to a CodecType
  static CodecType parse(final String value) {
    return CodecType.values.firstWhere(
      (final type) => type.name == value,
      orElse: () => throw ArgumentError('Unknown codec type: $value'),
    );
  }
}

/// Factory for creating compression codecs
///
/// Provides methods to create both block-based ([CompressionCodec]) and
/// stream-based ([CompressionStreamCodec]) codec instances.
class CodecFactory {
  /// All supported codec types
  static const types = CodecType.values;

  /// Default cumulative decompressed-output cap applied by [codec]/[streaming]
  /// when the caller doesn't specify one (matches each codec's own default).
  static const int defaultMaxDecompressedSize = 256 * 1024 * 1024;

  /// Default buffered-compressed-input cap for [streaming].
  static const int defaultMaxBufferSize = 64 * 1024 * 1024;

  /// Get a block-based (whole-buffer) codec for the given type.
  ///
  /// Block codecs operate on a complete byte array: decompression materializes
  /// the entire output (up to the codec's `maxDecompressedSize`) and verifies
  /// trailers/checksums only at the end, so corrupt or adversarial data can
  /// allocate and burn CPU up to that cap before being rejected; compression
  /// likewise allocates an estimated full-output buffer. This is fine for small
  /// or trusted data.
  ///
  /// For untrusted, large, or variable-size input prefer [streaming], which is
  /// incremental and bounded (and supports `verified: true` for all-or-nothing
  /// integrity).
  ///
  /// [maxDecompressedSize] caps decode output (the central place to enforce a
  /// tenant/request limit); omit it for the default cap, or pass `null` for
  /// unlimited (trusted input only).
  ///
  /// Example:
  /// ```dart
  /// final codec = CodecFactory.codec(CodecType.lz4, maxDecompressedSize: 8 << 20);
  /// final compressed = codec.compress(data);
  /// ```
  static CompressionCodec codec(
    final CodecType type, {
    final int? maxDecompressedSize = defaultMaxDecompressedSize,
  }) {
    return switch (type) {
      CodecType.noop => NoopCodec(),
      CodecType.snappy => SnappyCodec(maxSize: maxDecompressedSize),
      CodecType.gzip => GzipCodec(maxDecompressedSize: maxDecompressedSize),
      CodecType.lz4 => Lz4Codec(maxDecompressedSize: maxDecompressedSize),
      CodecType.zstd => ZstdCodec(maxDecompressedSize: maxDecompressedSize),
    };
  }

  /// Get a stream-based codec for the given type.
  ///
  /// Preferred for untrusted, large, or variable-size input: decode is
  /// incremental and memory-bounded, output limits are cumulative, and an
  /// oversized input chunk is rejected before being buffered. See [codec] for
  /// the block (whole-buffer) alternative.
  ///
  /// [maxDecompressedSize] caps cumulative decode output (omit for the default,
  /// `null` for unlimited); [maxBufferSize] caps buffered compressed input;
  /// [verified] withholds each member/frame's output until its trailer/checksum
  /// validates (all-or-nothing integrity; not applicable to Snappy, whose chunks
  /// are independently checksummed).
  ///
  /// Example:
  /// ```dart
  /// final codec = CodecFactory.streaming(CodecType.zstd,
  ///     maxDecompressedSize: 64 << 20, verified: true);
  /// final out = await codec.decompress(inputStream).toList();
  /// ```
  static CompressionStreamCodec streaming(
    final CodecType type, {
    final int? maxDecompressedSize = defaultMaxDecompressedSize,
    final int maxBufferSize = defaultMaxBufferSize,
    final bool verified = false,
  }) {
    return switch (type) {
      CodecType.noop => NoopStreamCodec(),
      CodecType.snappy => SnappyStreamCodec(
        maxSize: maxDecompressedSize,
        maxBufferSize: maxBufferSize,
      ),
      CodecType.gzip => GzipStreamCodec(
        maxSize: maxDecompressedSize,
        maxBufferSize: maxBufferSize,
        verified: verified,
      ),
      CodecType.lz4 => Lz4StreamCodec(
        maxSize: maxDecompressedSize,
        maxBufferSize: maxBufferSize,
        verified: verified,
      ),
      CodecType.zstd => ZstdStreamCodec(
        maxSize: maxDecompressedSize,
        maxBufferSize: maxBufferSize,
        verified: verified,
      ),
    };
  }

  /// Check if a codec type supports a given mode
  ///
  /// Example:
  /// ```dart
  /// if (CodecFactory.supports(CodecType.lz4, CodecMode.stream)) {
  ///   final streamCodec = CodecFactory.streaming(CodecType.lz4);
  /// }
  /// ```
  static bool supports(final CodecType type, final CodecMode mode) {
    return codec(type).supports(mode);
  }
}
