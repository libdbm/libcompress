import 'dart:typed_data';

import '../exceptions.dart';
import '../util/byte_utils.dart';
import '../util/xxh32.dart';

// Re-export GrowableBuffer from util
export '../util/growable_buffer.dart' show GrowableBuffer;
// Re-export exception from centralized location
export '../exceptions.dart' show Lz4FormatException;

/// How LZ4 data is packaged.
enum Lz4Format {
  /// The LZ4 frame format: magic, header, blocks, end mark and optional
  /// checksums. Compatible with the `lz4` command-line tool.
  frame,

  /// A single bare LZ4 block with no frame, for containers that record sizes
  /// themselves (Parquet `LZ4_RAW`).
  raw,

  /// Hadoop block framing: outer blocks of a big-endian u32 uncompressed
  /// length, each followed by inner chunks of a big-endian u32 compressed
  /// length and a raw block. Parquet's legacy `LZ4` codec.
  hadoop,
}

const int lz4FrameMagic = 0x184D2204;

/// Skippable frames use the 16 magic values `0x184D2A50`-`0x184D2A5F`.
const int lz4SkippableMagic = 0x184D2A50;
const int lz4SkippableMagicMask = 0xFFFFFFF0;

/// Magic number of the legacy frame format (`lz4 -l`), which is not supported.
const int lz4LegacyMagic = 0x184C2102;

/// Throws for a magic number that is neither a frame nor a skippable frame.
void lz4CheckMagic(final int magic) {
  if (magic == lz4LegacyMagic) {
    throw Lz4FormatException('legacy LZ4 frame format is not supported');
  }
  if (magic != lz4FrameMagic) {
    throw Lz4FormatException(
      'Invalid LZ4 frame magic: 0x${magic.toRadixString(16)}',
    );
  }
}

/// The header of an LZ4 frame, or of a skippable frame ([skip] not null).
class Lz4Header {
  Lz4Header(
    this.length, {
    this.skip,
    this.blockChecksum = false,
    this.contentChecksum = false,
    this.independent = false,
    this.blockSize = 0,
    this.contentSize,
  });

  /// Header bytes, from the magic number to the header checksum.
  final int length;

  /// For a skippable frame, the bytes that follow the header.
  final int? skip;

  final bool blockChecksum;
  final bool contentChecksum;

  /// Whether blocks are independent: a match may not reach into an earlier
  /// block.
  final bool independent;

  /// The frame's Block Maximum Size.
  final int blockSize;

  /// The declared content size, if any.
  final int? contentSize;
}

/// Parses the frame header at `data[offset..end)` for the one-shot and
/// incremental decoders. Returns null when more bytes are needed, and throws
/// once the bytes present are invalid.
Lz4Header? lz4Header(final Uint8List data, final int offset, final int end) {
  final available = end - offset;
  if (available < 4) return null;
  final magic = ByteUtils.readUint32LE(data, offset);
  if (magic & lz4SkippableMagicMask == lz4SkippableMagic) {
    if (available < 8) return null;
    return Lz4Header(8, skip: ByteUtils.readUint32LE(data, offset + 4));
  }
  lz4CheckMagic(magic);
  if (available < 6) return null;
  final flag = data[offset + 4];
  if (flag >> 6 != 0x01) {
    throw Lz4FormatException('Unsupported LZ4 frame version ${flag >> 6}');
  }
  if ((flag & 0x02) != 0) {
    throw Lz4FormatException('Reserved bit set in LZ4 FLG byte');
  }
  final bd = data[offset + 5];
  if ((bd & 0x8F) != 0) {
    throw Lz4FormatException('Reserved bits set in LZ4 BD byte');
  }
  final sized = (flag & 0x08) != 0;
  final dictionary = (flag & 0x01) != 0;
  final length = 7 + (sized ? 8 : 0) + (dictionary ? 4 : 0);
  if (available < length) return null;

  var position = offset + 6;
  int? contentSize;
  if (sized) {
    contentSize = ByteUtils.readUintLE(data, position, 8);
    position += 8;
  }
  if (dictionary) {
    if (ByteUtils.readUint32LE(data, position) != 0) {
      throw Lz4FormatException('External dictionaries are not supported');
    }
    position += 4;
  }
  final descriptor = Uint8List.sublistView(data, offset + 4, position);
  if (data[position] != lz4HeaderChecksum(descriptor)) {
    throw Lz4FormatException('Invalid LZ4 header checksum');
  }
  return Lz4Header(
    length,
    blockChecksum: (flag & 0x10) != 0,
    independent: (flag & 0x20) != 0,
    contentChecksum: (flag & 0x04) != 0,
    blockSize: blockSizeFromCode((bd >> 4) & 0x07),
    contentSize: contentSize,
  );
}

const int lz4MinMatch = 4;
const int lz4MaxOffset = 0xFFFF;
const int lz4HashLog = 16;
const int lz4HashTableSize = 1 << lz4HashLog;

/// Default LZ4 frame block size (4 MB).
const int lz4DefaultBlockSize = 4 * 1024 * 1024;

/// LZ4 frame block size of 64 KB.
const int lz4BlockSize64K = 64 * 1024;

/// LZ4 frame block size of 256 KB.
const int lz4BlockSize256K = 256 * 1024;

/// LZ4 frame block size of 1 MB.
const int lz4BlockSize1M = 1 * 1024 * 1024;

/// LZ4 frame block size of 4 MB, the largest.
const int lz4BlockSize4M = 4 * 1024 * 1024;

// MFLIMIT: Last 5 bytes must be literals to ensure safe decoding
const int lz4MFLimit = 12; // Minimum input size where matches are worth it
const int lz4LastLiterals = 5; // Last bytes that must be literals

int blockSizeFromCode(final int code) {
  switch (code) {
    case 4:
      return 64 * 1024;
    case 5:
      return 256 * 1024;
    case 6:
      return 1 * 1024 * 1024;
    case 7:
      return 4 * 1024 * 1024;
    default:
      throw Lz4FormatException('Unsupported block size code: $code');
  }
}

int blockSizeCodeFromSize(final int size) {
  if (size <= 64 * 1024) {
    return 4;
  } else if (size <= 256 * 1024) {
    return 5;
  } else if (size <= 1 * 1024 * 1024) {
    return 6;
  } else if (size <= 4 * 1024 * 1024) {
    return 7;
  }
  throw ArgumentError('Unsupported block size for LZ4 frame: $size');
}

int lz4HeaderChecksum(final List<int> headerBytes) {
  final checksum = XXH32.hash(Uint8List.fromList(headerBytes));
  return (checksum >> 8) & 0xFF;
}

int lz4ContentChecksum(final Uint8List content) {
  return XXH32.hash(content);
}
