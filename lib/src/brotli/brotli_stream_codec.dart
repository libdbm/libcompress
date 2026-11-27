import 'dart:typed_data';

import '../compression_options.dart';
import '../compression_stream_codec.dart';
import '../util/incremental_decoder.dart';
import '../util/stream_compressor.dart';
import 'brotli_codec.dart';
import 'brotli_incremental_decoder.dart';
import 'streaming_brotli_encoder.dart';

/// Brotli streaming codec
///
/// Compression writes one stream whose meta-blocks share history across
/// input chunks; its output is the same as [BrotliCodec.compress] with the
/// same level and window. Decompression is incremental: it decodes and emits
/// one meta-block at a time.
///
/// Brotli has no checksum, so there is no `verified` mode: a corrupt stream
/// can decode to wrong bytes, which are emitted as they decode.
final class BrotliStreamCodec extends CompressionStreamCodec {
  /// Encoder effort, 1-11 (see [BrotliCodec.level]).
  final int level;

  /// Encoder window, `WBITS` 10-24 (see [BrotliCodec.window]).
  final int window;

  /// Maximum *cumulative* decompressed size, or null for unlimited.
  final int? maxSize;

  /// Maximum compressed input buffered while waiting for a whole meta-block.
  final int maxBufferSize;

  /// Creates a Brotli streaming codec.
  BrotliStreamCodec({
    this.level = 6,
    this.window = 22,
    this.maxSize = defaultMaxSize,
    this.maxBufferSize = defaultMaxBufferSize,
  }) {
    validateLevel(level, 1, 11);
    validateRange(window, 10, 24, 'window');
    validateOptionalPositive(maxSize, 'maxSize');
    validatePositive(maxBufferSize, 'maxBufferSize');
  }

  /// Creates a Brotli stream codec from [options].
  factory BrotliStreamCodec.fromOptions(final BrotliOptions options) =>
      BrotliStreamCodec(
        level: options.level,
        window: options.window,
        maxSize: options.maxSize,
      );

  @override
  String get name => 'BROTLI';

  @override
  Stream<Uint8List> compress(final Stream<Uint8List> input) => compressStream(
    input,
    StreamingBrotliEncoder(level: level, window: window),
  );

  @override
  Stream<Uint8List> decompress(final Stream<Uint8List> input) =>
      IncrementalDecompressTransformer(
        () => BrotliIncrementalDecoder(
          maxSize: maxSize,
          maxBufferSize: maxBufferSize,
        ),
      ).bind(input);
}
