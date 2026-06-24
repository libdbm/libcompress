import 'dart:typed_data';
import 'zstd_common.dart';

/// Huffman decoder for Zstandard literals (Java-style implementation)
class HuffmanDecoder {
  static const int maxTableLog = 12;

  late List<int> _symbols;
  late List<int> _numBits;
  late int _tableLog;

  int get tableLog => _tableLog;

  /// Debug helper: get symbol at table index
  int getSymbol(final int idx) => _symbols[idx];

  /// Debug helper: get number of bits at table index
  int getNumBits(final int idx) => _numBits[idx];

  /// Build Huffman table from weights (Java-style approach)
  void buildFromWeights(final List<int> weights) {
    // Calculate total weight and find max weight
    var total = 0;
    final ranks = List<int>.filled(maxTableLog + 2, 0);

    for (var i = 0; i < weights.length; i++) {
      final w = weights[i];
      if (w > 0) {
        ranks[w]++;
        total += (1 << w) >> 1;
      }
    }

    if (total == 0) {
      throw ZstdFormatException('Huffman: no symbols');
    }

    // Calculate tableLog from totalWeight
    _tableLog = _highestBit(total) + 1;
    if (_tableLog > maxTableLog) {
      throw ZstdFormatException('Huffman tableLog too large: $_tableLog');
    }

    // Calculate rest and lastWeight
    final tableSize = 1 << _tableLog;
    final rest = tableSize - total;
    if (rest == 0 || (rest & (rest - 1)) != 0) {
      throw ZstdFormatException('Huffman rest is not power of 2: $rest');
    }

    final lastWeight = _highestBit(rest) + 1;

    // Add implicit last symbol
    final count = weights.length;
    final all = List<int>.filled(count + 1, 0);
    for (var i = 0; i < count; i++) {
      all[i] = weights[i];
    }
    all[count] = lastWeight;
    ranks[lastWeight]++;

    // Calculate rank start positions
    var next = 0;
    for (var i = 1; i <= _tableLog + 1; i++) {
      final cur = next;
      next += ranks[i] << (i - 1);
      ranks[i] = cur;
    }

    // Build table
    _symbols = List<int>.filled(tableSize, 0);
    _numBits = List<int>.filled(tableSize, 0);

    for (var symbol = 0; symbol < count + 1; symbol++) {
      final w = all[symbol];
      if (w == 0) continue;

      final len = (1 << w) >> 1;
      final bits = _tableLog + 1 - w;
      final start = ranks[w];

      for (var i = 0; i < len; i++) {
        _symbols[start + i] = symbol;
        _numBits[start + i] = bits;
      }
      ranks[w] += len;
    }
  }

  static int _highestBit(final int v) {
    if (v == 0) return 0;
    return v.bitLength - 1;
  }

  /// Decode single symbol using MSB-first bit reading
  int decodeSymbol(final HuffmanBitReader reader) {
    final idx = reader.peekBits(_tableLog);
    final symbol = _symbols[idx];
    final bits = _numBits[idx];
    reader.consumeBits(bits);
    return symbol;
  }

  /// Decode a single stream of Huffman-compressed literals
  void decodeSingle(
    final Uint8List data,
    final int start,
    final int end,
    final Uint8List output,
    final int outStart,
    final int outEnd,
  ) {
    final reader = HuffmanBitReader(data, start, end);

    var out = outStart;
    final fast = outEnd - 4;

    // Fast loop: decode 4 symbols at a time
    while (out < fast) {
      if (reader.load()) break;

      output[out] = decodeSymbol(reader);
      output[out + 1] = decodeSymbol(reader);
      output[out + 2] = decodeSymbol(reader);
      output[out + 3] = decodeSymbol(reader);
      out += 4;
    }

    // Tail: decode one at a time with load checks
    while (out < outEnd) {
      if (reader.load()) break;
      output[out++] = decodeSymbol(reader);
    }

    // Remaining: decode without loading (bits already available)
    while (out < outEnd) {
      output[out++] = decodeSymbol(reader);
    }
  }

