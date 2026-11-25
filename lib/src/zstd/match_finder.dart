import 'dart:math' as math;
import 'dart:typed_data';
import '../util/byte_utils.dart';
import '../util/platform.dart';
import 'sequences.dart';

/// The Zstd match finder, as the Java port's `Finder`:
///
/// - Levels 1-3 ([fast]) use zstd's double-fast search: single-entry tables
///   hashed on 8 and 5 bytes, a repeat at the next position, backward
///   extension and immediate repeats after a match.
/// - Higher levels search hash chains [depth] candidates deep, score matches
///   with zstd's `gain` and match lazily, and stop a search at [nice] bytes.
/// - The repeat offsets are tracked exactly as the decoder updates them, are
///   tried at every position, and a match at one is coded as a repeat. Each
///   sequence holds its RFC 8878 `Offset_Value`.
/// - In frame mode ([prepare] then [next]) the tables persist across the
///   blocks of a frame, so matches reach into earlier blocks. Stream mode
///   ([find]) rebuilds them for each block from its history.
class MatchFinder {
  MatchFinder({
    required this.depth,
    required this.min,
    required this.nice,
    required this.strength,
    required this.fast,
  });

  static const int _hashLimit = 17; // at most a 128K-entry hash table
  static const int _chainLimit = 1 << 16; // at most a 64K-entry chain table
  static const int _maxOffset = 1 << 22; // 4 MB, within the 8 MB window
  static const int _maxMatch = 65536;

  /// The hash chain search depth.
  final int depth;

  /// The shortest match (3 or 4).
  final int min;

  /// The match length that ends a search.
  final int nice;

  /// How fast the search skips ahead after misses: the step is
  /// `((position - anchor) >> strength) + 1`; 31 for none.
  final int strength;

  /// Whether to use the double-fast search instead of hash chains.
  final bool fast;

  /// The sequences found by the last search, reused across calls.
  final Sequences sequences = Sequences();

  Int32List _longs = Int32List(0);
  Int32List _shorts = Int32List(0);
  int _longBits = 0;
  int _shortBits = 0;
  Int32List _heads = Int32List(0);
  Int32List _chains = Int32List(0);
  int _shift = 0;
  int _mask = 0;
  int _span = 0;
  int _links = 0;
  Uint8List _data = Uint8List(0);
  ByteData _view = ByteData(0);
  int _size = 0;
  int _found = 0;
  int _rep0 = 1;
  int _rep1 = 4;
  int _rep2 = 8;
  int _saved0 = 1;
  int _saved1 = 4;
  int _saved2 = 8;

  /// Starts a frame: the decoder's initial repeat offsets 1, 4 and 8.
  void start() {
    _rep0 = 1;
    _rep1 = 4;
    _rep2 = 8;
  }

  /// Remembers the repeat offsets before a block, for [restore].
  void save() {
    _saved0 = _rep0;
    _saved1 = _rep1;
    _saved2 = _rep2;
  }

  /// The repeat offsets saved by [save], as a decoder holds them before the
  /// block.
  List<int> get saved => [_saved0, _saved1, _saved2];

  /// Undoes a block's repeat offset updates: the block is written raw or
  /// RLE, which the decoder does not track.
  void restore() {
    _rep0 = _saved0;
    _rep1 = _saved1;
    _rep2 = _saved2;
  }

  /// Starts frame mode over `data[0, total)`: the tables are sized for the
  /// frame and persist across [next] calls.
  void prepare(final Uint8List data, final int total) {
    _bind(data);
    _configure(total);
    start();
  }

  /// Finds the sequences of `data[from, end)` in frame mode; earlier blocks
  /// are already in the tables. Returns the position of the trailing
  /// literals, which run to [end].
  int next(final int from, final int end) {
    sequences.clear((end - from) ~/ min + 1);
    if (end - from < min) return from;
    return _search(from, end);
  }

  /// Finds the sequences of `data[from, end)` in stream mode, seeding fresh
  /// tables with `data[0, from)` as history. Returns the position of the
  /// trailing literals, which run to [end].
  int find(final Uint8List data, final int from, final int end) {
    _bind(data);
    sequences.clear((end - from) ~/ min + 1);
    if (end - from < min) return from;
    _configure(end);
    _size = end;
    for (var i = 0; i < from; i++) {
      _update(i);
    }
    return _search(from, end);
  }

  void _bind(final Uint8List data) {
    if (!identical(data, _data)) {
      _data = data;
      _view = ByteData.sublistView(data);
    }
  }

