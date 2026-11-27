import 'dart:typed_data';

import '../exceptions.dart';
import '../util/output_limit.dart';
import 'bit_reader.dart';
import 'dictionary.dart';
import 'prefix_code.dart';
import 'tables.dart';

/// Decoded bytes of one Brotli stream.
///
/// [bytes] holds stream positions `base .. base + length`. The block decoder
/// keeps the whole output (base 0); the streaming decoder drops bytes older
/// than the window after emitting them, moving [base] forward.
class History {
  History(final int capacity, this.limit)
    : bytes = Uint8List(capacity < 1024 ? 1024 : capacity);

  /// Cap on [total], or null for unlimited.
  final int? limit;

  Uint8List bytes;
  int length = 0;
  int base = 0;

  /// Bytes decoded since the start of the stream.
  int get total => base + length;

  /// Drops all but the last [keep] bytes, moving [base] forward.
  void slide(final int keep) {
    if (length <= keep) return;
    final drop = length - keep;
    bytes.setRange(0, keep, bytes, drop);
    length = keep;
    base += drop;
  }

  /// Ensures room for [count] more bytes, within [limit].
  void reserve(final int count) {
    final cap = limit;
    if (cap != null && total + count > cap) {
      throw OutputLimitException('Decoded size exceeds the limit of $cap');
    }
    final need = length + count;
    if (need <= bytes.length) return;
    var size = bytes.length * 2;
    if (size < need) size = need;
    if (cap != null && size > cap - base) size = cap - base;
    bytes = Uint8List(size)..setRange(0, length, bytes);
  }
}

/// Per-stream decoder state carried across meta-blocks.
class StreamState {
  StreamState(final int bits, this.output) : window = (1 << bits) - 16;

  /// Largest backward distance (RFC 7932 section 9.1).
  final int window;

  final History output;

  /// The last four distances (section 4), the latest at `ring[(index - 1) & 3]`.
  final Int32List ring = Int32List.fromList(const [16, 15, 11, 4]);
  int index = 0;
}

// Block count codes (section 6): extra bits and base value.
const List<int> _countBits = [
  2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, //
  13, 24, //
];
const List<int> _countBase = [
  1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, //
  369, 497, 753, 1265, 2289, 4337, 8433, 16625, //
];

// Short distance codes 0..15 (section 4): which of the last distances
// (0 = last) and the delta added to it.
const List<int> _slots = [0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1];
const List<int> _deltas = [
  0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3, //
];

/// Context lookup for the four literal context modes (section 7.1): the
/// context is `table[mode * 512 + p1] | table[mode * 512 + 256 + p2]`.
final Uint8List _contexts = () {
  final table = Uint8List(2048);
  for (var byte = 0; byte < 256; byte++) {
    table[byte] = byte & 0x3F;
    table[512 + byte] = byte >> 2;
    table[1024 + byte] = lut0[byte];
    table[1024 + 256 + byte] = lut1[byte];
    table[1536 + byte] = lut2[byte] << 3;
    table[1536 + 256 + byte] = lut2[byte];
  }
  return table;
}();

/// A count larger than any meta-block, for categories with one block type.
const int _unbounded = 1 << 28;

/// Block switching state of one category: literals, commands or distances
/// (section 6).
class _Blocks {
  _Blocks._(this.types, this.typeCode, this.countCode, this.count);

  factory _Blocks.read(final BitReader reader) {
    final types = readCount(reader);
    if (types < 2) return _Blocks._(1, null, null, _unbounded);
    final typeCode = readPrefixCode(reader, types + 2);
    final countCode = readPrefixCode(reader, 26);
    return _Blocks._(types, typeCode, countCode, _readCount(reader, countCode));
  }

  final int types;
  final PrefixCode? typeCode;
  final PrefixCode? countCode;
  int count;
  int type = 0;
  int previous = 1;

  /// Reads a block switch command: the new block type and its count.
  void next(final BitReader reader) {
    final symbol = typeCode!.read(reader);
    var value = switch (symbol) {
      0 => previous,
      1 => type + 1,
      _ => symbol - 2,
    };
    if (value >= types) value -= types;
    previous = type;
    type = value;
    count = _readCount(reader, countCode!);
  }
}

