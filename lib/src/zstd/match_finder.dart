import 'dart:typed_data';
import '../util/byte_utils.dart';

/// Represents a match with literal context for Zstd
class ZstdMatch {
  final int offset; // Distance back to the match
  final int length; // Length of the match
  final int literalLength; // Number of literals before this match

  const ZstdMatch({
    required this.offset,
    required this.length,
    required this.literalLength,
  });
}

/// LZ77-style match finder for Zstd compression with hash chains
///
/// This finds repeated sequences in the input data using a hash table
/// with chaining for better match quality. Also searches repeat offsets
/// for improved compression.
class MatchFinder {
  static const int _hashLog = 17; // 128K hash table
  static const int _hashTableSize = 1 << _hashLog;
  static const int _hashMask = _hashTableSize - 1;
  static const int _chainMask = 0xFFFF; // 64K chain table
  static const int _chainSize = 1 << 16;
  static const int _minMatch = 3; // Zstd minimum match
  static const int _maxOffset = 1 << 22; // ~4MB max offset for Zstd
  static final BigInt _u32Mask = BigInt.from(0xFFFFFFFF);

  final int searchDepth;
  final int maxMatch;

  MatchFinder({this.searchDepth = 32, this.maxMatch = 65536});

  /// Hash function for match finding
  int _hash(final Uint8List data, final int pos) {
    if (pos + 3 >= data.length) return 0;
    final v = ByteUtils.readUint32LE(data, pos);
    final product = (BigInt.from(v) * BigInt.from(2654435761) & _u32Mask)
        .toInt();
    return (product >> (32 - _hashLog)) & _hashMask;
  }

  /// Find all matches in the input data using hash chains
  ///
  /// Returns a list of matches and the trailing literals.
  /// Note: Repeat offset optimization is handled by SequenceEncoder.
  (List<ZstdMatch>, Uint8List) findMatches(final Uint8List input) {
    if (input.length < _minMatch) {
      return (<ZstdMatch>[], input);
    }

    final matches = <ZstdMatch>[];
    final hashTable = List<int>.filled(_hashTableSize, -1);
    final chainTable = List<int>.filled(_chainSize, -1);

    var pos = 0;
    var anchor = 0;
    final end = input.length;
    final limit = end - _minMatch;

    while (pos <= limit) {
      // Find best match using hash chain
      final (bestLen, bestOffset) = _findBestMatch(
        input,
        pos,
        hashTable,
        chainTable,
      );

      // Update hash table and chain
      final hash = _hash(input, pos);
      final prev = hashTable[hash];
      if (prev >= 0 && pos - prev < _chainSize) {
        chainTable[pos & _chainMask] = prev;
      }
      hashTable[hash] = pos;

      if (bestLen >= _minMatch) {
        // Emit match
        final litLen = pos - anchor;
        matches.add(
          ZstdMatch(offset: bestOffset, length: bestLen, literalLength: litLen),
        );

        // Update hash table for positions we're skipping
        for (var i = 1; i < bestLen && pos + i <= limit; i++) {
          final h = _hash(input, pos + i);
          final p = hashTable[h];
          if (p >= 0 && (pos + i) - p < _chainSize) {
            chainTable[(pos + i) & _chainMask] = p;
          }
          hashTable[h] = pos + i;
        }

        pos += bestLen;
        anchor = pos;
      } else {
        pos++;
      }
    }

    // Trailing literals
    final trailing = Uint8List.sublistView(input, anchor);
    return (matches, trailing);
  }

  /// Find the best match at current position using hash chain
  ///
  /// Returns (matchLength, offset)
  (int, int) _findBestMatch(
    final Uint8List input,
    final int pos,
    final List<int> hashTable,
    final List<int> chainTable,
  ) {
    var bestLen = 0;
    var bestOffset = 0;
    final end = input.length;

    // Search hash chain for best match
    final hash = _hash(input, pos);
    var candidate = hashTable[hash];
    var depth = 0;

    while (candidate >= 0 &&
        pos - candidate < _maxOffset &&
        depth < searchDepth) {
      // Quick 4-byte check before full match
      if (candidate + 3 < end &&
          ByteUtils.readUint32LE(input, candidate) ==
              ByteUtils.readUint32LE(input, pos)) {
        final len = _matchLength(input, candidate, pos, end);
        if (len > bestLen) {
          bestLen = len;
          bestOffset = pos - candidate;
        }
      }

      // Follow chain
      final nextCandidate = chainTable[candidate & _chainMask];
      if (nextCandidate >= candidate) break; // Chain must go backward
      candidate = nextCandidate;
      depth++;
    }

    return (bestLen, bestOffset);
  }

  /// Calculate match length between two positions
  int _matchLength(
    final Uint8List data,
    final int ref,
    final int cur,
    final int end,
  ) {
    var len = 0;
    final maxLen = end - cur;
    final limit = maxLen < maxMatch ? maxLen : maxMatch;

    // Fast 8-byte comparison when possible
    while (len + 8 <= limit) {
      if (ref + len + 7 >= data.length) break;
      var diff = false;
      for (var i = 0; i < 8; i++) {
        if (data[ref + len + i] != data[cur + len + i]) {
          diff = true;
          break;
        }
      }
      if (diff) break;
      len += 8;
    }

    // Byte-by-byte for remainder
    while (len < limit && data[ref + len] == data[cur + len]) {
      len++;
    }

    return len;
  }

  /// Extract literals for all matches from the input
  Uint8List extractLiterals(
    final Uint8List input,
    final List<ZstdMatch> matches,
    final Uint8List trailing,
  ) {
    final literals = <int>[];
    var pos = 0;

    for (final match in matches) {
      if (match.literalLength > 0) {
        literals.addAll(input.sublist(pos, pos + match.literalLength));
      }
      pos += match.literalLength + match.length;
    }

    literals.addAll(trailing);
    return Uint8List.fromList(literals);
  }
}
