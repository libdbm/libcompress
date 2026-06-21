import 'dart:typed_data';

import '../compression_options.dart';
import '../compression_stream_codec.dart';
import '../util/byte_pending.dart';
import '../util/incremental_decompress_transformer.dart';
import '../util/output_limit.dart';
import '../util/stream_compressor.dart';
import 'snappy_decoder.dart';
import 'snappy_stream_decoder.dart';
import 'snappy_stream_encoder.dart';

/// Default maximum buffer size for stream decoders (64MB)
const int snappyDefaultMaxBufferSize = 64 * 1024 * 1024;

/// Snappy streaming codec
///
/// Provides stream-based compression and decompression using the
/// Snappy framing format. The framing format allows for streaming
/// decompression and chunk-based processing.
class SnappyStreamCodec extends CompressionStreamCodec {
  /// Maximum cumulative decompressed size across all chunks
  /// (`null` = unlimited; trusted input only).
  final int? maxSize;

  /// Maximum buffer size for compressed data before rejecting
  final int maxBufferSize;

  /// Chunk size for compression (max 65536 per spec)
  final int chunkSize;

  /// Creates a Snappy streaming codec
  SnappyStreamCodec({
    this.maxSize = snappyDefaultMaxDecompressedSize,
    this.maxBufferSize = snappyDefaultMaxBufferSize,
    this.chunkSize = SnappyStreamEncoder.maxChunkSize,
  }) {
    validateOptionalPositive(maxSize, 'maxSize');
    validatePositive(maxBufferSize, 'maxBufferSize');
    validateRange(chunkSize, 1, SnappyStreamEncoder.maxChunkSize, 'chunkSize');
  }

  @override
  String get name => 'SNAPPY';

  @override
  Stream<Uint8List> compress(final Stream<Uint8List> input) {
    return compressStream(input, _SnappyStreamCompressor(chunkSize));
  }

  @override
  Stream<Uint8List> decompress(final Stream<Uint8List> input) {
    return IncrementalDecompressTransformer(
      () => SnappyIncrementalDecoder(
        maxSize: maxSize,
        maxBufferSize: maxBufferSize,
      ),
    ).bind(input);
  }
}

/// Incremental Snappy framing decoder: parses and decodes one framing chunk at
/// a time. Chunk-type validation (incl. the leading stream identifier) is
/// enforced by [SnappyStreamDecoder].
class SnappyIncrementalDecoder implements IncrementalDecoder {
  SnappyIncrementalDecoder({required this.maxSize, required this.maxBufferSize});

  final int? maxSize;
  final int maxBufferSize;

  // Cumulative output cap across all chunks (the per-chunk SnappyStreamDecoder
  // limit alone lets an unbounded number of chunks exceed maxSize).
  late final OutputLimit _limit = OutputLimit(maxSize);

  final BytePending _pending = BytePending();
  int _cursor = 0;
  late final SnappyStreamDecoder _decoder =
      SnappyStreamDecoder(maxUncompressedSize: maxSize);

  int get _avail => _pending.length - _cursor;

  @override
  void add(final Uint8List input, final void Function(Uint8List) emit) {
    // Reject before appending so an oversized chunk can't force the
    // allocation/copy in _pending.add ahead of the limit check.
    if (_avail + input.length > maxBufferSize) {
      throw SnappyFormatException(
        'Stream buffer would exceed $maxBufferSize bytes - '
        'frame too large or malformed',
      );
    }
    _pending.add(input);
    while (_avail >= 4) {
      final length = _pending[_cursor + 1] |
          (_pending[_cursor + 2] << 8) |
          (_pending[_cursor + 3] << 16);
      final chunkSize = 4 + length;
      if (_avail < chunkSize) break;
      final chunk = _pending.slice(_cursor, _cursor + chunkSize);
      final decoded = _decoder.decompressChunk(chunk);
      _limit.record(decoded.length);
      if (maxSize != null && _limit.produced > maxSize!) {
        throw SnappyFormatException(
          'Decompressed size ${_limit.produced} exceeds maximum allowed size $maxSize',
        );
      }
      emit(decoded);
      _cursor += chunkSize;
    }
    if (_cursor > 0 && (_cursor >= _pending.length || _cursor >= 8192)) {
      _pending.discard(_cursor);
      _cursor = 0;
    }
  }

  @override
  void close(final void Function(Uint8List) emit) {
    if (_avail != 0) {
      throw SnappyFormatException('Incomplete Snappy chunk at end of stream');
    }
    if (!_decoder.seenIdentifier) {
      throw SnappyFormatException('Stream missing required stream identifier');
    }
  }
}

/// Buffers input into <=chunkSize framing chunks (independent per the Snappy
/// spec), emitting the stream identifier first.
class _SnappyStreamCompressor implements StreamCompressor {
  _SnappyStreamCompressor(this._chunkSize)
      : _encoder = SnappyStreamEncoder(chunkSize: _chunkSize);

  final int _chunkSize;
  final SnappyStreamEncoder _encoder;
  // Typed, contiguous pending buffer; consumed full chunks are discarded once
  // per addChunk rather than via repeated List.removeRange (which was O(n^2)).
  final BytePending _buf = BytePending();

  @override
  Uint8List header() => _encoder.streamIdentifier;

  @override
  Uint8List addChunk(final Uint8List data) {
    _buf.add(data);
    final out = BytesBuilder(copy: false);
    var cursor = 0;
    while (_buf.length - cursor >= _chunkSize) {
      out.add(_encoder.compressChunkOnly(_buf.slice(cursor, cursor + _chunkSize)));
      cursor += _chunkSize;
    }
    if (cursor > 0) _buf.discard(cursor);
    return out.takeBytes();
  }

  @override
  Uint8List finish() {
    final remaining = _buf.length;
    if (remaining == 0) return Uint8List(0);
    final chunk = _buf.slice(0, remaining);
    _buf.discard(remaining);
    return _encoder.compressChunkOnly(chunk);
  }
}
