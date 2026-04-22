import 'dart:typed_data';
import '../util/byte_utils.dart';
import '../util/xxh64.dart';
import 'zstd_common.dart';
import 'compressed_block_encoder.dart';

/// Zstandard compressor
///
/// Supports compression levels 1-22:
/// - Level 1: Fastest, lowest compression (search depth 4)
/// - Level 3: Default balance (search depth 32)
/// - Level 6: Better compression (search depth 96)
/// - Level 9: High compression (search depth 128)
/// - Level 12: Higher compression (search depth 256)
/// - Level 16: Very high compression (search depth 512)
/// - Level 17-22: Maximum compression (search depth 1024)
///
/// Current implementation uses:
/// - Hash chain match finding with level-based search depth
/// - Huffman-compressed literals for compressible data
/// - FSE-compressed sequences
/// - Raw/RLE blocks for incompressible/repetitive data
/// - XXH64 content checksum (optional)
class ZstdEncoder {
  final int level;
  final int blockSize;
  final bool enableChecksum;
  final bool validate;

  /// Search depth for match finding (derived from level)
  late final int searchDepth;

  /// Minimum match length (lower = better compression, slower)
  late final int minMatchLen;

  ZstdEncoder({
    this.level = 3,
    this.blockSize = 128 * 1024,
    this.enableChecksum = false,
    this.validate = false,
  }) {
    if (level < 1 || level > 22) {
      throw ArgumentError('Level must be between 1 and 22, got $level');
    }
    if (blockSize > zstdMaxBlockSize) {
      throw ArgumentError('Block size cannot exceed $zstdMaxBlockSize');
    }

    // Map level to search depth (similar to zstd CLI behavior)
    searchDepth = _levelToSearchDepth(level);
    minMatchLen = level >= 6 ? 3 : 4;
  }

  /// Map compression level to match search depth
  static int _levelToSearchDepth(final int level) {
    if (level <= 1) return 4;
    if (level <= 2) return 8;
    if (level <= 3) return 32;
    if (level <= 4) return 48;
    if (level <= 5) return 64;
    if (level <= 6) return 96;
    if (level <= 9) return 128;
    if (level <= 12) return 256;
    if (level <= 16) return 512;
    return 1024; // Levels 17-22
  }

  Uint8List compress(final Uint8List input) {
    // Estimate output size: magic(4) + header(~6) + blocks + checksum(4)
    // Worst case is uncompressed blocks with 3-byte headers
    final estimated = 32 + input.length + (input.length ~/ blockSize + 1) * 4;
    final output = Uint8List(estimated);
    var pos = 0;

    // Write magic number
    ByteUtils.writeUint32LEAt(output, pos, zstdMagicNumber);
    pos += 4;

    // Write frame header
    pos = _writeFrameHeader(output, pos, input.length);

    // Handle empty input: write an empty raw block
    if (input.isEmpty) {
      pos = _writeBlockHeader(output, pos, true, ZstdBlockType.raw, 0);
    } else {
      // Compress data in blocks
      var offset = 0;
      while (offset < input.length) {
        final remaining = input.length - offset;
        final chunkSize = remaining < blockSize ? remaining : blockSize;
        final isLastBlock = offset + chunkSize >= input.length;

        // Extract chunk
        final chunk = Uint8List.sublistView(input, offset, offset + chunkSize);

        // Try RLE compression first
        if (_isRleCandidate(chunk)) {
          pos = _writeRleBlock(output, pos, chunk, isLastBlock);
        } else {
          // Try compressed block encoding with FSE sequences
          // Falls back to raw if compression doesn't help
          final compressedEncoder = CompressedBlockEncoder(
            searchDepth: searchDepth,
            validate: validate,
          );
          final compressed = compressedEncoder.encodeBlock(chunk);
          if (compressed.length < chunk.length && compressed.isNotEmpty) {
            pos = _writeCompressedBlock(output, pos, compressed, isLastBlock);
          } else {
            pos = _writeRawBlock(output, pos, chunk, isLastBlock);
          }
        }

        offset += chunkSize;
      }
    }

    // Write checksum if enabled
    if (enableChecksum) {
      // Per RFC 8878: content checksum is low 32 bits of XXH64
      final checksum = XXH64.hashLow32(input);
      ByteUtils.writeUint32LEAt(output, pos, checksum);
      pos += 4;
    }

    return Uint8List.sublistView(output, 0, pos);
  }

