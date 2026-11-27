// Test-only writers for hand-built Brotli streams (RFC 7932). They let tests
// reach format features the reference encoder rarely or never produces.
import 'dart:io';
import 'dart:typed_data';

import 'package:libcompress/src/brotli/bit_reader.dart';
import 'package:libcompress/src/brotli/dictionary.dart';
import 'package:libcompress/src/brotli/tables.dart';

/// Least-significant-bit-first writer.
class BitWriter {
  final List<int> _bits = [];

  void put(final int value, final int count) {
    for (var i = 0; i < count; i++) {
      _bits.add((value >> i) & 1);
    }
  }

  Uint8List finish() {
    while (_bits.length % 8 != 0) {
      _bits.add(0);
    }
    final out = Uint8List(_bits.length >> 3);
    for (var i = 0; i < _bits.length; i++) {
      out[i >> 3] |= _bits[i] << (i & 7);
    }
    return out;
  }

  BitReader reader() => BitReader(finish());
}

/// Canonical prefix codes for [lengths] (RFC 7932 section 3.2), bit-reversed
/// so they can be written least significant bit first.
List<int> canonical(final List<int> lengths) {
  final counts = List.filled(16, 0);
  for (final length in lengths) {
    if (length > 0) counts[length]++;
  }
  final next = List.filled(16, 0);
  var code = 0;
  for (var bits = 1; bits < 16; bits++) {
    next[bits] = code;
    code = (code + counts[bits]) << 1;
  }
  return [
    for (final length in lengths)
      if (length == 0) 0 else _reverse(next[length]++, length),
  ];
}

int _reverse(final int code, final int length) {
  var result = 0;
  for (var i = 0; i < length; i++) {
    result |= ((code >> i) & 1) << (length - 1 - i);
  }
  return result;
}

/// The code-length code symbol order (RFC 7932 section 3.5).
const lengthOrder = [
  1,
  2,
  3,
  4,
  0,
  5,
  17,
  6,
  16,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
];

/// The fixed code for code-length code lengths 0..5, as (bits, count) written
/// least significant bit first (RFC 7932 section 3.5).
const lengthLengthCodes = [(0, 2), (7, 4), (3, 3), (2, 2), (1, 2), (15, 4)];

/// Writes a complex prefix code: [skip] (HSKIP), the code-length code
/// [lengthLengths] (indexed by code-length symbol 0..17), then [symbols] as
/// (code-length symbol, extra bits value) pairs.
void writeComplex(
  final BitWriter writer,
  final List<int> lengthLengths,
  final List<(int, int)> symbols, {
  final int skip = 0,
}) {
  writer.put(skip, 2);
  var space = 32;
  var used = 0;
  for (var i = skip; i < lengthOrder.length; i++) {
    final length = lengthLengths[lengthOrder[i]];
    final (bits, count) = lengthLengthCodes[length];
    writer.put(bits, count);
    if (length != 0) {
      space -= 32 >> length;
      used++;
      if (space <= 0) break;
    }
  }
  final codes = canonical(lengthLengths);
  for (final (symbol, extra) in symbols) {
    writer.put(codes[symbol], used == 1 ? 0 : lengthLengths[symbol]);
    if (symbol == 16) writer.put(extra, 2);
    if (symbol == 17) writer.put(extra, 3);
  }
}

/// Writes [lengths] as a complex prefix code using code-length symbols 0..15
/// only, each 4 bits long. Stops where the decoder stops: once the code space
/// is used up.
void writeLengths(final BitWriter writer, final List<int> lengths) {
  final lengthLengths = List.filled(18, 0)..fillRange(0, 16, 4);
  final symbols = <(int, int)>[];
  var space = 1 << 15;
  for (final length in lengths) {
    if (space <= 0) break;
    symbols.add((length, 0));
    if (length != 0) space -= (1 << 15) >> length;
  }
  writeComplex(writer, lengthLengths, symbols);
}

/// Writes [symbols] with the canonical code for [lengths].
void writeSymbols(
  final BitWriter writer,
  final List<int> lengths,
  final List<int> symbols,
) {
  final codes = canonical(lengths);
  for (final symbol in symbols) {
    writer.put(codes[symbol], lengths[symbol]);
  }
}

