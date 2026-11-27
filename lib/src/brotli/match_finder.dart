import 'dart:typed_data';

import '../util/byte_utils.dart';

/// Match-finder settings for one level.
class _Config {
  const _Config(this.chain, this.nice, {this.lazy = true});

  /// The most hash chain entries to search.
  final int chain;

  /// Stop searching once a match is this long.
  final int nice;

  /// Whether to try the next position before taking a match.
  final bool lazy;
}

const List<_Config> _configs = [
  _Config(4, 16, lazy: false),
  _Config(8, 32, lazy: false),
  _Config(16, 32, lazy: false),
  _Config(16, 64),
  _Config(32, 64),
  _Config(64, 128),
  _Config(128, 128),
  _Config(256, 256),
  _Config(512, 256),
  _Config(1024, 512),
  _Config(4096, 1024),
];

/// Shortest match the finder reports.
const int _minimum = 4;

/// Longest match the finder reports, so a command's copy length stays small.
const int _maximum = 1 << 16;

/// Commands found for one meta-block: each inserts `inserts[i]` literals,
/// then copies `copies[i]` bytes from `distances[i]` back. The last command
/// may have a copy of 0 (literals only).
class Commands {
  Int32List inserts = Int32List(256);
  Int32List copies = Int32List(256);
  Int32List distances = Int32List(256);
  int count = 0;

  void clear() => count = 0;

  void add(final int insert, final int copy, final int distance) {
    if (count == inserts.length) {
      final size = count * 2;
      inserts = Int32List(size)..setRange(0, count, inserts);
      copies = Int32List(size)..setRange(0, count, copies);
      distances = Int32List(size)..setRange(0, count, distances);
    }
    inserts[count] = insert;
    copies[count] = copy;
    distances[count] = distance;
    count++;
  }
}

/// Hash-chain LZ77 match finder over stream positions.
///
/// Positions are offsets from the start of the stream. The bytes are held in
/// a buffer starting at stream position `base`, so the streaming encoder can
/// drop old input while the tables keep their positions.
///
/// When the input [size] is known, the chain is sized to it: a chain at least
/// as long as the input finds the same matches as a longer one, so the output
/// is the same as without [size].
class MatchFinder {
  MatchFinder({
    required final int level,
    required final int window,
    final int? size,
  }) : _config = _configs[level - 1],
       _window = (1 << window) - 16,
       _chainBits = _bits(window, size),
       _hashBits = level < 4 ? 15 : 17 {
    _heads = Int32List(1 << _hashBits);
    _chain = Int32List(1 << _chainBits);
  }

  static int _bits(final int window, final int? size) {
    var bits = window < 20 ? window : 20;
    if (size != null) {
      final need = size < 2 ? 1 : (size - 1).bitLength;
      if (need < bits) bits = need;
    }
    return bits;
  }

  final _Config _config;
  final int _window;
  final int _chainBits;
  final int _hashBits;
  // Both tables hold stream positions plus one, so 0 (a fresh table) is
  // empty and needs no fill.
  late final Int32List _heads;
  late final Int32List _chain;

  // Stream position up to which positions are in the tables.
  int _inserted = 0;

  /// Subtracts [delta] from every stored position, so positions stay within
  /// 32 bits on long streams. Positions before [delta] are forgotten. [delta]
  /// must be a multiple of the chain size, so each chain entry stays in the
  /// slot its new position indexes.
  void shift(final int delta) {
    assert(delta & ((1 << _chainBits) - 1) == 0);

    for (final table in [_heads, _chain]) {
      for (var i = 0; i < table.length; i++) {
        final value = table[i] - delta;
        table[i] = value < 0 ? 0 : value;
      }
    }
    _inserted = _inserted > delta ? _inserted - delta : 0;
  }

  /// Finds commands for positions `start..end` of [data], whose first byte is
  /// position [base], appending them to [out]. Bytes before [start] (back to
  /// [base]) are history; matches end before [end]. [base] is negative when
  /// positions were shifted past the start of [data].
  void find(
    final Uint8List data,
    final int base,
    final int start,
    final int end,
    final Commands out,
  ) {
    final limit = end - _minimum;
    var literal = start;
    var position = start;
    while (position <= limit) {
      _insert(data, base, position);
      var (length, distance) = _longest(data, base, position, end);
      if (length < _minimum) {
        position++;
        continue;
      }
      if (_config.lazy && length < _config.nice && position + 1 <= limit) {
        _insert(data, base, position + 1);
        final (next, far) = _longest(data, base, position + 1, end);
        if (next > length + 1 || (next == length + 1 && far <= distance)) {
          position++;
          length = next;
          distance = far;
        }
      }
      out.add(position - literal, length, distance);
      position += length;
      literal = position;
      // Long matches at low levels skip inserting their middle positions.
      if (!_config.lazy && length > 32) _inserted = position - 1;
    }
    if (literal < end) out.add(end - literal, 0, 0);
    if (_inserted < end - 3) _insert(data, base, end - 3);
  }

  void _insert(final Uint8List data, final int base, final int position) {
    final mask = (1 << _chainBits) - 1;
    final end = position + 1;
    var at = _inserted > base ? _inserted : base;
    while (at < end) {
      if (at - base + 3 >= data.length) break;
      final hash = _hash(data, at - base);
      _chain[at & mask] = _heads[hash];
      _heads[hash] = at + 1;
      at++;
    }
    if (at > _inserted) _inserted = at;
  }

  /// The longest match at stream position [position], as (length, distance).
  (int, int) _longest(
    final Uint8List data,
    final int base,
    final int position,
    final int end,
  ) {
    final mask = (1 << _chainBits) - 1;
    final span = 1 << _chainBits;
    final reach = _window < span ? _window : span - 1;
    final room = end - position < _maximum ? end - position : _maximum;
    final at = position - base;
    var best = 0;
    var distance = 0;
    var candidate = _chain[position & mask] - 1;
    var steps = _config.chain;
    while (candidate >= base && steps-- > 0) {
      final gap = position - candidate;
      if (gap > reach || gap <= 0) break;
      final from = candidate - base;
      if (data[from + best] == data[at + best]) {
        var length = 0;
        while (length < room && data[from + length] == data[at + length]) {
          length++;
        }
        if (length > best) {
          best = length;
          distance = gap;
          if (length >= _config.nice || length == room) break;
        }
      }
      final next = _chain[candidate & mask] - 1;
      if (next >= candidate) break;
      candidate = next;
    }
    return (best, distance);
  }

  int _hash(final Uint8List data, final int at) {
    final value =
        data[at] |
        (data[at + 1] << 8) |
        (data[at + 2] << 16) |
        (data[at + 3] << 24);
    return ByteUtils.mul32(value, 0x1E35A7BD) >> (32 - _hashBits);
  }
}
