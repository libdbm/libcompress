import 'dart:typed_data';

import '../util/huffman.dart';
import '../util/bit_stream.dart';
import 'fse_encoder.dart';
import 'sequence_encoder.dart';

/// Huffman encoder for Zstd literal compression
///
/// Uses backward bitstream encoding as per RFC 8878:
/// - Symbols are encoded in reverse order (last to first)
/// - Bits are packed LSB-first into bytes
/// - A sentinel bit (1) marks the stream end
///
/// The code assignment matches the Zstd decoder's table building algorithm:
/// symbols are assigned codes in symbol-value order within each bit-length group.
class HuffmanEncoder {
  static const int maxTableLog = 12;

  /// Largest Huffman weight, and the most accuracy log the FSE table that
  /// compresses weights may use (RFC 8878 section 4.2.1.2).
  static const int _maxWeight = 12;
  static const int _weightLog = 6;

  /// Longest permitted literal code (RFC 8878 Section 4.2.1).
  static const int maxCodeLength = 11;
  static const int maxSymbol = 255;

  late Uint16List _codes;
  late Uint8List _bits;
  late int _maxBits;
  late int _tableLog;

  int get maxBits => _maxBits;
  int get tableLog => _tableLog;

  /// Build Huffman table from symbol counts
  void buildFromCounts(final List<int> counts, final int maxSym) {
    if (maxSym > maxSymbol) {
      throw ArgumentError('maxSymbol exceeds $maxSymbol');
    }

    // Find non-zero symbols
    var nonZero = 0;
    for (var i = 0; i <= maxSym; i++) {
      if (counts[i] > 0) nonZero++;
    }

    if (nonZero == 0) {
      throw ArgumentError('No symbols with non-zero count');
    }

    if (nonZero == 1) {
      // Single symbol: 1-bit code
      _codes = Uint16List(maxSym + 1);
      _bits = Uint8List(maxSym + 1);
      for (var i = 0; i <= maxSym; i++) {
        if (counts[i] > 0) {
          _codes[i] = 0;
          _bits[i] = 1;
          break;
        }
      }
      _maxBits = 1;
      _tableLog = 1;
      return;
    }

    // Length-limited Huffman lengths; always a complete prefix code.
    final lengths = HuffmanTreeBuilder.computeLimitedCodeLengths(
      counts.sublist(0, maxSym + 1),
      maxCodeLength,
    );

    _maxBits = 1;
    for (final length in lengths) {
      if (length > _maxBits) _maxBits = length;
    }

    // Weight = maxBits + 1 - length (0 for unused symbols).
    final weights = List.filled(maxSym + 1, 0);
    for (var i = 0; i <= maxSym; i++) {
      if (lengths[i] > 0) {
        weights[i] = _maxBits + 1 - lengths[i];
      }
    }

    // For a complete code the weights, including the last symbol's, sum to
    // exactly 2^maxBits, so the decoder's table log equals maxBits.
    _tableLog = _maxBits;

    // Generate codes to match decoder's table building
    _generateCodesFromWeights(weights, maxSym);
  }

  /// Generate codes that match the decoder's table building algorithm
  ///
  /// The decoder builds a table where entries are assigned by processing symbols
  /// in order, within each weight class. The code to write is the MSB portion
  /// of the table index.
  void _generateCodesFromWeights(final List<int> weights, final int maxSym) {
    _codes = Uint16List(maxSym + 1);
    _bits = Uint8List(maxSym + 1);

    // Count entries per weight (rank)
    final ranks = List.filled(maxTableLog + 2, 0);
    for (var i = 0; i <= maxSym; i++) {
      if (weights[i] > 0) {
        ranks[weights[i]]++;
      }
    }

    // Calculate starting table index for each weight
    // Same algorithm as decoder
    var next = 0;
    final starts = List.filled(maxTableLog + 2, 0);
    for (var w = 1; w <= _tableLog + 1; w++) {
      starts[w] = next;
      next += ranks[w] << (w - 1);
    }

    // Assign codes: the code is the MSB bits of the table index
    for (var symbol = 0; symbol <= maxSym; symbol++) {
      final w = weights[symbol];
      if (w == 0) continue;

      final numBits = _tableLog + 1 - w;
      final tableIdx = starts[w];

      // The code is the table index shifted right to get just the MSB bits
      // Since entries for this symbol span (1 << w) >> 1 consecutive indices,
      // and we only write numBits bits, the code is tableIdx >> (tableLog - numBits)
      _codes[symbol] = tableIdx >> (_tableLog - numBits);
      _bits[symbol] = numBits;

      // Advance to next position for this weight
      starts[w] += (1 << w) >> 1;
    }
  }

  /// Encode literals to a bitstream
  ///
  /// Returns encoded data or null if a literal has no code
  Uint8List? encodeSingle(final Uint8List literals) {
    if (literals.isEmpty) return Uint8List(0);
    final output = Uint8List(_bound(literals.length) + 1);
    final end = _encodeStream(literals, 0, literals.length, output, 0);
    return end < 0 ? null : Uint8List.sublistView(output, 0, end);
  }

