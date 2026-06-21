import 'dart:typed_data';

import '../compression_options.dart';
import '../compression_stream_codec.dart';
import '../util/incremental_decompress_transformer.dart';
import '../util/stream_compressor.dart';
import 'zstd_common.dart';
import 'zstd_decoder.dart';
import 'streaming_zstd_encoder.dart';

/// Default maximum buffer size for stream decoders (64MB)
const int zstdDefaultMaxBufferSize = 64 * 1024 * 1024;

/// Zstd streaming codec
///
/// Provides stream-based compression and decompression for Zstd.
/// Each chunk emitted during compression is a complete, independent
/// Zstd frame that can be concatenated with others.
class ZstdStreamCodec extends CompressionStreamCodec {
  /// Compression level (1-22)
  final int level;

  /// Block size for frame compression
  final int blockSize;

  /// Whether to include XXH64 content checksum
  final bool checksum;

  /// Maximum *cumulative* decompressed size across all frames (prevents OOM
  /// attacks from concatenated frames).
  final int? maxSize;

  /// Maximum buffer size for compressed data before rejecting
  final int maxBufferSize;

  /// Whether to validate compressed blocks by decompressing them
  final bool validate;

  /// When true, a frame's output is withheld until its content checksum and
  /// size validate, then released (buffers up to one frame's output, bounded
  /// by [maxSize]). The default (false) emits as it decodes, so an integrity
  /// error can arrive after some bytes were already emitted.
  final bool verified;

  /// Creates a Zstd streaming codec
  ZstdStreamCodec({
    this.level = 3,
    this.blockSize = 128 * 1024,
    this.checksum = false,
    this.maxSize = zstdDefaultMaxDecompressedSize,
    this.maxBufferSize = zstdDefaultMaxBufferSize,
    this.validate = false,
    this.verified = false,
  }) {
    validateLevel(level, 1, 22);
    validateRange(blockSize, 1, zstdMaxBlockSize, 'blockSize');
    validateOptionalPositive(maxSize, 'maxSize');
    validatePositive(maxBufferSize, 'maxBufferSize');
  }

  @override
  String get name => 'ZSTD';

  @override
  Stream<Uint8List> compress(final Stream<Uint8List> input) {
    // Stateful single-frame compression with a shared window so matches span
    // chunk boundaries. Backpressure + error boundary come from the base.
    return compressStream(
      input,
      StreamingZstdEncoder(
        level: level,
        checksum: checksum,
        validate: validate,
        blockSize: blockSize,
      ),
    );
  }

  @override
  Stream<Uint8List> decompress(final Stream<Uint8List> input) {
    // Incremental, memory-bounded: decodes and emits one block at a time,
    // retaining at most the frame window rather than the whole frame.
    return IncrementalDecompressTransformer(
      () => ZstdIncrementalDecoder(
        maxSize: maxSize,
        maxBufferSize: maxBufferSize,
        verified: verified,
      ),
    ).bind(input);
  }
}
