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

    if (start1 >= start2 || start2 >= start3 || start3 >= start4 || start4 > end) {
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

/// Bit reader for Huffman decoding (MSB-first backward stream, like Java BitInputStream)
class HuffmanBitReader {
  final Uint8List _data;
  final int _start;
  int _current;
  BigInt _bits;
  int _consumed;
  bool _overflow = false;

  HuffmanBitReader(this._data, final int start, final int end)
      : _start = start,
        _current = 0,
        _bits = BigInt.zero,
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
      _bits = _load64(_current);
    } else {
      _current = start;
      _bits = _loadTail(start, size);
      _consumed += (8 - size) * 8;
    }
  }

  BigInt _load64(final int off) {
    var r = BigInt.zero;
    for (var i = 0; i < 8 && off + i < _data.length; i++) {
      r |= BigInt.from(_data[off + i] & 0xFF) << (i * 8);
    }
    return r;
  }

  BigInt _loadTail(final int off, final int n) {
    var r = BigInt.zero;
    for (var i = 0; i < n; i++) {
      r |= BigInt.from(_data[off + i] & 0xFF) << (i * 8);
    }
    return r;
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
        _bits = _load64(_current);
      }
      _consumed &= 7;
    } else if (_current - bytes < _start) {
      final actual = _current - _start;
      _current = _start;
      _consumed -= actual * 8;
      _bits = _load64(_start);
      return true;
    } else {
      _current -= bytes;
      _consumed -= bytes * 8;
      _bits = _load64(_current);
    }
    return false;
  }

  /// Peek bits from MSB (Java-style)
  int peekBits(final int n) {
    if (n == 0) return 0;
    // Java formula: ((bits << consumed) >>> (64 - n))
    final shifted = (_bits << _consumed) & _uint64Mask;
    return ((shifted >> (64 - n)) & BigInt.from((1 << n) - 1)).toInt();
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

final BigInt _uint64Mask = (BigInt.one << 64) - BigInt.one;
