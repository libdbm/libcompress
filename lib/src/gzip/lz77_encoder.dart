import 'dart:math' as math;
import 'dart:typed_data';

import 'deflate_common.dart';

/// Match-finder settings for one compression level, as zlib's
/// `configuration_table`.
class _Config {
  const _Config(
    this.good,
    this.lazy,
    this.nice,
    this.chain, {
    this.fast = false,
  });

  /// Once the previous match is this long, search a quarter of the chain.
  final int good;

  /// Do not look for a better match once the previous one is this long. In
  /// [fast] mode, the longest match whose positions are all inserted.
  final int lazy;

  /// Stop searching once a match is this long.
  final int nice;

  /// The most hash chain entries to search.
  final int chain;

  /// Greedy matching (levels 1-3) in place of lazy evaluation.
  final bool fast;
}

const _configs = [
  _Config(4, 4, 8, 4, fast: true),
  _Config(4, 5, 16, 8, fast: true),
  _Config(4, 6, 32, 32, fast: true),
  _Config(4, 4, 16, 16),
  _Config(8, 16, 32, 32),
  _Config(8, 16, 128, 128),
  _Config(8, 32, 128, 256),
  _Config(32, 128, 258, 1024),
  _Config(32, 258, 258, 4096),
];

/// A 3-byte match further back than this is not worth its distance code.
const _far = 4096;

/// LZ77 sliding window encoder for DEFLATE compression
///
/// Finds repeated sequences and replaces them with length/distance pairs,
/// with zlib's per-level search settings. Hash chains hold positions in one
/// buffer across calls to [tokenize], so matches reach back across blocks.
class Lz77Encoder {
  Lz77Encoder({final int level = 6}) : _config = _configs[level - 1] {
    reset();
  }

  final _Config _config;

  /// Most recent position for each hash.
  final Int32List _head = Int32List(hashSize);

  /// Previous position with the same hash, indexed by position in the window.
  final Int32List _prev = Int32List(windowSize);

  /// Length and distance of the match found by the last successful [_find].
  int _length = 0;
  int _distance = 0;

  /// Clears the hash chains, for a new buffer.
  void reset() {
    _head.fillRange(0, hashSize, -1);
    _prev.fillRange(0, windowSize, -1);
  }

  /// Inserts positions `[start, end)` of [data] as history for later matches.
  void insert(final Uint8List data, final int start, final int end) {
    for (var i = start; i < end; i++) {
      _insert(data, i);
    }
  }

  /// Tokenizes `data[start..limit)`; a match may run past [limit] up to the
  /// end of [data]. Positions before [start] must already be inserted.
  /// Returns the tokens and the position reached.
  (List<Token>, int) tokenize(
    final Uint8List data,
    final int start,
    final int limit,
  ) => _config.fast ? _greedy(data, start, limit) : _lazy(data, start, limit);

  /// Takes the first match found at each position (zlib `deflate_fast`).
  (List<Token>, int) _greedy(
    final Uint8List data,
    final int start,
    final int limit,
  ) {
    final tokens = <Token>[];
    var pos = start;
    while (pos < limit) {
      final candidate = _insert(data, pos);
      if (candidate >= 0 &&
          _find(data, pos, candidate, minMatch - 1, _config.chain)) {
        tokens.add(MatchToken(_length, _distance));
        final end = pos + _length;
        if (_length <= _config.lazy) insert(data, pos + 1, end);
        pos = end;
      } else {
        tokens.add(LiteralToken(data[pos]));
        pos++;
      }
    }
    return (tokens, pos);
  }

  /// Defers each match by one position, taking the next one instead when it
  /// is longer (zlib `deflate_slow`).
  (List<Token>, int) _lazy(
    final Uint8List data,
    final int start,
    final int limit,
  ) {
    final tokens = <Token>[];
    var pos = start;
    // Whether the byte at pos - 1 is still to be emitted; [length] and
    // [distance] are then the match found there.
    var pending = false;
    var length = minMatch - 1;
    var distance = 0;
    while (pos < limit) {
      final candidate = _insert(data, pos);
      final previous = length;
      final back = distance;
      length = minMatch - 1;
      if (candidate >= 0 && previous < _config.lazy) {
        final chain = previous >= _config.good
            ? _config.chain >> 2
            : _config.chain;
        final floor = math.max(previous, minMatch - 1);
        if (_find(data, pos, candidate, floor, chain)) {
          length = _length;
          distance = _distance;
          if (length == minMatch && distance > _far) length = minMatch - 1;
        }
      }

      if (previous >= minMatch && length <= previous) {
        tokens.add(MatchToken(previous, back));
        final end = pos - 1 + previous;
        insert(data, pos + 1, end);
        pos = end;
        pending = false;
        length = minMatch - 1;
      } else {
        if (pending) tokens.add(LiteralToken(data[pos - 1]));
        pending = true;
        pos++;
      }
    }

    if (pending) {
      if (length >= minMatch) {
        tokens.add(MatchToken(length, distance));
        final end = pos - 1 + length;
        insert(data, pos, end);
        pos = end;
      } else {
        tokens.add(LiteralToken(data[pos - 1]));
      }
    }
    return (tokens, pos);
  }

  /// Searches up to [chain] entries from [candidate] for a match at [pos]
  /// longer than [best]. Returns whether one was found, leaving it in
  /// [_length] and [_distance].
  bool _find(
    final Uint8List data,
    final int pos,
    int candidate,
    int best,
    int chain,
  ) {
    final most = math.min(maxMatch, data.length - pos);
    final nice = math.min(_config.nice, most);
    var found = false;
    while (candidate >= 0 && chain-- > 0 && best < most) {
      final distance = pos - candidate;
      if (distance > maxDistance) break;
      if (data[candidate + best] == data[pos + best] &&
          data[candidate] == data[pos]) {
        var length = 1;
        while (length < most &&
            data[candidate + length] == data[pos + length]) {
          length++;
        }
        if (length > best) {
          best = length;
          _length = length;
          _distance = distance;
          found = true;
          if (length >= nice) break;
        }
      }
      final next = _prev[candidate & (windowSize - 1)];
      // A slot overwritten by a newer position ends the chain.
      if (next >= candidate) break;
      candidate = next;
    }
    return found;
  }

  /// Adds [pos] to its hash chain and returns the previous position with the
  /// same hash, or -1.
  int _insert(final Uint8List data, final int pos) {
    if (pos + minMatch > data.length) return -1;
    final h = hash(data, pos);
    final candidate = _head[h];
    _prev[pos & (windowSize - 1)] = candidate;
    _head[h] = pos;
    return candidate;
  }
}
