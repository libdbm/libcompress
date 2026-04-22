import 'dart:typed_data';
import '../util/growable_buffer.dart';
import '../util/xxh64.dart';
import '../util/byte_utils.dart';
import 'zstd_common.dart';
import 'compressed_block_decoder.dart';

/// Zstandard decompressor
///
/// Current implementation supports:
/// - Frame format parsing with magic number validation
/// - Raw (uncompressed) blocks
/// - RLE (run-length encoded) blocks
/// - Compressed blocks with FSE/Huffman decoding
/// - XXH64 content checksum verification
/// - Multiple concatenated frames
/// - Skippable frames
///
/// Not implemented:
/// - Dictionary support
class ZstdDecoder {
  /// Maximum allowed decompressed size (prevents OOM attacks)
  /// Set to null for unlimited (not recommended for untrusted input)
  final int? maxSize;

  /// Creates a decoder with optional size limit
  ///
  /// [maxSize] defaults to [zstdDefaultMaxDecompressedSize] (256MB).
  /// Set to null to allow unlimited output (use with trusted input only).
  ZstdDecoder({this.maxSize = zstdDefaultMaxDecompressedSize});

  Uint8List decompress(final Uint8List data) {
    if (data.isEmpty) {
      throw ZstdFormatException('Input too short for Zstd frame');
    }

    // Track total decompressed output across all frames
    var total = 0;
    final limit = maxSize;

    // Use maxSize for merged output buffer too
    final merged = GrowableBuffer(data.length, maxSize);
    var offset = 0;
    var frames = 0;
    var skippableFrames = 0;

    while (offset < data.length) {
      if (offset + 4 > data.length) {
        throw ZstdFormatException(
          'Unexpected end of input while reading frame magic',
        );
      }

      final magic = ByteUtils.readUint32LE(data, offset);

      if (_isSkippableMagic(magic)) {
        if (offset + 8 > data.length) {
          throw ZstdFormatException('Incomplete skippable frame header');
        }
        final size = ByteUtils.readUint32LE(data, offset + 4);
        offset += 8;
        final skipEnd = offset + size;
        if (skipEnd > data.length) {
          throw ZstdFormatException('Skippable frame exceeds input bounds');
        }
        offset = skipEnd;
        skippableFrames++;
        continue;
      }

      if (magic != zstdMagicNumber) {
        throw ZstdFormatException(
          'Invalid Zstd magic number: 0x${magic.toRadixString(16)}',
        );
      }

      // Calculate remaining capacity for this frame
      final remaining = limit != null ? limit - total : null;
      final result = _decompressFrame(data, offset + 4, remaining);
      offset = result.$1;
      final frameBytes = result.$2;

      // Check cumulative limit before adding
      if (limit != null && total + frameBytes.length > limit) {
        throw ZstdFormatException(
          'Cumulative decompressed size ${total + frameBytes.length} exceeds '
          'maximum allowed size $limit',
        );
      }

      merged.addBytes(frameBytes);
      total += frameBytes.length;
      frames++;
    }

    // Valid input must have at least one frame (data or skippable)
    if (frames == 0 && skippableFrames == 0) {
      throw ZstdFormatException('No Zstd frame found in input');
    }

    return merged.toBytes();
  }

  bool _isSkippableMagic(int magic) {
    return (magic & zstdSkippableFrameMagicMask) == zstdSkippableFrameMagicBase;
  }

  /// Decompress a single frame. [remaining] is the remaining capacity
  /// for the cumulative output across all frames (null = unlimited).
  (int, Uint8List) _decompressFrame(
    Uint8List data,
    int offset,
    int? remaining,
  ) {
    final frameHeader = _parseFrameHeader(data, offset);
    offset = frameHeader.$1;
    final header = frameHeader.$2;

    if (header.dictionaryId != null) {
      throw ZstdFormatException(
        'Dictionary compression (id=${header.dictionaryId}) is not supported',
      );
    }

    // Use the smaller of maxSize and remaining capacity
    final limit = (maxSize != null && remaining != null)
        ? (maxSize! < remaining ? maxSize! : remaining)
        : (maxSize ?? remaining);

    // Validate declared content size against limit early
    if (limit != null &&
        header.contentSize != null &&
        header.contentSize! > limit) {
      throw ZstdFormatException(
        'Declared content size ${header.contentSize} exceeds '
        'maximum allowed size $limit',
      );
    }

    // Cap initial allocation to prevent OOM from malicious headers:
    // - Use contentSize if known, otherwise 64KB default
    // - Never allocate more than 10x input size initially (min 64KB)
    // - Never exceed limit
    final inputRemaining = data.length - offset;
    final maxInitial = (inputRemaining * 10).clamp(64 * 1024, 1 << 30);
    var capacity = header.contentSize ?? 64 * 1024;
    if (capacity > maxInitial) {
      capacity = maxInitial;
    }
    if (limit != null && capacity > limit) {
      capacity = limit;
    }
    // Ensure minimum reasonable capacity
    if (capacity < 1024) {
      capacity = 1024;
    }

    final output = GrowableBuffer(capacity, limit);
    final offsets = [1, 4, 8];
    final blockDecoder = CompressedBlockDecoder()..reset();

    var lastBlock = false;
    while (!lastBlock) {
      if (offset + 3 > data.length) {
        final noBlockData = offset == data.length && output.length == 0;
        if (noBlockData) {
          lastBlock = true;
          break;
        }
        throw ZstdFormatException(
          'Unexpected end of frame while reading block header',
        );
      }

      final blockHeader = ZstdBlockHeader.parse(data, offset);
      offset += 3;

      // Validate block size against spec limit (128KB max)
      if (blockHeader.blockSize > zstdMaxBlockSize) {
        throw ZstdFormatException(
          'Block size ${blockHeader.blockSize} exceeds maximum '
          '$zstdMaxBlockSize bytes',
        );
      }

      lastBlock = blockHeader.lastBlock;

      switch (blockHeader.blockType) {
        case ZstdBlockType.raw:
          // For raw blocks, block size equals output size
          if (limit != null && blockHeader.blockSize > limit - output.length) {
            throw ZstdFormatException(
              'Raw block size ${blockHeader.blockSize} exceeds remaining '
              'capacity ${limit - output.length} bytes',
            );
          }
          offset = _decodeRawBlock(
            data,
            offset,
            blockHeader.blockSize,
            output,
          );
          break;
        case ZstdBlockType.rle:
          // For RLE blocks, block size equals output size
          if (limit != null && blockHeader.blockSize > limit - output.length) {
            throw ZstdFormatException(
              'RLE block size ${blockHeader.blockSize} exceeds remaining '
              'capacity ${limit - output.length} bytes',
            );
          }
          offset = _decodeRleBlock(
            data,
            offset,
            blockHeader.blockSize,
            output,
          );
          break;
        case ZstdBlockType.compressed:
          blockDecoder.decodeBlock(
            data,
            offset,
            blockHeader.blockSize,
            output,
            offsets,
            windowSize: header.windowSize,
          );
          offset += blockHeader.blockSize;
          break;
        case ZstdBlockType.reserved:
          throw ZstdFormatException('Reserved block type encountered');
      }
    }

    final frameBytes = output.toBytes();

    if (header.descriptor.checksumFlag) {
      if (offset + 4 > data.length) {
        throw ZstdFormatException('Missing content checksum');
      }
      final expectedChecksum = ByteUtils.readUint32LE(data, offset);
      offset += 4;
      final actualChecksum = XXH64.hashLow32(frameBytes);
      if (actualChecksum != expectedChecksum) {
        throw ZstdFormatException(
          'Content checksum mismatch: '
          'expected=0x${expectedChecksum.toRadixString(16)}, '
          'actual=0x${actualChecksum.toRadixString(16)}',
        );
      }
    }

    if (header.contentSize != null && frameBytes.length != header.contentSize) {
      throw ZstdFormatException(
        'Content size mismatch: expected ${header.contentSize}, got ${frameBytes.length}',
      );
    }

    return (offset, frameBytes);
  }

