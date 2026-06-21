import 'dart:typed_data';

import '../compression_codec.dart';
import '../compression_options.dart';
import 'zstd_common.dart';
import 'zstd_compressor.dart';
import 'zstd_decoder.dart';

/// Zstandard (Zstd) compression codec
///
/// Pure Dart implementation of a practical **subset** of Zstandard (RFC 8878) —
/// not a full decoder. In particular **dictionary-compressed frames are
/// rejected**: a `.zst` produced with `zstd -D <dict>` (or any frame carrying a
/// Dictionary_ID) throws a [ZstdFormatException] on decode, so don't assume
/// arbitrary `.zst` files will decode. See Supported / Not implemented below.
///
/// Supported features:
/// - Full frame format parsing with magic number validation
/// - Raw (uncompressed) blocks
/// - RLE (run-length encoded) blocks
/// - Compressed blocks (FSE/Huffman encoding)
/// - Sequence encoding (literal lengths, match lengths, offsets)
/// - Repeat offset history (rep0/rep1/rep2 codes)
/// - XXH64 content checksum (optional)
/// - Multiple concatenated frames
/// - Skippable frames
///
/// Not implemented:
/// - Dictionary compression
/// - Window sizes larger than frame content
///
/// CLI compatibility: Files produced by this codec decompress correctly with
/// the standard `zstd` CLI tool, and non-dictionary `.zst` files from the CLI
/// decode here. Dictionary frames (`zstd -D`) are the exception — they fail.
class ZstdCodec extends CompressionCodec {
  /// Compression level (1-9)
  final int level;

  /// Block size for compression
  final int blockSize;

  /// Whether to include XXH64 content checksum
  final bool enableChecksum;

  /// Maximum decompressed size (prevents OOM on malicious input)
  /// Set to null for unlimited (not recommended for untrusted input)
  final int? maxDecompressedSize;

  /// Whether to validate compressed blocks by decompressing them
  ///
  /// When enabled, each block is decompressed immediately after compression
  /// to verify correctness. This doubles CPU work but is useful for debugging.
  final bool validate;

  /// Creates a Zstd codec with specified options
  ZstdCodec({
    this.level = 3,
    this.blockSize = 128 * 1024,
    this.enableChecksum = false,
    this.maxDecompressedSize = zstdDefaultMaxDecompressedSize,
    this.validate = false,
  }) {
    validateLevel(level, 1, 22);
    validateRange(blockSize, 1, zstdMaxBlockSize, 'blockSize');
    validateOptionalPositive(maxDecompressedSize, 'maxDecompressedSize');
  }

  /// Creates a Zstd codec from compression options
  factory ZstdCodec.fromOptions(final ZstdOptions options) {
    return ZstdCodec(
      level: options.level,
      blockSize: options.blockSize,
      enableChecksum: options.checksum,
      validate: options.validate,
      maxDecompressedSize: options.maxDecompressedSize,
    );
  }

  @override
  Uint8List compress(final Uint8List data) {
    final compressor = ZstdCompressor(
      level: level,
      blockSize: blockSize,
      enableChecksum: enableChecksum,
      validate: validate,
    );
    return compressor.compress(data);
  }

  @override
  Uint8List decompress(final Uint8List data) {
    return ZstdDecoder(maxSize: maxDecompressedSize).decompress(data);
  }

  @override
  String get name => 'ZSTD';

  @override
  bool supports(final CodecMode mode) =>
      mode == CodecMode.block || mode == CodecMode.stream;
}

/// Zstd-specific compression options
class ZstdOptions extends CompressionOptions {
  /// Block size for compression (max 128KB)
  final int blockSize;

  /// Whether to validate compressed blocks by decompressing them
  ///
  /// When enabled, each block is decompressed immediately after compression
  /// to verify correctness. This doubles CPU work but is useful for debugging.
  final bool validate;

  /// Creates Zstd options with specified parameters
  ///
  /// [level] must be between 1 and 22 (Zstd supports higher levels than other codecs).
  /// Throws [ArgumentError] if level is not between 1 and 22.
  ZstdOptions({
    super.level = 3,
    super.checksum = false,
    super.maxDecompressedSize,
    this.blockSize = 128 * 1024,
    this.validate = false,
  }) {
    if (level < 1 || level > 22) {
      throw ArgumentError.value(level, 'level', 'Must be between 1 and 22');
    }
  }
}
