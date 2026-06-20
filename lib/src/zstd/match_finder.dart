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
  static const int _maxOffset = 1 << 22; // ~4MB max offset for Zstd

  final int searchDepth;
  final int maxMatch;

  /// Minimum match length to emit (level-derived; 3 or 4).
  final int minMatch;

  MatchFinder({
    this.searchDepth = 32,
    this.maxMatch = 65536,
    this.minMatch = 3,
  });

  // Reused across blocks: a fresh MatchFinder per block would reallocate
  // these ~192K entries every time. Reset (not reallocated) per findMatches.
  late final List<int> _hashTable = List<int>.filled(_hashTableSize, -1);
  late final List<int> _chainTable = List<int>.filled(_chainSize, -1);

  /// Hash function for match finding
  int _hash(final Uint8List data, final int pos) {
    if (pos + 3 >= data.length) return 0;
    final v = ByteUtils.readUint32LE(data, pos);
    final product = ByteUtils.mul32(v, 2654435761);
    return (product >> (32 - _hashLog)) & _hashMask;
  }

  /// Find all matches in the input data using hash chains
  ///
  /// Returns a list of matches and the trailing literals.
  /// Note: Repeat offset optimization is handled by SequenceEncoder.
  /// Finds matches in `input[from..]`. Positions in `[0, from)` are a history
  /// prefix: they seed the hash so matches in the new region can reference them
  /// (cross-chunk back-references), but no tokens are emitted for them. With
  /// the default `from == 0` this is plain whole-buffer matching.
  (List<ZstdMatch>, Uint8List) findMatches(final Uint8List input, {final int from = 0}) {
    if (input.length - from < minMatch) {
      return (<ZstdMatch>[], Uint8List.sublistView(input, from));
    }

    final matches = <ZstdMatch>[];
    final hashTable = _hashTable..fillRange(0, _hashTableSize, -1);
    final chainTable = _chainTable..fillRange(0, _chainSize, -1);

    // Seed the hash with the history prefix.
    for (var i = 0; i < from; i++) {
      _update(input, i, hashTable, chainTable);
    }

    var pos = from;
    var anchor = from;
    final end = input.length;
    final limit = end - minMatch;

    while (pos <= limit) {
      // Hash this position once and reuse it for the chain search and the
      // table update (it was computed twice per position before).
      final hash = _hash(input, pos);

      // Find best match using hash chain
      final (bestLen, bestOffset) = _findBestMatch(
        input,
        pos,
        hash,
        hashTable,
        chainTable,
      );

      // Update hash table and chain
      final prev = hashTable[hash];
      if (prev >= 0 && pos - prev < _chainSize) {
        chainTable[pos & _chainMask] = prev;
      }
      hashTable[hash] = pos;

      if (bestLen >= minMatch) {
        // Emit match
        final litLen = pos - anchor;
        matches.add(ZstdMatch(
          offset: bestOffset,
          length: bestLen,
          literalLength: litLen,
        ));

        // Update hash table for positions we're skipping
        for (var i = 1; i < bestLen && pos + i <= limit; i++) {
          _update(input, pos + i, hashTable, chainTable);
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

  void _update(final Uint8List input, final int pos, final List<int> hashTable,
      final List<int> chainTable) {
    final h = _hash(input, pos);
    final prev = hashTable[h];
    if (prev >= 0 && pos - prev < _chainSize) {
      chainTable[pos & _chainMask] = prev;
    }
    hashTable[h] = pos;
  }

  /// Find the best match at current position using hash chain
  ///
  /// Returns (matchLength, offset)
  (int, int) _findBestMatch(
    final Uint8List input,
    final int pos,
    final int hash,
    final List<int> hashTable,
    final List<int> chainTable,
  ) {
    var bestLen = 0;
    var bestOffset = 0;
    final end = input.length;

    // Search hash chain for best match
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
    final Uint8List trailing, {
    final int from = 0,
  }) {
    var total = trailing.length;
    for (final match in matches) {
      total += match.literalLength;
    }

    // Single typed allocation with bulk copies, rather than per-match
    // sublist + growable addAll + a final fromList (three copies of the data).
    final literals = Uint8List(total);
    var src = from; // read cursor into input (history prefix is skipped)
    var dst = 0; // write cursor into literals
    for (final match in matches) {
      final len = match.literalLength;
      if (len > 0) {
        literals.setRange(dst, dst + len, input, src);
        dst += len;
      }
      src += len + match.length;
    }
    literals.setRange(dst, dst + trailing.length, trailing);
    return literals;
  }
}
