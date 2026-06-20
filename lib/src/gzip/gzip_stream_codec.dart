import 'dart:async';
import 'dart:typed_data';

import '../compression_stream_codec.dart';
import '../util/crc32.dart';
import '../util/incremental_decompress_transformer.dart';
import 'gzip_codec.dart';
import 'gzip_frame.dart';
import 'gzip_incremental_decoder.dart';
import 'streaming_deflate_encoder.dart';

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
    // Stateful single-member compression: one GZIP header, one DEFLATE stream
    // whose matches span chunk boundaries (history is preserved), and one
    // trailer with the streamed CRC32 + ISIZE. More standard and better-
    // compressing than the previous member-per-chunk output.
    final controller = StreamController<Uint8List>();
    final encoder = StreamingDeflateEncoder(level: level);
    var crc = 0xFFFFFFFF;
    var isize = 0;
    var headerWritten = false;
    late StreamSubscription<Uint8List> subscription;

    void writeHeaderIfNeeded() {
      if (headerWritten) return;
      controller.add(_header());
      headerWritten = true;
    }

    subscription = input.listen(
      (chunk) {
        writeHeaderIfNeeded();
        crc = Crc32.update(chunk, crc);
        isize = (isize + chunk.length) & 0xFFFFFFFF;
        final out = encoder.addChunk(chunk);
        if (out.isNotEmpty) controller.add(out);
      },
      onError: (Object e, StackTrace st) {
        controller.addError(e, st);
        subscription.cancel();
      },
      onDone: () {
        writeHeaderIfNeeded();
        final out = encoder.finish();
        if (out.isNotEmpty) controller.add(out);
        controller.add(_trailer(crc ^ 0xFFFFFFFF, isize));
        controller.close();
      },
      cancelOnError: true,
    );
    controller.onCancel = subscription.cancel;
    return controller.stream;
  }

  /// 10-byte GZIP header (no optional fields).
  Uint8List _header() {
    final xfl = level >= 9 ? 2 : (level <= 1 ? 4 : 0);
    return Uint8List.fromList([
      GzipFrame.id1, GzipFrame.id2, GzipFrame.cmDeflate, 0, // magic, CM, FLG
      0, 0, 0, 0, // MTIME = 0
      xfl, GzipFrame.osUnix,
    ]);
  }

  /// 8-byte GZIP trailer: CRC32 then ISIZE, little-endian.
  Uint8List _trailer(final int crc, final int isize) {
    return Uint8List.fromList([
      crc & 0xFF, (crc >> 8) & 0xFF, (crc >> 16) & 0xFF, (crc >> 24) & 0xFF,
      isize & 0xFF, (isize >> 8) & 0xFF, (isize >> 16) & 0xFF, (isize >> 24) & 0xFF,
    ]);
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
