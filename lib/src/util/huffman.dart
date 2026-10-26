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

  /// Computes Huffman code lengths limited to [maxBits].
  ///
  /// Builds an unconstrained Huffman tree; while its longest code exceeds
  /// [maxBits], halves every non-zero frequency (rounding up, so no symbol
  /// drops out) and rebuilds. Every result is a real Huffman tree, so the code
  /// is always complete (Kraft sum exactly 1) and never over-subscribed. The
  /// loop terminates: once all frequencies reach 1 the tree is balanced, with
  /// depth ceil(log2(symbols)). This trades a little optimality for
  /// guaranteed validity (RFC 1951 Section 3.2.2, RFC 8878 Section 4.2.1).
  ///
  /// Returns `result[symbol]` = code length, 0 for zero-frequency symbols. A
  /// single used symbol gets length 1. Throws [ArgumentError] if [maxBits] is
  /// not positive or the used symbols cannot fit in [maxBits] bits.
  static List<int> computeLimitedCodeLengths(
    List<int> frequencies,
    int maxBits,
  ) {
    if (maxBits <= 0) {
      throw ArgumentError('maxBits must be positive');
    }
    final used = frequencies.where((frequency) => frequency > 0).length;
    if (maxBits < 31 && used > (1 << maxBits)) {
      throw ArgumentError('$used symbols cannot fit in $maxBits-bit codes');
    }

    var scaled = frequencies;
    while (true) {
      final lengths = _codeLengths(scaled);
      if (lengths.every((length) => length <= maxBits)) return lengths;
      scaled = [
        for (final frequency in scaled)
          frequency > 0 ? (frequency + 1) >> 1 : 0,
      ];
    }
  }

  /// Unconstrained Huffman code lengths for [frequencies].
  static List<int> _codeLengths(List<int> frequencies) {
    final lengths = List<int>.filled(frequencies.length, 0);
    final codes = generateCodes(build(frequencies), frequencies.length);
    for (final entry in codes.entries) {
      lengths[entry.key] = entry.value.length;
    }
    return lengths;
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
