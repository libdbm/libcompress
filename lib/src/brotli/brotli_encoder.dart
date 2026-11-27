import 'dart:typed_data';

import 'bit_writer.dart';
import 'match_finder.dart';
import 'prefix_writer.dart';
import 'tables.dart';

/// Writes the stream header for a window of `(1 << bits) - 16` bytes
/// (RFC 7932 section 9.1).
void writeWindowBits(final BitWriter writer, final int bits) {
  if (bits == 16) {
    writer.bits(0, 1);
  } else if (bits == 17) {
    writer.bits(1, 7);
  } else if (bits > 17) {
    writer.bits(1 | (bits - 17) << 1, 4);
  } else {
    writer.bits(1 | (bits - 8) << 4, 7);
  }
}

/// Writes the header of a data meta-block of [length] bytes (1..2^24), up to
/// and including ISUNCOMPRESSED when [last] is false (section 9.2).
void writeMetaBlockHeader(
  final BitWriter writer,
  final int length, {
  required final bool last,
  required final bool uncompressed,
}) {
  writer.bits(last ? 1 : 0, 1);
  if (last) writer.bits(0, 1); // ISLASTEMPTY
  final value = length - 1;
  final nibbles = value < 1 << 16 ? 4 : (value < 1 << 20 ? 5 : 6);
  writer.bits(nibbles - 4, 2);
  for (var i = 0; i < nibbles; i++) {
    writer.bits((value >> (4 * i)) & 0xF, 4);
  }
  if (!last) writer.bits(uncompressed ? 1 : 0, 1);
}

/// Writes [length] bytes of [data] from [offset] as an uncompressed
/// meta-block, which cannot be the last one.
void writeUncompressed(
  final BitWriter writer,
  final Uint8List data,
  final int offset,
  final int length,
) {
  writeMetaBlockHeader(writer, length, last: false, uncompressed: true);
  writer.align();
  writer.bytes(data, offset, length);
}

/// Ends the stream with an empty last meta-block (ISLAST, ISLASTEMPTY).
void writeEnd(final BitWriter writer) {
  writer.bits(3, 2);
  writer.align();
}

/// Bytes per meta-block the encoder writes.
const int metaBlockSize = 1 << 18;

// The explicit-distance cell for each (insert range, copy range), as
// `cells[insert >> 3 * 3 + copy >> 3]` (RFC 7932 section 5).
const List<int> _cells = [2, 3, 6, 4, 5, 8, 7, 9, 10];

int _code(final List<int> base, final List<int> bits, final int value) {
  var code = base.length - 1;
  while (base[code] > value) {
    code--;
  }
  return code;
}

/// Distance from the match finder's origin at which its positions are
/// rebased, so they stay within its 32-bit tables.
const int defaultRebase = 1 << 30;

/// Encodes meta-blocks of one stream, keeping the match finder's history and
/// the last distance between them.
///
/// Callers pass stream positions. The match finder holds them relative to an
/// origin that moves forward by `rebase / 2` once a meta-block starts
/// [rebase] or more bytes past it. The move depends only on where meta-blocks
/// start, so the block and streaming encoders move it at the same points and
/// give the same output. It is a multiple of every chain size, so chain slots
/// (`position & mask`) are unchanged by it.
class MetaBlockEncoder {
  MetaBlockEncoder({
    required final int level,
    required final int window,
    final int? size,
    this.rebase = defaultRebase,
  }) : _finder = MatchFinder(level: level, window: window, size: size) {
    assert(rebase >= 1 << 21 && rebase & (rebase - 1) == 0);
  }

  /// See the class documentation; at least 2^21 and a power of two, so half
  /// of it is a multiple of the largest chain (2^20 entries).
  final int rebase;

  final MatchFinder _finder;

  // Stream position that the match finder's position 0 stands for.
  int _origin = 0;
  final Commands _commands = Commands();

  // The decoder's last distance (RFC 7932 section 4): distance code 0. Only
  // code 0 and explicit codes are written, so the rest of the ring is unused.
  int _last = 4;

  /// Writes stream positions `start..end` of [data] (whose first byte is
  /// stream position [base]) as one meta-block: compressed, or uncompressed
  /// when that is smaller.
  void write(
    final BitWriter writer,
    final Uint8List data,
    final int base,
    final int start,
    final int end,
  ) {
    while (start - _origin >= rebase) {
      _finder.shift(rebase >> 1);
      _origin += rebase >> 1;
    }
    _commands.clear();
    _finder.find(
      data,
      base - _origin,
      start - _origin,
      end - _origin,
      _commands,
    );
    final mark = writer.position;
    final last = _last;
    final length = end - start;
    _compressed(writer, data, base, start, length);
    if (writer.position - mark >= length * 8 + 32) {
      writer.rewind(mark);
      _last = last;
      writeUncompressed(writer, data, start - base, length);
    }
  }

