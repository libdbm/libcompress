import 'dart:typed_data';

import '../exceptions.dart';

/// Huffman decoder using two-level lookup tables
///
/// [table] starts with a root table indexed by the next [root] input bits in
/// DEFLATE's LSB-first order (that is, by bit-reversed codes). A root entry is
/// either `symbol << 5 | length` for a code of at most [root] bits, or a link
/// `offset << 5 | 16 | extra` to a subtable at `offset`, indexed by the next
/// `extra` bits, whose entries are `symbol << 5 | length`. 0 marks an index no
/// code maps to. A root of at most 9 bits keeps building a table cheap even
/// when codes reach 15 bits.
class HuffmanDecoder {
  /// Root table followed by the subtables.
  final Uint32List table;

  /// Longest code length: the most bits a lookup may need.
  final int bits;

  /// Number of bits the root table is indexed by.
  final int root;

  HuffmanDecoder(this.table, this.bits, this.root);
}

/// Root table index bits, at most (as zlib uses for literal/length codes).
const int _rootBits = 9;

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

  final root = bits < _rootBits ? bits : _rootBits;
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

  final table = Uint32List(size);
  for (var prefix = 0; prefix < rootSize; prefix++) {
    final offset = offsets[prefix];
    if (offset != 0) table[prefix] = offset << 5 | 16 | extra;
  }
  for (var symbol = 0; symbol < lengths.length; symbol++) {
    final length = lengths[symbol];
    if (length == 0) continue;
    final entry = symbol << 5 | length;
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

  return buildDecoder(lengths);
}

/// Builds the fixed distance Huffman decoder.
///
/// The RFC 1951 fixed distance code is 30 codes of length 5 — incomplete by
/// design (codes 30-31 are unused), so [allowIncomplete] is required.
HuffmanDecoder buildFixedDistanceDecoder() {
  final lengths = List<int>.filled(30, 5);
  return buildDecoder(lengths, allowIncomplete: true);
}
