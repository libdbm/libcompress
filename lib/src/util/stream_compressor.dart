import 'dart:typed_data';

import 'stream_pump.dart';

/// A stateful streaming compressor: emit [header] once, then [addChunk] per
/// input chunk (carrying history across chunks), then [finish] (trailer/flush).
abstract interface class StreamCompressor {
  /// Frame/member header bytes, emitted before the first output.
  Uint8List header();

  /// Compresses [data] and returns the bytes produced (may be empty if the
  /// chunk is too small to emit yet).
  Uint8List addChunk(Uint8List data);

  /// Flushes the final block and trailer.
  Uint8List finish();
}

/// Drives [input] through [compressor] with backpressure and a uniform error
/// boundary (via [pumpBytes]); the header is emitted before the first output.
Stream<Uint8List> compressStream(
  final Stream<Uint8List> input,
  final StreamCompressor compressor,
) {
  var headerWritten = false;
  void writeHeader(final void Function(Uint8List) emit) {
    if (headerWritten) return;
    emit(compressor.header());
    headerWritten = true;
  }

  return pumpBytes(
    input,
    onData: (chunk, emit) {
      writeHeader(emit);
      emit(compressor.addChunk(chunk));
    },
    onDone: (emit) {
      writeHeader(emit);
      emit(compressor.finish());
    },
  );
}