  void _configure(final int total) {
    final bits = math.max(8, math.max(1, total - 1).bitLength);
    final log = math.min(_hashLimit, bits);
    _shift = 32 - log;
    _mask = (1 << log) - 1;
    _span = math.min(_chainLimit, 1 << bits);
    _links = _span - 1;
    if (!fast) {
      if (_heads.length <= _mask) _heads = Int32List(_mask + 1);
      if (_chains.length < _span) _chains = Int32List(_span);
      _heads.fillRange(0, _mask + 1, -1);
      _chains.fillRange(0, _span, -1);
    } else {
      _longBits = math.min(17, bits);
      _shortBits = math.min(16, bits);
      if (_longs.length < 1 << _longBits) _longs = Int32List(1 << _longBits);
      if (_shorts.length < 1 << _shortBits) {
        _shorts = Int32List(1 << _shortBits);
      }
      _longs.fillRange(0, 1 << _longBits, -1);
      _shorts.fillRange(0, 1 << _shortBits, -1);
    }
  }

  int _search(final int from, final int end) {
    _size = end;
    if (fast) return _quick(from, end);
    var position = from;
    var anchor = from;
    final limit = end - min;
    while (position <= limit) {
      var best = _longest(position);
      var distance = _found;
      _insert(position);
      if (best < min) {
        position += ((position - anchor) >> strength) + 1;
        continue;
      }
      // Lazy matching, scored as zstd does: a match at the next position must
      // beat this one's gain, with a bonus for keeping the current byte out of
      // the literals.
      while (best < nice && position + 1 <= limit) {
        final later = _longest(position + 1);
        if (later < min || _gain(later, _found) <= _gain(best, distance) + 4) {
          break;
        }
        position++;
        _insert(position);
        best = later;
        distance = _found;
      }
      _emit(distance, best, position - anchor);
      for (var i = 1; i < best && position + i <= limit; i++) {
        _update(position + i);
      }
      position += best;
      anchor = position;
    }
    return anchor;
  }

  /// The best match at [position] by [_gain]: hash chain candidates, then the
  /// repeat offsets. The match's distance is left in [_found].
  int _longest(final int position) {
    var best = 0;
    var distance = 0;
    if (position + 3 < _size) {
      final view = _view;
      final word = view.getUint32(position, Endian.little);
      var candidate = _heads[_hash(position)];
      var tried = 0;
      while (candidate >= 0 &&
          position - candidate < _maxOffset &&
          tried < depth) {
        if (view.getUint32(candidate, Endian.little) == word) {
          final length = _match(candidate, position);
          if (length > best &&
              (best == 0 ||
                  _gain(length, position - candidate) >
                      _gain(best, distance))) {
            best = length;
            distance = position - candidate;
            if (length >= nice) break;
          }
        }
        final next = _chains[candidate & _links];
        if (next >= candidate) break;
        candidate = next;
        tried++;
      }
      // A match at a repeat offset costs only a code: take it when it is as
      // long as the best.
      final mask = min == 3 ? 0xFFFFFF : 0xFFFFFFFF;
      final wanted = word & mask;
      for (var index = 0; index < 3; index++) {
        final repeat = index == 0
            ? _rep0
            : index == 1
            ? _rep1
            : _rep2;
        if (repeat <= position &&
            repeat != distance &&
            (view.getUint32(position - repeat, Endian.little) & mask) ==
                wanted) {
          final length = _match(position - repeat, position);
          if (length >= min &&
              (best == 0 || 4 * length - 1 >= _gain(best, distance))) {
            best = length;
            distance = repeat;
          }
        }
      }
    }
    _found = distance;
    return best;
  }

  /// The worth of a match, as zstd's lazy search scores it: four per byte,
  /// less the bits of its offset.
  int _gain(final int length, final int distance) {
    if (distance == _rep0 || distance == _rep1 || distance == _rep2) {
      return 4 * length - 1;
    }
    return 4 * length - ((distance + 3).bitLength - 1);
  }

  /// Adds [position] to the head of its hash chain.
  void _insert(final int position) {
    final hash = _hash(position);
    final previous = _heads[hash];
    if (previous >= 0 && position - previous < _span) {
      _chains[position & _links] = previous;
    }
    _heads[hash] = position;
  }

  /// Inserts [position] into the two fast tables, hashed on 8 and 5 bytes.
  void _remember(final int position) {
    if (position + 8 <= _size) {
      _longs[_longHash(position)] = position;
      _shorts[_shortHash(position)] = position;
    }
  }

