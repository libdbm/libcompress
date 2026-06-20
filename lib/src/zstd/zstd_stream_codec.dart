import 'dart:async';
import 'dart:typed_data';

import '../compression_stream_codec.dart';
import '../util/incremental_decompress_transformer.dart';
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

  /// Maximum decompressed size per frame (prevents OOM attacks)
  final int? maxSize;

  /// Maximum buffer size for compressed data before rejecting
  final int maxBufferSize;

  /// Chunk size for buffering input during compression
  final int chunkSize;

  /// Whether to validate compressed blocks by decompressing them
  final bool validate;

  /// Creates a Zstd streaming codec
  ZstdStreamCodec({
    this.level = 3,
    this.blockSize = 128 * 1024,
    this.checksum = false,
    this.maxSize = zstdDefaultMaxDecompressedSize,
    this.maxBufferSize = zstdDefaultMaxBufferSize,
    this.chunkSize = 1024 * 1024, // 1MB default
    this.validate = false,
  });

  @override
  String get name => 'ZSTD';

  @override
  Stream<Uint8List> compress(final Stream<Uint8List> input) {
    // Stateful single-frame compression with a shared window, so matches span
    // chunk boundaries (history preserved) rather than an independent frame
    // per chunk.
    final controller = StreamController<Uint8List>();
    final encoder = StreamingZstdEncoder(
      level: level,
      checksum: checksum,
      validate: validate,
    );
    var headerWritten = false;
    late StreamSubscription<Uint8List> subscription;

    void writeHeaderIfNeeded() {
      if (headerWritten) return;
      controller.add(encoder.header());
      headerWritten = true;
    }

    subscription = input.listen(
      (chunk) {
        writeHeaderIfNeeded();
        final out = encoder.addChunk(chunk);
        if (out.isNotEmpty) controller.add(out);
      },
      onError: (Object e, StackTrace st) {
        controller.addError(e, st);
        subscription.cancel();
      },
      onDone: () {
        writeHeaderIfNeeded();
        controller.add(encoder.finish());
        controller.close();
      },
      cancelOnError: true,
    );
    controller.onCancel = subscription.cancel;
    return controller.stream;
  }

  @override
  Stream<Uint8List> decompress(final Stream<Uint8List> input) {
    // Incremental, memory-bounded: decodes and emits one block at a time,
    // retaining at most the frame window rather than the whole frame.
    return IncrementalDecompressTransformer(
      () => ZstdIncrementalDecoder(
        maxSize: maxSize,
        maxBufferSize: maxBufferSize,
      ),
    ).bind(input);
  }
}
