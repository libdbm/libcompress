import 'dart:typed_data';

/// A writer for creating a stream of bits.
///
/// Bits are written from a value's LSB to MSB, and packed into bytes
/// starting from the LSB of each byte.
class BitStreamWriter {
  Uint8List _bytes = Uint8List(256);
  int _length = 0;
  int _bitBuffer = 0;
  int _bitCount = 0;

  void _push(final int byte) {
    if (_length == _bytes.length) {
      final grown = Uint8List(_bytes.length * 2);
      grown.setRange(0, _length, _bytes);
      _bytes = grown;
    }
    _bytes[_length++] = byte;
  }

  /// Writes a value with a specific number of bits to the stream.
  void writeBits(int value, int bitCount) {
    if (bitCount < 0 || bitCount > 32) {
      throw ArgumentError('bitCount must be between 0 and 32');
    }
    _bitBuffer |= (value & ((1 << bitCount) - 1)) << _bitCount;
    _bitCount += bitCount;

    while (_bitCount >= 8) {
      _push(_bitBuffer & 0xFF);
      _bitBuffer >>= 8;
      _bitCount -= 8;
    }
  }

  /// Flushes any remaining bits in the current byte and aligns the
  /// writer to the next byte boundary.
  void flushToByte() {
    if (_bitCount > 0) {
      _push(_bitBuffer & 0xFF);
      _bitBuffer = 0;
      _bitCount = 0;
    }
  }

  /// Returns and clears the complete bytes written so far, preserving any
  /// pending sub-byte bits. Lets a streaming writer drain finished bytes
  /// between bit-packed blocks without disturbing the in-progress byte.
  Uint8List takeBytes() {
    final result = Uint8List.fromList(
      Uint8List.sublistView(_bytes, 0, _length),
    );
    _length = 0;
    return result;
  }

  /// Returns the written bits as a byte list, flushing any remaining bits.
  Uint8List toBytes() {
    if (_bitCount != 0) {
      _push(_bitBuffer & 0xFF);
      _bitBuffer = 0;
      _bitCount = 0;
    }
    return Uint8List.fromList(Uint8List.sublistView(_bytes, 0, _length));
  }
}