  /// The double-fast search: at each position the 8-byte table's candidate,
  /// then the 5-byte one, then a repeat at the next position; greedy,
  /// skipping ahead faster the longer no match is found.
  int _quick(final int from, final int end) {
    final view = _view;
    final data = _data;
    final longs = _longs;
    final shorts = _shorts;
    var position = from;
    var anchor = from;
    final limit = end - 8;
    while (position <= limit) {
      final wideHash = _longHash(position);
      final narrowHash = _shortHash(position);
      final far = longs[wideHash];
      final near = shorts[narrowHash];
      longs[wideHash] = position;
      shorts[narrowHash] = position;
      var start = position;
      var best = 0;
      var distance = 0;
      final next = position + 1;
      if (_rep0 <= next &&
          view.getUint32(next, Endian.little) ==
              view.getUint32(next - _rep0, Endian.little)) {
        best = _match(next - _rep0, next);
        distance = _rep0;
        start = next;
      } else if (far >= 0 &&
          position - far < _maxOffset &&
          _equal8(far, position)) {
        best = _match(far, position);
        distance = position - far;
      } else if (near >= 0 &&
          position - near < _maxOffset &&
          view.getUint32(near, Endian.little) ==
              view.getUint32(position, Endian.little)) {
        best = _match(near, position);
        distance = position - near;
        // A short match: prefer a long one starting at the next position, as
        // zstd does.
        if (next <= limit) {
          final slot = _longHash(next);
          final later = longs[slot];
          longs[slot] = next;
          if (later >= 0 && next - later < _maxOffset && _equal8(later, next)) {
            final length = _match(later, next);
            if (length > best) {
              best = length;
              distance = next - later;
              start = next;
            }
          }
        }
      }
      if (best >= min) {
        // Extend the match backwards over the literals before it.
        while (start > anchor &&
            start - distance > 0 &&
            data[start - 1] == data[start - 1 - distance]) {
          start--;
          best++;
        }
      }
      if (best < min) {
        position += ((position - anchor) >> strength) + 1;
        continue;
      }
      _emit(distance, best, start - anchor);
      var stop = start + best;
      // Insert a couple of positions inside the match, as zstd does, rather
      // than every one.
      if (start + 2 <= limit) _remember(start + 2);
      if (stop - 2 > start + 2 && stop - 2 <= limit) _remember(stop - 2);
      if (stop - 1 > start + 2 && stop - 1 <= limit) _remember(stop - 1);
      // A match right after a match at the previous offset costs only a
      // code: take them while they last.
      while (stop <= limit &&
          _rep1 <= stop &&
          view.getUint32(stop, Endian.little) ==
              view.getUint32(stop - _rep1, Endian.little)) {
        final length = _match(stop - _rep1, stop);
        if (length < min) break;
        _remember(stop);
        _emit(_rep1, length, 0);
        stop += length;
      }
      position = stop;
      anchor = stop;
    }
    return anchor;
  }

  /// Adds a sequence, coding its offset as a repeat where it is one, and
  /// updates the repeat offsets as the decoder does.
  void _emit(final int distance, final int length, final int run) {
    final int value;
    if (run > 0) {
      value = distance == _rep0
          ? 1
          : distance == _rep1
          ? 2
          : distance == _rep2
          ? 3
          : distance + 3;
    } else {
      value = distance == _rep1
          ? 1
          : distance == _rep2
          ? 2
          : distance == _rep0 - 1
          ? 3
          : distance + 3;
    }
    if (value > 3) {
      _rep2 = _rep1;
      _rep1 = _rep0;
      _rep0 = distance;
    } else {
      final index = value - 1 + (run == 0 ? 1 : 0);
      if (index == 1) {
        _rep1 = _rep0;
        _rep0 = distance;
      } else if (index >= 2) {
        _rep2 = _rep1;
        _rep1 = _rep0;
        _rep0 = distance;
      }
    }
    sequences.add(value, length, run);
  }

  /// The 4-byte chain hash at [position], 0 within 3 bytes of the end.
  int _hash(final int position) {
    if (position + 3 >= _size) return 0;
    final value = _view.getUint32(position, Endian.little);
    final product = wide
        ? (value * 2654435761) & 0xFFFFFFFF
        : ByteUtils.mul32(value, 2654435761);
    return (product >> _shift) & _mask;
  }

