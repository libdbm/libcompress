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
import 'compression_options.dart' as options;

/// Supported compression codec types
enum CodecType {
  /// No compression: data passes through unchanged.
  noop,

  /// Snappy ([SnappyCodec]).
  snappy,

  /// GZIP ([GzipCodec]).
  gzip,

  /// LZ4 ([Lz4Codec]).
  lz4,

  /// Zstandard ([ZstdCodec]).
  zstd;

  /// The type whose [name] is [value], ignoring case, so both `'lz4'` and a
  /// codec's upper-case `CompressionCodec.name` (`'LZ4'`) parse.
  static CodecType parse(final String value) {
    final lower = value.toLowerCase();
    return CodecType.values.firstWhere(
      (final type) => type.name == lower,
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
  static const int defaultMaxSize = options.defaultMaxSize;

  /// Default buffered-compressed-input cap for [streaming].
  static const int defaultMaxBufferSize = options.defaultMaxBufferSize;

  /// Get a block-based (whole-buffer) codec for the given type.
  ///
  /// Block codecs operate on a complete byte array: decompression materializes
  /// the entire output (up to the codec's `maxSize`) and verifies
  /// trailers/checksums only at the end, so corrupt or adversarial data can
  /// allocate and burn CPU up to that cap before being rejected; compression
  /// likewise allocates an estimated full-output buffer. This is fine for small
  /// or trusted data.
  ///
  /// For untrusted, large, or variable-size input prefer [streaming], which is
  /// incremental and bounded (and supports `verified: true` for all-or-nothing
  /// integrity).
  ///
  /// [maxSize] caps decode output (the central place to enforce a
  /// tenant/request limit); omit it for the default cap, or pass `null` for
  /// unlimited (trusted input only).
  ///
  /// Example:
  /// ```dart
  /// final codec = CodecFactory.codec(CodecType.lz4, maxSize: 8 << 20);
  /// final compressed = codec.compress(data);
  /// ```
  static CompressionCodec codec(
    final CodecType type, {
    final int? maxSize = defaultMaxSize,
  }) {
    return switch (type) {
      CodecType.noop => NoopCodec(maxSize: maxSize),
      CodecType.snappy => SnappyCodec(maxSize: maxSize),
      CodecType.gzip => GzipCodec(maxSize: maxSize),
      CodecType.lz4 => Lz4Codec(maxSize: maxSize),
      CodecType.zstd => ZstdCodec(maxSize: maxSize),
    };
  }

  /// Get a stream-based codec for the given type.
  ///
  /// Preferred for untrusted, large, or variable-size input: decode is
  /// incremental and memory-bounded, output limits are cumulative, and an
  /// oversized input chunk is rejected before being buffered. See [codec] for
  /// the block (whole-buffer) alternative.
  ///
  /// [maxSize] caps cumulative decode output (omit for the default,
  /// `null` for unlimited); [maxBufferSize] caps buffered compressed input;
  /// [verified] withholds each member/frame's output until its trailer/checksum
  /// validates (all-or-nothing integrity; not applicable to Snappy, whose chunks
  /// are independently checksummed).
  ///
  /// Example:
  /// ```dart
  /// final codec = CodecFactory.streaming(CodecType.zstd,
  ///     maxSize: 64 << 20, verified: true);
  /// final out = await codec.decompress(inputStream).toList();
  /// ```
  static CompressionStreamCodec streaming(
    final CodecType type, {
    final int? maxSize = defaultMaxSize,
    final int maxBufferSize = defaultMaxBufferSize,
    final bool verified = false,
  }) {
    return switch (type) {
      CodecType.noop => NoopStreamCodec(maxSize: maxSize),
      CodecType.snappy => SnappyStreamCodec(
        maxSize: maxSize,
        maxBufferSize: maxBufferSize,
      ),
      CodecType.gzip => GzipStreamCodec(
        maxSize: maxSize,
        maxBufferSize: maxBufferSize,
        verified: verified,
      ),
      CodecType.lz4 => Lz4StreamCodec(
        maxSize: maxSize,
        maxBufferSize: maxBufferSize,
        verified: verified,
      ),
      CodecType.zstd => ZstdStreamCodec(
        maxSize: maxSize,
        maxBufferSize: maxBufferSize,
        verified: verified,
      ),
    };
  }
}
