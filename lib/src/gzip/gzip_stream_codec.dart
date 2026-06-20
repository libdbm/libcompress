import 'dart:typed_data';

import '../compression_stream_codec.dart';
import '../util/incremental_decompress_transformer.dart';
import '../util/stream_compress_transformer.dart';
import 'gzip_codec.dart';
import 'gzip_frame.dart';
import 'gzip_incremental_decoder.dart';

/// Default maximum buffer size for stream decoders (64MB)
const int defaultMaxBufferSize = 64 * 1024 * 1024;

/// Gzip streaming codec
///
/// Provides stream-based compression and decompression for GZIP.
/// Each chunk emitted during compression is a complete, independent
/// GZIP member that can be concatenated (per RFC 1952, multiple members
/// are allowed).
class GzipStreamCodec extends CompressionStreamCodec {
  /// Compression level (1-9)
  final int level;

  /// Maximum decompressed size per member (prevents OOM attacks)
  final int? maxSize;

  /// Maximum buffer size for compressed data before rejecting
  final int maxBufferSize;

  /// Chunk size for buffering input during compression
  final int chunkSize;

  /// Creates a GZIP streaming codec
  GzipStreamCodec({
    this.level = 6,
    this.maxSize = gzipDefaultMaxDecompressedSize,
    this.maxBufferSize = defaultMaxBufferSize,
    this.chunkSize = 1024 * 1024, // 1MB default
  });

  @override
  String get name => 'GZIP';

  @override
  Stream<Uint8List> compress(final Stream<Uint8List> input) {
    return StreamCompressTransformer(
      chunkSize: chunkSize,
      compress: (data) => GzipFrame.compress(data, level: level),
    ).bind(input);
  }

  @override
  Stream<Uint8List> decompress(final Stream<Uint8List> input) {
    // Incremental, memory-bounded: decodes the DEFLATE stream as bytes arrive
    // and emits output retaining only a 32 KB window, instead of buffering the
    // whole member and inflating it at once.
    return IncrementalDecompressTransformer(
      () => GzipIncrementalDecoder(
        maxSize: maxSize,
        maxBufferSize: maxBufferSize,
      ),
    ).bind(input);
  }
}
