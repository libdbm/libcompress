import 'dart:typed_data';
import 'backward_bit_reader.dart';
import 'zstd_common.dart';

/// Huffman decoder for Zstandard literals (Java-style implementation)
class HuffmanDecoder {
  static const int maxTableLog = 12;

  late List<int> _symbols;
  late List<int> _numBits;
  late int _tableLog;

  int get tableLog => _tableLog;

  /// Build Huffman table from weights (Java-style approach)
  void buildFromWeights(final List<int> weights) {
    // Calculate total weight and find max weight
    var total = 0;
    final ranks = List<int>.filled(maxTableLog + 2, 0);

    for (var i = 0; i < weights.length; i++) {
      final w = weights[i];
      if (w > maxTableLog) {
        throw ZstdFormatException('Huffman weight $w exceeds $maxTableLog');
      }
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
      final start = next;
      next += ranks[i] << (i - 1);
      ranks[i] = start;
    }

    // Build table
    _symbols = List<int>.filled(tableSize, 0);
    _numBits = List<int>.filled(tableSize, 0);

    for (var symbol = 0; symbol < count + 1; symbol++) {
      final w = all[symbol];
      if (w == 0) continue;

      final count = (1 << w) >> 1;
      final bits = _tableLog + 1 - w;
      final start = ranks[w];

      for (var i = 0; i < count; i++) {
        _symbols[start + i] = symbol;
        _numBits[start + i] = bits;
      }
      ranks[w] += count;
    }
  }

  static int _highestBit(final int v) {
    if (v == 0) return 0;
    return v.bitLength - 1;
  }

  /// Decode single symbol using MSB-first bit reading
  int decodeSymbol(final BackwardBitReader reader) {
    final index = reader.peekBits(_tableLog);
    final symbol = _symbols[index];
    final bits = _numBits[index];
    reader.skipBits(bits);
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
    final reader = BackwardBitReader(data, start, end);

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
    reader.finish();
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
    final r1 = BackwardBitReader(data, start1, start2);
    final r2 = BackwardBitReader(data, start2, start3);
    final r3 = BackwardBitReader(data, start3, start4);
    final r4 = BackwardBitReader(data, start4, end);

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
    r1.finish();
    r2.finish();
    r3.finish();
    r4.finish();
  }

  void _decodeTail(
    final BackwardBitReader reader,
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
