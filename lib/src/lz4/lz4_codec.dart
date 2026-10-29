import 'dart:typed_data';

import '../compression_codec.dart';
import '../util/expected_size.dart';
import '../compression_options.dart';
import 'lz4_encoder.dart';
import 'lz4_decoder.dart';
import 'lz4_common.dart';

/// LZ4 compression codec
///
/// Pure Dart implementation of LZ4 compression, in the [Lz4Format.frame]
/// format (compatible with the standard lz4 command-line tool), as a bare
/// [Lz4Format.raw] block (Parquet `LZ4_RAW`), or in [Lz4Format.hadoop] block
/// framing (Parquet's legacy `LZ4`).
///
/// Example:
/// ```dart
/// final codec = Lz4Codec();
/// final compressed = codec.compress(data);
/// final decompressed = codec.decompress(compressed);
/// ```
final class Lz4Codec extends CompressionCodec {
  /// Creates an LZ4 codec with specified options
  ///
  /// [format] selects the frame format (default), a bare raw block or Hadoop
  /// block framing.
  /// [level] controls compression quality: 1 is the fast compressor, 2-9 use
  /// high-compression (HC) mode, searching deeper as the level rises.
  /// [blockSize] sets the frame block size (use lz4BlockSize* constants).
  /// [checksum] adds XXH32 checksum for integrity verification.
  /// [maxSize] limits output size to prevent OOM attacks.
  Lz4Codec({
    this.format = Lz4Format.frame,
    this.level = 1,
    this.blockSize = lz4DefaultBlockSize,
    this.checksum = true,
    this.maxSize = defaultMaxSize,
  }) {
    validateLevel(level, 1, 9);
    validateRange(blockSize, 1, lz4BlockSize4M, 'blockSize');
    validateOptionalPositive(maxSize, 'maxSize');
  }

  /// Creates an LZ4 codec from compression options
  factory Lz4Codec.fromOptions(final Lz4Options options) {
    return Lz4Codec(
      format: options.format,
      level: options.level,
      blockSize: options.blockSize,
      checksum: options.checksum,
      maxSize: options.maxSize,
    );
  }

  /// How the data is packaged: an LZ4 frame, a bare raw block or Hadoop block
  /// framing.
  final Lz4Format format;

  /// Compression level (1 fast, 2-9 high-compression mode)
  final int level;

  /// Block size for frame compression (unused for [Lz4Format.raw])
  final int blockSize;

  /// Whether to include content checksum in output
  final bool checksum;

  /// Maximum decompressed size (prevents OOM on malicious input)
  /// Set to null for unlimited (not recommended for untrusted input)
  final int? maxSize;

  @override
  Uint8List compress(final Uint8List data) {
    final encoder = Lz4Encoder(
      level: level,
      blockSize: blockSize,
      checksum: checksum,
    );
    return switch (format) {
      Lz4Format.frame => encoder.compress(data),
      Lz4Format.raw => encoder.compressBlock(data),
      Lz4Format.hadoop => encoder.compressHadoop(data),
    };
  }

  @override
  Uint8List decompress(final Uint8List data, {final int? size}) {
    final decoder = Lz4Decoder(maxSize: capFor(maxSize, size));
    final output = switch (format) {
      Lz4Format.frame => decoder.decompress(data),
      Lz4Format.raw => decoder.decompressBlock(data, size: size),
      Lz4Format.hadoop => decoder.decompressHadoop(data),
    };
    return checkSize(output, size, Lz4FormatException.new);
  }

  @override
  String get name => 'LZ4';
}

/// LZ4-specific compression options
class Lz4Options extends CompressionOptions {
  /// Block size for LZ4 frame compression
  ///
  /// Standard values: 64KB, 256KB, 1MB, 4MB (default).
  /// Use [lz4BlockSize64K], [lz4BlockSize256K], [lz4BlockSize1M],
  /// or [lz4BlockSize4M] constants.
  final int blockSize;

  /// How the data is packaged: an LZ4 frame, a bare raw block or Hadoop block
  /// framing.
  final Lz4Format format;

  /// Creates LZ4 options with specified parameters
  ///
  /// [level] must be between 1 and 9 (2-9 use high-compression mode).
  /// Throws [ArgumentError] if level is not between 1 and 9.
  Lz4Options({
    super.level = 1,
    super.checksum = true,
    super.maxSize,
    this.blockSize = lz4DefaultBlockSize,
    this.format = Lz4Format.frame,
  }) {
    validateLevel(level, 1, 9);
    validateRange(blockSize, 1, lz4BlockSize4M, 'blockSize');
  }
}