/// Code lengths of a complete code over [size] symbols that are all within
/// one bit of the same length.
List<int> flat(final int size) {
  final bits = (size - 1).bitLength;
  final short = (1 << bits) - size;
  return [for (var i = 0; i < size; i++) i < short ? bits - 1 : bits];
}

/// A command for [brotliStream]: [literals] to insert, then a copy of [copy]
/// bytes from [distance] back (or a static dictionary word when [distance]
/// exceeds the bytes available). [short] writes the distance as that short
/// distance code (0..15); [implicit] uses the command's implied distance
/// code 0. A copy of 0 ends the meta-block after the literals.
typedef Command = ({
  List<int> literals,
  int copy,
  int distance,
  int? short,
  bool implicit,
});

Command command(
  final List<int> literals, {
  final int copy = 0,
  final int distance = 0,
  final int? short,
  final bool implicit = false,
}) => (
  literals: literals,
  copy: copy,
  distance: distance,
  short: short,
  implicit: implicit,
);

const _insertBits = [
  0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24, //
];
const _insertBase = [
  0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, //
  1090, 2114, 6210, 22594, //
];
const _copyBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24, //
];
const _copyBase = [
  2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, //
  326, 582, 1094, 2118, //
];

int _code(final List<int> base, final List<int> bits, final int value) {
  for (var code = base.length - 1; code >= 0; code--) {
    if (value >= base[code]) {
      if (value - base[code] >= 1 << bits[code]) break;
      return code;
    }
  }
  throw ArgumentError.value(value);
}

/// The distance code and extra bits for [distance] (RFC 7932 section 4).
(int code, int bits, int extra) distanceCode(
  final int distance,
  final int postfix,
  final int direct,
) {
  if (distance <= direct) return (15 + distance, 0, 0);
  final value = distance - direct - 1;
  final low = value & ((1 << postfix) - 1);
  final high = (value >> postfix) + 4;
  final bits = high.bitLength - 2;
  final odd = (high >> bits) & 1;
  final extra = high - ((2 + odd) << bits);
  final code = 16 + direct + (((2 * (bits - 1) + odd) << postfix) | low);
  return (code, bits, extra);
}

/// Bytes a static dictionary word of [length] takes after [transform].
int wordLength(final int length, final int transform) {
  final type = transformTypes[transform];
  var size = length;
  if (type >= 12) size -= type - 11;
  if (type >= 3 && type < 12) size -= type - 2;
  if (size < 0) size = 0;
  return transformPrefixes[transform].length +
      size +
      transformSuffixes[transform].length;
}

/// The dictionary distance of word [index] of [length] under [transform],
/// with [available] bytes decoded before it in a window of [window] bytes.
int wordDistance(
  final int length,
  final int index,
  final int transform,
  final int available, {
  final int window = (1 << 16) - 16,
}) {
  final limit = available < window ? available : window;
  return limit + 1 + (transform << dictionaryBits[length] | index);
}

