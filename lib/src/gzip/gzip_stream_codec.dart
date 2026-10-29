import 'dart:typed_data';

import '../compression_options.dart';
import '../compression_stream_codec.dart';
import '../util/crc32.dart';
import '../util/incremental_decoder.dart';
import '../util/stream_compressor.dart';
import 'gzip_frame.dart';
import 'gzip_incremental_decoder.dart';
import 'streaming_deflate_encoder.dart';
import 'gzip_codec.dart' show GzipOptions, validateHeader;

/// Gzip streaming codec
///
/// Provides stream-based compression and decompression for GZIP.
/// Compression emits one member whose DEFLATE matches span input chunks
/// (32 KB window); decompression accepts concatenated members (RFC 1952).
final class GzipStreamCodec extends CompressionStreamCodec {
  /// Compression level (1-9)
  final int level;

  /// Maximum *cumulative* decompressed size across all members (prevents OOM
  /// attacks from concatenated members).
  final int? maxSize;

  /// Maximum buffer size for compressed data before rejecting
  final int maxBufferSize;

  /// When true, each member's decompressed output is withheld until its CRC32
  /// and ISIZE trailer validate, then released — so a consumer never receives
  /// bytes from a member that later fails integrity (at the cost of buffering
  /// up to one member's output, bounded by [maxSize]).
  ///
  /// The default (false) emits output as it decodes for true bounded-memory
  /// streaming; in that mode an integrity error can arrive *after* some bytes
  /// have already been emitted (inherent to streaming, like zlib).
  final bool verified;

  /// MTIME written into the header, in seconds since the epoch (0 = not
  /// set). The default 0 makes output depend only on the input.
  final int mtime;

  /// Optional filename to embed in the GZIP header
  final String? filename;

  /// Optional comment to embed in the GZIP header
  final String? comment;

  /// Creates a GZIP streaming codec. [filename] and [comment] may not contain
  /// a NUL, which GZIP uses to end them.
  GzipStreamCodec({
    this.level = 6,
    this.mtime = 0,
    this.filename,
    this.comment,
    this.maxSize = defaultMaxSize,
    this.maxBufferSize = defaultMaxBufferSize,
    this.verified = false,
  }) {
    validateLevel(level, 1, 9);
    validateOptionalPositive(maxSize, 'maxSize');
    validatePositive(maxBufferSize, 'maxBufferSize');
    validateHeader(mtime, filename, comment);
  }

  /// Creates a GZIP stream codec from [options].
  factory GzipStreamCodec.fromOptions(final GzipOptions options) {
    return GzipStreamCodec(
      level: options.level,
      mtime: options.mtime,
      filename: options.filename,
      comment: options.comment,
      maxSize: options.maxSize,
    );
  }

  @override
  String get name => 'GZIP';

  @override
  Stream<Uint8List> compress(final Stream<Uint8List> input) {
    // Stateful single-member compression: one GZIP header, one DEFLATE stream
    // whose matches span chunk boundaries (history is preserved), one trailer
    // with the streamed CRC32 + ISIZE. Backpressure + error boundary come from
    // the shared base.
    return compressStream(
      input,
      _GzipStreamCompressor(
        level,
        GzipFrame.headerBytes(
          level: level,
          mtime: mtime,
          filename: filename,
          comment: comment,
        ),
      ),
    );
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
        verified: verified,
      ),
    ).bind(input);
  }
}

/// Wraps [StreamingDeflateEncoder] with the GZIP member framing (single header,
/// streamed CRC32 + ISIZE trailer).
class _GzipStreamCompressor implements StreamCompressor {
  _GzipStreamCompressor(final int level, this._header)
    : _deflate = StreamingDeflateEncoder(level: level);

  final Uint8List _header;
  final StreamingDeflateEncoder _deflate;
  int _crc = 0xFFFFFFFF;
  int _isize = 0;

  @override
  Uint8List header() => _header;

  @override
  Uint8List addChunk(final Uint8List data) {
    _crc = Crc32.update(data, _crc);
    _isize = (_isize + data.length) & 0xFFFFFFFF;
    return _deflate.addChunk(data);
  }

  @override
  Uint8List finish() {
    final tail = _deflate.finish();
    final trailer = GzipFrame.trailerBytes(_crc ^ 0xFFFFFFFF, _isize);
    return Uint8List(tail.length + 8)
      ..setRange(0, tail.length, tail)
      ..setRange(tail.length, tail.length + 8, trailer);
  }
}
