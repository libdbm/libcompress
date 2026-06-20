import 'dart:typed_data';

import '../compression_stream_codec.dart';
import '../util/crc32.dart';
import '../util/incremental_decompress_transformer.dart';
import '../util/stream_compressor.dart';
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
    // whose matches span chunk boundaries (history is preserved), one trailer
    // with the streamed CRC32 + ISIZE. Backpressure + error boundary come from
    // the shared base.
    return compressStream(input, _GzipStreamCompressor(level));
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

/// Wraps [StreamingDeflateEncoder] with the GZIP member framing (single header,
/// streamed CRC32 + ISIZE trailer).
class _GzipStreamCompressor implements StreamCompressor {
  _GzipStreamCompressor(this._level)
      : _deflate = StreamingDeflateEncoder(level: _level);

  final int _level;
  final StreamingDeflateEncoder _deflate;
  int _crc = 0xFFFFFFFF;
  int _isize = 0;

  @override
  Uint8List header() {
    final xfl = _level >= 9 ? 2 : (_level <= 1 ? 4 : 0);
    return Uint8List.fromList([
      GzipFrame.id1, GzipFrame.id2, GzipFrame.cmDeflate, 0, // magic, CM, FLG
      0, 0, 0, 0, // MTIME = 0
      xfl, GzipFrame.osUnix,
    ]);
  }

  @override
  Uint8List addChunk(final Uint8List data) {
    _crc = Crc32.update(data, _crc);
    _isize = (_isize + data.length) & 0xFFFFFFFF;
    return _deflate.addChunk(data);
  }

  @override
  Uint8List finish() {
    final tail = _deflate.finish();
    final crc = _crc ^ 0xFFFFFFFF;
    final out = Uint8List(tail.length + 8);
    out.setRange(0, tail.length, tail);
    var p = tail.length;
    out[p++] = crc & 0xFF;
    out[p++] = (crc >> 8) & 0xFF;
    out[p++] = (crc >> 16) & 0xFF;
    out[p++] = (crc >> 24) & 0xFF;
    out[p++] = _isize & 0xFF;
    out[p++] = (_isize >> 8) & 0xFF;
    out[p++] = (_isize >> 16) & 0xFF;
    out[p++] = (_isize >> 24) & 0xFF;
    return out;
  }
}
