/// Huffman tree node for encoding/decoding
class HuffmanNode implements Comparable<HuffmanNode> {
  final int? symbol;
  final int frequency;
  final HuffmanNode? left;
  final HuffmanNode? right;

  HuffmanNode({this.symbol, required this.frequency, this.left, this.right});

  bool get isLeaf => left == null && right == null;

  @override
  int compareTo(HuffmanNode other) => frequency.compareTo(other.frequency);
}

/// Huffman code table entry
class HuffmanCode {
  final int code;
  final int length;

  const HuffmanCode(this.code, this.length);
}

/// Builds a Huffman tree from symbol frequencies
class HuffmanTreeBuilder {
  /// Builds a Huffman tree from frequency counts
  ///
  /// Returns the root node of the tree, or null if no symbols exist.
  static HuffmanNode? build(List<int> frequencies) {
    final queue = PriorityQueue<HuffmanNode>();

    // Create leaf nodes for all symbols with non-zero frequency
    for (var i = 0; i < frequencies.length; i++) {
      if (frequencies[i] > 0) {
        queue.add(HuffmanNode(symbol: i, frequency: frequencies[i]));
      }
    }

    if (queue.isEmpty) {
      return null;
    }

    // Build tree by combining lowest frequency nodes
    while (queue.length > 1) {
      final left = queue.removeFirst();
      final right = queue.removeFirst();

      final parent = HuffmanNode(
        frequency: left.frequency + right.frequency,
        left: left,
        right: right,
      );

      queue.add(parent);
    }

    return queue.first;
  }

  /// Generates Huffman code table from a tree
  ///
  /// Returns a map from symbol to (code, length) pairs.
  static Map<int, HuffmanCode> generateCodes(
    HuffmanNode? root,
    int maxSymbols,
  ) {
    final codes = <int, HuffmanCode>{};

    if (root == null) {
      return codes;
    }

    // Handle single-symbol tree (degenerate case)
    if (root.isLeaf) {
      codes[root.symbol!] = const HuffmanCode(0, 1);
      return codes;
    }

    _generateCodesRecursive(root, 0, 0, codes);
    return codes;
  }

  static void _generateCodesRecursive(
    HuffmanNode node,
    int code,
    int length,
    Map<int, HuffmanCode> codes,
  ) {
    if (node.isLeaf) {
      codes[node.symbol!] = HuffmanCode(code, length);
      return;
    }

    if (node.left != null) {
      _generateCodesRecursive(node.left!, code << 1, length + 1, codes);
    }

    if (node.right != null) {
      _generateCodesRecursive(node.right!, (code << 1) | 1, length + 1, codes);
    }
  }

  /// Generates canonical Huffman codes from code lengths
  ///
  /// Canonical codes have the property that codes of the same length
  /// are sequential, which makes them easier to transmit and decode.
  static Map<int, HuffmanCode> generateCanonicalCodes(List<int> codeLengths) {
    final codes = <int, HuffmanCode>{};

    // Find max code length
    var maxLength = 0;
    for (final len in codeLengths) {
      if (len > maxLength) {
        maxLength = len;
      }
    }

    if (maxLength == 0) {
      return codes;
    }

    // Count symbols at each code length
    final lengthCounts = List<int>.filled(maxLength + 1, 0);
    for (final len in codeLengths) {
      if (len > 0) {
        lengthCounts[len]++;
      }
    }

    // Compute starting code for each length
    final nextCode = List<int>.filled(maxLength + 1, 0);
    var code = 0;
    for (var i = 1; i <= maxLength; i++) {
      code = (code + lengthCounts[i - 1]) << 1;
      nextCode[i] = code;
    }

    // Assign codes to symbols
    for (var symbol = 0; symbol < codeLengths.length; symbol++) {
      final len = codeLengths[symbol];
      if (len > 0) {
        codes[symbol] = HuffmanCode(nextCode[len], len);
        nextCode[len]++;
      }
    }

    return codes;
  }