  /// Parse frame header and return (new offset, header)
  (int, ZstdFrameHeader) _parseFrameHeader(
    final Uint8List data,
    final int offset,
  ) {
    var pos = offset;

    if (pos >= data.length) {
      throw ZstdFormatException('Incomplete frame header');
    }

    // Parse frame header descriptor
    final descriptor = ZstdFrameHeaderDescriptor.parse(data[pos++]);

    // Parse window descriptor
    int? windowSize;
    if (!descriptor.singleSegment) {
      if (pos >= data.length) {
        throw ZstdFormatException('Missing window descriptor');
      }
      final windowByte = data[pos++];
      final exponent = windowByte >> 3;
      final mantissa = windowByte & 0x07;
      final base = 1 << (10 + exponent);
      windowSize = base + (base ~/ 8) * mantissa;
    }

    // Parse dictionary ID
    int? dictionaryId;
    if (descriptor.dictionaryIdFlag > 0) {
      final dictIdSize = 1 << (descriptor.dictionaryIdFlag - 1);
      if (pos + dictIdSize > data.length) {
        throw ZstdFormatException('Missing dictionary ID');
      }
      var dictId = 0;
      for (var i = 0; i < dictIdSize; i++) {
        dictId |= data[pos++] << (i * 8);
      }
      dictionaryId = dictId;
    }

    // Parse frame content size per RFC 8878
    // FCS_Field_Size depends on Frame_Content_Size_flag:
    //   0: 1 byte if Single_Segment_Flag, else 0 bytes
    //   1: 2 bytes (values 256-65791, with 256 offset)
    //   2: 4 bytes
    //   3: 8 bytes
    int? contentSize;
    if (descriptor.singleSegment || descriptor.contentSizeFlag > 0) {
      final sizeBytes = descriptor.singleSegment
          ? [1, 2, 4, 8][descriptor.contentSizeFlag]
          : [0, 2, 4, 8][descriptor.contentSizeFlag];

      if (sizeBytes > 0) {
        if (pos + sizeBytes > data.length) {
          throw ZstdFormatException('Missing frame content size');
        }
        var size = 0;
        for (var i = 0; i < sizeBytes; i++) {
          size |= data[pos++] << (i * 8);
        }
        // Apply 256 offset for FCS flag 1 (2-byte encoding)
        // This encoding covers values 256-65791
        if (descriptor.contentSizeFlag == 1) {
          size += 256;
        }
        contentSize = size;
      }
    }

    return (
      pos,
      ZstdFrameHeader(
        descriptor: descriptor,
        windowSize: windowSize,
        dictionaryId: dictionaryId,
        contentSize: contentSize,
      ),
    );
  }

  /// Decode raw (uncompressed) block
  int _decodeRawBlock(
    final Uint8List data,
    final int offset,
    final int size,
    final GrowableBuffer output,
  ) {
    if (offset + size > data.length) {
      throw ZstdFormatException('Raw block extends beyond input');
    }

    output.addBytes(data, offset, size);
    return offset + size;
  }

  /// Decode RLE (run-length encoded) block
  int _decodeRleBlock(
    final Uint8List data,
    final int offset,
    final int size,
    final GrowableBuffer output,
  ) {
    if (offset >= data.length) {
      throw ZstdFormatException('RLE block missing byte value');
    }

    final byte = data[offset];
    for (var i = 0; i < size; i++) {
      output.addByte(byte);
    }

    return offset + 1;
  }
}
