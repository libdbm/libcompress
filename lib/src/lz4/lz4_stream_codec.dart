import 'dart:typed_data';

import '../compression_options.dart';
import '../compression_stream_codec.dart';
import '../util/incremental_decoder.dart';
import '../util/stream_compressor.dart';
import 'lz4_common.dart';
import 'lz4_decoder.dart';
import 'lz4_encoder.dart';
import 'lz4_codec.dart';

/// LZ4 streaming codec
///
/// Provides stream-based compression and decompression for LZ4 frames.
/// Compression emits one frame whose linked blocks carry a 64 KB history
/// across input chunks; decompression accepts concatenated frames.
final class Lz4StreamCodec extends CompressionStreamCodec {
  /// Compression level (1 fast, 2-9 high-compression mode)
  final int level;

  /// Block size for frame compression
  final int blockSize;

  /// Whether to include content checksum in output
  final bool checksum;

  /// Maximum *cumulative* decompressed size across all frames (prevents OOM
  /// attacks from concatenated frames).
  final int? maxSize;

  /// Maximum buffer size for compressed data before rejecting
  final int maxBufferSize;

  /// When true, a frame's output is withheld until its content checksum and
  /// size validate, then released (buffers up to one frame's output, bounded
  /// by [maxSize]). The default (false) emits as it decodes, so an integrity
  /// error can arrive after some bytes were already emitted.
  final bool verified;

  /// Creates an LZ4 streaming codec
  Lz4StreamCodec({
    this.level = 1,
    this.blockSize = lz4DefaultBlockSize,
    this.checksum = true,
    this.maxSize = defaultMaxSize,
    this.maxBufferSize = defaultMaxBufferSize,
    this.verified = false,
  }) {
    validateLevel(level, 1, 9);
    validateRange(blockSize, 1, lz4BlockSize4M, 'blockSize');
    validateOptionalPositive(maxSize, 'maxSize');
    validatePositive(maxBufferSize, 'maxBufferSize');
  }

  /// Creates an LZ4 stream codec from [options]. Streams use the frame
  /// format, so options with another [Lz4Options.format] are rejected.
  factory Lz4StreamCodec.fromOptions(final Lz4Options options) {
    if (options.format != Lz4Format.frame) {
      throw ArgumentError.value(
        options.format,
        'format',
        'Stream codecs use the frame format',
      );
    }
    return Lz4StreamCodec(
      level: options.level,
      blockSize: options.blockSize,
      checksum: options.checksum,
      maxSize: options.maxSize,
    );
  }

  @override
  String get name => 'LZ4';

  @override
  Stream<Uint8List> compress(final Stream<Uint8List> input) {
    // Stateful, block-linked single frame: matches span chunk boundaries
    // (history preserved). Backpressure + error boundary come from the base.
    return compressStream(
      input,
      StreamingLz4Encoder(
        level: level,
        blockSize: blockSize,
        contentChecksum: checksum,
      ),
    );
  }

  @override
  Stream<Uint8List> decompress(final Stream<Uint8List> input) {
    // Incremental, memory-bounded: emits per block instead of buffering and
    // decoding the whole frame at once.
    return IncrementalDecompressTransformer(
      () => Lz4IncrementalDecoder(
        maxSize: maxSize,
        maxBufferSize: maxBufferSize,
        verified: verified,
      ),
    ).bind(input);
  }
}