  /// Computes optimal code lengths limited to maxBits
  ///
  /// Builds a Huffman tree and applies a length-limiting adjustment to
  /// ensure no code exceeds maxBits. This is required for DEFLATE which
  /// limits literal/length codes to 15 bits and distance codes to 15 bits.
  ///
  /// ## Algorithm
  ///
  /// This implementation uses a two-phase approach:
  ///
  /// 1. **Build optimal tree**: First constructs an unconstrained Huffman tree
  ///    using the standard algorithm, which may produce codes longer than maxBits.
  ///
  /// 2. **Apply length limiting**: If any codes exceed maxBits, redistributes
  ///    bit lengths using a heuristic based on the Kraft inequality. Codes that
  ///    are too long are shortened to maxBits, and shorter codes are lengthened
  ///    to maintain a valid prefix-free code.
  ///
  /// The redistribution ensures:
  /// - Sum of 2^(-length) for all codes equals 1.0 (Kraft inequality)
  /// - No code exceeds maxBits
  /// - Symbols with lower frequencies get longer codes
  ///
  /// ## Parameters
  ///
  /// - [frequencies]: Symbol frequency counts (index = symbol value)
  /// - [maxBits]: Maximum allowed code length (typically 15 for DEFLATE)
  ///
  /// ## Returns
  ///
  /// List where `result[symbol]` is the bit length for that symbol.
  /// Symbols with zero frequency have length 0 (no code assigned).
  ///
  /// ## References
  ///
  /// - RFC 1951 Section 3.2.2 (DEFLATE Huffman coding)
  /// - Larmore & Hirschberg, "A Fast Algorithm for Optimal Length-Limited
  ///   Huffman Codes" (for the theoretical background)
  static List<int> computeLimitedCodeLengths(
    List<int> frequencies,
    int maxBits,
  ) {
    if (maxBits <= 0) {
      throw ArgumentError('maxBits must be positive');
    }

    final n = frequencies.length;
    final lengths = List<int>.filled(n, 0);
    final symbols = <int>[];

    for (var i = 0; i < n; i++) {
      if (frequencies[i] > 0) {
        symbols.add(i);
      }
    }

    if (symbols.isEmpty) {
      return lengths;
    }

    if (symbols.length == 1) {
      lengths[symbols.first] = 1;
      return lengths;
    }

    final tree = build(frequencies);
    if (tree == null) {
      return lengths;
    }

    final codes = generateCodes(tree, n);
    var maxLen = 0;
    for (final entry in codes.entries) {
      final len = entry.value.length;
      lengths[entry.key] = len;
      if (len > maxLen) {
        maxLen = len;
      }
    }

    if (maxLen <= maxBits) {
      return lengths;
    }

    final blCount = List<int>.filled(maxBits + 1, 0);
    var overflow = 0;

    for (final len in lengths) {
      if (len == 0) {
        continue;
      }
      if (len > maxBits) {
        overflow++;
        blCount[maxBits]++;
      } else {
        blCount[len]++;
      }
    }

    while (overflow > 0) {
      var bits = maxBits - 1;
      while (bits > 0 && blCount[bits] == 0) {
        bits--;
      }
      if (bits == 0) {
        break;
      }

      blCount[bits]--;
      blCount[bits + 1] += 2;
      blCount[maxBits]--;
      overflow -= 2;
    }

    var total = 0;
    for (var bits = 1; bits <= maxBits; bits++) {
      total += blCount[bits];
    }
    if (total < symbols.length) {
      blCount[maxBits] += symbols.length - total;
    } else if (total > symbols.length) {
      var extra = total - symbols.length;
      for (var bits = maxBits; bits >= 1 && extra > 0; bits--) {
        final reduce = extra < blCount[bits] ? extra : blCount[bits];
        blCount[bits] -= reduce;
        extra -= reduce;
      }
    }

    symbols.sort((a, b) {
      final freqCompare = frequencies[a].compareTo(frequencies[b]);
      return freqCompare != 0 ? freqCompare : a.compareTo(b);
    });

    final limited = List<int>.filled(n, 0);
    var symbolIndex = 0;
    for (var bits = maxBits; bits >= 1; bits--) {
      final count = blCount[bits];
      for (var i = 0; i < count; i++) {
        if (symbolIndex >= symbols.length) {
          break;
        }
        limited[symbols[symbolIndex++]] = bits;
      }
    }

    return limited;
  }
}

/// Priority queue implementation for Huffman tree building
class PriorityQueue<T extends Comparable> {
  final List<T> _heap = [];

  void add(T item) {
    _heap.add(item);
    _bubbleUp(_heap.length - 1);
  }

  T removeFirst() {
    if (_heap.isEmpty) {
      throw StateError('Queue is empty');
    }

    final result = _heap[0];
    final last = _heap.removeLast();

    if (_heap.isNotEmpty) {
      _heap[0] = last;
      _bubbleDown(0);
    }

    return result;
  }

  T get first => _heap[0];
  int get length => _heap.length;
  bool get isEmpty => _heap.isEmpty;

  void _bubbleUp(int index) {
    while (index > 0) {
      final parentIndex = (index - 1) ~/ 2;
      if (_heap[index].compareTo(_heap[parentIndex]) >= 0) {
        break;
      }
      _swap(index, parentIndex);
      index = parentIndex;
    }
  }

  void _bubbleDown(int index) {
    while (true) {
      final leftChild = 2 * index + 1;
      final rightChild = 2 * index + 2;
      var smallest = index;

      if (leftChild < _heap.length &&
          _heap[leftChild].compareTo(_heap[smallest]) < 0) {
        smallest = leftChild;
      }

      if (rightChild < _heap.length &&
          _heap[rightChild].compareTo(_heap[smallest]) < 0) {
        smallest = rightChild;
      }

      if (smallest == index) {
        break;
      }

      _swap(index, smallest);
      index = smallest;
    }
  }

  void _swap(int i, int j) {
    final temp = _heap[i];
    _heap[i] = _heap[j];
    _heap[j] = temp;
  }
}