  /// The top [_longBits] bits of the 64-bit product of the 8 bytes at
  /// [position] and zstd's 8-byte prime.
  int _longHash(final int position) {
    if (wide) {
      return (_view.getUint64(position, Endian.little) * _prime8) >>>
          (64 - _longBits);
    }
    final data = _data;
    final a0 = data[position] | data[position + 1] << 8;
    final a1 = data[position + 2] | data[position + 3] << 8;
    final a2 = data[position + 4] | data[position + 5] << 8;
    final a3 = data[position + 6] | data[position + 7] << 8;
    final t0 = a0 * 0x6463;
    final t1 = a0 * 0xB7A5 + a1 * 0x6463 + t0 ~/ 0x10000;
    final t2 = a0 * 0xBBDC + a1 * 0xB7A5 + a2 * 0x6463 + t1 ~/ 0x10000;
    final t3 =
        a0 * 0xCF1B + a1 * 0xBBDC + a2 * 0xB7A5 + a3 * 0x6463 + t2 ~/ 0x10000;
    final high = (t3 % 0x10000) * 0x10000 + t2 % 0x10000;
    return high ~/ (1 << (32 - _longBits));
  }

  /// The top [_shortBits] bits of the 64-bit product of the low 5 bytes at
  /// [position], shifted to the top, and zstd's 5-byte prime: bits
  /// `40 - _shortBits` to 40 of the 40-bit product.
  int _shortHash(final int position) {
    if (wide) {
      return ((_view.getUint64(position, Endian.little) << 24) * _prime5) >>>
          (64 - _shortBits);
    }
    final data = _data;
    final low =
        data[position] |
        data[position + 1] << 8 |
        (data[position + 2] & 0xF) << 16;
    final high =
        data[position + 2] >> 4 |
        data[position + 3] << 4 |
        data[position + 4] << 12;
    final middle = (high * _prime5Low + low * _prime5High) % 0x100000;
    final product = (low * _prime5Low + middle * 0x100000) % 0x10000000000;
    return product ~/ (0x10000 * (1 << (24 - _shortBits)));
  }

  /// Whether the 8 bytes at [left] and [right] are equal.
  bool _equal8(final int left, final int right) {
    final view = _view;
    if (wide) {
      return view.getUint64(left, Endian.little) ==
          view.getUint64(right, Endian.little);
    }
    return view.getUint32(left, Endian.little) ==
            view.getUint32(right, Endian.little) &&
        view.getUint32(left + 4, Endian.little) ==
            view.getUint32(right + 4, Endian.little);
  }

  void _update(final int position) {
    if (fast) {
      _remember(position);
    } else {
      _insert(position);
    }
  }

  /// The length of the match of [current] against [source], up to the end of
  /// the data searched and at most [_maxMatch].
  int _match(final int source, final int current) {
    final data = _data;
    final most = math.min(_size - current, _maxMatch);
    var count = 0;
    // 8 bytes at a time on the VM: the lowest differing byte of two
    // little-endian words is the first mismatch.
    if (wide) {
      final view = _view;
      while (count + 8 <= most) {
        final difference =
            view.getUint64(source + count, Endian.little) ^
            view.getUint64(current + count, Endian.little);
        if (difference != 0) {
          return count + (((difference & -difference).bitLength - 1) >> 3);
        }
        count += 8;
      }
    }
    while (count < most && data[source + count] == data[current + count]) {
      count++;
    }
    return count;
  }

  /// Copies the literals of the last search into [output]: each sequence's
  /// run, then `input[trailing, end)`. Returns the number of literals.
  int literals(
    final Uint8List input,
    final int from,
    final int trailing,
    final int end,
    final Uint8List output,
  ) {
    final count = sequences.count;
    final lengths = sequences.lengths;
    final runs = sequences.literals;
    var source = from;
    var target = 0;
    for (var i = 0; i < count; i++) {
      final run = runs[i];
      output.setRange(target, target + run, input, source);
      target += run;
      source += run + lengths[i];
    }
    output.setRange(target, target + end - trailing, input, trailing);
    return target + end - trailing;
  }
}

/// zstd's 8-byte hash prime, 0xCF1BBCDCB7A56463, built at run time because
/// the literal is not exact on dart2js, where it is never used.
final int _prime8 = wide ? (0xCF1BBCDC << 32) | 0xB7A56463 : 0;

/// zstd's 5-byte hash prime, and its halves at bit 20 for dart2js.
const int _prime5 = 889523592379;
const int _prime5Low = _prime5 % 0x100000;
const int _prime5High = _prime5 ~/ 0x100000;
