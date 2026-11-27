import 'dart:typed_data';

/// Least-significant-bit-first reader over a Brotli stream (RFC 7932
/// section 2).
///
/// Holds at most 31 buffered bits, so every operation stays within 32-bit
/// arithmetic and behaves the same under dart2js. Reads of up to 24 bits are
/// supported, the widest field the format has.
///
/// Running out of input throws [StateError], the signal the incremental
/// decoders use for "wait for more data"; `guardFormat` turns it into a format
/// exception on the block path.
class BitReader {
  /// Reads [_data] from byte [offset], skipping its first [bit] bits, up to
  /// byte [end].
  BitReader(
    this._data, [
    final int offset = 0,
    final int? end,
    final int bit = 0,
  ]) : _next = offset,
       _end = end ?? _data.length {
    if (bit > 0) bits(bit);
  }

  final Uint8List _data;
  final int _end;

  // Index of the next byte to load into [_value].
  int _next;

  // Buffered bits, the next bit to read in bit 0.
  int _value = 0;

  // Number of valid bits in [_value].
  int _count = 0;

  /// Bits consumed from the start of the underlying data.
  int get position => _next * 8 - _count;

  /// Whether every byte has been loaded and every bit consumed.
  bool get done => _next >= _end && _count == 0;

  void _fill() {
    while (_count < 24 && _next < _end) {
      _value |= _data[_next++] << _count;
      _count += 8;
    }
  }

  /// Reads [count] bits (0..24) as an unsigned integer.
  int bits(final int count) {
    assert(count >= 0 && count <= 24);
    if (_count < count) {
      _fill();
      if (_count < count) throw StateError('Unexpected end of input');
    }
    final value = _value & ((1 << count) - 1);
    _value >>= count;
    _count -= count;
    return value;
  }

  /// Returns the next [count] bits (0..24) without consuming them. Bits past
  /// the end of input read as zero.
  int peek(final int count) {
    if (_count < count) _fill();
    return _value & ((1 << count) - 1);
  }

  /// Consumes [count] bits already examined with [peek].
  void skip(final int count) {
    if (_count < count) throw StateError('Unexpected end of input');
    _value >>= count;
    _count -= count;
  }

  /// Reads one bit.
  int bit() => bits(1);

  /// Skips to the next byte boundary, returning the skipped bits, which the
  /// format requires to be zero.
  int align() => bits(_count & 7);

  /// Copies [length] bytes into [target] at [offset]. The reader must be at a
  /// byte boundary.
  void copy(final Uint8List target, final int offset, final int length) {
    assert(_count & 7 == 0);
    var at = offset;
    var left = length;
    while (left > 0 && _count > 0) {
      target[at++] = _value & 0xFF;
      _value >>= 8;
      _count -= 8;
      left--;
    }
    if (_next + left > _end) throw StateError('Unexpected end of input');
    target.setRange(at, at + left, _data, _next);
    _next += left;
  }

  /// Skips [length] bytes. The reader must be at a byte boundary.
  void discard(final int length) {
    assert(_count & 7 == 0);
    final buffered = _count >> 3;
    if (length <= buffered) {
      bits(length * 8);
      return;
    }
    _value = 0;
    _count = 0;
    final next = _next + length - buffered;
    if (next > _end) throw StateError('Unexpected end of input');
    _next = next;
  }
}
