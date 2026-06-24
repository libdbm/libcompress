import '../exceptions.dart';
import '../util/huffman.dart';

/// Huffman decoder using lookup tables
class HuffmanDecoder {
  /// Maps code length -> code -> symbol
  final Map<int, Map<int, int>> _codeToSymbol;

  HuffmanDecoder(this._codeToSymbol);

  /// Decodes a symbol from a code of given length
  ///
  /// Returns null if no symbol matches.
  int? decode(int code, int length) {
    final table = _codeToSymbol[length];
    if (table == null) return null;
    return table[code];
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
HuffmanDecoder buildDecoder(List<int> lengths, {bool allowIncomplete = false}) {
  _validateCodeLengths(lengths, allowIncomplete);

  // Generate canonical codes
  final codes = HuffmanTreeBuilder.generateCanonicalCodes(lengths);

  // Build lookup table
  final codeToSymbol = <int, Map<int, int>>{};
  for (final entry in codes.entries) {
    final symbol = entry.key;
    final code = entry.value;

    codeToSymbol.putIfAbsent(code.length, () => {})[code.code] = symbol;
  }

  return HuffmanDecoder(codeToSymbol);
}

void _validateCodeLengths(List<int> lengths, bool allowIncomplete) {
  final counts = List<int>.filled(16, 0);
  var numSymbols = 0;
  var maxLen = 0;
  for (final len in lengths) {
    if (len < 0 || len > 15) {
      throw DeflateFormatException('Invalid Huffman code length: $len');
    }
    if (len > 0) {
      counts[len]++;
      numSymbols++;
      if (len > maxLen) maxLen = len;
    }
  }
  if (numSymbols == 0) {
    return; // empty table (e.g. no distance codes) is allowed
  }

  // Kraft inequality: the codes must not overflow the 2^len code space.
  var left = 1;
  for (var len = 1; len <= 15; len++) {
    left = (left << 1) - counts[len];
    if (left < 0) {
      throw DeflateFormatException('Over-subscribed Huffman code');
    }
  }
  // Incomplete code: allowed only for the RFC fixed tables (allowIncomplete) or
  // a single 1-bit code (zlib's exception); otherwise it is malformed.
  if (left > 0 && !allowIncomplete && maxLen > 1) {
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
