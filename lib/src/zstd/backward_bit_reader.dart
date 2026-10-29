import 'dart:typed_data';

import 'zstd_common.dart';

/// Bit reader for Huffman decoding (MSB-first backward stream, like Java
/// BitInputStream).
///
/// The 64-bit window is held as two 32-bit halves (`_hi`/`_lo`) to avoid
/// allocating a [BigInt] per symbol on the decode hot path; all peek/read math
/// stays below 2^53 and is exact on the VM and dart2js (see
/// [SequenceBitReader] for the same technique).
class BackwardBitReader {
  final Uint8List _data;
  final int _start;
  final int _end;
  int _current;
  int _hi;
  int _lo;
  int _consumed;
  bool _overflow = false;

  BackwardBitReader(this._data, final int start, final int end)
    : _start = start,
      _end = end,
      _current = 0,
      _hi = 0,
      _lo = 0,
      _consumed = 0 {
    if (end <= start) {
      throw ZstdFormatException('Empty bitstream');
    }

    final last = _data[end - 1];
    if (last == 0) {
      throw ZstdFormatException('Bitstream sentinel bit not found');
    }

    // Find sentinel bit position (highest set bit)
    final sentinel = last.bitLength - 1;
    _consumed = 8 - sentinel;

    final size = end - start;
    if (size >= 8) {
      _current = end - 8;
      _load64(_current);
    } else {
      _current = start;
      _load64(start);
      _consumed += (8 - size) * 8;
    }
  }

  void _load64(final int off) {
    _lo = _read4(off);
    _hi = _read4(off + 4);
  }

  int _read4(final int off) {
    var result = 0;
    var multiplier = 1;
    for (var i = 0; i < 4; i++) {
      final p = off + i;
      if (p >= 0 && p < _end) {
        result += _data[p] * multiplier;
      }
      multiplier *= 256;
    }
    return result;
  }

  bool get isOverflow => _overflow;

  /// The byte position of the 8-byte window and the bits consumed from it,
  /// for a caller that reads the same stream with its own window.
  int get current => _current;
  int get consumed => _consumed;

  /// Continues from a position taken from [current] and [consumed].
  void resume(final int current, final int consumed) {
    _current = current;
    _consumed = consumed;
    _load64(current);
  }

  /// Throws unless the stream was consumed exactly: no unread bytes or bits,
  /// and no reads past its start (RFC 8878 §4.2.2).
  void finish() {
    load();
    if (_overflow || _current != _start || _consumed != 64) {
      throw ZstdFormatException('Bitstream not fully consumed');
    }
  }

  /// Reload bits from stream.
  /// Returns true if stream is exhausted (but bits may still remain in buffer).
  bool load() {
    if (_consumed > 64) {
      _overflow = true;
      return true;
    }
    if (_current == _start) {
      return true;
    }

    final bytes = _consumed >> 3;
    if (_current >= _start + 8) {
      if (bytes > 0) {
        _current -= bytes;
        _load64(_current);
      }
      _consumed &= 7;
    } else if (_current - bytes < _start) {
      final actual = _current - _start;
      _current = _start;
      _consumed -= actual * 8;
      _load64(_start);
      return true;
    } else {
      _current -= bytes;
      _consumed -= bytes * 8;
      _load64(_current);
    }
    return false;
  }

  /// Peek [n] bits from the MSB end .
  int peekBits(final int n) {
    if (n == 0) return 0;
    final consumed = _consumed;
    final available = 64 - consumed;
    if (available <= 0) return 0;
    if (available >= n) {
      final shift = available - n;
      if (shift >= 32) {
        return (_hi >> (shift - 32)) & _mask[n];
      } else if (shift + n <= 32) {
        return (_lo >> shift) & _mask[n];
      } else {
        final lowCount = 32 - shift;
        final lowPart = _lo >> shift;
        final highCount = n - lowCount;
        final highPart = _hi & _mask[highCount];
        return lowPart + highPart * _pow2[lowCount];
      }
    }
    // The unconsumed bits are the low `available` bits of the window (consumed
    // from the MSB down); place them MSB-aligned, low bits zero. available < n
    // <= 32, so they all live in _lo.
    final lowBits = _lo & _mask[available];
    return (lowBits * _pow2[n - available]) & _mask[n];
  }

  /// Skip bits
  void skipBits(final int n) {
    _consumed += n;
  }

  /// Read bits
  int readBits(final int n) {
    final r = peekBits(n);
    skipBits(n);
    return r;
  }
}

/// `_pow2[i] == 2^i` and `_mask[i] == 2^i - 1` for i in 0..32 (all <= 2^32,
/// exact on dart2js).
final List<int> _pow2 = _buildPow2();
final List<int> _mask = List<int>.generate(33, (final i) => _pow2[i] - 1);

List<int> _buildPow2() {
  final result = List<int>.filled(33, 0);
  var value = 1;
  for (var i = 0; i <= 32; i++) {
    result[i] = value;
    value *= 2;
  }
  return result;
}
