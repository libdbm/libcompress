import 'dart:typed_data';

import '../compression_codec.dart';
import '../compression_options.dart';
import '../exceptions.dart';
import '../util/expected_size.dart';
import 'brotli_decoder.dart';
import 'brotli_encoder.dart';

/// Brotli compression codec (RFC 7932)
///
/// The decoder implements the whole format: block switching, context
/// modeling, the static dictionary and its 121 transforms, and window sizes
/// up to 16 MB (`WBITS` 24). Streams from the reference `brotli` tool at any
/// quality decode here, as do Parquet `BROTLI` pages (bare Brotli streams):
///
/// ```dart
/// final page = BrotliCodec().decompress(bytes, size: n);
/// ```
///
/// The encoder writes valid streams with a smaller feature set: one block
/// type per category, no context modeling and no dictionary references. Its
/// output decodes with the reference tool but is larger than the reference
/// encoder's at the same level.
///
/// Not supported: the large-window extension, which is rejected with a
/// [BrotliFormatException], and shared dictionaries (RFC 9842). A stream
/// compressed with a shared dictionary carries no mark of it, so it cannot be
/// detected: it decodes to wrong bytes or fails with an unrelated error.
///
/// Brotli has no checksum and no frame concatenation, so a corrupt stream can
/// decode to wrong bytes, and bytes after the end of the stream are an error.
final class BrotliCodec extends CompressionCodec {
  /// Encoder effort, 1-11. Higher levels search harder for matches; they do
  /// not reproduce the reference encoder's ratio at the same quality number.
  final int level;

  /// Encoder window: `WBITS`, 10-24, for a window of `(1 << window) - 16`
  /// bytes. Decoding accepts any window the stream declares.
  final int window;

  /// Maximum decompressed size (prevents OOM on malicious input).
  /// Set to null for unlimited (not recommended for untrusted input).
  final int? maxSize;

  /// Creates a Brotli codec.
  BrotliCodec({
    this.level = 6,
    this.window = 22,
    this.maxSize = defaultMaxSize,
  }) {
    validateLevel(level, 1, 11);
    validateRange(window, 10, 24, 'window');
    validateOptionalPositive(maxSize, 'maxSize');
  }

  /// Creates a Brotli codec from compression options.
  factory BrotliCodec.fromOptions(final BrotliOptions options) => BrotliCodec(
    level: options.level,
    window: options.window,
    maxSize: options.maxSize,
  );

  @override
  Uint8List compress(final Uint8List data) =>
      BrotliEncoder(level: level, window: window).compress(data);

  @override
  Uint8List decompress(final Uint8List data, {final int? size}) {
    return checkSize(
      BrotliDecoder(
        maxSize: capFor(maxSize, size),
        size: size,
      ).decompress(data),
      size,
      BrotliFormatException.new,
    );
  }

  @override
  String get name => 'BROTLI';
}

/// Brotli-specific compression options
///
/// [checksum] is ignored: the Brotli format has no checksum.
class BrotliOptions extends CompressionOptions {
  /// Encoder window, `WBITS` 10-24 (see [BrotliCodec.window]).
  final int window;

  /// Creates Brotli options. Throws [ArgumentError] if [level] is not between
  /// 1 and 11 or [window] is not between 10 and 24.
  BrotliOptions({super.level = 6, super.maxSize, this.window = 22})
    : super(checksum: false) {
    validateLevel(level, 1, 11);
    validateRange(window, 10, 24, 'window');
  }
}