int _readCount(final BitReader reader, final PrefixCode code) {
  final symbol = code.read(reader);
  return _countBase[symbol] + reader.bits(_countBits[symbol]);
}

/// Reads a value 1..256 in the variable-length code used for NBLTYPES and
/// NTREES (section 9.2).
int readCount(final BitReader reader) {
  if (reader.bit() == 0) return 1;
  final bits = reader.bits(3);
  return (1 << bits) + reader.bits(bits) + 1;
}

/// Reads a context map of [size] entries over [trees] trees (section 7.3).
Uint8List readContextMap(
  final BitReader reader,
  final int size,
  final int trees,
) {
  final map = Uint8List(size);
  final run = reader.bit() == 1 ? reader.bits(4) + 1 : 0;
  final code = readPrefixCode(reader, trees + run);
  var i = 0;
  while (i < size) {
    final symbol = code.read(reader);
    if (symbol == 0) {
      i++;
    } else if (symbol <= run) {
      final zeros = (1 << symbol) + reader.bits(symbol);
      if (i + zeros > size) {
        throw const BrotliFormatException('Context map run is too long');
      }
      i += zeros;
    } else {
      map[i++] = symbol - run;
    }
  }
  if (reader.bit() == 1) {
    final order = Uint8List(256);
    for (var j = 0; j < 256; j++) {
      order[j] = j;
    }
    for (var j = 0; j < size; j++) {
      final index = map[j];
      final value = order[index];
      map[j] = value;
      order.setRange(1, index + 1, order);
      order[0] = value;
    }
  }
  return map;
}

/// Decodes one compressed meta-block of [length] bytes into
/// `state.output`, reading its header (RFC 7932 section 9.2) and commands
/// (section 9.3).
void decodeCompressed(
  final BitReader reader,
  final StreamState state,
  final int length,
) {
  final literals = _Blocks.read(reader);
  final commands = _Blocks.read(reader);
  final distances = _Blocks.read(reader);
  final postfix = reader.bits(2);
  final direct = reader.bits(4) << postfix;
  final modes = Uint8List(literals.types);
  for (var i = 0; i < literals.types; i++) {
    modes[i] = reader.bits(2);
  }
  final literalTrees = readCount(reader);
  final literalMap = literalTrees >= 2
      ? readContextMap(reader, literals.types << 6, literalTrees)
      : Uint8List(literals.types << 6);
  final distanceTrees = readCount(reader);
  final distanceMap = distanceTrees >= 2
      ? readContextMap(reader, distances.types << 2, distanceTrees)
      : Uint8List(distances.types << 2);
  final literalCodes = [
    for (var i = 0; i < literalTrees; i++) readPrefixCode(reader, 256),
  ];
  final commandCodes = [
    for (var i = 0; i < commands.types; i++) readPrefixCode(reader, 704),
  ];
  final alphabet = 16 + direct + (48 << postfix);
  final distanceCodes = [
    for (var i = 0; i < distanceTrees; i++) readPrefixCode(reader, alphabet),
  ];

  final output = state.output;
  output.reserve(length);
  final out = output.bytes;
  final ring = state.ring;
  final mask = (1 << postfix) - 1;
  var position = output.length;
  var remaining = length;

  while (remaining > 0) {
    if (commands.count == 0) commands.next(reader);
    commands.count--;
    final command = commandCodes[commands.type].read(reader);
    final cell = command >> 6;
    final insertCode = insertCells[cell] + ((command >> 3) & 7);
    final copyCode = copyCells[cell] + (command & 7);
    final insert = insertBase[insertCode] + reader.bits(insertBits[insertCode]);
    final copy = copyBase[copyCode] + reader.bits(copyBits[copyCode]);
    if (insert > remaining) {
      throw const BrotliFormatException('Insert length exceeds MLEN');
    }

    if (insert > 0) {
      var p1 = output.base + position > 0 ? out[position - 1] : 0;
      var p2 = output.base + position > 1 ? out[position - 2] : 0;
      final end = position + insert;
      while (position < end) {
        if (literals.count == 0) literals.next(reader);
        literals.count--;
        final type = literals.type;
        final table = modes[type] << 9;
        final context = _contexts[table + p1] | _contexts[table + 256 + p2];
        final byte = literalCodes[literalMap[(type << 6) + context]].read(
          reader,
        );
        out[position++] = byte;
        p2 = p1;
        p1 = byte;
      }
      remaining -= insert;
      if (remaining == 0) break;
    }

    var code = 0;
    final int distance;
    if (cell < 2) {
      distance = ring[(state.index - 1) & 3];
    } else {
      if (distances.count == 0) distances.next(reader);
      distances.count--;
      final context = copy > 4 ? 3 : copy - 2;
      code = distanceCodes[distanceMap[(distances.type << 2) + context]].read(
        reader,
      );
      if (code < 16) {
        distance = ring[(state.index - 1 - _slots[code]) & 3] + _deltas[code];
        if (distance <= 0) {
          throw const BrotliFormatException('Invalid short distance code');
        }
      } else if (code < 16 + direct) {
        distance = code - 15;
      } else {
        final value = code - direct - 16;
        final bits = 1 + (value >> (postfix + 1));
        final high = value >> postfix;
        final offset = ((2 + (high & 1)) << bits) - 4;
        distance =
            ((offset + reader.bits(bits)) << postfix) +
            (value & mask) +
            direct +
            1;
      }
    }

    final produced = output.base + position;
    final limit = produced < state.window ? produced : state.window;
    if (distance > limit) {
      final written = _word(
        out,
        position,
        copy,
        distance - limit - 1,
        remaining,
      );
      position += written;
      remaining -= written;
      continue;
    }
    if (code != 0) {
      ring[state.index & 3] = distance;
      state.index++;
    }
    if (copy > remaining) {
      throw const BrotliFormatException('Copy length exceeds MLEN');
    }
    final from = position - distance;
    if (distance >= copy) {
      out.setRange(position, position + copy, out, from);
    } else if (copy <= 32) {
      for (var i = 0; i < copy; i++) {
        out[position + i] = out[from + i];
      }
    } else {
      // Doubling copies of whole periods; each source ends before its
      // destination begins.
      var copied = distance;
      out.setRange(position, position + distance, out, from);
      while (copied < copy) {
        final count = copied < copy - copied ? copied : copy - copied;
        out.setRange(position + copied, position + copied + count, out, from);
        copied += count;
      }
    }
    position += copy;
    remaining -= copy;
  }
  output.length = position;
}

