import 'dart:typed_data';
import '../compression_codec.dart';

/// Pass-through codec that performs no compression
///
/// Useful for testing, benchmarking, and as a placeholder when
/// compression is optional.
class NoopCodec extends CompressionCodec {
  // Return independent copies so the codec's output does not alias the
  // caller's buffer (mutating the source must not mutate the result).
  @override
  Uint8List compress(final Uint8List data) => Uint8List.fromList(data);

  @override
  Uint8List decompress(final Uint8List data) => Uint8List.fromList(data);

  @override
  String get name => 'NOOP';

  @override
  bool supports(final CodecMode mode) =>
      mode == CodecMode.block || mode == CodecMode.stream;
}
