import 'dart:async';
import 'dart:typed_data';

import 'stream_pump.dart';

/// A push-based, memory-bounded incremental decompressor.
///
/// An [IncrementalDecoder] is fed compressed bytes via [add] as they arrive and
/// emits decompressed output via the `emit` callback as soon as a unit (block)
/// is ready, retaining only bounded internal state — rather than buffering a
/// whole frame and inflating it at once. [close] flushes any tail and validates
/// trailers.
abstract class IncrementalDecoder {
  /// Consumes [input], emitting any decompressed output now available.
  void add(Uint8List input, void Function(Uint8List) emit);

  /// Signals end of input; emits the tail and validates trailers (throws on
  /// an incomplete or invalid stream).
  void close(void Function(Uint8List) emit);
}

/// Drives an [IncrementalDecoder] over a `Stream<Uint8List>`.
class IncrementalDecompressTransformer
    extends StreamTransformerBase<Uint8List, Uint8List> {
  final IncrementalDecoder Function() create;

  IncrementalDecompressTransformer(this.create);

  @override
  Stream<Uint8List> bind(final Stream<Uint8List> stream) {
    final decoder = create();
    return pumpBytes(stream, onData: decoder.add, onDone: decoder.close);
  }
}
