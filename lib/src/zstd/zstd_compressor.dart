import 'dart:typed_data';

import 'zstd_encoder.dart';

/// Zstandard compressor using ZstdEncoder
///
/// This uses the full ZstdEncoder which supports compressed blocks
/// with FSE-encoded sequences and Huffman-compressed literals.
class ZstdCompressor {
  ZstdCompressor({
    required this.level,
    required this.blockSize,
    required this.enableChecksum,
    this.validate = false,
    this.strict = false,
    this.onFallback,
  });

  final int level;
  final int blockSize;
  final bool enableChecksum;
  final bool validate;
  final bool strict;
  final void Function(Object error, StackTrace stackTrace)? onFallback;

  Uint8List compress(Uint8List data) {
    final encoder = ZstdEncoder(
      level: level,
      blockSize: blockSize,
      enableChecksum: enableChecksum,
      validate: validate,
      strict: strict,
      onFallback: onFallback,
    );
    return encoder.compress(data);
  }
}
