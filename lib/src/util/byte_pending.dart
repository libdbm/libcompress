import 'dart:typed_data';

import '../exceptions.dart';

/// A contiguous, `Uint8List`-backed pending-input buffer for incremental
/// decoders: append at the end, read by absolute index, and discard a consumed
/// prefix (compacting). Unboxed (unlike a `List<int>`) and contiguous, so a
/// `DeflateReader` can read its [bytes] backing directly.
class BytePending {
  BytePending([final int initialCapacity = 1024])
    : _backing = Uint8List(initialCapacity < 64 ? 64 : initialCapacity);

  Uint8List _backing;
  int _length = 0;

  /// Number of valid bytes; valid range is `bytes[0..length)`.
  int get length => _length;

  /// The backing store. Bytes `[0, length)` are valid (the tail up to capacity
  /// is scratch). Pass with an explicit `end == length` to readers.
  Uint8List get bytes => _backing;

  int operator [](final int index) => _backing[index];

  /// Index of the first byte not yet consumed by the decoder.
  int cursor = 0;

  /// Bytes from [cursor] to the end.
  int get available => _length - cursor;

  /// The little-endian 32-bit value at [offset] (exact on dart2js).
  int u32(final int offset) =>
      _backing[offset] +
      _backing[offset + 1] * 0x100 +
      _backing[offset + 2] * 0x10000 +
      _backing[offset + 3] * 0x1000000;

  /// Appends [data], first throwing [LimitException] if more than [limit]
  /// unconsumed bytes would then be buffered: rejecting before appending stops
  /// an oversized chunk forcing the copy ahead of the check.
  void append(final Uint8List data, final int limit) {
    if (available + data.length > limit) {
      throw LimitException(
        limit,
        'Buffered input would exceed the limit of $limit bytes - '
        'frame too large or malformed',
      );
    }
    add(data);
  }

  /// Discards the consumed bytes before [cursor] once they are all of the
  /// buffer or at least 8 KB, so the copy is not repeated for every chunk.
  void compact() {
    if (cursor > 0 && (cursor >= _length || cursor >= 8192)) {
      discard(cursor);
      cursor = 0;
    }
  }

  /// Appends [data].
  void add(final Uint8List data) {
    _ensure(_length + data.length);
    _backing.setRange(_length, _length + data.length, data);
    _length += data.length;
  }

  /// Returns an owned copy of `[start, end)`.
  Uint8List slice(final int start, final int end) =>
      Uint8List.fromList(Uint8List.sublistView(_backing, start, end));

  /// Discards the first [count] bytes, shifting the remainder to the front.
  void discard(final int count) {
    if (count <= 0) return;
    _backing.setRange(0, _length - count, _backing, count);
    _length -= count;
  }

  void _ensure(final int need) {
    if (need <= _backing.length) return;
    var capacity = _backing.length;
    while (capacity < need) {
      final doubled = capacity * 2;
      capacity = doubled <= capacity ? need : doubled;
    }
    _backing = Uint8List(capacity)..setRange(0, _length, _backing);
  }
}
