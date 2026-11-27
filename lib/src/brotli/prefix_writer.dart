import 'dart:typed_data';

import '../util/huffman.dart';
import 'bit_writer.dart';

/// Order in which code-length code lengths are stored (RFC 7932 section 3.5).
const List<int> _order = [
  1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
];

// The fixed code for code-length code lengths 0..5 (section 3.5): the bits as
// written, least significant first, and their count.
const List<int> _patterns = [0, 7, 3, 2, 1, 15];
const List<int> _widths = [2, 4, 3, 2, 2, 4];

/// A prefix code chosen for a histogram: per-symbol code lengths and the
/// bit-reversed canonical codes to write.
class PrefixCodes {
  PrefixCodes._(this.lengths, this.codes);

  /// The code for [counts] (symbol frequencies), with lengths of at most 15
  /// bits. A single used symbol takes zero bits; with no used symbol, symbol 0
  /// is given that zero-bit code.
  factory PrefixCodes.build(final List<int> counts) {
    final used = <int>[];
    for (var symbol = 0; symbol < counts.length; symbol++) {
      if (counts[symbol] > 0) used.add(symbol);
    }
    if (used.length <= 1) {
      return PrefixCodes._(Uint8List(counts.length), Int32List(counts.length))
        .._single = used.isEmpty ? 0 : used.first;
    }
    final lengths = Uint8List.fromList(
      HuffmanTreeBuilder.computeLimitedCodeLengths(counts, 15),
    );
    return PrefixCodes._(lengths, canonical(lengths));
  }

  final Uint8List lengths;
  final Int32List codes;

  // The one symbol of a zero-bit code, or -1.
  int _single = -1;

  /// Writes [symbol]'s code.
  void put(final BitWriter writer, final int symbol) {
    final length = lengths[symbol];
    if (length != 0) writer.bits(codes[symbol], length);
  }

  /// Cost in bits of writing [symbol].
  int cost(final int symbol) => lengths[symbol];

  /// Writes the code's description (section 3.4 or 3.5) for an alphabet of
  /// `lengths.length` symbols.
  void describe(final BitWriter writer) {
    final alphabet = lengths.length;
    final width = (alphabet - 1).bitLength;
    if (_single >= 0) {
      writer
        ..bits(1, 2)
        ..bits(0, 2)
        ..bits(_single, width);
      return;
    }
    final used = <int>[];
    for (var symbol = 0; symbol < alphabet; symbol++) {
      if (lengths[symbol] != 0) used.add(symbol);
    }
    if (used.length <= 4) {
      _simple(writer, used, width);
    } else {
      _complex(writer);
    }
  }

  void _simple(final BitWriter writer, final List<int> used, final int width) {
    // Listed in order of increasing length; the decoder gives the lengths
    // 1,1 / 1,2,2 / 2,2,2,2 or 1,2,3,3 in that order.
    used.sort((final a, final b) => lengths[a].compareTo(lengths[b]));
    writer
      ..bits(1, 2)
      ..bits(used.length - 1, 2);
    for (final symbol in used) {
      writer.bits(symbol, width);
    }
    if (used.length == 4) writer.bits(lengths[used.first] == 1 ? 1 : 0, 1);
  }

