import 'dart:typed_data';
import '../exceptions.dart';
import '../util/byte_pending.dart';
import '../util/growable_buffer.dart';
import '../util/incremental_decompress_transformer.dart';
import '../util/window_buffer.dart';
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

  Uint8List decompress(final Uint8List data) =>
      guardFormat(() => _decompress(data), ZstdFormatException.new);

  Uint8List _decompress(final Uint8List data) {
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
        var size = ByteUtils.readUintLE(data, pos, sizeBytes);
        pos += sizeBytes;
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

/// Incremental, memory-bounded Zstd frame decoder.
///
/// Decodes one block at a time, appending to a [WindowBuffer] sized to the
/// frame window and draining emittable bytes, so peak retained output is the
/// frame window (bounded for window-descriptor frames; equal to the content
/// size for single-segment frames, which by definition declare they fit). The
/// content checksum is streamed via [Xxh64Sink]. Supports skippable and
/// concatenated frames.
class ZstdIncrementalDecoder implements IncrementalDecoder {
  ZstdIncrementalDecoder({
    this.maxSize,
    required this.maxBufferSize,
    this.verified = false,
  });

  final int? maxSize;
  final int maxBufferSize;

  /// When true, a frame's output is withheld until its content checksum and
  /// size validate, then released (memory rises to one frame's output, bounded
  /// by [maxSize]). The default emits as it decodes.
  final bool verified;

  // Holds a frame's output in verified mode until its trailer validates.
  BytesBuilder? _hold;

  final BytePending _pending = BytePending();
  int _cursor = 0;
  int _total = 0; // decompressed bytes across completed frames

  bool _inFrame = false;
  bool _lastBlockSeen = false;
  WindowBuffer? _output;
  Xxh64Sink? _sink;
  CompressedBlockDecoder? _blockDecoder;
  List<int> _offsets = const [1, 4, 8];
  bool _checksumFlag = false;
  int? _frameWindowSize;
  int? _frameContentSize;

  int get _avail => _pending.length - _cursor;

  int _u32(final int o) =>
      _pending[o] +
      _pending[o + 1] * 0x100 +
      _pending[o + 2] * 0x10000 +
      _pending[o + 3] * 0x1000000;

  @override
  void add(final Uint8List input, final void Function(Uint8List) emit) {
    _pending.add(input);
    if (_avail > maxBufferSize) {
      throw ZstdFormatException(
        'Stream buffer exceeded $maxBufferSize bytes - '
        'frame too large or malformed',
      );
    }
    guardFormat(() => _drive(emit), ZstdFormatException.new);
  }

  @override
  void close(final void Function(Uint8List) emit) {
    guardFormat(() => _drive(emit), ZstdFormatException.new);
    if (_inFrame || _avail != 0) {
      throw ZstdFormatException('Incomplete Zstd frame at end of stream');
    }
  }

  void _drive(final void Function(Uint8List) emit) {
    var progressed = true;
    while (progressed) {
      if (!_inFrame) {
        progressed = _avail > 0 && _startFrame();
      } else if (_lastBlockSeen) {
        progressed = _finishFrame(emit);
      } else {
        progressed = _decodeNextBlock(emit);
      }
    }
    _compact();
  }

  /// Reads a frame magic; skips skippable frames; parses a normal frame header.
  bool _startFrame() {
    if (_avail < 4) return false;
    final magic = _u32(_cursor);

    if ((magic & zstdSkippableFrameMagicMask) == zstdSkippableFrameMagicBase) {
      if (_avail < 8) return false;
      final size = _u32(_cursor + 4);
      if (_avail < 8 + size) return false;
      _cursor += 8 + size;
      return true;
    }

    if (magic != zstdMagicNumber) {
      throw ZstdFormatException(
        'Invalid Zstd magic number: 0x${magic.toRadixString(16)}',
      );
    }

    if (_avail < 5) return false; // magic + descriptor
    final descriptor = ZstdFrameHeaderDescriptor.parse(_pending[_cursor + 4]);
    final windowBytes = descriptor.singleSegment ? 0 : 1;
    final dictIdBytes =
        descriptor.dictionaryIdFlag > 0 ? 1 << (descriptor.dictionaryIdFlag - 1) : 0;
    final fcsBytes = descriptor.singleSegment
        ? const [1, 2, 4, 8][descriptor.contentSizeFlag]
        : const [0, 2, 4, 8][descriptor.contentSizeFlag];
    final headerLen = 1 + windowBytes + dictIdBytes + fcsBytes;
    if (_avail < 4 + headerLen) return false;

    var p = _cursor + 5; // past magic + descriptor
    int? windowSize;
    if (!descriptor.singleSegment) {
      final windowByte = _pending[p++];
      final exponent = windowByte >> 3;
      final mantissa = windowByte & 0x07;
      final base = 1 << (10 + exponent);
      windowSize = base + (base ~/ 8) * mantissa;
    }
    if (descriptor.dictionaryIdFlag > 0) {
      var dictId = 0;
      for (var i = 0; i < dictIdBytes; i++) {
        dictId |= _pending[p++] << (i * 8);
      }
      if (dictId != 0) {
        throw ZstdFormatException(
          'Dictionary compression (id=$dictId) is not supported',
        );
      }
    }
    int? contentSize;
    if (fcsBytes > 0) {
      var size = ByteUtils.readUintLE(_pending.bytes, p, fcsBytes);
      p += fcsBytes;
      if (descriptor.contentSizeFlag == 1) size += 256;
      contentSize = size;
    }

    final frameLimit = maxSize != null ? maxSize! - _total : null;
    if (frameLimit != null && contentSize != null && contentSize > frameLimit) {
      throw ZstdFormatException(
        'Declared content size $contentSize exceeds maximum allowed size $maxSize',
      );
    }

    // The window bounds the largest back-reference: windowSize if present,
    // else the content size (single-segment), else the remaining limit.
    var window = windowSize ?? contentSize ?? (frameLimit ?? (1 << 27));
    if (frameLimit != null && window > frameLimit) window = frameLimit;
    if (window < 1) window = 1;

    _cursor += 4 + headerLen;
    _inFrame = true;
    _lastBlockSeen = false;
    _checksumFlag = descriptor.checksumFlag;
    _frameWindowSize = windowSize;
    _frameContentSize = contentSize;
    _offsets = [1, 4, 8];
    _output = WindowBuffer(window, maxSize: frameLimit);
    _hold = verified ? BytesBuilder(copy: false) : null;
    _sink = descriptor.checksumFlag ? Xxh64Sink() : null;
    _blockDecoder = CompressedBlockDecoder()..reset();
    return true;
  }

  bool _decodeNextBlock(final void Function(Uint8List) emit) {
    if (_avail < 3) return false;
    final header = ZstdBlockHeader.parse(
      Uint8List.fromList(
          [_pending[_cursor], _pending[_cursor + 1], _pending[_cursor + 2]]),
      0,
    );
    if (header.blockSize > zstdMaxBlockSize) {
      throw ZstdFormatException(
        'Block size ${header.blockSize} exceeds maximum $zstdMaxBlockSize bytes',
      );
    }
    final content = header.blockType == ZstdBlockType.rle ? 1 : header.blockSize;
    if (_avail < 3 + content) return false;

    final output = _output!;
    final start = _cursor + 3;
    switch (header.blockType) {
      case ZstdBlockType.raw:
        output.addBytes(_pending.bytes, start, header.blockSize);
        break;
      case ZstdBlockType.rle:
        final byte = _pending[start];
        for (var i = 0; i < header.blockSize; i++) {
          output.addByte(byte);
        }
        break;
      case ZstdBlockType.compressed:
        final block = _pending.slice(start, start + header.blockSize);
        _blockDecoder!.decodeBlock(
          block,
          0,
          header.blockSize,
          output,
          _offsets,
          windowSize: _frameWindowSize,
        );
        break;
      case ZstdBlockType.reserved:
        throw ZstdFormatException('Reserved block type encountered');
    }

    _cursor = start + content;
    _flush(output.drain(), emit);
    if (header.lastBlock) _lastBlockSeen = true;
    return true;
  }

  bool _finishFrame(final void Function(Uint8List) emit) {
    final output = _output!;
    _flush(output.finish(), emit);

    if (_checksumFlag) {
      if (_avail < 4) return false;
      final expected = _u32(_cursor);
      if (expected != _sink!.digestLow32()) {
        throw ZstdFormatException('Content checksum mismatch');
      }
      _cursor += 4;
    }
    if (_frameContentSize != null && output.length != _frameContentSize) {
      throw ZstdFormatException(
        'Content size mismatch: expected $_frameContentSize, got ${output.length}',
      );
    }

    // Frame validated — in verified mode, release the held output now.
    final hold = _hold;
    if (hold != null) {
      if (hold.isNotEmpty) emit(hold.takeBytes());
      _hold = null;
    }

    _total += output.length;
    _inFrame = false;
    _lastBlockSeen = false;
    _output = null;
    _sink = null;
    _blockDecoder = null;
    return true;
  }

  void _flush(final Uint8List bytes, final void Function(Uint8List) emit) {
    if (bytes.isEmpty) return;
    _sink?.add(bytes);
    final hold = _hold;
    if (hold != null) {
      hold.add(bytes); // verified mode: release only after the frame validates
    } else {
      emit(bytes);
    }
  }

  void _compact() {
    if (_cursor > 0 && (_cursor >= _pending.length || _cursor >= 8192)) {
      _pending.discard(_cursor);
      _cursor = 0;
    }
  }
}
