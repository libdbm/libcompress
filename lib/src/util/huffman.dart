/// Huffman tree node for encoding/decoding
class HuffmanNode implements Comparable<HuffmanNode> {
  final int? symbol;
  final int frequency;
  final HuffmanNode? left;
  final HuffmanNode? right;

  HuffmanNode({this.symbol, required this.frequency, this.left, this.right});

  bool get isLeaf => left == null && right == null;

  @override
  int compareTo(final HuffmanNode other) =>
      frequency.compareTo(other.frequency);
}

/// Builds a Huffman tree from symbol frequencies
class HuffmanTreeBuilder {
  /// Builds a Huffman tree from frequency counts
  ///
  /// Returns the root node of the tree, or null if no symbols exist.
  static HuffmanNode? build(final List<int> frequencies) {
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

  /// Records each leaf's depth below [node] in [lengths].
  static void _depths(
    final HuffmanNode node,
    final int depth,
    final List<int> lengths,
  ) {
    final symbol = node.symbol;
    if (symbol != null) {
      lengths[symbol] = depth;
      return;
    }
    _depths(node.left!, depth + 1, lengths);
    _depths(node.right!, depth + 1, lengths);
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
    final List<int> frequencies,
    final int maxBits,
  ) {
    if (maxBits <= 0) {
      throw ArgumentError('maxBits must be positive');
    }
    final used = frequencies.where((final frequency) => frequency > 0).length;
    if (maxBits < 31 && used > (1 << maxBits)) {
      throw ArgumentError('$used symbols cannot fit in $maxBits-bit codes');
    }

    var scaled = frequencies;
    while (true) {
      final lengths = _codeLengths(scaled);
      if (lengths.every((final length) => length <= maxBits)) return lengths;
      scaled = [
        for (final frequency in scaled)
          frequency > 0 ? (frequency + 1) >> 1 : 0,
      ];
    }
  }

  /// Unconstrained Huffman code lengths for [frequencies].
  static List<int> _codeLengths(final List<int> frequencies) {
    final lengths = List<int>.filled(frequencies.length, 0);
    final root = build(frequencies);
    if (root == null) return lengths;
    // A single used symbol still needs a 1-bit code.
    if (root.isLeaf) {
      lengths[root.symbol!] = 1;
      return lengths;
    }
    _depths(root, 0, lengths);
    return lengths;
  }
}

/// Priority queue implementation for Huffman tree building
class PriorityQueue<T extends Comparable> {
  final List<T> _heap = [];

  void add(final T item) {
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

  void _swap(final int i, final int j) {
    final temp = _heap[i];
    _heap[i] = _heap[j];
    _heap[j] = temp;
  }
}
