import 'dart:typed_data';

import 'deflate_common.dart';

/// The alphabet a [HuffmanDecoder] decodes, which sets its root width and
/// what its entries hold.
enum Alphabet {
  /// Code lengths (RFC 1951 section 3.2.7): entries hold the symbol.
  plain,

  /// Literal/length codes: entries hold a literal byte, the end of the block,
  /// or a match length base and its extra-bit count.
  literals,

  /// Distance codes: entries hold a distance base and its extra-bit count.
  distances,
}

/// Bits 0-3 of an entry: the code length.
const int entryLength = 0xF;

/// Set in a link to a subtable. The link's value is the subtable offset and
/// its extra-bit count is the subtable's index width.
const int entrySubtable = 1 << 8;

/// Set for the end of a block, an invalid symbol (its value is the symbol),
/// and an index no code maps to (code length 0).
const int entryException = 1 << 9;

/// Set, with [entryException], for the end of a block.
const int entryEnd = 1 << 10;

/// Set for a literal: its value is the byte.
const int entryLiteral = 1 << 11;

/// The count of extra bits after the code (bits 4-7 of [entry]).
int entryExtra(final int entry) => (entry >> 4) & 0xF;

/// The value of [entry] (bits 16 and up): a literal byte, a length or
/// distance base, a symbol, or a subtable offset.
int entryValue(final int entry) => entry >> 16;

/// Huffman decoder using two-level lookup tables, with libdeflate's packed
/// entries: one lookup gives the code length, the extra-bit count and the
/// value (a literal, or the base a length or distance adds its extra bits to).
///
/// [table] starts with a root table indexed by the next [root] input bits in
/// DEFLATE's LSB-first order (that is, by bit-reversed codes), followed by
/// subtables for codes longer than [root]. Entries are described by
/// [entryLength], [entryExtra], [entryValue] and the `entry*` flags. Values
/// stay below 2^15 (subtable offsets of a 286-symbol alphabet included), so
/// entries are exact on dart2js.
class HuffmanDecoder {
  /// Root table followed by the subtables.
  final Uint32List table;

  /// Longest code length: the most bits a lookup may need.
  final int bits;

  /// Number of bits the root table is indexed by.
  final int root;

  HuffmanDecoder(this.table, this.bits, this.root);
}

/// Root table index bits, at most, per [Alphabet]. libdeflate (and the Java
/// port) use 10 for literal/length codes; 9 measured as fast on large inputs
/// and avoids a 5-10% loss on 1 KB pages, where building the table dominates.
const List<int> _roots = [7, 9, 8];

/// The entry for [symbol] of [alphabet], without its code length.
int _entry(final Alphabet alphabet, final int symbol) {
  switch (alphabet) {
    case Alphabet.plain:
      return symbol << 16;
    case Alphabet.distances:
      return symbol < 30
          ? distanceBase[symbol] << 16 | distanceExtraBits[symbol] << 4
          : entryException | symbol << 16;
    case Alphabet.literals:
      if (symbol < 256) return entryLiteral | symbol << 16;
      if (symbol == endBlock) return entryException | entryEnd;
      return symbol <= 285
          ? lengthBase[symbol - 257] << 16 | lengthExtraBits[symbol - 257] << 4
          : entryException | symbol << 16;
  }
}

