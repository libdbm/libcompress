import 'dart:typed_data';
import '../exceptions.dart';
import '../util/byte_pending.dart';
import '../util/growable_buffer.dart';
import '../util/incremental_decoder.dart';
import '../util/window_buffer.dart';
import '../util/xxh64.dart';
import '../util/byte_utils.dart';
import 'zstd_common.dart';
import 'compressed_block_decoder.dart';
import '../compression_options.dart';

/// Window_Size from a Window_Descriptor byte (RFC 8878 §3.1.1.1.2). The base
/// is built by doubling, not `1 << (10 + exponent)`: windows reach 2^41, and
/// dart2js shifts are 32-bit.
int _windowSize(final int descriptor) {
  var base = 1 << 10;
  for (var exponent = descriptor >> 3; exponent > 0; exponent--) {
    base *= 2;
  }
  return base + (base ~/ 8) * (descriptor & 0x07);
}

int _maximumBlockSize(final int? window) =>
    window != null && window < zstdMaxBlockSize ? window : zstdMaxBlockSize;

/// The header of a frame, or of a skippable frame ([skip] not null).
class _Start {
  _Start(this.length, {this.skip, this.frame});

  /// Header bytes, from the magic number to the end of the frame header.
  final int length;

  /// For a skippable frame, the bytes that follow the header.
  final int? skip;

  final ZstdFrameHeader? frame;
}

