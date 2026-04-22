import 'dart:typed_data';

import 'zstd_common.dart';

/// Bit reader for sequence decoding (Java-style implementation)
///
/// This implementation follows the Java aircompressor library's approach:
/// - Bits are loaded as little-endian 64-bit values from the end of data
/// - Bits are consumed from MSB toward LSB using bitsConsumed counter
/// - The load() method should be called at the start of each sequence
class SequenceBitReader {
  final Uint8List data;
  final int _startAddress;
  int _currentAddress;
  BigInt _bits;
  int _bitsConsumed;
  bool _overflow;

  SequenceBitReader(this.data, int endOffset, {int startOffset = 0})
      : _startAddress = startOffset,
        _currentAddress = 0,
        _bits = BigInt.zero,
      _bitsConsumed = 0,
      _overflow = false {
    if (endOffset <= startOffset) {
      throw ZstdFormatException('Empty bitstream');
    }

    // Find sentinel bit in last byte
    final lastByte = data[endOffset - 1];
    if (lastByte == 0) {
      throw ZstdFormatException('Bitstream sentinel bit not found');
    }

    // Initial bitsConsumed = 8 - highestBit(lastByte)
    // This represents how many bits in the last byte are "consumed" (sentinel + padding)
    final highestBit = _highBit32(lastByte);
    _bitsConsumed = 8 - highestBit;

    final inputSize = endOffset - startOffset;
    if (inputSize >= 8) {
      _currentAddress = endOffset - 8;
      _bits = _loadLittleEndian64(_currentAddress);
    } else {
      _currentAddress = startOffset;
      _bits = _loadTail(startOffset, inputSize);
      _bitsConsumed += (8 - inputSize) * 8;
    }
  }

  static int _highBit32(int value) {
    if (value == 0) return 0;
    return value.bitLength - 1;
  }

  BigInt _loadLittleEndian64(int offset) {
    var result = BigInt.zero;
    for (var i = 0; i < 8 && offset + i < data.length; i++) {
      result |= BigInt.from(data[offset + i]) << (8 * i);
    }
    return result;
  }

  BigInt _loadTail(int offset, int size) {
    var result = BigInt.zero;
    for (var i = 0; i < size; i++) {
      result |= BigInt.from(data[offset + i]) << (8 * i);
    }
    return result;
  }

  /// Reload bits from stream. Call at start of each sequence.
  /// Returns true if done (at start of stream or overflow).
  bool load() {
    if (_bitsConsumed > 64) {
      _overflow = true;
      return true;
    }

    if (_currentAddress == _startAddress) {
      return true;
    }

    final bytes = _bitsConsumed >> 3;
    if (_currentAddress >= _startAddress + 8) {
      if (bytes > 0) {
        _currentAddress -= bytes;
        _bits = _loadLittleEndian64(_currentAddress);
      }
      _bitsConsumed &= 7;
    } else if (_currentAddress - bytes < _startAddress) {
      final actualBytes = _currentAddress - _startAddress;
      _currentAddress = _startAddress;
      _bitsConsumed -= actualBytes * 8;
      _bits = _loadLittleEndian64(_startAddress);
      return true;
    } else {
      _currentAddress -= bytes;
      _bitsConsumed -= bytes * 8;
      _bits = _loadLittleEndian64(_currentAddress);
    }

    return false;
  }

  bool get isOverflow => _overflow;

  /// Peek bits from MSB end without consuming
  int peekBits(int numBits) {
    // Java formula: (((bits << bitsConsumed) >>> 1) >>> (63 - numberOfBits))
    // Handle Dart's signed arithmetic carefully
    if (numBits == 0) return 0;
    final shifted = (_bits << _bitsConsumed) & _uint64Mask;
    return ((shifted >> (64 - numBits)) & BigInt.from((1 << numBits) - 1))
        .toInt();
  }

  /// Read specified number of bits (consumes them)
  ///
  /// Note: During state initialization, bitsConsumed may exceed 64.
  /// Missing bits are returned as zeros. Call load() to refill before
  /// reading sequence data.
  int readBits(final int count) {
    if (count == 0) return 0;

    final result = peekBits(count);
    _bitsConsumed += count;
    return result;
  }

  /// Skip specified number of bits
  void skipBits(int count) {
    _bitsConsumed += count;
  }

  int get bitsConsumed => _bitsConsumed;

  /// Check if more data is available
  bool get hasMoreData => !_overflow && (_currentAddress > _startAddress || _bitsConsumed < 64);

  /// Check if bitstream was fully consumed (all bits read, at start of stream)
  /// Returns true if exactly at start with no remaining bits.
  /// Used to validate that compressed blocks have no trailing garbage.
  bool get isFullyConsumed {
    if (_overflow) return false;
    // At start address with all bits consumed (except sentinel)
    return _currentAddress == _startAddress && _bitsConsumed >= 64;
  }

  /// Returns number of unconsumed bytes remaining (approximate)
  int get remaining {
    if (_overflow) return 0;
    final bytesRemaining = _currentAddress - _startAddress;
    final bitsRemaining = 64 - _bitsConsumed;
    return bytesRemaining + (bitsRemaining > 0 ? 1 : 0);
  }
}

final BigInt _uint64Mask = (BigInt.one << 64) - BigInt.one;
