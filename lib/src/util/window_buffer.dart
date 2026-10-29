import 'dart:typed_data';

import 'byte_sink.dart';
import 'output_limit.dart';

/// A sliding-window output buffer for incremental decompression.
///
/// Decoded bytes are appended with [addByte]/[addBytes]; LZ77 back-references
/// resolve against the most recent [window] bytes via [copyFromHistory]
/// (e.g. 32 KB for DEFLATE, the frame window for Zstd). Bytes older than
/// [window] can no longer be referenced, so [drain] emits and discards them,
/// keeping retained memory bounded to roughly [window] regardless of the total
/// decompressed size — unlike [GrowableBuffer], which keeps the whole output.
///
/// [length] always reports the total number of bytes produced (including those
/// already drained), so callers can keep enforcing a cumulative size limit.
class WindowBuffer implements DirectSink {
  /// Number of trailing bytes retained for back-references.
  final int window;

  final int? _maxSize;

  Uint8List _buffer;
  int _start = 0; // index of the first retained byte in _buffer
  int _length = 0; // index one past the last byte in _buffer
  int _base = 0; // logical offset of _buffer[0] in the full output

  /// Creates a buffer retaining at least [window] trailing bytes.
  ///
  /// [maxSize], when set, caps the total produced size (a safety backstop
  /// against decompression bombs); exceeding it throws [OutputLimitException].
  WindowBuffer(this.window, {final int? maxSize})
    : assert(window > 0),
      _maxSize = maxSize,
      // Start modest and grow; `window` may be large (a Zstd frame window),
      // so it bounds retention, not the initial allocation.
      _buffer = Uint8List(window.clamp(1024, 1 << 16));

  /// Total bytes produced so far, including bytes already drained.
  @override
  int get length => _base + _length;

  @override
  Uint8List get bytes => _buffer;

  @override
  int get position => _length;

  @override
  set position(final int value) {
    RangeError.checkValueInInterval(value, _start, _buffer.length, 'position');
    _length = value;
  }

  @override
  int get floor => _start;

  /// The array's end, or the index at which the maximum size is reached.
  @override
  int get room {
    final max = _maxSize;
    return max != null && max - _base < _buffer.length
        ? max - _base
        : _buffer.length;
  }

  @override
  void reserve(final int count) => _ensure(_length + count);

  /// Appends a single byte.
  @override
  void addByte(final int byte) {
    _ensure(_length + 1);
    _buffer[_length++] = byte;
  }

  /// Appends [count] bytes from [bytes] starting at [offset].
  @override
  void addBytes(
    final List<int> bytes, [
    final int offset = 0,
    final int? count,
  ]) {
    final n = count ?? bytes.length - offset;
    _ensure(_length + n);
    if (bytes is Uint8List) {
      _buffer.setRange(_length, _length + n, bytes, offset);
    } else {
      for (var i = 0; i < n; i++) {
        _buffer[_length + i] = bytes[offset + i];
      }
    }
    _length += n;
  }

  /// Copies [length] bytes from [distance] bytes back, handling overlap
  /// (distance < length produces a repeating pattern). [distance] must lie
  /// within the retained window.
  @override
  void copyFromHistory(final int distance, final int length) {
    final retained = _length - _start;
    if (distance <= 0 || distance > retained) {
      throw ArgumentError(
        'Back-reference distance $distance outside window (retained $retained)',
      );
    }
    _ensure(_length + length);
    final from = _length - distance;
    if (distance >= length) {
      _buffer.setRange(_length, _length + length, _buffer, from);
    } else {
      for (var i = 0; i < length; i++) {
        _buffer[_length + i] = _buffer[from + i];
      }
    }
    _length += length;
  }

  /// Emits and discards bytes that are now older than [window] (no longer
  /// reachable by [copyFromHistory]); the last [window] bytes are retained.
  /// Returns an owned copy of the emitted bytes (empty if nothing is ready).
  ///
  /// The retained bytes are moved to the front of the buffer only once the
  /// discarded space ahead of them reaches [window], not on every drain, so
  /// a large window is not copied after every block.
  Uint8List drain() {
    final end = _length - window;
    if (end <= _start) return Uint8List(0);
    final out = Uint8List.fromList(Uint8List.sublistView(_buffer, _start, end));
    _start = end;
    if (_start >= window) _compact();
    return out;
  }

  /// Emits all remaining retained bytes (call once at end of stream).
  Uint8List finish() {
    final out = Uint8List.fromList(
      Uint8List.sublistView(_buffer, _start, _length),
    );
    _base += _length;
    _start = 0;
    _length = 0;
    return out;
  }

  /// Moves the retained bytes to the front of the buffer.
  void _compact() {
    _buffer.setRange(0, _length - _start, _buffer, _start);
    _base += _start;
    _length -= _start;
    _start = 0;
  }

  void _ensure(final int required) {
    // Enforce the size cap BEFORE allocating, so a malicious expansion can't
    // allocate the full (bomb-sized) buffer and only then be rejected.
    final max = _maxSize;
    if (max != null && _base + required > max) {
      throw OutputLimitException('Decompressed size exceeds maximum $max');
    }
    if (required <= _buffer.length) return;
    if (_start > 0) {
      // Reclaim the discarded space before growing.
      final shift = _start;
      _compact();
      return _ensure(required - shift);
    }
    var capacity = _buffer.length;
    while (capacity < required) {
      final doubled = capacity * 2;
      capacity = doubled <= capacity ? required : doubled;
    }
    final grown = Uint8List(capacity)..setRange(0, _length, _buffer);
    _buffer = grown;
  }
}
