import 'dart:typed_data';

import '../exceptions.dart';
import 'bit_reader.dart';

/// Root table size of the lookup tables for the large alphabets (literals,
/// insert-and-copy lengths, distances), as in the reference decoder.
const int rootBits = 8;

/// Longest code a Brotli prefix code may have (RFC 7932 section 3.5).
const int _maxLength = 15;

/// Order in which code-length code lengths are stored (section 3.5).
const List<int> _order = [
  1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
];

// The fixed code for code-length code lengths (section 3.5), indexed by the
// next 4 bits: how many bits the code takes and the length it stands for.
const List<int> _widths = [2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4];
const List<int> _values = [0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5];

/// A canonical prefix code (RFC 7932 section 3.2) with a two-level lookup
/// table.
///
/// Each entry is `length << 16 | symbol`. A root entry for codes longer than
/// the root is instead `(16 + bits) << 16 | offset`: a second-level table of
/// `1 << bits` entries at [offset], indexed by the bits after the root.
class PrefixCode {
  PrefixCode._(this._table, this._root);

  /// A code with one symbol, which takes no bits.
  PrefixCode.single(final int symbol) : this._(Int32List(1)..[0] = symbol, 0);

  /// The code for [lengths] (0 = unused), which must be complete.
  factory PrefixCode.lengths(final List<int> lengths, {final int root = 8}) {
    final counts = List.filled(_maxLength + 1, 0);
    var longest = 0;
    for (final length in lengths) {
      if (length == 0) continue;
      counts[length]++;
      if (length > longest) longest = length;
    }
    final next = List.filled(_maxLength + 1, 0);
    var code = 0;
    for (var bits = 1; bits <= _maxLength; bits++) {
      next[bits] = code;
      code = (code + counts[bits]) << 1;
    }
    final width = longest < root ? longest : root;
    final size = 1 << width;
    final mask = size - 1;

    // Bit-reversed codes, so a table index is the next bits as read.
    final codes = Int32List(lengths.length);
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      final length = lengths[symbol];
      if (length != 0) codes[symbol] = _reverse(next[length]++, length);
    }

    // Size the second-level tables: one per root index, as deep as the
    // longest code sharing it.
    final depths = Int32List(size);
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      final length = lengths[symbol];
      if (length > width) {
        final index = codes[symbol] & mask;
        if (length > depths[index]) depths[index] = length;
      }
    }
    final offsets = Int32List(size);
    var total = size;
    for (var index = 0; index < size; index++) {
      if (depths[index] != 0) {
        offsets[index] = total;
        total += 1 << (depths[index] - width);
      }
    }

    final table = Int32List(total);
    for (var index = 0; index < size; index++) {
      if (depths[index] != 0) {
        table[index] = (16 + depths[index] - width) << 16 | offsets[index];
      }
    }
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      final length = lengths[symbol];
      if (length == 0) continue;
      final entry = length << 16 | symbol;
      final reversed = codes[symbol];
      if (length <= width) {
        for (var i = reversed; i < size; i += 1 << length) {
          table[i] = entry;
        }
      } else {
        final index = reversed & mask;
        final end = offsets[index] + (1 << (depths[index] - width));
        for (
          var i = offsets[index] + (reversed >> width);
          i < end;
          i += 1 << (length - width)
        ) {
          table[i] = entry;
        }
      }
    }
    return PrefixCode._(table, width);
  }

  final Int32List _table;
  final int _root;

  /// Reads one symbol.
  int read(final BitReader reader) {
    final bits = reader.peek(_maxLength);
    var entry = _table[bits & ((1 << _root) - 1)];
    var length = entry >> 16;
    if (length > _maxLength) {
      final index = (bits >> _root) & ((1 << (length - 16)) - 1);
      entry = _table[(entry & 0xFFFF) + index];
      length = entry >> 16;
    }
    reader.skip(length);
    return entry & 0xFFFF;
  }
}

