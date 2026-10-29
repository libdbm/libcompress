import 'dart:math' as math;
import 'dart:typed_data';

import '../util/bit_stream.dart';
import 'deflate_common.dart';
import 'deflate_encoder.dart';
import 'lz77_encoder.dart';

/// Stateful, sliding-window DEFLATE encoder for streaming compression.
///
/// Input is buffered into blocks of [_block] bytes, each written once the
/// longest match ([maxMatch]) of lookahead past it has arrived, so the output
/// does not depend on how the input is split into chunks, and memory stays at
/// one block plus the 32 KB window that matches reach back into (plus the
/// chunk being added).
class StreamingDeflateEncoder {
  StreamingDeflateEncoder({this.level = 6})
    : _blocks = DeflateEncoder(level: level),
      _lz77 = Lz77Encoder(level: level);

  /// Input bytes per DEFLATE block, as [DeflateEncoder] uses.
  static const _block = 65535;

  final int level;
  final DeflateEncoder _blocks; // reused only for token-based block writing
  final Lz77Encoder _lz77;
  final BitStreamWriter _out = BitStreamWriter();

  /// The window (up to 32 KB already encoded, before [_start]) followed by
  /// input not yet encoded, up to [_length].
  Uint8List _buffer = Uint8List(0);
  int _start = 0;
  int _length = 0;

  /// Feeds a chunk; returns the DEFLATE bytes produced (empty until a block
  /// and its lookahead have arrived).
  Uint8List addChunk(final Uint8List chunk) {
    _append(chunk);
    while (_length - _start >= _block + maxMatch) {
      _encode(_start + _block, isFinal: false);
    }
    return _out.takeBytes();
  }

  /// Encodes the remaining input, ending with the final block, and returns the
  /// remaining DEFLATE bytes (byte-aligned).
  Uint8List finish() {
    while (_length - _start > _block) {
      _encode(_start + _block, isFinal: false);
    }
    _encode(_length, isFinal: true);
    _out.flushToByte();
    return _out.takeBytes();
  }

  void _append(final Uint8List chunk) {
    if (_length + chunk.length > _buffer.length) {
      final capacity = math.max(_buffer.length * 2, _length + chunk.length);
      _buffer = Uint8List(capacity)..setRange(0, _length, _buffer);
    }
    _buffer.setRange(_length, _length + chunk.length, chunk);
    _length += chunk.length;
  }

  /// Writes one block for the input from [_start] to [limit] (its last match
  /// may run past [limit]), then keeps the last 32 KB before the new start.
  void _encode(final int limit, {required final bool isFinal}) {
    final data = Uint8List.sublistView(_buffer, 0, _length);
    // Seed the hash with the window preceding [_start] so matches reach it.
    _lz77
      ..reset()
      ..insert(data, math.max(0, _start - maxDistance), _start);
    final (tokens, end) = _lz77.tokenize(data, _start, limit);
    _blocks.writeBlock(
      _out,
      tokens,
      Uint8List.sublistView(data, _start, end),
      isFinal: isFinal,
    );
    _start = end;

    final drop = _start - maxDistance;
    if (drop > 0) {
      _buffer.setRange(0, _length - drop, _buffer, drop);
      _length -= drop;
      _start -= drop;
    }
  }
}