  void _compressed(
    final BitWriter writer,
    final Uint8List data,
    final int base,
    final int start,
    final int length,
  ) {
    final commands = _commands;
    final count = commands.count;
    final symbols = Int32List(count);
    final codes = Int32List(count);
    final extras = Int32List(count);
    final literalCounts = Int32List(256);
    final commandCounts = Int32List(704);
    final distanceCounts = Int32List(64);

    var position = start - base;
    for (var i = 0; i < count; i++) {
      final insert = commands.inserts[i];
      final copy = commands.copies[i];
      final distance = commands.distances[i];
      for (var p = position; p < position + insert; p++) {
        literalCounts[data[p]]++;
      }
      position += insert + copy;
      final insertCode = _code(insertBase, insertBits, insert);
      final copyCode = copy == 0 ? 0 : _code(copyBase, copyBits, copy);
      final repeat = copy == 0 || distance == _last;
      final int cell;
      if (repeat && insertCode < 8 && copyCode < 16) {
        cell = copyCode >> 3;
        codes[i] = -1;
      } else {
        cell = _cells[(insertCode >> 3) * 3 + (copyCode >> 3)];
        if (copy == 0) {
          codes[i] = -1;
        } else if (distance == _last) {
          codes[i] = 0;
        } else {
          final value = distance + 3;
          final bits = value.bitLength - 2;
          final odd = (value >> bits) & 1;
          codes[i] = 16 + 2 * (bits - 1) + odd;
          extras[i] = value - ((2 + odd) << bits);
          _last = distance;
        }
      }
      if (codes[i] >= 0) distanceCounts[codes[i]]++;
      final symbol = (cell << 6) | ((insertCode & 7) << 3) | (copyCode & 7);
      symbols[i] = symbol;
      commandCounts[symbol]++;
    }

    final literals = PrefixCodes.build(literalCounts);
    final commandCodes = PrefixCodes.build(commandCounts);
    final distances = PrefixCodes.build(distanceCounts);

    writeMetaBlockHeader(writer, length, last: false, uncompressed: false);
    writer
      ..bits(0, 3) // NBLTYPESL, NBLTYPESI, NBLTYPESD = 1
      ..bits(0, 2) // NPOSTFIX
      ..bits(0, 4) // NDIRECT
      ..bits(0, 2) // context mode LSB6
      ..bits(0, 2); // NTREESL, NTREESD = 1
    literals.describe(writer);
    commandCodes.describe(writer);
    distances.describe(writer);

    position = start - base;
    for (var i = 0; i < count; i++) {
      final insert = commands.inserts[i];
      final copy = commands.copies[i];
      final symbol = symbols[i];
      commandCodes.put(writer, symbol);
      final cell = symbol >> 6;
      final insertCode = insertCells[cell] + ((symbol >> 3) & 7);
      final copyCode = copyCells[cell] + (symbol & 7);
      writer.bits(insert - insertBase[insertCode], insertBits[insertCode]);
      final written = copy == 0 ? copyBase[copyCode] : copy;
      writer.bits(written - copyBase[copyCode], copyBits[copyCode]);
      for (var p = position; p < position + insert; p++) {
        literals.put(writer, data[p]);
      }
      position += insert + copy;
      final code = codes[i];
      if (code >= 0) {
        distances.put(writer, code);
        if (code >= 16) writer.bits(extras[i], 1 + ((code - 16) >> 1));
      }
    }
  }
}

/// Whole-buffer Brotli encoder (RFC 7932).
class BrotliEncoder {
  BrotliEncoder({
    required this.level,
    required this.window,
    this.rebase = defaultRebase,
  });

  /// Effort, 1..11.
  final int level;

  /// WBITS, 10..24.
  final int window;

  /// See [MetaBlockEncoder.rebase].
  final int rebase;

  Uint8List compress(final Uint8List data) {
    final writer = BitWriter((data.length >> 1) + 64);
    writeWindowBits(writer, window);
    final encoder = MetaBlockEncoder(
      level: level,
      window: window,
      size: data.length,
      rebase: rebase,
    );
    for (var start = 0; start < data.length; start += metaBlockSize) {
      final end = start + metaBlockSize < data.length
          ? start + metaBlockSize
          : data.length;
      encoder.write(writer, data, 0, start, end);
    }
    writeEnd(writer);
    return writer.finish();
  }
}