/// Builds a Huffman decoder from code lengths.
///
/// Validates the set forms a valid prefix code (RFC 1951 §3.2.2): an
/// over-subscribed set (codes overflow the space, aliasing symbols and
/// silently mis-decoding) is always rejected; an *incomplete* set is rejected
/// too — except an empty table or a single 1-bit code (which zlib permits), or
/// when [allowIncomplete] is set for the RFC fixed distance table, which is
/// itself incomplete (30 codes of length 5).
HuffmanDecoder buildDecoder(
  final List<int> lengths, {
  final Alphabet alphabet = Alphabet.plain,
  final bool allowIncomplete = false,
}) {
  final counts = Int32List(16);
  var bits = 0;
  for (final length in lengths) {
    if (length < 0 || length > 15) {
      throw DeflateFormatException('Invalid Huffman code length: $length');
    }
    counts[length]++;
    if (length > bits) bits = length;
  }
  counts[0] = 0;
  _validateCounts(counts, bits, allowIncomplete);

  // Canonical codes (RFC 1951 §3.2.2), assigned in symbol order.
  final starts = Int32List(16);
  var code = 0;
  for (var length = 1; length <= 15; length++) {
    code = (code + counts[length - 1]) << 1;
    starts[length] = code;
  }
  final reversed = Int32List(lengths.length);
  for (var symbol = 0; symbol < lengths.length; symbol++) {
    final length = lengths[symbol];
    if (length == 0) continue;
    final value = starts[length]++;
    var result = 0;
    for (var i = 0; i < length; i++) {
      result = (result << 1) | ((value >> i) & 1);
    }
    reversed[symbol] = result;
  }

  final limit = _roots[alphabet.index];
  final root = bits < limit ? bits : limit;
  final rootSize = 1 << root;
  final rootMask = rootSize - 1;
  final extra = bits - root;
  final subSize = 1 << extra;

  // Give each root prefix shared by codes longer than [root] a subtable.
  final offsets = Int32List(rootSize);
  var size = rootSize;
  for (var symbol = 0; symbol < lengths.length; symbol++) {
    if (lengths[symbol] <= root) continue;
    final prefix = reversed[symbol] & rootMask;
    if (offsets[prefix] == 0) {
      offsets[prefix] = size;
      size += subSize;
    }
  }

  final table = Uint32List(size)..fillRange(0, size, entryException);
  for (var prefix = 0; prefix < rootSize; prefix++) {
    final offset = offsets[prefix];
    if (offset != 0) table[prefix] = offset << 16 | entrySubtable | extra << 4;
  }
  for (var symbol = 0; symbol < lengths.length; symbol++) {
    final length = lengths[symbol];
    if (length == 0) continue;
    final entry = _entry(alphabet, symbol) | length;
    final value = reversed[symbol];
    if (length <= root) {
      for (var index = value; index < rootSize; index += 1 << length) {
        table[index] = entry;
      }
    } else {
      final base = offsets[value & rootMask];
      for (
        var index = value >> root;
        index < subSize;
        index += 1 << (length - root)
      ) {
        table[base + index] = entry;
      }
    }
  }

  return HuffmanDecoder(table, bits, root);
}

/// Checks that code-length [counts] (per length, longest [bits]) form a valid
/// prefix code; see [buildDecoder].
void _validateCounts(
  final Int32List counts,
  final int bits,
  final bool allowIncomplete,
) {
  if (bits == 0) {
    return; // empty table (e.g. no distance codes) is allowed
  }

  // Kraft inequality: the codes must not overflow the 2^width code space.
  var left = 1;
  for (var width = 1; width <= 15; width++) {
    left = (left << 1) - counts[width];
    if (left < 0) {
      throw DeflateFormatException('Over-subscribed Huffman code');
    }
  }
  // Incomplete code: allowed only for the RFC fixed tables (allowIncomplete) or
  // a single 1-bit code (zlib's exception); otherwise it is malformed.
  if (left > 0 && !allowIncomplete && bits > 1) {
    throw DeflateFormatException('Incomplete Huffman code');
  }
}

/// Shared fixed-Huffman decoders.
///
/// The RFC 1951 fixed literal/length and distance tables are constant, so the
/// decoders are built once on first use and reused across all fixed blocks.
final HuffmanDecoder fixedLiteralDecoder = buildFixedLiteralDecoder();

/// See [fixedLiteralDecoder].
final HuffmanDecoder fixedDistanceDecoder = buildFixedDistanceDecoder();

/// Builds the fixed literal/length Huffman decoder
HuffmanDecoder buildFixedLiteralDecoder() {
  final lengths = List<int>.filled(288, 0);

  // 0-143: 8 bits
  for (var i = 0; i <= 143; i++) {
    lengths[i] = 8;
  }

  // 144-255: 9 bits
  for (var i = 144; i <= 255; i++) {
    lengths[i] = 9;
  }

  // 256-279: 7 bits
  for (var i = 256; i <= 279; i++) {
    lengths[i] = 7;
  }

  // 280-287: 8 bits
  for (var i = 280; i <= 287; i++) {
    lengths[i] = 8;
  }

  return buildDecoder(lengths, alphabet: Alphabet.literals);
}

/// Builds the fixed distance Huffman decoder.
///
/// The RFC 1951 fixed distance code is 30 codes of length 5 — incomplete by
/// design (codes 30-31 are unused), so [allowIncomplete] is required.
HuffmanDecoder buildFixedDistanceDecoder() {
  final lengths = List<int>.filled(30, 5);
  return buildDecoder(
    lengths,
    alphabet: Alphabet.distances,
    allowIncomplete: true,
  );
}
