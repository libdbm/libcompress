import 'dart:async';
import 'dart:typed_data';

/// Drives a byte [source] through [onData] / [onDone] callbacks, emitting
/// output via the `emit` argument, with two production guarantees the codecs
/// previously hand-rolled inconsistently:
///
/// - **Backpressure**: the returned stream's pause/resume is propagated to the
///   source subscription, so a slow consumer throttles a fast producer instead
///   of buffering output unboundedly. (Buffering is bounded to roughly one
///   input event's expansion, since each [onData] runs synchronously.)
/// - **Uniform error boundary**: any throw from [onData] / [onDone] (or a
///   source error) is delivered through the output stream's error channel and
///   terminates it — never as an unhandled asynchronous error.
///
/// The source is subscribed lazily (on first listen) and cancelled when the
/// output subscription is cancelled.
Stream<Uint8List> pumpBytes(
  final Stream<Uint8List> source, {
  required final void Function(Uint8List chunk, void Function(Uint8List) emit) onData,
  required final void Function(void Function(Uint8List) emit) onDone,
}) {
  late final StreamController<Uint8List> controller;
  late StreamSubscription<Uint8List> subscription;

  void emit(final Uint8List output) {
    if (output.isNotEmpty) controller.add(output);
  }

  // Deliver a terminal error then close (called at most once per stream).
  void fail(final Object error, final StackTrace stackTrace) {
    controller.addError(error, stackTrace);
    controller.close();
  }

  controller = StreamController<Uint8List>(
    onListen: () {
      subscription = source.listen(
        (chunk) {
          try {
            onData(chunk, emit);
          } catch (e, st) {
            subscription.cancel();
            fail(e, st);
          }
        },
        onError: (Object e, StackTrace st) => fail(e, st),
        onDone: () {
          try {
            onDone(emit);
          } catch (e, st) {
            fail(e, st);
            return;
          }
          controller.close();
        },
        cancelOnError: true,
      );
    },
    onPause: () => subscription.pause(),
    onResume: () => subscription.resume(),
    onCancel: () => subscription.cancel(),
  );

  return controller.stream;
}
