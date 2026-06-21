import 'dart:typed_data';

import '../compression_codec.dart';
import '../compression_options.dart';
import 'lz4_encoder.dart';
import 'lz4_decoder.dart';
import 'lz4_common.dart';

/// LZ4 compression codec
///
/// Pure Dart implementation of LZ4 frame format compression.
/// Compatible with standard lz4 command-line tools.
///
/// Example:
/// ```dart
/// final codec = Lz4Codec();
/// final compressed = codec.compress(data);
/// final decompressed = codec.decompress(compressed);
/// ```
class Lz4Codec extends CompressionCodec {
  /// Creates an LZ4 codec with specified options
  ///
  /// [level] controls compression quality (1=fast, 9=best with HC mode).
  /// [blockSize] sets the frame block size (use lz4BlockSize* constants).
  /// [enableContentChecksum] adds XXH32 checksum for integrity verification.
  /// [maxDecompressedSize] limits output size to prevent OOM attacks.
  Lz4Codec({
    this.level = 1,
    this.blockSize = lz4DefaultBlockSize,
    this.enableContentChecksum = true,
    this.maxDecompressedSize = lz4DefaultMaxDecompressedSize,
  }) {
    validateLevel(level, 1, 9);
    validateRange(blockSize, 1, lz4BlockSize4M, 'blockSize');
    validateOptionalPositive(maxDecompressedSize, 'maxDecompressedSize');
  }

  /// Creates an LZ4 codec from compression options
  factory Lz4Codec.fromOptions(Lz4Options options) {
    return Lz4Codec(
      level: options.level,
      blockSize: options.blockSize,
      enableContentChecksum: options.checksum,
    );
  }

  /// Compression level (1-9, where 9 enables high-compression mode)
  final int level;

  /// Block size for frame compression
  final int blockSize;

  /// Whether to include content checksum in output
  final bool enableContentChecksum;

  /// Maximum decompressed size (prevents OOM on malicious input)
  /// Set to null for unlimited (not recommended for untrusted input)
  final int? maxDecompressedSize;

  @override
  Uint8List compress(Uint8List data) {
    return Lz4Encoder(
      level: level,
      blockSize: blockSize,
      enableContentChecksum: enableContentChecksum,
    ).compress(data);
  }

  @override
  Uint8List decompress(Uint8List data) {
    return Lz4Decoder(maxSize: maxDecompressedSize).decompress(data);
  }

  @override
  String get name => 'LZ4';

  @override
  bool supports(final CodecMode mode) =>
      mode == CodecMode.block || mode == CodecMode.stream;
}

/// LZ4-specific compression options
class Lz4Options extends CompressionOptions {
  /// Block size for LZ4 frame compression
  ///
  /// Standard values: 64KB, 256KB, 1MB, 4MB (default).
  /// Use [lz4BlockSize64K], [lz4BlockSize256K], [lz4BlockSize1M],
  /// or [lz4BlockSize4M] constants.
  final int blockSize;

  /// Creates LZ4 options with specified parameters
  ///
  /// [level] must be between 1 and 9 (9 enables high-compression mode).
  /// Throws [ArgumentError] if level is not between 1 and 9.
  Lz4Options({
    super.level = 1,
    super.checksum = true,
    this.blockSize = lz4DefaultBlockSize,
  }) {
    if (level < 1 || level > 9) {
      throw ArgumentError.value(level, 'level', 'Must be between 1 and 9');
    }
  }
}