/// Parses the frame header at `data[offset..end)` for the one-shot and
/// incremental decoders. Returns null when more bytes are needed, and throws
/// once the bytes present are invalid.
_Start? _start(final Uint8List data, final int offset, final int end) {
  final available = end - offset;
  if (available < 4) return null;
  final magic = ByteUtils.readUint32LE(data, offset);
  if ((magic & zstdSkippableFrameMagicMask) == zstdSkippableFrameMagicBase) {
    if (available < 8) return null;
    return _Start(8, skip: ByteUtils.readUint32LE(data, offset + 4));
  }
  if (magic != zstdMagicNumber) {
    throw ZstdFormatException(
      'Invalid Zstd magic number: 0x${magic.toRadixString(16)}',
    );
  }
  if (available < 5) return null;
  final descriptor = ZstdFrameHeaderDescriptor.parse(data[offset + 4]);
  final dictionaryBytes = descriptor.dictionaryIdFlag > 0
      ? 1 << (descriptor.dictionaryIdFlag - 1)
      : 0;
  // Frame_Content_Size bytes per RFC 8878: flag 0 is 1 byte when single
  // segment, else absent; flag 1 is 2 bytes holding size - 256.
  final sizeBytes = descriptor.singleSegment
      ? const [1, 2, 4, 8][descriptor.contentSizeFlag]
      : const [0, 2, 4, 8][descriptor.contentSizeFlag];
  final length =
      5 + (descriptor.singleSegment ? 0 : 1) + dictionaryBytes + sizeBytes;
  if (available < length) return null;

  var position = offset + 5;
  int? windowSize;
  if (!descriptor.singleSegment) {
    windowSize = _windowSize(data[position++]);
  }
  if (dictionaryBytes > 0) {
    final dictionary = ByteUtils.readUintLE(data, position, dictionaryBytes);
    position += dictionaryBytes;
    if (dictionary != 0) {
      throw ZstdFormatException(
        'Dictionary compression (id=$dictionary) is not supported',
      );
    }
  }
  int? contentSize;
  if (sizeBytes > 0) {
    contentSize = ByteUtils.readUintLE(data, position, sizeBytes);
    if (descriptor.contentSizeFlag == 1) contentSize += 256;
  }
  return _Start(
    length,
    frame: ZstdFrameHeader(
      descriptor: descriptor,
      windowSize: windowSize,
      contentSize: contentSize,
    ),
  );
}

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
  /// [maxSize] defaults to [defaultMaxSize] (256MB).
  /// Set to null to allow unlimited output (use with trusted input only).
  ZstdDecoder({this.maxSize = defaultMaxSize});

  Uint8List decompress(final Uint8List data) => guardFormat(
    () => _decompress(data),
    ZstdFormatException.new,
    limit: maxSize,
  );

  Uint8List _decompress(final Uint8List data) {
    if (data.isEmpty) {
      throw ZstdFormatException('Input too short for Zstd frame');
    }

    // Track total decompressed output across all frames
    var total = 0;
    final limit = maxSize;

    // Each frame's output; a single frame is returned without a merge copy.
    final outputs = <Uint8List>[];
    var offset = 0;
    var skippableFrames = 0;

    while (offset < data.length) {
      final start = _start(data, offset, data.length);
      if (start == null) {
        throw ZstdFormatException('Incomplete frame header');
      }
      offset += start.length;
      final skip = start.skip;
      if (skip != null) {
        if (offset + skip > data.length) {
          throw ZstdFormatException('Skippable frame exceeds input bounds');
        }
        offset += skip;
        skippableFrames++;
        continue;
      }

      // Calculate remaining capacity for this frame
      final remaining = limit != null ? limit - total : null;
      final result = _decompressFrame(data, offset, start.frame!, remaining);
      offset = result.$1;
      final frameBytes = result.$2;

      // Check cumulative limit before adding
      if (limit != null && total + frameBytes.length > limit) {
        throw LimitException(limit);
      }

      outputs.add(frameBytes);
      total += frameBytes.length;
    }

    // Valid input must have at least one frame (data or skippable)
    if (outputs.isEmpty && skippableFrames == 0) {
      throw ZstdFormatException('No Zstd frame found in input');
    }

    if (outputs.length == 1) return outputs.first;
    final merged = Uint8List(total);
    var position = 0;
    for (final output in outputs) {
      merged.setRange(position, position + output.length, output);
      position += output.length;
    }
    return merged;
  }

  /// Decompress a single frame. [remaining] is the remaining capacity
  /// for the cumulative output across all frames (null = unlimited).
  (int, Uint8List) _decompressFrame(
    final Uint8List data,
    int offset,
    final ZstdFrameHeader header,
    final int? remaining,
  ) {
    // The frame's share of maxSize (never more than maxSize itself).
    final limit = remaining;

    // Validate declared content size against limit early
    if (limit != null &&
        header.contentSize != null &&
        header.contentSize! > limit) {
      throw LimitException(limit);
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
    final frameWindow = header.windowSize ?? header.contentSize;
    final maxBlockSize = _maximumBlockSize(frameWindow);
    final offsets = [1, 4, 8];
    final blockDecoder = CompressedBlockDecoder()..reset();

    var lastBlock = false;
    while (!lastBlock) {
      // A well-formed frame always has at least one block (an empty frame is a
      // single raw last-block of size 0), so a frame body that ends before a
      // block header is malformed — matching the streaming decoder, which
      // requires a real last block.
      if (offset + 3 > data.length) {
        throw ZstdFormatException(
          'Unexpected end of frame while reading block header',
        );
      }

      final blockHeader = ZstdBlockHeader.parse(data, offset);
      offset += 3;

      // Both compressed and regenerated block sizes are bounded by the
      // smaller of the declared frame window and 128 KiB.
      if (blockHeader.blockSize > maxBlockSize) {
        throw ZstdFormatException(
          'Block size ${blockHeader.blockSize} exceeds maximum '
          '$maxBlockSize bytes',
        );
      }

      lastBlock = blockHeader.lastBlock;

      switch (blockHeader.blockType) {
        case ZstdBlockType.raw:
          // For raw blocks, block size equals output size
          if (limit != null && blockHeader.blockSize > limit - output.length) {
            throw LimitException(limit);
          }
          offset = _decodeRawBlock(data, offset, blockHeader.blockSize, output);
          break;
        case ZstdBlockType.rle:
          // For RLE blocks, block size equals output size
          if (limit != null && blockHeader.blockSize > limit - output.length) {
            throw LimitException(limit);
          }
          offset = _decodeRleBlock(data, offset, blockHeader.blockSize, output);
          break;
        case ZstdBlockType.compressed:
          blockDecoder.decodeBlock(
            data,
            offset,
            blockHeader.blockSize,
            BlockOutput(output, maxBlockSize),
            offsets,
            windowSize: frameWindow,
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

    output.addBytes(Uint8List(size)..fillRange(0, size, data[offset]));

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
  int _frameBlockMaxSize = zstdMaxBlockSize;

  // True until a non-empty chunk arrives: empty input is an error.
  bool _empty = true;

  @override
  void add(final Uint8List input, final void Function(Uint8List) emit) {
    if (input.isNotEmpty) _empty = false;
    _pending.append(input, maxBufferSize);
    guardFormat(() => _drive(emit), ZstdFormatException.new, limit: maxSize);
  }

  // Bytes of a skippable frame still to discard; they are never buffered.
  int _skipping = 0;

  @override
  void close(final void Function(Uint8List) emit) {
    guardFormat(() => _drive(emit), ZstdFormatException.new, limit: maxSize);
    if (_empty) {
      throw ZstdFormatException('Empty Zstd stream');
    }
    if (_inFrame || _skipping > 0 || _pending.available != 0) {
      throw ZstdFormatException('Incomplete Zstd frame at end of stream');
    }
  }

  void _drive(final void Function(Uint8List) emit) {
    var progressed = true;
    while (progressed) {
      if (_skipping > 0) {
        final count = _pending.available < _skipping
            ? _pending.available
            : _skipping;
        _pending.cursor += count;
        _skipping -= count;
        progressed = count > 0;
      } else if (!_inFrame) {
        progressed = _pending.available > 0 && _startFrame();
      } else if (_lastBlockSeen) {
        progressed = _finishFrame(emit);
      } else {
        progressed = _decodeNextBlock(emit);
      }
    }
    _pending.compact();
  }

  /// Reads a frame magic; skips skippable frames; parses a normal frame header.
  bool _startFrame() {
    final start = _start(_pending.bytes, _pending.cursor, _pending.length);
    if (start == null) return false;
    final skip = start.skip;
    if (skip != null) {
      // Discard the payload as it arrives rather than buffering it whole.
      _pending.cursor += start.length;
      _skipping = skip;
      return true;
    }
    final header = start.frame!;
    final windowSize = header.windowSize;
    final contentSize = header.contentSize;

    final frameLimit = maxSize != null ? maxSize! - _total : null;
    if (frameLimit != null && contentSize != null && contentSize > frameLimit) {
      throw LimitException(frameLimit);
    }

    // The window bounds the largest back-reference: windowSize if present,
    // else the content size (single-segment), else the remaining limit.
    var window = windowSize ?? contentSize ?? (frameLimit ?? (1 << 27));
    if (frameLimit != null && window > frameLimit) window = frameLimit;
    if (window < 1) window = 1;

    _pending.cursor += start.length;
    _inFrame = true;
    _lastBlockSeen = false;
    _checksumFlag = header.descriptor.checksumFlag;
    _frameWindowSize = windowSize ?? contentSize;
    _frameBlockMaxSize = _maximumBlockSize(_frameWindowSize);
    _frameContentSize = contentSize;
    _offsets = [1, 4, 8];
    _output = WindowBuffer(window, maxSize: frameLimit);
    _hold = verified ? BytesBuilder(copy: false) : null;
    _sink = header.descriptor.checksumFlag ? Xxh64Sink() : null;
    _blockDecoder = CompressedBlockDecoder()..reset();
    return true;
  }

  bool _decodeNextBlock(final void Function(Uint8List) emit) {
    if (_pending.available < 3) return false;
    final header = ZstdBlockHeader.parse(
      Uint8List.fromList([
        _pending[_pending.cursor],
        _pending[_pending.cursor + 1],
        _pending[_pending.cursor + 2],
      ]),
      0,
    );
    if (header.blockSize > _frameBlockMaxSize) {
      throw ZstdFormatException(
        'Block size ${header.blockSize} exceeds maximum $_frameBlockMaxSize bytes',
      );
    }
    final content = header.blockType == ZstdBlockType.rle
        ? 1
        : header.blockSize;
    if (_pending.available < 3 + content) return false;

    final output = _output!;
    final start = _pending.cursor + 3;
    switch (header.blockType) {
      case ZstdBlockType.raw:
        output.addBytes(_pending.bytes, start, header.blockSize);
        break;
      case ZstdBlockType.rle:
        final size = header.blockSize;
        output.addBytes(Uint8List(size)..fillRange(0, size, _pending[start]));
        break;
      case ZstdBlockType.compressed:
        final block = _pending.slice(start, start + header.blockSize);
        _blockDecoder!.decodeBlock(
          block,
          0,
          header.blockSize,
          BlockOutput(output, _frameBlockMaxSize),
          _offsets,
          windowSize: _frameWindowSize,
        );
        break;
      case ZstdBlockType.reserved:
        throw ZstdFormatException('Reserved block type encountered');
    }

    _pending.cursor = start + content;
    _flush(output.drain(), emit);
    if (header.lastBlock) _lastBlockSeen = true;
    return true;
  }

  bool _finishFrame(final void Function(Uint8List) emit) {
    final output = _output!;
    _flush(output.finish(), emit);

    if (_checksumFlag) {
      if (_pending.available < 4) return false;
      final expected = _pending.u32(_pending.cursor);
      if (expected != _sink!.digestLow32()) {
        throw ZstdFormatException('Content checksum mismatch');
      }
      _pending.cursor += 4;
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
}