int _reverse(final int code, final int length) {
  var result = 0;
  for (var i = 0; i < length; i++) {
    result |= ((code >> i) & 1) << (length - 1 - i);
  }
  return result;
}

/// Reads a prefix code over [alphabet] symbols (RFC 7932 section 3.4 or 3.5).
PrefixCode readPrefixCode(
  final BitReader reader,
  final int alphabet, {
  final int root = rootBits,
}) {
  final skip = reader.bits(2);
  if (skip == 1) return _simple(reader, alphabet, root);
  return PrefixCode.lengths(readLengths(reader, alphabet, skip), root: root);
}

PrefixCode _simple(final BitReader reader, final int alphabet, final int root) {
  final count = reader.bits(2) + 1;
  final width = (alphabet - 1).bitLength;
  final symbols = List.filled(count, 0);
  for (var i = 0; i < count; i++) {
    final symbol = reader.bits(width);
    if (symbol >= alphabet) {
      throw BrotliFormatException(
        'Simple prefix code symbol $symbol is outside the alphabet',
      );
    }
    for (var j = 0; j < i; j++) {
      if (symbols[j] == symbol) {
        throw const BrotliFormatException(
          'Simple prefix code has a duplicate symbol',
        );
      }
    }
    symbols[i] = symbol;
  }
  if (count == 1) return PrefixCode.single(symbols[0]);
  final shape = switch (count) {
    2 => const [1, 1],
    3 => const [1, 2, 2],
    _ => reader.bit() == 0 ? const [2, 2, 2, 2] : const [1, 2, 3, 3],
  };
  final lengths = Uint8List(alphabet);
  for (var i = 0; i < count; i++) {
    lengths[symbols[i]] = shape[i];
  }
  return PrefixCode.lengths(lengths, root: root);
}

/// Reads the code lengths of a complex prefix code over [alphabet] symbols,
/// after its 2-bit HSKIP value [skip] (RFC 7932 section 3.5). The lengths
/// form a complete code.
Uint8List readLengths(
  final BitReader reader,
  final int alphabet,
  final int skip,
) {
  final lengthLengths = Uint8List(18);
  var space = 32;
  var used = 0;
  for (var i = skip; i < _order.length; i++) {
    final bits = reader.peek(4);
    reader.skip(_widths[bits]);
    final length = _values[bits];
    lengthLengths[_order[i]] = length;
    if (length != 0) {
      space -= 32 >> length;
      used++;
      if (space <= 0) break;
    }
  }
  if (used != 1 && space != 0) {
    throw const BrotliFormatException('Code-length code is not complete');
  }
  final code = used == 1
      ? PrefixCode.single(lengthLengths.indexWhere((final n) => n != 0))
      : PrefixCode.lengths(lengthLengths, root: 5);

  final lengths = Uint8List(alphabet);
  const full = 1 << _maxLength;
  var free = full;
  var symbol = 0;
  var previous = 8;
  var repeat = 0;
  var repeated = 0;
  while (symbol < alphabet && free > 0) {
    final length = code.read(reader);
    if (length < 16) {
      repeat = 0;
      lengths[symbol++] = length;
      if (length != 0) {
        previous = length;
        free -= full >> length;
      }
      continue;
    }
    final extra = length == 16 ? 2 : 3;
    final value = length == 16 ? previous : 0;
    if (repeated != value) {
      repeat = 0;
      repeated = value;
    }
    final old = repeat;
    if (repeat > 0) repeat = (repeat - 2) << extra;
    repeat += reader.bits(extra) + 3;
    final count = repeat - old;
    if (symbol + count > alphabet) {
      throw const BrotliFormatException(
        'Code length repeat runs past the alphabet',
      );
    }
    if (value != 0) {
      lengths.fillRange(symbol, symbol + count, value);
      free -= count * (full >> value);
    }
    symbol += count;
  }
  if (free != 0) {
    throw BrotliFormatException(
      free > 0 ? 'Prefix code is incomplete' : 'Prefix code is over-subscribed',
    );
  }
  return lengths;
}
