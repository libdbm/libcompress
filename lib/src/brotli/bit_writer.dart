import 'dart:typed_data';

import '../util/growable_buffer.dart' show trim;

/// Least-significant-bit-first writer for a Brotli stream (RFC 7932
/// section 2).
///
/// Holds at most 7 pending bits between writes, so a write of up to 24 bits
/// stays within 31 bits and behaves the same under dart2js.
class BitWriter {
  BitWriter([final int capacity = 1024])
    : _bytes = Uint8List(capacity < 16 ? 16 : capacity);

  Uint8List _bytes;
  int _length = 0;
  int _value = 0;
  int _count = 0;

  /// Bits written so far.
  int get position => _length * 8 + _count;

  /// Writes the low [count] bits (0..24) of [value].
  void bits(final int value, final int count) {
    _value |= value << _count;
    _count += count;
    if (_count >= 8) {
      if (_length + 4 > _bytes.length) _grow(4);
      while (_count >= 8) {
        _bytes[_length++] = _value & 0xFF;
        _value >>= 8;
        _count -= 8;
      }
    }
  }

  /// Pads with zero bits to the next byte boundary.
  void align() {
    if (_count > 0) bits(0, 8 - _count);
  }

  /// Writes [count] bytes of [data] from [offset]. The writer must be at a
  /// byte boundary.
  void bytes(final Uint8List data, final int offset, final int count) {
    assert(_count == 0);
    if (_length + count > _bytes.length) _grow(count);
    _bytes.setRange(_length, _length + count, data, offset);
    _length += count;
  }

  /// Discards everything written after bit [position], which must be a value
  /// [position] returned earlier.
  void rewind(final int position) {
    final index = position >> 3;
    final count = position & 7;
    final mask = (1 << count) - 1;
    // The partial byte is still pending when it is the current one.
    _value = index < _length ? _bytes[index] & mask : _value & mask;
    _length = index;
    _count = count;
  }

  /// The bytes written, padded to a byte boundary: a copy when the buffer is
  /// more than twice their length, so the result does not keep it alive.
  Uint8List finish() {
    align();
    return trim(_bytes, _length);
  }

  /// Removes and returns the whole bytes written so far, keeping any pending
  /// bits. Used by the streaming encoder to emit output as it goes.
  Uint8List take() {
    final out = Uint8List.fromList(Uint8List.sublistView(_bytes, 0, _length));
    _length = 0;
    return out;
  }

  void _grow(final int count) {
    var size = _bytes.length * 2;
    if (size < _length + count) size = _length + count;
    _bytes = Uint8List(size)..setRange(0, _length, _bytes);
  }
}