  /// Write frame header per RFC 8878. Returns new position.
  int _writeFrameHeader(
    final Uint8List output,
    int pos,
    final int contentSize,
  ) {
    // Frame header descriptor
    var descriptor = 0;

    // Set content size flag per RFC 8878:
    //   FCS flag 0: 1 byte if Single_Segment, else 0 bytes (values 0-255)
    //   FCS flag 1: 2 bytes with 256 offset (values 256-65791)
    //   FCS flag 2: 4 bytes (values 65792-4294967295)
    //   FCS flag 3: 8 bytes (values 4294967296+)
    if (contentSize < 256) {
      descriptor |= 0x00 << 6; // FCS flag 0: 1 byte
    } else if (contentSize <= 65791) {
      descriptor |= 0x01 << 6; // FCS flag 1: 2 bytes
    } else if (contentSize < 4294967296) {
      descriptor |= 0x02 << 6; // FCS flag 2: 4 bytes
    } else {
      descriptor |= 0x03 << 6; // FCS flag 3: 8 bytes
    }

    // Single segment flag (no window descriptor needed)
    descriptor |= 0x20;

    // Checksum flag
    if (enableChecksum) {
      descriptor |= 0x04;
    }

    // No dictionary
    descriptor |= 0x00;

    output[pos++] = descriptor;

    // Write content size
    if (contentSize < 256) {
      output[pos++] = contentSize;
    } else if (contentSize <= 65791) {
      // FCS flag 1: Store value - 256 in 2 bytes
      final adjusted = contentSize - 256;
      output[pos++] = adjusted & 0xFF;
      output[pos++] = (adjusted >> 8) & 0xFF;
    } else if (contentSize < 4294967296) {
      // FCS flag 2: Store in 4 bytes
      output[pos++] = contentSize & 0xFF;
      output[pos++] = (contentSize >> 8) & 0xFF;
      output[pos++] = (contentSize >> 16) & 0xFF;
      output[pos++] = (contentSize >> 24) & 0xFF;
    } else {
      // FCS flag 3: Store in 8 bytes
      for (var i = 0; i < 8; i++) {
        output[pos++] = (contentSize >> (i * 8)) & 0xFF;
      }
    }
    return pos;
  }

  /// Write block header. Returns new position.
  int _writeBlockHeader(
    final Uint8List output,
    int pos,
    final bool lastBlock,
    final ZstdBlockType blockType,
    final int size,
  ) {
    var header = 0;

    if (lastBlock) {
      header |= 0x01;
    }

    final typeValue = switch (blockType) {
      ZstdBlockType.raw => 0,
      ZstdBlockType.rle => 1,
      ZstdBlockType.compressed => 2,
      ZstdBlockType.reserved => 3,
    };

    header |= typeValue << 1;
    header |= size << 3;

    // Write 3-byte little-endian header
    output[pos++] = header & 0xFF;
    output[pos++] = (header >> 8) & 0xFF;
    output[pos++] = (header >> 16) & 0xFF;
    return pos;
  }

  /// Write raw (uncompressed) block. Returns new position.
  int _writeRawBlock(
    final Uint8List output,
    int pos,
    final Uint8List chunk,
    final bool isLastBlock,
  ) {
    pos = _writeBlockHeader(output, pos, isLastBlock, ZstdBlockType.raw, chunk.length);
    output.setRange(pos, pos + chunk.length, chunk);
    return pos + chunk.length;
  }

  /// Write RLE block. Returns new position.
  int _writeRleBlock(
    final Uint8List output,
    int pos,
    final Uint8List chunk,
    final bool isLastBlock,
  ) {
    pos = _writeBlockHeader(output, pos, isLastBlock, ZstdBlockType.rle, chunk.length);
    output[pos++] = chunk[0]; // Single byte value
    return pos;
  }

  /// Write compressed block. Returns new position.
  int _writeCompressedBlock(
    final Uint8List output,
    int pos,
    final Uint8List compressed,
    final bool isLastBlock,
  ) {
    pos = _writeBlockHeader(
      output,
      pos,
      isLastBlock,
      ZstdBlockType.compressed,
      compressed.length,
    );
    output.setRange(pos, pos + compressed.length, compressed);
    return pos + compressed.length;
  }

  /// Check if chunk is a good candidate for RLE encoding
  ///
  /// Returns true only if ALL bytes in the chunk are identical.
  /// This prevents data corruption where trailing non-matching bytes
  /// would be lost during RLE compression.
  bool _isRleCandidate(final Uint8List chunk) {
    if (chunk.isEmpty) return false;

    final firstByte = chunk[0];

    for (var i = 1; i < chunk.length; i++) {
      if (chunk[i] != firstByte) {
        return false;
      }
    }

    return true;
  }
}
