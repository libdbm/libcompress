import 'dart:typed_data';

/// The sequences of one Zstd block: for each match, its absolute offset, its
/// length, and the number of literals before it.
///
/// The lists are reused from block to block, so only the first [count]
/// entries are sequences, and only until the next [clear].
final class Sequences {
  Int32List _offsets = Int32List(0);
  Int32List _lengths = Int32List(0);
  Int32List _literals = Int32List(0);
  int _count = 0;

  /// The number of sequences.
  int get count => _count;

  /// Match offsets (absolute distances back).
  Int32List get offsets => _offsets;

  /// Match lengths.
  Int32List get lengths => _lengths;

  /// Literal lengths: the literals before each match.
  Int32List get literals => _literals;

  /// Empties the list, with room for at least [capacity] sequences.
  void clear(final int capacity) {
    if (_offsets.length < capacity) {
      _offsets = Int32List(capacity);
      _lengths = Int32List(capacity);
      _literals = Int32List(capacity);
    }
    _count = 0;
  }

  /// Appends a match of [length] at [offset] after [literals] literals.
  void add(final int offset, final int length, final int literals) {
    _offsets[_count] = offset;
    _lengths[_count] = length;
    _literals[_count] = literals;
    _count++;
  }
}
