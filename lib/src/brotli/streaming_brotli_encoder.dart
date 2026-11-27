import 'dart:typed_data';

import '../util/stream_compressor.dart';
import 'bit_writer.dart';
import 'brotli_encoder.dart';

/// Streaming Brotli encoder: one stream whose meta-blocks share history.
///
/// Input is buffered into whole meta-blocks of [metaBlockSize] bytes, so the
/// output is the same however the input is split, and the same as
/// `BrotliEncoder`'s.
class StreamingBrotliEncoder implements StreamCompressor {
  StreamingBrotliEncoder({
    required this.level,
    required this.window,
    final int rebase = defaultRebase,
  }) : _encoder = MetaBlockEncoder(
         level: level,
         window: window,
         rebase: rebase,
       ),
       _span = (1 << window) - 16;

  /// Effort, 1..11.
  final int level;

  /// WBITS, 10..24.
  final int window;

  final MetaBlockEncoder _encoder;
  final int _span;
  final BitWriter _writer = BitWriter();

  // Input bytes: stream positions `_base .. _base + _length`.
  Uint8List _buffer = Uint8List(metaBlockSize);
  int _length = 0;
  int _base = 0;

  // Stream position of the first byte not yet encoded.
  int _start = 0;

  /// The stream header is a few bits; they are held in the writer and leave
  /// with the first meta-block.
  @override
  Uint8List header() {
    writeWindowBits(_writer, window);
    return Uint8List(0);
  }

  @override
  Uint8List addChunk(final Uint8List data) {
    _append(data);
    while (_base + _length - _start >= metaBlockSize) {
      _write(_start + metaBlockSize);
    }
    _trim();
    return _writer.take();
  }

  @override
  Uint8List finish() {
    if (_start < _base + _length) _write(_base + _length);
    writeEnd(_writer);
    return _writer.finish();
  }

  void _write(final int end) {
    final view = Uint8List.sublistView(_buffer, 0, _length);
    _encoder.write(_writer, view, _base, _start, end);
    _start = end;
  }

  void _append(final Uint8List data) {
    final need = _length + data.length;
    if (need > _buffer.length) {
      var size = _buffer.length * 2;
      if (size < need) size = need;
      _buffer = Uint8List(size)..setRange(0, _length, _buffer);
    }
    _buffer.setRange(_length, need, data);
    _length = need;
  }

  // Drops input older than the window before the next unencoded byte, once
  // that is more than a window's worth, so the copy is amortized.
  void _trim() {
    final keep = _start - _span;
    if (keep - _base <= _span) return;
    final drop = keep - _base;
    _buffer.setRange(0, _length - drop, _buffer, drop);
    _length -= drop;
    _base += drop;
  }
}
