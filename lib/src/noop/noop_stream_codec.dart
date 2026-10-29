import 'dart:async';
import 'dart:typed_data';

import '../compression_options.dart';
import '../compression_stream_codec.dart';
import '../exceptions.dart';
import '../util/stream_pump.dart';

/// Pass-through streaming codec that performs no compression
///
/// Useful for testing streaming pipelines, benchmarking, and as a
/// placeholder when compression is optional. Decompression enforces the
/// cumulative [maxSize]; nothing is buffered, so there is no buffer limit.
final class NoopStreamCodec extends CompressionStreamCodec {
  /// Creates a pass-through streaming codec. [maxSize] caps cumulative
  /// decompressed output (null for unlimited, trusted input only).
  NoopStreamCodec({this.maxSize = defaultMaxSize}) {
    validateOptionalPositive(maxSize, 'maxSize');
  }

  /// Maximum cumulative decompressed size, or null for unlimited.
  final int? maxSize;

  @override
  String get name => 'NOOP';

  @override
  Stream<Uint8List> compress(final Stream<Uint8List> input) => input;

  @override
  Stream<Uint8List> decompress(final Stream<Uint8List> input) {
    final limit = maxSize;
    if (limit == null) return input;
    var total = 0;
    return pumpBytes(
      input,
      onData: (final chunk, final emit) {
        total += chunk.length;
        if (total > limit) throw LimitException(limit);
        emit(chunk);
      },
      onDone: (final emit) {},
    );
  }
}
