import 'dart:typed_data';

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
  static const int minTableLog = 5;
  static const int maxSymbol = 255;

  late List<int> _codes;
  late List<int> _bits;
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
      _codes = List.filled(maxSym + 1, 0);
      _bits = List.filled(maxSym + 1, 0);
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

    // Build Huffman tree and get bit lengths
    final numBits = _buildTree(counts, maxSym);

    // Limit depth and get weights
    _limitDepth(numBits, maxSym, maxTableLog);

    // Find max bits (to calculate weights)
    _maxBits = 1;
    for (var i = 0; i <= maxSym; i++) {
      if (numBits[i] > _maxBits) _maxBits = numBits[i];
    }

    // Calculate weights (weight = maxBits + 1 - numBits)
    final weights = List.filled(maxSym + 1, 0);
    for (var i = 0; i <= maxSym; i++) {
      if (numBits[i] > 0) {
        weights[i] = _maxBits + 1 - numBits[i];
      }
    }

    // Calculate tableLog from weights (same as decoder)
    var total = 0;
    for (var i = 0; i <= maxSym; i++) {
      if (weights[i] > 0) {
        total += (1 << weights[i]) >> 1;
      }
    }
    _tableLog = _highestBit(total) + 1;

    // Generate codes to match decoder's table building
    _generateCodesFromWeights(weights, maxSym);
  }

  /// Build Huffman tree and return bit lengths for each symbol
  List<int> _buildTree(final List<int> counts, final int maxSym) {
    // Create sorted list of (count, symbol) pairs
    final symbols = <_Symbol>[];
    for (var i = 0; i <= maxSym; i++) {
      if (counts[i] > 0) {
        symbols.add(_Symbol(i, counts[i]));
      }
    }
    symbols.sort((a, b) => a.count.compareTo(b.count));

    // Build tree using classic Huffman algorithm
    final nodes = <_Node>[];
    for (final sym in symbols) {
      nodes.add(_Node.leaf(sym.symbol, sym.count));
    }

    while (nodes.length > 1) {
      nodes.sort((a, b) => a.count.compareTo(b.count));
      final left = nodes.removeAt(0);
      final right = nodes.removeAt(0);
      nodes.add(_Node.internal(left, right));
    }

    // Extract bit lengths
    final numBits = List.filled(maxSym + 1, 0);
    if (nodes.isNotEmpty) {
      _assignDepths(nodes[0], 0, numBits);
    }

    return numBits;
  }

  void _assignDepths(final _Node node, final int depth, final List<int> bits) {
    if (node.symbol >= 0) {
      bits[node.symbol] = depth > 0 ? depth : 1;
    } else {
      _assignDepths(node.left!, depth + 1, bits);
      _assignDepths(node.right!, depth + 1, bits);
    }
  }

  /// Limit code lengths to maxDepth
  void _limitDepth(final List<int> bits, final int maxSym, final int maxDepth) {
    for (var i = 0; i <= maxSym; i++) {
      if (bits[i] > maxDepth) {
        bits[i] = maxDepth;
      }
    }
  }

  static int _highestBit(final int v) {
    if (v == 0) return 0;
    return v.bitLength - 1;
  }

  /// Generate codes that match the decoder's table building algorithm
  ///
  /// The decoder builds a table where entries are assigned by processing symbols
  /// in order, within each weight class. The code to write is the MSB portion
  /// of the table index.
  void _generateCodesFromWeights(final List<int> weights, final int maxSym) {
    _codes = List.filled(maxSym + 1, 0);
    _bits = List.filled(maxSym + 1, 0);

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
  /// Returns encoded data or null if compression failed
  Uint8List? encodeSingle(final Uint8List literals) {
    if (literals.isEmpty) return Uint8List(0);

    final writer = _BitWriter(literals.length * 2 + 8);

    // Encode in reverse order (last symbol first) per Zstd spec
    // This allows the decoder to read symbols in forward order
    final n = literals.length & ~3; // Align to 4

    // Handle remainder first (like Java: switch on inputSize & 3)
    switch (literals.length & 3) {
      case 3:
        writer.addBits(_codes[literals[n + 2]], _bits[literals[n + 2]]);
        continue case2;
      case2:
      case 2:
        writer.addBits(_codes[literals[n + 1]], _bits[literals[n + 1]]);
        continue case1;
      case1:
      case 1:
        writer.addBits(_codes[literals[n]], _bits[literals[n]]);
        writer.flush();
    }

    // Process 4 symbols at a time, in reverse
    for (var i = n; i > 0; i -= 4) {
      final s3 = literals[i - 1];
      final s2 = literals[i - 2];
      final s1 = literals[i - 3];
      final s0 = literals[i - 4];

      if (_bits[s3] == 0 ||
          _bits[s2] == 0 ||
          _bits[s1] == 0 ||
          _bits[s0] == 0) {
        return null;
      }

      writer.addBits(_codes[s3], _bits[s3]);
      writer.addBits(_codes[s2], _bits[s2]);
      writer.addBits(_codes[s1], _bits[s1]);
      writer.addBits(_codes[s0], _bits[s0]);
      writer.flush();
    }

    return writer.close();
  }

  /// Encode literals using 4 interleaved streams
  ///
  /// Returns encoded data with 6-byte jump table prefix, or null on failure
  Uint8List? encode4Streams(final Uint8List literals) {
    if (literals.length < 16) {
      return encodeSingle(literals);
    }

    final seg = (literals.length + 3) ~/ 4;
    final end1 = seg;
    final end2 = seg * 2;
    final end3 = seg * 3;

    final s1 = encodeSingle(Uint8List.sublistView(literals, 0, end1));
    final s2 = encodeSingle(Uint8List.sublistView(literals, end1, end2));
    final s3 = encodeSingle(Uint8List.sublistView(literals, end2, end3));
    final s4 = encodeSingle(Uint8List.sublistView(literals, end3));

    if (s1 == null || s2 == null || s3 == null || s4 == null) {
      return null;
    }

    // Build output with jump table
    final total = 6 + s1.length + s2.length + s3.length + s4.length;
    final output = Uint8List(total);

    // Jump table: 3 x uint16 LE sizes
    output[0] = s1.length & 0xFF;
    output[1] = (s1.length >> 8) & 0xFF;
    output[2] = s2.length & 0xFF;
    output[3] = (s2.length >> 8) & 0xFF;
    output[4] = s3.length & 0xFF;
    output[5] = (s3.length >> 8) & 0xFF;

    var pos = 6;
    output.setRange(pos, pos + s1.length, s1);
    pos += s1.length;
    output.setRange(pos, pos + s2.length, s2);
    pos += s2.length;
    output.setRange(pos, pos + s3.length, s3);
    pos += s3.length;
    output.setRange(pos, pos + s4.length, s4);

    return output;
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

  /// Encode weights header using direct encoding (4 bits per weight)
  ///
  /// Returns the encoded header bytes
  Uint8List encodeWeightsHeader(final int maxSym) {
    final weights = getWeights(maxSym);
    final count = maxSym; // Last symbol is implicit

    // Direct encoding: header byte + packed weights
    final size = 1 + (count + 1) ~/ 2;
    final output = Uint8List(size);

    // Header: count + 127
    output[0] = 127 + count;

    // Pack weights 2 per byte (high nibble first)
    for (var i = 0; i < count; i += 2) {
      final w1 = weights[i];
      final w2 = i + 1 < count ? weights[i + 1] : 0;
      output[1 + i ~/ 2] = (w1 << 4) | w2;
    }

    return output;
  }
}

/// Helper class for building Huffman tree
class _Symbol {
  final int symbol;
  final int count;
  _Symbol(this.symbol, this.count);
}

/// Node in Huffman tree
class _Node {
  final int symbol; // -1 for internal nodes
  final int count;
  final _Node? left;
  final _Node? right;

  _Node.leaf(this.symbol, this.count) : left = null, right = null;

  _Node.internal(_Node this.left, _Node this.right)
    : symbol = -1,
      count = left.count + right.count;
}

/// Forward bitstream writer (LSB-first accumulation, like Java BitOutputStream)
///
/// Writes bits LSB-first into a container, flushing complete bytes forward.
/// The final stream includes a sentinel bit for the decoder.
class _BitWriter {
  final Uint8List _buffer;
  BigInt _container = BigInt.zero;
  int _bitCount = 0;
  int _pos = 0;

  _BitWriter(final int size) : _buffer = Uint8List(size);

  void addBits(final int value, final int bits) {
    if (bits <= 0) return;
    final mask = (BigInt.one << bits) - BigInt.one;
    _container |= (BigInt.from(value) & mask) << _bitCount;
    _bitCount += bits;
  }

  void flush() {
    final bytes = _bitCount >> 3;
    for (var i = 0; i < bytes && _pos < _buffer.length; i++) {
      _buffer[_pos++] = (_container & BigInt.from(0xFF)).toInt();
      _container >>= 8;
    }
    _bitCount &= 7;
  }

  Uint8List? close() {
    // Add sentinel bit (marks end of stream)
    addBits(1, 1);
    flush();

    // Write any remaining bits
    if (_bitCount > 0 && _pos < _buffer.length) {
      _buffer[_pos++] = (_container & BigInt.from(0xFF)).toInt();
    }

    if (_pos == 0) return null;
    return Uint8List.sublistView(_buffer, 0, _pos);
  }
}
