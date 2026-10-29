import 'dart:typed_data';

import '../exceptions.dart';

// Re-export exception from centralized location
export '../exceptions.dart' show ZstdFormatException;

/// Zstandard magic number
/// File bytes: 28 B5 2F FD (little-endian)
/// When read as uint32LE: 0xFD2FB528
const int zstdMagicNumber = 0xFD2FB528;

/// Base magic number for skippable frames (0x184D2A50 + n, where n in [0, 15])
const int zstdSkippableFrameMagicBase = 0x184D2A50;

/// Mask used to detect skippable magic numbers.
const int zstdSkippableFrameMagicMask = 0xFFFFFFF0;

/// Maximum block size (128 KB)
const int zstdMaxBlockSize = 128 * 1024;

/// Block types in Zstandard format
enum ZstdBlockType {
  /// Uncompressed data block
  raw,

  /// Single byte repeated (run-length encoded)
  rle,

  /// Zstd compressed block (FSE/Huffman)
  compressed,

  /// Invalid/reserved block type
  reserved,
}

/// Frame header descriptor flags parsed from first header byte
class ZstdFrameHeaderDescriptor {
  /// Whether frame contains a single segment (no window descriptor)
  final bool singleSegment;

  /// Whether frame includes XXH64 content checksum
  final bool checksumFlag;

  /// Dictionary ID field size (0, 1, 2, or 4 bytes)
  final int dictionaryIdFlag;

  /// Content size field presence and size
  final int contentSizeFlag;

  /// Creates a frame header descriptor with the given flags
  ZstdFrameHeaderDescriptor({
    required this.singleSegment,
    required this.checksumFlag,
    required this.dictionaryIdFlag,
    required this.contentSizeFlag,
  });

  /// Parses a frame header descriptor from a single byte
  factory ZstdFrameHeaderDescriptor.parse(final int byte) {
    if (byte & 0x08 != 0) {
      throw ZstdFormatException('Frame header descriptor reserved bit is set');
    }
    return ZstdFrameHeaderDescriptor(
      singleSegment: (byte & 0x20) != 0,
      checksumFlag: (byte & 0x04) != 0,
      dictionaryIdFlag: byte & 0x03,
      contentSizeFlag: (byte >> 6) & 0x03,
    );
  }
}

/// Parsed Zstd frame header information
class ZstdFrameHeader {
  /// The header descriptor flags
  final ZstdFrameHeaderDescriptor descriptor;

  /// Window size for decompression buffer (null if single segment)
  final int? windowSize;

  /// Dictionary ID if present (null if no dictionary)
  final int? dictionaryId;

  /// Uncompressed content size if known (null if not specified)
  final int? contentSize;

  /// Creates a frame header with the given parameters
  ZstdFrameHeader({
    required this.descriptor,
    this.windowSize,
    this.dictionaryId,
    this.contentSize,
  });
}

/// Parsed Zstd block header information
class ZstdBlockHeader {
  /// Whether this is the last block in the frame
  final bool lastBlock;

  /// The type of this block (raw, rle, compressed, reserved)
  final ZstdBlockType blockType;

  /// Size of the block content in bytes
  final int blockSize;

  /// Creates a block header with the given parameters
  ZstdBlockHeader({
    required this.lastBlock,
    required this.blockType,
    required this.blockSize,
  });

  /// Parses a block header from data at the given offset
  factory ZstdBlockHeader.parse(final Uint8List data, final int offset) {
    if (offset + 3 > data.length) {
      throw ZstdFormatException('Insufficient data for block header');
    }

    // Read 3-byte little-endian value
    final header =
        data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16);

    final lastBlock = (header & 0x01) != 0;
    final blockTypeValue = (header >> 1) & 0x03;
    final blockSize = (header >> 3) & 0x1FFFFF;

    ZstdBlockType blockType;
    switch (blockTypeValue) {
      case 0:
        blockType = ZstdBlockType.raw;
        break;
      case 1:
        blockType = ZstdBlockType.rle;
        break;
      case 2:
        blockType = ZstdBlockType.compressed;
        break;
      default:
        blockType = ZstdBlockType.reserved;
    }

    return ZstdBlockHeader(
      lastBlock: lastBlock,
      blockType: blockType,
      blockSize: blockSize,
    );
  }
}