/// Writes static dictionary word [id] of [length] bytes, transformed, at
/// [position] (section 8). Returns the bytes written, at most [room].
int _word(
  final Uint8List out,
  final int position,
  final int length,
  final int id,
  final int room,
) {
  if (length < 4 || length > 24) {
    throw const BrotliFormatException('Invalid dictionary word length');
  }
  final bits = dictionaryBits[length];
  final transform = id >> bits;
  if (transform > 120) {
    throw const BrotliFormatException('Invalid dictionary transform');
  }
  var start = dictionaryOffsets[length] + (id & ((1 << bits) - 1)) * length;
  var end = start + length;
  final type = transformTypes[transform];
  if (type >= 12) {
    end -= type - 11;
    if (end < start) end = start;
  } else if (type >= 3) {
    start += type - 2;
    if (start > end) start = end;
  }
  final prefix = transformPrefixes[transform];
  final suffix = transformSuffixes[transform];
  final total = prefix.length + (end - start) + suffix.length;
  if (total > room) {
    throw const BrotliFormatException('Dictionary word exceeds MLEN');
  }
  var at = position;
  for (final byte in prefix) {
    out[at++] = byte;
  }
  final word = at;
  out.setRange(at, at + end - start, dictionary, start);
  at += end - start;
  if (type == 1) {
    _ferment(out, word, at);
  } else if (type == 2) {
    var i = word;
    while (i < at) {
      i += _ferment(out, i, at);
    }
  }
  for (final byte in suffix) {
    out[at++] = byte;
  }
  return total;
}

/// Uppercases the character at [position] in `out[position..end)` (section 8) and
/// returns its length in bytes.
int _ferment(final Uint8List out, final int position, final int end) {
  if (position >= end) return 1;
  final byte = out[position];
  if (byte < 192) {
    if (byte >= 97 && byte <= 122) out[position] = byte ^ 32;
    return 1;
  }
  if (byte < 224) {
    if (position + 1 < end) out[position + 1] ^= 32;
    return 2;
  }
  if (position + 2 < end) out[position + 2] ^= 5;
  return 3;
}
