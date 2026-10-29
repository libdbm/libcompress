import 'dart:typed_data';

import 'deflate_common.dart';
import 'huffman_tables.dart';

/// LSB-first DEFLATE bit reader shared by the block and incremental decoders.
///
/// Holds at most 23 pending bits, so every value stays a non-negative 32-bit
/// integer on both the VM and dart2js. Reads past [end] are padded with zeros
/// so a table lookup can peek a full code width near the end of the available
/// input; consuming any padding means the input ran out. When [partial] is
/// true (more input may arrive) that throws [StateError], the incremental
/// decoder's signal to rewind to a checkpoint and wait; otherwise it throws
/// [DeflateFormatException].
class DeflateReader {
  /// Reads `data[start..end)`, starting [bit] bits into `data[start]`.
  DeflateReader(
    this._data, {
    final int start = 0,
    final int? end,
    final int bit = 0,
    this.partial = false,
  }) : _start = start,
       _end = end ?? _data.length,
       _next = start {
    rewind(bit);
  }

  final Uint8List _data;
  final int _start;
  final int _end;

  /// Whether more input may follow [_end] (see the class documentation).
  final bool partial;

  int _next; // index of the next byte to load into _hold
  int _hold = 0; // pending bits, LSB first
  int _count = 0; // number of valid bits in _hold

  /// Bits consumed since `start`; a checkpoint for [rewind].
  int get consumed => (_next - _start) * 8 - _count;

  /// Absolute byte offset of the first byte not yet consumed (exact once
  /// aligned).
  int get position => _next - (_count >> 3);

  /// Whole bytes available after the current (aligned) position.
  int get available => _end - position;

  /// Restores a checkpoint previously read from [consumed].
  void rewind(final int bits) {
    _next = _start + (bits >> 3);
    _hold = 0;
    _count = 0;
    if ((bits & 7) != 0) {
      _fill(8);
      _drop(bits & 7);
    }
  }

  void _fill(final int count) {
    while (_count < count) {
      final byte = _next < _end ? _data[_next] : 0;
      _hold |= byte << _count;
      _next++;
      _count += 8;
    }
  }

  /// True while padding bytes beyond [_end] sit in [_hold].
  bool get _padded => _next > _end;

  void _drop(final int count) {
    _hold >>= count;
    _count -= count;
    // Padding bytes still in _hold must outnumber the bits just consumed.
    if (_padded && (_next - _end) * 8 > _count) _exhausted();
  }

  Never _exhausted() {
    if (partial) throw StateError('Need more DEFLATE input');
    throw DeflateFormatException('Unexpected end of DEFLATE stream');
  }

  /// Reads [count] bits (at most 16).
  int read(final int count) {
    if (count == 0) return 0;
    _fill(count);
    final value = _hold & ((1 << count) - 1);
    _drop(count);
    return value;
  }

  /// Decodes one symbol with [decoder]'s lookup table.
  int decode(final HuffmanDecoder decoder) {
    _fill(decoder.bits);
    final table = decoder.table;
    var entry = table[_hold & ((1 << decoder.root) - 1)];
    if (entry & 16 != 0) {
      entry =
          table[(entry >> 5) +
              ((_hold >> decoder.root) & ((1 << (entry & 0xF)) - 1))];
    }
    if (entry == 0) {
      // With padding in the peeked bits the code may simply be incomplete.
      if (partial && _padded) _exhausted();
      throw DeflateFormatException('Invalid Huffman code');
    }
    _drop(entry & 0xF);
    return entry >> 5;
  }

  /// Discards bits up to the next byte boundary.
  void align() => _drop(_count & 7);

  /// The input bytes, for a decoder that reads bits itself between [state]
  /// and [resume].
  Uint8List get data => _data;

  /// Index one past the last input byte.
  int get end => _end;

  /// The bit position as (next byte to load, pending bits, pending count).
  (int, int, int) get state => (_next, _hold, _count);

  /// Continues from a position taken with [state] and advanced by the caller,
  /// who may have loaded more whole bytes than it consumed: those are handed
  /// back, so at most 7 bits stay pending.
  void resume(final int next, final int hold, final int count) {
    _next = next - (count >> 3);
    _count = count & 7;
    _hold = hold & ((1 << _count) - 1);
  }

  /// Returns the next [count] bytes (byte-aligned) without copying them.
  Uint8List take(final int count) {
    final start = position;
    if (start + count > _end) {
      if (partial) _exhausted();
      throw DeflateFormatException('Stored block extends past end of input');
    }
    _next = start + count;
    _hold = 0;
    _count = 0;
    return Uint8List.sublistView(_data, start, start + count);
  }
}

/// Reads a dynamic block's code-length tables (RFC 1951 Section 3.2.7) and
/// returns the literal/length and distance decoders.
(HuffmanDecoder, HuffmanDecoder) readDynamicTables(final DeflateReader input) {
  // Read tree descriptions
  final hlit = input.read(5) + 257;
  final hdist = input.read(5) + 1;
  final hclen = input.read(4) + 4;

  // Read code length code lengths
  final lengths = List<int>.filled(19, 0);
  for (var i = 0; i < hclen; i++) {
    lengths[codeLengthOrder[i]] = input.read(3);
  }

  // Build code length decoder
  final decoder = buildDecoder(lengths);

  // Decode literal/length and distance code lengths
  final totalLength = hlit + hdist;
  final codeLengths = Uint8List(totalLength);
  var filled = 0;
  while (filled < totalLength) {
    final symbol = input.decode(decoder);

    if (symbol < 16) {
      // Literal code length
      codeLengths[filled++] = symbol;
      continue;
    }
    final int value;
    final int repeat;
    if (symbol == 16) {
      // Repeat previous code length 3-6 times
      if (filled == 0) {
        throw DeflateFormatException('Invalid repeat code at start');
      }
      value = codeLengths[filled - 1];
      repeat = input.read(2) + 3;
    } else if (symbol == 17) {
      // Repeat zero 3-10 times
      value = 0;
      repeat = input.read(3) + 3;
    } else if (symbol == 18) {
      // Repeat zero 11-138 times
      value = 0;
      repeat = input.read(7) + 11;
    } else {
      throw DeflateFormatException('Invalid code length symbol: $symbol');
    }
    if (repeat > totalLength - filled) {
      throw DeflateFormatException(
        'Run-length code overruns code-length table',
      );
    }
    codeLengths.fillRange(filled, filled + repeat, value);
    filled += repeat;
  }

  // Split into literal/length and distance code lengths and build decoders
  return (
    buildDecoder(Uint8List.sublistView(codeLengths, 0, hlit)),
    buildDecoder(Uint8List.sublistView(codeLengths, hlit, totalLength)),
  );
}