  void _complex(final BitWriter writer) {
    var last = lengths.length;
    while (lengths[last - 1] == 0) {
      last--;
    }
    final symbols = <int>[];
    final extras = <int>[];
    _runs(lengths, last, symbols, extras);

    final counts = List.filled(18, 0);
    for (final symbol in symbols) {
      counts[symbol]++;
    }
    final distinct = counts.where((final count) => count > 0).length;
    final lengthLengths = distinct == 1
        ? (List.filled(18, 0)..[symbols.first] = 1)
        : HuffmanTreeBuilder.computeLimitedCodeLengths(counts, 5);
    final lengthCodes = canonical(lengthLengths);

    var skip = 0;
    if (lengthLengths[_order[0]] == 0 && lengthLengths[_order[1]] == 0) {
      skip = lengthLengths[_order[2]] == 0 ? 3 : 2;
    }
    // The decoder reads entries until the code space is used up, so stop at
    // the last used entry; with one used entry it reads all of them.
    var end = _order.length;
    if (distinct > 1) {
      while (lengthLengths[_order[end - 1]] == 0) {
        end--;
      }
    }
    writer.bits(skip, 2);
    for (var i = skip; i < end; i++) {
      final length = lengthLengths[_order[i]];
      writer.bits(_patterns[length], _widths[length]);
    }
    for (var i = 0; i < symbols.length; i++) {
      final symbol = symbols[i];
      if (distinct > 1) {
        writer.bits(lengthCodes[symbol], lengthLengths[symbol]);
      }
      if (symbol == 16) writer.bits(extras[i], 2);
      if (symbol == 17) writer.bits(extras[i], 3);
    }
  }
}

/// Run-length codes the first [count] [lengths] with repeat codes 16 and 17
/// (section 3.5), as the reference encoder's `BrotliWriteHuffmanTree`.
void _runs(
  final Uint8List lengths,
  final int count,
  final List<int> symbols,
  final List<int> extras,
) {
  var previous = 8;
  var i = 0;
  while (i < count) {
    final value = lengths[i];
    var run = 1;
    while (i + run < count && lengths[i + run] == value) {
      run++;
    }
    if (value == 0) {
      _zeros(run, symbols, extras);
    } else {
      _repeats(previous, value, run, symbols, extras);
      previous = value;
    }
    i += run;
  }
}

void _zeros(final int count, final List<int> symbols, final List<int> extras) {
  var run = count;
  if (run == 11) {
    symbols.add(0);
    extras.add(0);
    run--;
  }
  if (run < 3) {
    for (var i = 0; i < run; i++) {
      symbols.add(0);
      extras.add(0);
    }
    return;
  }
  final start = symbols.length;
  run -= 3;
  while (true) {
    symbols.add(17);
    extras.add(run & 7);
    run >>= 3;
    if (run == 0) break;
    run--;
  }
  _reverse(symbols, start);
  _reverse(extras, start);
}

void _repeats(
  final int previous,
  final int value,
  final int count,
  final List<int> symbols,
  final List<int> extras,
) {
  var run = count;
  if (previous != value) {
    symbols.add(value);
    extras.add(0);
    run--;
  }
  if (run == 7) {
    symbols.add(value);
    extras.add(0);
    run--;
  }
  if (run < 3) {
    for (var i = 0; i < run; i++) {
      symbols.add(value);
      extras.add(0);
    }
    return;
  }
  final start = symbols.length;
  run -= 3;
  while (true) {
    symbols.add(16);
    extras.add(run & 3);
    run >>= 2;
    if (run == 0) break;
    run--;
  }
  _reverse(symbols, start);
  _reverse(extras, start);
}

void _reverse(final List<int> values, final int start) {
  var low = start;
  var high = values.length - 1;
  while (low < high) {
    final value = values[low];
    values[low++] = values[high];
    values[high--] = value;
  }
}

/// Bit-reversed canonical codes for [lengths] (section 3.2), ready to write
/// least significant bit first.
Int32List canonical(final List<int> lengths) {
  final counts = List.filled(16, 0);
  for (final length in lengths) {
    if (length > 0) counts[length]++;
  }
  final next = List.filled(16, 0);
  var code = 0;
  for (var bits = 1; bits < 16; bits++) {
    next[bits] = code;
    code = (code + counts[bits]) << 1;
  }
  final codes = Int32List(lengths.length);
  for (var symbol = 0; symbol < lengths.length; symbol++) {
    final length = lengths[symbol];
    if (length == 0) continue;
    var value = next[length]++;
    var reversed = 0;
    for (var i = 0; i < length; i++) {
      reversed = (reversed << 1) | (value & 1);
      value >>= 1;
    }
    codes[symbol] = reversed;
  }
  return codes;
}
