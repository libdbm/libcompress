import 'dart:math' as math;
import 'dart:typed_data';
import '../util/byte_utils.dart';
import '../util/platform.dart';

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
/// This finds repeated sequences in the input data using a hash table with
/// chaining for better match quality. Matches are absolute offsets; the
/// encoder does not emit repeat-offset codes.
class MatchFinder {
  static const int _hashLimit = 17; // at most a 128K-entry hash table
  static const int _chainLimit = 1 << 16; // at most a 64K-entry chain table
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

  // Reused across blocks, grown on demand, and reset per findMatches. Both are
  // sized to the data matched, so a small page does not allocate and clear
  // 192K entries.
  Int32List _hashTable = Int32List(0);
  Int32List _chainTable = Int32List(0);
  int _hashLog = _hashLimit;
  int _hashMask = (1 << _hashLimit) - 1;
  int _chainSize = _chainLimit;
  int _chainMask = _chainLimit - 1;

  // Logical end of the data being matched, set per findMatches run. Lets the
  // streaming encoder pass a larger reused buffer (native, fast element access)
  // while bounding matching to the live `history + piece` region.
  int _end = 0;

  /// [ByteData] over the data being matched, for word loads.
  ByteData _view = ByteData(0);

  /// Hash function for match finding
  int _hash(final Uint8List data, final int pos) {
    if (pos + 3 >= _end) return 0;
    final v = _view.getUint32(pos, Endian.little);
    final product = wide
        ? (v * 2654435761) & 0xFFFFFFFF
        : ByteUtils.mul32(v, 2654435761);
    return (product >> (32 - _hashLog)) & _hashMask;
  }

  /// Finds matches in `input[from..end)` using hash chains, and returns them
  /// with the trailing literals. Positions in `[0, from)` are a history
  /// prefix: they seed the hash so matches can reach back into them, but no
  /// tokens are emitted for them. [end] defaults to `input.length`; pass a
  /// smaller bound to match only a prefix of a larger (reused) buffer.
  (List<ZstdMatch>, Uint8List) findMatches(
    final Uint8List input, {
    final int from = 0,
    final int? end,
  }) {
    _end = end ?? input.length;
    _view = ByteData.sublistView(input);
    if (_end - from < minMatch) {
      return (<ZstdMatch>[], Uint8List.sublistView(input, from, _end));
    }

    final matches = <ZstdMatch>[];
    // Positions are below _end, so a chain of that many slots never aliases.
    final bits = math.max(8, (_end - 1).bitLength);
    _hashLog = math.min(_hashLimit, bits);
    _hashMask = (1 << _hashLog) - 1;
    _chainSize = math.min(_chainLimit, 1 << bits);
    _chainMask = _chainSize - 1;
    if (_hashTable.length <= _hashMask) _hashTable = Int32List(_hashMask + 1);
    if (_chainTable.length < _chainSize) _chainTable = Int32List(_chainSize);
    final hashTable = _hashTable..fillRange(0, _hashMask + 1, -1);
    final chainTable = _chainTable..fillRange(0, _chainSize, -1);

    // Seed the hash with the history prefix.
    for (var i = 0; i < from; i++) {
      _update(input, i, hashTable, chainTable);
    }

    var pos = from;
    var anchor = from;
    final limit = _end - minMatch;

    while (pos <= limit) {
      // Hash this position once and reuse it for the chain search and the
      // table update (it was computed twice per position before).
      final hash = _hash(input, pos);

      // Find the best match along the hash chain (inline: a record returned
      // per position costs more than the search at low levels).
      var bestLen = 0;
      var bestOffset = 0;
      if (pos + 3 < _end) {
        final word = _view.getUint32(pos, Endian.little);
        var candidate = hashTable[hash];
        var depth = 0;
        while (candidate >= 0 &&
            pos - candidate < _maxOffset &&
            depth < searchDepth) {
          // candidate < pos, so both 4-byte reads stay inside the live region.
          if (_view.getUint32(candidate, Endian.little) == word) {
            final size = _matchLength(input, candidate, pos, _end);
            if (size > bestLen) {
              bestLen = size;
              bestOffset = pos - candidate;
            }
          }
          final next = chainTable[candidate & _chainMask];
          if (next >= candidate) break; // Chain must go backward
          candidate = next;
          depth++;
        }
      }

      // Update hash table and chain
      final previous = hashTable[hash];
      if (previous >= 0 && pos - previous < _chainSize) {
        chainTable[pos & _chainMask] = previous;
      }
      hashTable[hash] = pos;

      if (bestLen >= minMatch) {
        // Emit match
        final litLen = pos - anchor;
        matches.add(
          ZstdMatch(offset: bestOffset, length: bestLen, literalLength: litLen),
        );

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
    final trailing = Uint8List.sublistView(input, anchor, _end);
    return (matches, trailing);
  }

  void _update(
    final Uint8List input,
    final int pos,
    final Int32List hashTable,
    final Int32List chainTable,
  ) {
    final h = _hash(input, pos);
    final previous = hashTable[h];
    if (previous >= 0 && pos - previous < _chainSize) {
      chainTable[pos & _chainMask] = previous;
    }
    hashTable[h] = pos;
  }

  /// Calculate match length between two positions
  int _matchLength(
    final Uint8List data,
    final int source,
    final int current,
    final int end,
  ) {
    var count = 0;
    final available = end - current;
    final limit = available < maxMatch ? available : maxMatch;

    // 8 bytes at a time on the VM: the lowest differing byte of two
    // little-endian words is the first mismatch.
    if (wide) {
      while (count + 8 <= limit) {
        final difference =
            _view.getUint64(source + count, Endian.little) ^
            _view.getUint64(current + count, Endian.little);
        if (difference != 0) {
          return count + (((difference & -difference).bitLength - 1) >> 3);
        }
        count += 8;
      }
    }

    // Byte-by-byte for remainder
    while (count < limit && data[source + count] == data[current + count]) {
      count++;
    }

    return count;
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
    var source = from; // read cursor into input (history prefix is skipped)
    var target = 0; // write cursor into literals
    for (final match in matches) {
      final count = match.literalLength;
      if (count > 0) {
        literals.setRange(target, target + count, input, source);
        target += count;
      }
      source += count + match.length;
    }
    literals.setRange(target, target + trailing.length, trailing);
    return literals;
  }
}
