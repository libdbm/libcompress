import 'dart:async';
import 'dart:typed_data';

import '../compression_stream_codec.dart';
import '../util/incremental_decompress_transformer.dart';
import 'lz4_common.dart';
import 'lz4_decoder.dart';
import 'lz4_encoder.dart';

/// Default maximum buffer size for stream decoders (64MB)
const int lz4DefaultMaxBufferSize = 64 * 1024 * 1024;

/// LZ4 streaming codec
///
/// Provides stream-based compression and decompression for LZ4.
/// Each chunk emitted during compression is a complete, independent
/// LZ4 frame that can be concatenated with others.
class Lz4StreamCodec extends CompressionStreamCodec {
  /// Compression level (1-9, where 9 enables high-compression mode)
  final int level;

  /// Block size for frame compression
  final int blockSize;

  /// Whether to include content checksum in output
  final bool checksum;

  /// Maximum decompressed size per frame (prevents OOM attacks)
  final int? maxSize;

  /// Maximum buffer size for compressed data before rejecting
  final int maxBufferSize;

  /// Chunk size for buffering input during compression
  final int chunkSize;

  /// Creates an LZ4 streaming codec
  Lz4StreamCodec({
    this.level = 1,
    this.blockSize = lz4DefaultBlockSize,
    this.checksum = true,
    this.maxSize = lz4DefaultMaxDecompressedSize,
    this.maxBufferSize = lz4DefaultMaxBufferSize,
    this.chunkSize = 1024 * 1024, // 1MB default
  });

  @override
  String get name => 'LZ4';

  @override
  Stream<Uint8List> compress(final Stream<Uint8List> input) {
    // Stateful, block-linked single frame: matches span chunk boundaries
    // (history preserved), better ratio than an independent frame per chunk.
    final controller = StreamController<Uint8List>();
    final encoder = StreamingLz4Encoder(
      level: level,
      blockSize: blockSize,
      contentChecksum: checksum,
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
    // Incremental, memory-bounded: emits per block instead of buffering and
    // decoding the whole frame at once.
    return IncrementalDecompressTransformer(
      () => Lz4IncrementalDecoder(
        maxSize: maxSize,
        maxBufferSize: maxBufferSize,
      ),
    ).bind(input);
  }
}