  /// Decode 4 interleaved streams of Huffman-compressed literals
  void decode4Streams(
    final Uint8List data,
    final int start,
    final int end,
    final Uint8List output,
    final int outStart,
    final int outEnd,
  ) {
    if (end - start < 10) {
      throw ZstdFormatException('4-stream Huffman data too short');
    }

    // Read jump table (6 bytes for 3 uint16 sizes)
    final size1 = (data[start] & 0xFF) | ((data[start + 1] & 0xFF) << 8);
    final size2 = (data[start + 2] & 0xFF) | ((data[start + 3] & 0xFF) << 8);
    final size3 = (data[start + 4] & 0xFF) | ((data[start + 5] & 0xFF) << 8);

    final start1 = start + 6;
    final start2 = start1 + size1;
    final start3 = start2 + size2;
    final start4 = start3 + size3;

    if (start1 >= start2 ||
        start2 >= start3 ||
        start3 >= start4 ||
        start4 > end) {
      throw ZstdFormatException('Invalid 4-stream jump table');
    }

    // Output segments
    final seg = (outEnd - outStart + 3) ~/ 4;
    final out2 = outStart + seg;
    final out3 = out2 + seg;
    final out4 = out3 + seg;

    // Initialize 4 readers
    final r1 = HuffmanBitReader(data, start1, start2);
    final r2 = HuffmanBitReader(data, start2, start3);
    final r3 = HuffmanBitReader(data, start3, start4);
    final r4 = HuffmanBitReader(data, start4, end);

    var o1 = outStart;
    var o2 = out2;
    var o3 = out3;
    var o4 = out4;

    final fast = outEnd - 7;

    // Fast loop: decode 4 symbols from each stream
    while (o4 < fast) {
      output[o1] = decodeSymbol(r1);
      output[o2] = decodeSymbol(r2);
      output[o3] = decodeSymbol(r3);
      output[o4] = decodeSymbol(r4);

      output[o1 + 1] = decodeSymbol(r1);
      output[o2 + 1] = decodeSymbol(r2);
      output[o3 + 1] = decodeSymbol(r3);
      output[o4 + 1] = decodeSymbol(r4);

      output[o1 + 2] = decodeSymbol(r1);
      output[o2 + 2] = decodeSymbol(r2);
      output[o3 + 2] = decodeSymbol(r3);
      output[o4 + 2] = decodeSymbol(r4);

      output[o1 + 3] = decodeSymbol(r1);
      output[o2 + 3] = decodeSymbol(r2);
      output[o3 + 3] = decodeSymbol(r3);
      output[o4 + 3] = decodeSymbol(r4);

      o1 += 4;
      o2 += 4;
      o3 += 4;
      o4 += 4;

      // Try to reload all streams
      if (r1.load()) break;
      if (r2.load()) break;
      if (r3.load()) break;
      if (r4.load()) break;
    }

    // Finish each stream individually
    _decodeTail(r1, output, o1, out2);
    _decodeTail(r2, output, o2, out3);
    _decodeTail(r3, output, o3, out4);
    _decodeTail(r4, output, o4, outEnd);
  }

  void _decodeTail(
    final HuffmanBitReader reader,
    final Uint8List output,
    int pos,
    final int limit,
  ) {
    // First phase: decode with load checks
    while (pos < limit) {
      if (reader.load()) break;
      output[pos++] = decodeSymbol(reader);
    }

    // Second phase: decode remaining without loading
    while (pos < limit) {
      output[pos++] = decodeSymbol(reader);
    }
  }
}

/// Bit reader for Huffman decoding (MSB-first backward stream, like Java
/// BitInputStream).
///
/// The 64-bit window is held as two 32-bit halves (`_hi`/`_lo`) to avoid
/// allocating a [BigInt] per symbol on the decode hot path; all peek/read math
/// stays below 2^53 and is exact on the VM and dart2js (see
/// [SequenceBitReader] for the same technique).
class HuffmanBitReader {
  final Uint8List _data;
  final int _start;
  final int _end;
  int _current;
  int _hi;
  int _lo;
  int _consumed;
  bool _overflow = false;

  HuffmanBitReader(this._data, final int start, final int end)
    : _start = start,
      _end = end,
      _current = 0,
      _hi = 0,
      _lo = 0,
      _consumed = 0 {
    if (end <= start) {
      throw ZstdFormatException('Empty Huffman stream');
    }

    final last = _data[end - 1];
    if (last == 0) {
      throw ZstdFormatException('Huffman sentinel not found');
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

  /// Peek [n] bits from the MSB end (see [SequenceBitReader.peekBits]).
  int peekBits(final int n) {
    if (n == 0) return 0;
    final consumed = _consumed;
    final available = 64 - consumed;
    if (available <= 0) return 0;
    if (available >= n) {
      final shift = available - n;
      if (shift >= 32) {
        return (_hi >> (shift - 32)) & _hMask[n];
      } else if (shift + n <= 32) {
        return (_lo >> shift) & _hMask[n];
      } else {
        final lowCount = 32 - shift;
        final lowPart = _lo >> shift;
        final highCount = n - lowCount;
        final highPart = _hi & _hMask[highCount];
        return lowPart + highPart * _hPow2[lowCount];
      }
    }
    // The unconsumed bits are the low `available` bits of the window (consumed
    // from the MSB down); place them MSB-aligned, low bits zero. available < n
    // <= 32, so they all live in _lo.
    final lowBits = _lo & _hMask[available];
    return (lowBits * _hPow2[n - available]) & _hMask[n];
  }

  /// Consume bits
  void consumeBits(final int n) {
    _consumed += n;
  }

  /// Read bits
  int readBits(final int n) {
    final r = peekBits(n);
    consumeBits(n);
    return r;
  }
}

/// `_hPow2[i] == 2^i` and `_hMask[i] == 2^i - 1` for i in 0..32 (all <= 2^32,
/// exact on dart2js).
final List<int> _hPow2 = _buildHPow2();
final List<int> _hMask = List<int>.generate(33, (i) => _hPow2[i] - 1);

List<int> _buildHPow2() {
  final result = List<int>.filled(33, 0);
  var value = 1;
  for (var i = 0; i <= 32; i++) {
    result[i] = value;
    value *= 2;
  }
  return result;
}
