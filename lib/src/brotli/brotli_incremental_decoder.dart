import 'dart:typed_data';

import '../exceptions.dart';
import '../util/byte_pending.dart';
import '../util/incremental_decoder.dart';
import 'bit_reader.dart';
import 'brotli_decoder.dart';
import 'meta_block.dart';

/// Incremental, memory-bounded Brotli decoder.
///
/// Decodes one meta-block at a time as input arrives. When the buffered input
/// ends inside a meta-block, the attempt is undone and retried once the
/// buffer has doubled (or at end of input), so the total work stays linear in
/// the input however it is split. Retained memory is the buffered compressed
/// input (at most [maxBufferSize]), the window, and one meta-block's output.
class BrotliIncrementalDecoder implements IncrementalDecoder {
  BrotliIncrementalDecoder({this.maxSize, required this.maxBufferSize});

  /// Cap on cumulative output, or null for unlimited.
  final int? maxSize;

  /// Cap on buffered compressed input.
  final int maxBufferSize;

  final BytePending _pending = BytePending();

  // Bits already consumed of the byte at `_pending.cursor`.
  int _bit = 0;

  StreamState? _state;
  bool _done = false;
  bool _empty = true;

  // Buffered input needed before the next attempt after one ran out.
  int _need = 0;

  @override
  void add(final Uint8List input, final void Function(Uint8List) emit) {
    if (input.isEmpty) return;
    _empty = false;
    if (_done) {
      throw const BrotliFormatException('Trailing bytes after the stream');
    }
    // Before the buffer limit would reject this chunk, try what is buffered:
    // the retry threshold may be past the limit.
    if (_pending.available + input.length > maxBufferSize) {
      _need = 0;
      guardFormat(
        () => _drive(emit, false),
        BrotliFormatException.new,
        limit: maxSize,
      );
    }
    _pending.append(input, maxBufferSize);
    guardFormat(
      () => _drive(emit, false),
      BrotliFormatException.new,
      limit: maxSize,
    );
  }

  @override
  void close(final void Function(Uint8List) emit) {
    if (_empty) throw const BrotliFormatException('Empty Brotli stream');
    guardFormat(
      () => _drive(emit, true),
      BrotliFormatException.new,
      limit: maxSize,
    );
  }

  void _drive(final void Function(Uint8List) emit, final bool end) {
    while (!_done) {
      if (!end && _pending.available < _need) break;
      final reader = BitReader(
        _pending.bytes,
        _pending.cursor,
        _pending.length,
        _bit,
      );
      final state = _state;
      final ring = state == null ? null : Int32List.fromList(state.ring);
      final index = state?.index ?? 0;
      try {
        if (state == null) {
          _state = StreamState(
            readWindowBits(reader),
            History(1 << 16, maxSize),
          );
        } else {
          _block(reader, state, emit);
        }
      } on StateError {
        if (state != null) {
          state.ring.setAll(0, ring!);
          state.index = index;
        }
        if (end) {
          throw const BrotliFormatException('Truncated Brotli stream');
        }
        _need = _pending.available * 2;
        break;
      }
      final position = reader.position;
      _pending.cursor = position >> 3;
      _bit = position & 7;
      _need = 0;
    }
    if (_done && _pending.available > 0) {
      throw const BrotliFormatException('Trailing bytes after the stream');
    }
    _pending.compact();
  }

  void _block(
    final BitReader reader,
    final StreamState state,
    final void Function(Uint8List) emit,
  ) {
    final output = state.output;
    final start = output.length;
    final header = readMetaBlockHeader(reader);
    switch (header.kind) {
      case MetaBlockKind.end:
        break;
      case MetaBlockKind.metadata:
        reader.discard(header.length);
      case MetaBlockKind.uncompressed:
        output.reserve(header.length);
        reader.copy(output.bytes, output.length, header.length);
        output.length += header.length;
      case MetaBlockKind.compressed:
        decodeCompressed(reader, state, header.length);
    }
    if (header.last) {
      if (reader.align() != 0) {
        throw const BrotliFormatException('Non-zero padding bits');
      }
      _done = true;
    }
    if (output.length > start) {
      emit(
        Uint8List.fromList(
          Uint8List.sublistView(output.bytes, start, output.length),
        ),
      );
    }
    // Keep the window; slide only once twice the window is held, so the copy
    // is amortized.
    if (output.length > 2 * state.window) output.slide(state.window);
  }
}
