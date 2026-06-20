import 'dart:typed_data';

import 'zstd_common.dart';

/// Bit reader for sequence decoding (Java-style implementation)
///
/// This implementation follows the Java aircompressor library's approach:
/// - Bits are loaded as little-endian 64-bit values from the end of data
/// - Bits are consumed from MSB toward LSB using bitsConsumed counter
/// - The load() method should be called at the start of each sequence
///
/// The 64-bit window is held as two 32-bit halves (`_hi`, `_lo`) rather than a
/// [BigInt], so the per-sequence peek/read math uses only native int ops that
/// stay below 2^53 — exact on both the VM and dart2js, and far faster than
/// allocating BigInts on the hot path.
class SequenceBitReader {
  final Uint8List data;
  final int _startAddress;
  final int _endAddress;
  int _currentAddress;
  int _hi; // high 32 bits of the 64-bit window
  int _lo; // low 32 bits
  int _bitsConsumed;
  bool _overflow;

  SequenceBitReader(this.data, int endOffset, {int startOffset = 0})
      : _startAddress = startOffset,
        _endAddress = endOffset,
        _currentAddress = 0,
        _hi = 0,
        _lo = 0,
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
      _load64(_currentAddress);
    } else {
      _currentAddress = startOffset;
      _load64(startOffset);
      _bitsConsumed += (8 - inputSize) * 8;
    }
  }

  static int _highBit32(int value) {
    if (value == 0) return 0;
    return value.bitLength - 1;
  }

  /// Loads up to 8 little-endian bytes at [offset] into the `_hi`/`_lo` window.
  /// Bytes past the end of [data] read as zero (matching the original
  /// BigInt loader), built with multiplication to stay dart2js-safe.
  void _load64(int offset) {
    _lo = _read4(offset);
    _hi = _read4(offset + 4);
  }

  int _read4(int offset) {
    var result = 0;
    var multiplier = 1;
    for (var i = 0; i < 4; i++) {
      final p = offset + i;
      if (p >= 0 && p < _endAddress) {
        result += data[p] * multiplier;
      }
      multiplier *= 256;
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
        _load64(_currentAddress);
      }
      _bitsConsumed &= 7;
    } else if (_currentAddress - bytes < _startAddress) {
      final actualBytes = _currentAddress - _startAddress;
      _currentAddress = _startAddress;
      _bitsConsumed -= actualBytes * 8;
      _load64(_startAddress);
      return true;
    } else {
      _currentAddress -= bytes;
      _bitsConsumed -= bytes * 8;
      _load64(_currentAddress);
    }

    return false;
  }

  bool get isOverflow => _overflow;

  /// Peek bits from MSB end without consuming.
  ///
  /// Equivalent to `((bits << bitsConsumed) >>> (64 - numBits))` on a 64-bit
  /// window, i.e. the [numBits] bits starting `bitsConsumed` from the MSB.
  /// Bits beyond what remains in the window read as zero.
  int peekBits(int numBits) {
    if (numBits == 0) return 0;
    final consumed = _bitsConsumed;
    final available = 64 - consumed;
    if (available <= 0) return 0;

    if (available >= numBits) {
      // shift = 64 - consumed - numBits, the right-shift into the window.
      final shift = available - numBits;
      if (shift >= 32) {
        return (_hi >> (shift - 32)) & _mask[numBits];
      } else if (shift + numBits <= 32) {
        return (_lo >> shift) & _mask[numBits];
      } else {
        // The field straddles the 32-bit boundary.
        final lowCount = 32 - shift;
        final lowPart = _lo >> shift; // top `lowCount` bits of _lo
        final highCount = numBits - lowCount;
        final highPart = _hi & _mask[highCount];
        return lowPart + highPart * _pow2[lowCount];
      }
    }

    // Fewer than numBits remain: the unconsumed bits are the low `available`
    // bits of the window (bits are consumed from the MSB down). Place them
    // MSB-aligned in the result, low bits zero. available < numBits <= 32, so
    // they all live in _lo.
    final lowBits = _lo & _mask[available];
    return (lowBits * _pow2[numBits - available]) & _mask[numBits];
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

/// `_pow2[i] == 2^i` and `_mask[i] == 2^i - 1` for i in 0..32. All values are
/// <= 2^32, exact as doubles on dart2js.
final List<int> _pow2 = _buildPow2();
final List<int> _mask = List<int>.generate(33, (i) => _pow2[i] - 1);

List<int> _buildPow2() {
  final result = List<int>.filled(33, 0);
  var value = 1;
  for (var i = 0; i <= 32; i++) {
    result[i] = value;
    value *= 2;
  }
  return result;
}
