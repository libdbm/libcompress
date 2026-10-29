import 'dart:typed_data';
import '../compression_codec.dart';
import '../compression_options.dart';
import '../exceptions.dart';
import '../util/expected_size.dart';

/// Pass-through codec that performs no compression
///
/// Useful for testing, benchmarking, and as a placeholder when
/// compression is optional. Like every codec it enforces [maxSize] on
/// decompression.
final class NoopCodec extends CompressionCodec {
  /// Creates a pass-through codec. [maxSize] caps decompressed output (null
  /// for unlimited, trusted input only).
  NoopCodec({this.maxSize = defaultMaxSize}) {
    validateOptionalPositive(maxSize, 'maxSize');
  }

  /// Maximum decompressed size, or null for unlimited.
  final int? maxSize;

  // Return independent copies so the codec's output does not alias the
  // caller's buffer (mutating the source must not mutate the result).
  @override
  Uint8List compress(final Uint8List data) => Uint8List.fromList(data);

  @override
  Uint8List decompress(final Uint8List data, {final int? size}) {
    final cap = capFor(maxSize, size);
    if (cap != null && data.length > cap) {
      throw LimitException(cap);
    }
    // Longer than [size] was rejected above as the limit it breaks.
    return checkSize(Uint8List.fromList(data), size, NoopFormatException.new);
  }

  @override
  String get name => 'NOOP';
}
