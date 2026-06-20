import 'dart:typed_data';

import 'byte_sink.dart';

/// A growable byte buffer optimized for decompression operations
///
/// Provides efficient appending of bytes and copying from history (for LZ77
/// decompression). Automatically grows capacity as needed using a doubling
/// strategy to amortize allocation costs.
///
/// Used by LZ4, Snappy, and GZIP decoders.
class GrowableBuffer implements ByteSink {
  Uint8List _buffer;
  int _length = 0;
  final int? _maxCapacity;

  /// Creates a buffer with the specified initial capacity
  ///
  /// If [initialCapacity] is 0, a default capacity of 1024 bytes is used.
  /// If [maxCapacity] is provided, the buffer will throw [StateError] if
  /// growth would exceed this limit (prevents OOM from malicious inputs).
  GrowableBuffer([int initialCapacity = 1024, int? maxCapacity])
      : _maxCapacity = maxCapacity,
        _buffer = Uint8List(initialCapacity > 0 ? initialCapacity : 1024);

  /// The current number of bytes in the buffer
  @override
  int get length => _length;

  /// Returns the buffer contents as a Uint8List
  ///
  /// The returned list is a view into the internal buffer up to [length].
  /// The buffer should not be modified after calling this method.
  Uint8List toBytes() {
    return Uint8List.sublistView(_buffer, 0, _length);
  }

  /// Adds a single byte to the buffer
  @override
  void addByte(int byte) {
    _ensureCapacity(_length + 1);
    _buffer[_length++] = byte;
  }

  /// Adds multiple bytes from a list to the buffer
  ///
  /// If [offset] is provided, copying starts from that position in [bytes].
  /// If [length] is provided, only that many bytes are copied.
  ///
  /// Throws [RangeError] if offset/length are invalid or out of bounds.
  @override
  void addBytes(List<int> bytes, [int? offset, int? length]) {
    final start = offset ?? 0;
    final count = length ?? (bytes.length - start);

    // Validate parameters
    if (start < 0) {
      throw RangeError.value(start, 'offset', 'Cannot be negative');
    }
    if (count < 0) {
      throw RangeError.value(count, 'length', 'Cannot be negative');
    }
    if (start + count > bytes.length) {
      throw RangeError.range(
        start + count,
        0,
        bytes.length,
        'offset + length',
        'Exceeds source array bounds',
      );
    }

    _ensureCapacity(_length + count);

    if (bytes is Uint8List) {
      _buffer.setRange(_length, _length + count, bytes, start);
    } else {
      for (var i = 0; i < count; i++) {
        _buffer[_length + i] = bytes[start + i];
      }
    }

    _length += count;
  }

  /// Copies bytes from earlier in the buffer (for LZ77 back-references)
  ///
  /// Copies [length] bytes starting from [distance] bytes back from the
  /// current position. Handles overlapping copies correctly (when distance
  /// is less than length, which creates a repeating pattern).
  ///
  /// Example:
  /// ```dart
  /// buffer.addByte(65);  // 'A'
  /// buffer.copyFromHistory(1, 5);  // Copies 'A' 5 times: 'AAAAA'
  /// ```
  @override
  void copyFromHistory(int distance, int length) {
    if (distance <= 0) {
      throw ArgumentError('Distance must be positive, got $distance');
    }
    if (distance > _length) {
      throw ArgumentError('Distance $distance exceeds buffer length $_length');
    }

    final srcPos = _length - distance;
    _ensureCapacity(_length + length);

    // Handle overlapping copies (distance < length)
    // This creates a repeating pattern
    if (distance < length) {
      // Copy byte-by-byte to handle overlap correctly
      for (var i = 0; i < length; i++) {
        _buffer[_length + i] = _buffer[srcPos + i];
      }
    } else {
      // Non-overlapping: can use bulk copy
      _buffer.setRange(_length, _length + length, _buffer, srcPos);
    }

    _length += length;
  }

  /// Adds bytes from a Uint8List view
  void addBytesView(Uint8List bytes) {
    addBytes(bytes, 0, bytes.length);
  }

  /// Ensures the buffer has at least the specified capacity
  void _ensureCapacity(int requiredCapacity) {
    if (requiredCapacity <= _buffer.length) {
      return;
    }

    // Check max capacity limit before growing
    if (_maxCapacity != null && requiredCapacity > _maxCapacity) {
      throw StateError(
        'Buffer growth would exceed maximum capacity: '
        'required=$requiredCapacity, max=$_maxCapacity',
      );
    }

    // Double capacity until it's large enough, with overflow protection
    var newCapacity = _buffer.length;
    while (newCapacity < requiredCapacity) {
      final doubled = newCapacity * 2;
      // Check for integer overflow (doubled would wrap to negative or smaller)
      if (doubled <= newCapacity) {
        // Overflow detected, use requiredCapacity directly
        newCapacity = requiredCapacity;
        break;
      }
      newCapacity = doubled;
    }

    // Cap at maxCapacity if set
    if (_maxCapacity != null && newCapacity > _maxCapacity) {
      newCapacity = _maxCapacity;
    }

    final newBuffer = Uint8List(newCapacity);
    newBuffer.setRange(0, _length, _buffer);
    _buffer = newBuffer;
  }

  /// Clears the buffer (resets length to 0, keeps capacity)
  void clear() {
    _length = 0;
  }

  /// Returns the byte at the specified index
  ///
  /// Throws RangeError if index is out of bounds.
  int operator [](int index) {
    if (index < 0 || index >= _length) {
      throw RangeError.index(index, this, 'index', null, _length);
    }
    return _buffer[index];
  }

  /// Sets the byte at the specified index
  ///
  /// Throws RangeError if index is out of bounds.
  void operator []=(int index, int value) {
    if (index < 0 || index >= _length) {
      throw RangeError.index(index, this, 'index', null, _length);
    }
    _buffer[index] = value;
  }
}
