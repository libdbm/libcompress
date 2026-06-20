import 'dart:async';
import 'dart:typed_data';

/// A push-based, memory-bounded incremental decompressor.
///
/// Unlike the frame-buffering [StreamDecompressTransformer] (which holds a
/// whole compressed frame and its whole decompressed output), an
/// [IncrementalDecoder] is fed compressed bytes via [add] as they arrive and
/// emits decompressed output via the `emit` callback as soon as a unit (block)
/// is ready, retaining only bounded internal state. [close] flushes any tail
/// and validates trailers.
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
    final controller = StreamController<Uint8List>();
    final decoder = create();
    late StreamSubscription<Uint8List> subscription;

    void emit(final Uint8List output) {
      if (output.isNotEmpty) controller.add(output);
    }

    subscription = stream.listen(
      (chunk) {
        try {
          decoder.add(chunk, emit);
        } catch (e, st) {
          controller.addError(e, st);
          subscription.cancel();
        }
      },
      onError: (Object e, StackTrace st) {
        controller.addError(e, st);
        subscription.cancel();
      },
      onDone: () {
        try {
          decoder.close(emit);
        } catch (e, st) {
          controller.addError(e, st);
        }
        controller.close();
      },
      cancelOnError: true,
    );

    controller.onCancel = subscription.cancel;
    return controller.stream;
  }
}