/// A one-meta-block stream (WBITS 16) holding [commands], with one block type
/// per category and NPOSTFIX [postfix] / NDIRECT [direct].
///
/// Literals use a flat 256-symbol code unless [trees] is given: one
/// single-symbol literal tree per entry, selected through the 64-entry
/// literal context [map] under context [mode]. Then every literal decodes to
/// the byte its context selects, whatever the command says.
Uint8List brotliStream(
  final List<Command> commands, {
  required final int size,
  final int postfix = 0,
  final int direct = 0,
  final int mode = 0,
  final List<int>? trees,
  final List<int>? map,
}) {
  final writer = BitWriter()..put(0, 1);
  writer
    ..put(1, 1) // ISLAST
    ..put(0, 1); // ISLASTEMPTY
  final nibbles = ((size - 1).bitLength + 3) ~/ 4;
  final digits = nibbles < 4 ? 4 : nibbles;
  writer.put(digits - 4, 2);
  writer.put(size - 1, digits * 4);
  for (var i = 0; i < 3; i++) {
    writer.put(0, 1); // NBLTYPES = 1
  }
  writer
    ..put(postfix, 2)
    ..put(direct >> postfix, 4)
    ..put(mode, 2);

  // NTREESL and the literal context map.
  final count = trees?.length ?? 1;
  _writeCount(writer, count);
  if (count > 1) {
    writer.put(0, 1); // RLEMAX = 0
    writeSimple(writer, count, [for (var i = 0; i < count; i++) i]);
    final lengths = simpleLengths(count, [for (var i = 0; i < count; i++) i]);
    writeSymbols(writer, lengths, map!);
    writer.put(0, 1); // no IMTF
  }
  _writeCount(writer, 1); // NTREESD

  final literalLengths = flat(256);
  if (trees == null) {
    writeLengths(writer, literalLengths);
  } else {
    for (final symbol in trees) {
      writeSimple(writer, 256, [symbol]);
    }
  }
  final commandLengths = flat(704);
  writeLengths(writer, commandLengths);
  final alphabet = 16 + direct + (48 << postfix);
  final distanceLengths = flat(alphabet);
  writeLengths(writer, distanceLengths);

  final commandCodes = canonical(commandLengths);
  final distanceCodes = canonical(distanceLengths);
  final literalCodes = canonical(literalLengths);
  for (final step in commands) {
    final insert = step.literals.length;
    final insertCode = _code(_insertBase, _insertBits, insert);
    final copyCode = _code(_copyBase, _copyBits, step.copy < 2 ? 2 : step.copy);
    final insertRange = insertCode & ~7;
    final copyRange = copyCode & ~7;
    final cell = step.implicit
        ? (copyRange == 0 ? 0 : 1)
        : const {
            (0, 0): 2,
            (0, 8): 3,
            (8, 0): 4,
            (8, 8): 5,
            (0, 16): 6,
            (16, 0): 7,
            (8, 16): 8,
            (16, 8): 9,
            (16, 16): 10,
          }[(insertRange, copyRange)]!;
    final symbol = cell * 64 + ((insertCode & 7) << 3) + (copyCode & 7);
    writer.put(commandCodes[symbol], commandLengths[symbol]);
    writer.put(insert - _insertBase[insertCode], _insertBits[insertCode]);
    final copy = step.copy < 2 ? 2 : step.copy;
    writer.put(copy - _copyBase[copyCode], _copyBits[copyCode]);
    for (final literal in step.literals) {
      if (trees == null) {
        writer.put(literalCodes[literal], 8);
      }
    }
    if (step.copy == 0 || step.implicit) continue;
    final short = step.short;
    if (short != null) {
      writer.put(distanceCodes[short], distanceLengths[short]);
      continue;
    }
    final (code, bits, extra) = distanceCode(step.distance, postfix, direct);
    writer.put(distanceCodes[code], distanceLengths[code]);
    writer.put(extra, bits);
  }
  return writer.finish();
}

/// Code lengths of the simple prefix code [writeSimple] writes for [symbols].
List<int> simpleLengths(final int alphabet, final List<int> symbols) {
  final lengths = List.filled(alphabet, 0);
  final shape = switch (symbols.length) {
    1 => const [0],
    2 => const [1, 1],
    3 => const [1, 2, 2],
    _ => const [2, 2, 2, 2],
  };
  for (var i = 0; i < symbols.length; i++) {
    lengths[symbols[i]] = shape[i];
  }
  return lengths;
}

/// Writes a simple prefix code (HSKIP 1) for 1-4 [symbols]; four symbols use
/// tree-select 0 (all length 2).
void writeSimple(
  final BitWriter writer,
  final int alphabet,
  final List<int> symbols,
) {
  writer
    ..put(1, 2)
    ..put(symbols.length - 1, 2);
  for (final symbol in symbols) {
    writer.put(symbol, (alphabet - 1).bitLength);
  }
  if (symbols.length == 4) writer.put(0, 1);
}

void _writeCount(final BitWriter writer, final int value) {
  if (value == 1) {
    writer.put(0, 1);
    return;
  }
  final bits = (value - 1).bitLength - 1;
  writer
    ..put(1, 1)
    ..put(bits, 3)
    ..put(value - 1 - (1 << bits), bits);
}

/// Decodes [data] with the reference `brotli -d`, or returns null when it
/// rejects the stream.
Future<Uint8List?> referenceDecode(final Uint8List data) async {
  final process = await Process.start('brotli', ['-d', '-c']);
  process.stdin.add(data);
  await process.stdin.close();
  final output = BytesBuilder(copy: false);
  await process.stdout.forEach(output.add);
  await process.stderr.drain<void>();
  return await process.exitCode == 0 ? output.takeBytes() : null;
}