  /// Encode literals using 4 interleaved streams
  ///
  /// Returns encoded data with 6-byte jump table prefix, or null if a literal
  /// has no code
  Uint8List? encode4Streams(final Uint8List literals) {
    if (literals.length < 16) {
      return encodeSingle(literals);
    }

    // Segments of `seg` literals, the last taking the rest; each stream is
    // written straight after the 6-byte jump table of the first three sizes
    // (uint16 LE).
    final length = literals.length;
    final seg = (length + 3) ~/ 4;
    final output = Uint8List(6 + _bound(length) + 4);
    var offset = 6;
    for (var stream = 0; stream < 4; stream++) {
      final start = stream * seg;
      final end = stream == 3 ? length : start + seg;
      final next = _encodeStream(literals, start, end, output, offset);
      if (next < 0) return null;
      if (stream < 3) {
        final size = next - offset;
        output[stream * 2] = size & 0xFF;
        output[stream * 2 + 1] = (size >> 8) & 0xFF;
      }
      offset = next;
    }
    return Uint8List.sublistView(output, 0, offset);
  }

  /// Bytes enough for [count] literals at the longest code length, without
  /// the end mark.
  int _bound(final int count) => (count * _maxBits + 7) >> 3;

  /// Writes `literals[start..end)` as one backward stream at [offset] in
  /// [output]: last literal first, bits packed LSB-first, then an end-mark bit
  /// and padding to a byte. Returns the offset after it, or -1 if a literal
  /// has no code.
  int _encodeStream(
    final Uint8List literals,
    final int start,
    final int end,
    final Uint8List output,
    final int offset,
  ) {
    final codes = _codes;
    final bits = _bits;
    var position = offset;
    // Below 8 + 11 bits, so exact on the web.
    var container = 0;
    var count = 0;
    for (var i = end - 1; i >= start; i--) {
      final symbol = literals[i];
      final length = bits[symbol];
      if (length == 0) return -1;
      container |= codes[symbol] << count;
      count += length;
      while (count >= 8) {
        output[position++] = container & 0xFF;
        container >>= 8;
        count -= 8;
      }
    }
    container |= 1 << count; // end mark
    output[position++] = container & 0xFF;
    return position;
  }

  /// Get weights for encoding the Huffman table
  ///
  /// Weight = maxBits + 1 - numBits (0 for unused symbols)
  List<int> getWeights(final int maxSym) {
    final weights = List.filled(maxSym, 0);
    for (var i = 0; i < maxSym && i < _bits.length; i++) {
      if (_bits[i] > 0) {
        weights[i] = _tableLog + 1 - _bits[i];
      }
    }
    return weights;
  }

  /// Encodes the Huffman tree description: the weights of symbols
  /// `0..maxSym-1`, the last symbol's weight being implied (RFC 8878 section
  /// 4.2.1). Up to 128 weights use the direct 4-bit representation; more are
  /// FSE-compressed (section 4.2.1.2).
  ///
  /// Returns null when the weights cannot be FSE-compressed: all of them are
  /// equal (no table of two or more symbols), or the result exceeds the
  /// 127 bytes its header byte can describe.
  Uint8List? encodeWeightsHeader(final int maxSym) {
    final weights = getWeights(maxSym);
    final count = maxSym; // Last symbol is implicit
    return count <= 128 ? _direct(weights, count) : _compressed(weights, count);
  }

  /// Header byte `127 + count`, then the weights packed two per byte, high
  /// nibble first.
  Uint8List _direct(final List<int> weights, final int count) {
    final output = Uint8List(1 + (count + 1) ~/ 2);
    output[0] = 127 + count;
    for (var i = 0; i < count; i += 2) {
      final w1 = weights[i];
      final w2 = i + 1 < count ? weights[i + 1] : 0;
      output[1 + i ~/ 2] = (w1 << 4) | w2;
    }
    return output;
  }

  /// Header byte giving the size that follows, then an FSE table description
  /// and a backward bitstream of the weights, coded with two states that share
  /// the table.
  Uint8List? _compressed(final List<int> weights, final int count) {
    final counts = List<int>.filled(_maxWeight + 1, 0);
    for (var i = 0; i < count; i++) {
      counts[weights[i]]++;
    }
    if (counts.where((final c) => c > 0).length < 2) return null;

    final fse = FseEncoder()..build(counts, _weightLog, _maxWeight);
    final table = FseCompressionTable.create(
      fse.normalized,
      fse.tableLog,
      _maxWeight,
    );

    // The decoder reads the first state, then the second, and decodes
    // weights[0] with the first, weights[1] with the second, and so on. So
    // even indices use the first state and odd ones the second. As the
    // reference FSE_compress_usingCTable does, the last two weights set the
    // initial states, the rest are encoded from the end, and the second state
    // is flushed before the first.
    final stream = BitStreamWriter();
    var first = 0;
    var second = 0;
    for (var i = count - 1; i >= count - 2; i--) {
      if (i.isEven) {
        first = table.begin(weights[i]);
      } else {
        second = table.begin(weights[i]);
      }
    }
    for (var i = count - 3; i >= 0; i--) {
      if (i.isEven) {
        first = table.encode(stream, first, weights[i]);
      } else {
        second = table.encode(stream, second, weights[i]);
      }
    }
    table.finish(stream, second);
    table.finish(stream, first);
    stream.writeBits(1, 1); // end mark
    final body = stream.toBytes();

    final header = fse.encodeHeader();
    final size = header.length + body.length;
    if (size >= 128) return null;
    return Uint8List(1 + size)
      ..[0] = size
      ..setRange(1, 1 + header.length, header)
      ..setRange(1 + header.length, 1 + size, body);
  }
}
