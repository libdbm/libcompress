import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:libcompress/libcompress.dart';
import 'package:libcompress/src/util/stream_pump.dart';
import 'package:libcompress/src/util/stream_compressor.dart';

Uint8List _b(final List<int> v) => Uint8List.fromList(v);

/// A compressor that throws on the chosen lifecycle method (error-boundary test).
class _ThrowingCompressor implements StreamCompressor {
  _ThrowingCompressor(this.where);
  final String where;
  @override
  Uint8List header() => _b([1]);
  @override
  Uint8List addChunk(final Uint8List data) {
    if (where == 'addChunk') throw StateError('addChunk boom');
    return _b([]);
  }

  @override
  Uint8List finish() {
    if (where == 'finish') throw StateError('finish boom');
    return _b([]);
  }
}

void main() {
  group('pumpBytes — error boundary', () {
    test('a throw from onData surfaces via the output stream', () {
      final out = pumpBytes(
        Stream.value(_b([1, 2, 3])),
        onData: (chunk, emit) => throw StateError('boom'),
        onDone: (emit) {},
      );
      expect(out.toList(), throwsA(isA<StateError>()));
    });

    test('a throw from onDone surfaces via the output stream', () {
      final out = pumpBytes(
        const Stream.empty(),
        onData: (chunk, emit) {},
        onDone: (emit) => throw StateError('done boom'),
      );
      expect(out.toList(), throwsA(isA<StateError>()));
    });

    test('a source error surfaces via the output stream', () {
      final out = pumpBytes(
        Stream<Uint8List>.error(StateError('src')),
        onData: (chunk, emit) {},
        onDone: (emit) {},
      );
      expect(out.toList(), throwsA(isA<StateError>()));
    });
  });

  group('compressStream — error boundary', () {
    test('an encoder addChunk throw surfaces via onError (not unhandled)', () {
      final out = compressStream(
        Stream.value(_b([1, 2, 3])),
        _ThrowingCompressor('addChunk'),
      );
      expect(out.toList(), throwsA(isA<StateError>()));
    });

    test('an encoder finish throw surfaces via onError', () {
      final out = compressStream(
        const Stream.empty(),
        _ThrowingCompressor('finish'),
      );
      expect(out.toList(), throwsA(isA<StateError>()));
    });
  });

  group('pumpBytes — backpressure', () {
    test('pausing the output pauses the source; resume restores it', () async {
      var paused = false;
      final source = StreamController<Uint8List>(
        onPause: () => paused = true,
        onResume: () => paused = false,
      );
      final out = pumpBytes(
        source.stream,
        onData: (chunk, emit) => emit(chunk),
        onDone: (emit) {},
      );

      final sub = out.listen((_) {});
      sub.pause();
      await Future<void>.delayed(Duration.zero);
      expect(paused, isTrue, reason: 'consumer pause must propagate to source');

      sub.resume();
      await Future<void>.delayed(Duration.zero);
      expect(paused, isFalse, reason: 'consumer resume must propagate to source');

      await sub.cancel();
      await source.close();
    });

    test('codec compress propagates backpressure to the input', () async {
      var paused = false;
      final source = StreamController<Uint8List>(
        onPause: () => paused = true,
        onResume: () => paused = false,
      );
      final sub = GzipStreamCodec().compress(source.stream).listen((_) {});
      sub.pause();
      await Future<void>.delayed(Duration.zero);
      expect(paused, isTrue);
      await sub.cancel();
      await source.close();
    });
  });
}
