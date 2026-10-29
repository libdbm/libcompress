import 'dart:math' as math;
import 'dart:typed_data';

import '../exceptions.dart';
import '../util/byte_pending.dart';
import '../util/byte_sink.dart';
import '../util/byte_utils.dart';
import '../util/incremental_decoder.dart';
import '../util/output_limit.dart';
import '../util/window_buffer.dart';
import '../util/xxh32.dart';
import 'lz4_common.dart';
import '../compression_options.dart';

class Lz4Decoder {
  /// Maximum allowed decompressed size (prevents OOM attacks)
  /// Set to null for unlimited (not recommended for untrusted input)
  final int? maxSize;

  /// Creates a decoder with optional size limit
  ///
  /// [maxSize] defaults to [defaultMaxSize] (256MB).
  /// Set to null to allow unlimited output (use with trusted input only).
  Lz4Decoder({this.maxSize = defaultMaxSize});

  Uint8List decompress(final Uint8List input) => guardFormat(
    () => _decompress(input),
    Lz4FormatException.new,
    limit: maxSize,
  );

  /// Decompresses a single raw LZ4 block (no frame header, block-size prefix,
  /// end mark, or checksum) — the bare LZ77 token stream produced by
  /// [Lz4Encoder.compressBlock] and by containers such as Parquet `LZ4_RAW`.
  /// The whole [input] is treated as one block and decoded until consumed.
  /// Output is bounded by [maxSize]. When the decoded [size] is known, the
  /// block is decoded straight into a buffer of exactly that size.
  Uint8List decompressBlock(final Uint8List input, {final int? size}) =>
      guardFormat(
        () => size == null
            ? _decompressBlock(input, maxSize)
            : _decompressExact(input, size),
        Lz4FormatException.new,
        limit: maxSize,
      );

  /// Decodes one raw block into exactly [size] bytes: no growable buffer and
  /// no per-byte dispatch, one bounds check per literal run and per match.
  /// Accepts and rejects exactly the blocks [_decompressBlock] does, given
  /// the same expected length.
  Uint8List _decompressExact(final Uint8List input, final int size) {
    final limit = maxSize;
    if (limit != null && size > limit) throw LimitException(limit);
    if (input.isEmpty) {
      throw Lz4FormatException('Empty LZ4 block');
    }
    final out = Uint8List(size);
    final end = input.length;
    var ip = 0;
    var op = 0;
    while (ip < end) {
      final token = input[ip++];

      var literals = token >> 4;
      if (literals == 15) {
        int value;
        do {
          if (ip >= end) {
            throw Lz4FormatException(
              'Unexpected end while reading literal length extension',
            );
          }
          value = input[ip++];
          literals += value;
        } while (value == 255);
      }
      if (literals > 0) {
        if (ip + literals > end) {
          throw Lz4FormatException('Literal length exceeds block size');
        }
        if (op + literals > size) throw LimitException(size);
        if (literals <= 16) {
          for (var i = 0; i < literals; i++) {
            out[op + i] = input[ip + i];
          }
        } else {
          out.setRange(op, op + literals, input, ip);
        }
        ip += literals;
        op += literals;
      }
      if (ip >= end) break;

      if (ip + 1 >= end) {
        throw Lz4FormatException('Truncated offset in block');
      }
      final offset = input[ip] | (input[ip + 1] << 8);
      ip += 2;
      if (offset == 0) {
        throw Lz4FormatException(
          'Invalid match offset: 0 (offset must be at least 1)',
        );
      }
      if (offset > op) {
        throw Lz4FormatException(
          'Invalid match offset: $offset exceeds output length $op',
        );
      }

      var length = token & 0x0F;
      if (length == 15) {
        int value;
        do {
          if (ip >= end) {
            throw Lz4FormatException(
              'Unexpected end while reading match length extension',
            );
          }
          value = input[ip++];
          length += value;
        } while (value == 255);
      }
      length += lz4MinMatch;
      if (op + length > size) throw LimitException(size);

      final from = op - offset;
      if (offset == 1) {
        out.fillRange(op, op + length, out[from]);
      } else if (offset >= length) {
        // Source and destination do not overlap.
        if (length <= 16) {
          for (var i = 0; i < length; i++) {
            out[op + i] = out[from + i];
          }
        } else {
          out.setRange(op, op + length, out, from);
        }
      } else {
        // Overlapping: each byte may read one written earlier in this copy.
        for (var i = 0; i < length; i++) {
          out[op + i] = out[from + i];
        }
      }
      op += length;
    }
    if (op != size) {
      throw Lz4FormatException('Decompressed size $op != expected size $size');
    }
    return out;
  }

  /// Decompresses Hadoop block framing: outer blocks of a big-endian u32
  /// uncompressed length, each followed by one or more inner chunks of a
  /// big-endian u32 compressed length and a raw block. Each chunk decodes on
  /// its own, so matches cannot reach into an earlier chunk. Output is bounded
  /// by [maxSize].
  Uint8List decompressHadoop(final Uint8List input) => guardFormat(
    () => _decompressHadoop(input),
    Lz4FormatException.new,
    limit: maxSize,
  );

  Uint8List _decompressHadoop(final Uint8List input) {
    if (input.isEmpty) {
      throw Lz4FormatException('Empty LZ4 input');
    }
    final view = ByteData.sublistView(input);
    final output = BytesBuilder(copy: false);
    var position = 0;
    int u32() {
      if (input.length - position < 4) {
        throw Lz4FormatException('Truncated Hadoop LZ4 length');
      }
      final value = view.getUint32(position);
      position += 4;
      return value;
    }

    while (position < input.length) {
      final total = u32();
      final limit = maxSize;
      if (limit != null && output.length + total > limit) {
        throw LimitException(limit);
      }
      // At least one chunk per block: Arrow writes one even for empty data.
      var produced = 0;
      do {
        final length = u32();
        if (length > input.length - position) {
          throw Lz4FormatException('Hadoop LZ4 chunk extends past the input');
        }
        // The block total was checked against maxSize above, so a chunk that
        // runs past it is a framing error, not a limit breach.
        final Uint8List chunk;
        try {
          chunk = _decompressBlock(
            Uint8List.sublistView(input, position, position + length),
            total - produced,
          );
        } on OutputLimitException {
          throw Lz4FormatException('Hadoop LZ4 chunk decodes past its block');
        }
        position += length;
        produced += chunk.length;
        output.add(chunk);
      } while (produced < total);
    }
    return output.takeBytes();
  }

  Uint8List _decompressBlock(final Uint8List input, final int? cap) {
    if (input.isEmpty) {
      throw Lz4FormatException('Empty LZ4 block');
    }
    var initial = input.length * 3 + 64; // rough guess; grows as needed.
    if (cap != null && initial > cap) initial = cap;
    final output = GrowableBuffer(initial, cap);
    _BlockDecoder(output)
      ..reset(input)
      ..decode();
    return output.toBytes();
  }

  Uint8List _decompress(final Uint8List input) {
    if (input.isEmpty) {
      throw Lz4FormatException('Empty LZ4 input');
    }

    final reader = _FrameReader(input);

    // Decode each concatenated frame into one output, enforcing maxSize
    // cumulatively across frames (matching the GZIP/Zstd block decoders and the
    // LZ4 streaming decoder, which all accept concatenated members/frames).
    final frames = BytesBuilder(copy: false);
    var total = 0;
    while (!reader.isAtEnd) {
      final remaining = maxSize != null ? maxSize! - total : null;
      final frame = _decodeFrame(reader, remaining);
      frames.add(frame);
      total += frame.length;
    }
    return frames.takeBytes();
  }

  /// Decodes a single LZ4 frame at the reader's current position, bounding its
  /// output to [remaining] (null = unlimited), and advances the reader past the
  /// frame (end mark + optional content checksum).
  Uint8List _decodeFrame(final _FrameReader reader, final int? remaining) {
    final header = reader.header();
    final skip = header.skip;
    if (skip != null) {
      reader.readBytes(skip);
      return Uint8List(0);
    }
    final blockChecksumFlag = header.blockChecksum;
    final contentChecksumFlag = header.contentChecksum;
    final blockMaxSize = header.blockSize;
    // One output buffer serves both: linked blocks match into earlier blocks
    // (offsets are <= 64 KB); independent ones are bounded to their own.
    final expectedContentSize = header.contentSize;
    // Validate declared content size against the remaining limit early
    if (remaining != null &&
        expectedContentSize != null &&
        expectedContentSize > remaining) {
      throw LimitException(remaining);
    }

    // Without a content size, start at a few times the input left (at least
    // 1 KB, at most one block) and let the buffer double: allocating the
    // Block Maximum Size (4 MB by default) dominated decoding small frames.
    var initialCapacity = expectedContentSize != null
        ? math.max(256, math.min(expectedContentSize, blockMaxSize * 2))
        : math.min(blockMaxSize, math.max(1024, reader.remaining * 4));
    if (remaining != null && initialCapacity > remaining) {
      initialCapacity = remaining;
    }
    final output = GrowableBuffer(initialCapacity, remaining);
    final blockDecoder = _BlockDecoder(output);

    while (true) {
      final blockSizeField = reader.readUint32();
      if (blockSizeField == 0) {
        break;
      }

      final isCompressed = (blockSizeField & 0x80000000) == 0;
      final blockSize = blockSizeField & 0x7FFFFFFF;

      if (blockSize > blockMaxSize) {
        throw Lz4FormatException(
          'Block size $blockSize exceeds maximum $blockMaxSize',
        );
      }

      final blockBytes = reader.readBytes(blockSize);

      if (blockChecksumFlag) {
        final expectedBlockChecksum = reader.readUint32();
        final actualBlockChecksum = XXH32.hash(blockBytes);
        if (expectedBlockChecksum != actualBlockChecksum) {
          throw Lz4FormatException('Block checksum mismatch');
        }
      }

      if (!isCompressed) {
        output.addBytes(blockBytes, 0, blockBytes.length);
      } else {
        blockDecoder.reset(blockBytes);
        blockDecoder.decode(blockMaxSize, header.independent);
      }
    }

    final decompressed = output.toBytes();

    if (contentChecksumFlag) {
      final expectedContentChecksum = reader.readUint32();
      final actualContentChecksum = lz4ContentChecksum(decompressed);
      if (expectedContentChecksum != actualContentChecksum) {
        throw Lz4FormatException('Content checksum mismatch');
      }
    }

    if (expectedContentSize != null &&
        decompressed.length != expectedContentSize) {
      throw Lz4FormatException(
        'Decompressed size ${decompressed.length} != expected $expectedContentSize',
      );
    }

    return decompressed;
  }
}

/// Incremental, memory-bounded LZ4 frame decoder.
///
/// Emits one block at a time, keeping a 64 KB window so linked blocks
/// resolve, so peak memory is roughly one block plus its decoded output rather
/// than the whole frame and its whole output. Verifies the header checksum, optional
/// per-block checksums, and the optional content checksum (streamed via
/// [Xxh32Sink]). Supports concatenated frames, matching the streaming codec.
class Lz4IncrementalDecoder implements IncrementalDecoder {
  Lz4IncrementalDecoder({
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

  // Cumulative output limit across all concatenated frames.
  late final OutputLimit _limit = OutputLimit(maxSize);

  final BytePending _pending = BytePending();

  bool _inFrame = false;
  bool _blockChecksum = false;
  bool _independent = false;
  bool _contentChecksumFlag = false;
  int _blockMaxSize = 0;
  int? _expectedContentSize;
  Xxh32Sink? _contentSink;
  // One 64 KB window per frame (LZ4 match offsets are <= 64 KB), shared across
  // blocks so linked (dependent) blocks resolve and independent blocks also
  // decode correctly. Drained as it advances.
  WindowBuffer? _output;
  _BlockDecoder? _blockDecoder;
  bool _sawEndMark = false;

  // Bytes of a skippable frame still to discard; they are never buffered.
  int _skipping = 0;

  // True until a non-empty chunk arrives: empty input is an error.
  bool _empty = true;

  @override
  void add(final Uint8List input, final void Function(Uint8List) emit) {
    if (input.isNotEmpty) _empty = false;
    _pending.append(input, maxBufferSize);
    guardFormat(() => _drive(emit), Lz4FormatException.new, limit: maxSize);
  }

  @override
  void close(final void Function(Uint8List) emit) {
    guardFormat(() => _drive(emit), Lz4FormatException.new, limit: maxSize);
    if (_empty) {
      throw Lz4FormatException('Empty LZ4 stream');
    }
    if (_inFrame || _skipping > 0 || _pending.available != 0) {
      throw Lz4FormatException('Incomplete LZ4 frame at end of stream');
    }
  }

  void _drive(final void Function(Uint8List) emit) {
    var progressed = true;
    while (progressed) {
      if (_skipping > 0) {
        progressed = _skip();
      } else if (!_inFrame) {
        progressed = _pending.available > 0 && _parseHeader();
      } else if (_sawEndMark) {
        progressed = _finishFrame(emit);
      } else {
        progressed = _decodeBlock(emit);
      }
    }
    _pending.compact();
  }

  bool _skip() {
    final count = _pending.available < _skipping
        ? _pending.available
        : _skipping;
    if (count == 0) return false;
    _pending.cursor += count;
    _skipping -= count;
    return true;
  }

  bool _parseHeader() {
    final header = lz4Header(_pending.bytes, _pending.cursor, _pending.length);
    if (header == null) return false;
    _pending.cursor += header.length;
    final skip = header.skip;
    if (skip != null) {
      _skipping = skip;
      return true;
    }
    final size = header.contentSize;
    final budget = _limit.remaining;
    if (size != null && budget != null && size > budget) {
      throw LimitException(budget);
    }

    _inFrame = true;
    _sawEndMark = false;
    _blockChecksum = header.blockChecksum;
    _independent = header.independent;
    _contentChecksumFlag = header.contentChecksum;
    _blockMaxSize = header.blockSize;
    _expectedContentSize = size;
    _contentSink = _contentChecksumFlag ? Xxh32Sink() : null;
    // 64 KB LZ4 window, capped at the remaining cumulative budget so a single
    // block can't balloon memory before the post-decode check, and so many
    // frames can't collectively exceed maxSize.
    _output = WindowBuffer(1 << 16, maxSize: _limit.remaining);
    _hold = verified ? BytesBuilder(copy: false) : null;
    _blockDecoder = _BlockDecoder(_output!);
    return true;
  }

  bool _decodeBlock(final void Function(Uint8List) emit) {
    if (_pending.available < 4) return false;
    final sizeField = _pending.u32(_pending.cursor);
    if (sizeField == 0) {
      _pending.cursor += 4;
      _sawEndMark = true;
      return true;
    }
    final isCompressed = (sizeField & 0x80000000) == 0;
    final blockSize = sizeField & 0x7FFFFFFF;
    if (blockSize > _blockMaxSize) {
      throw Lz4FormatException(
        'Block size $blockSize exceeds maximum $_blockMaxSize',
      );
    }
    final trailer = _blockChecksum ? 4 : 0;
    if (_pending.available < 4 + blockSize + trailer) return false;

    final start = _pending.cursor + 4;
    final blockBytes = _pending.slice(start, start + blockSize);
    var p = start + blockSize;
    if (_blockChecksum) {
      if (_pending.u32(p) != XXH32.hash(blockBytes)) {
        throw Lz4FormatException('Block checksum mismatch');
      }
      p += 4;
    }

    final output = _output!;
    // The window's maxSize (the remaining cumulative budget) enforces the limit
    // *during* expansion below, before a whole block can balloon memory.
    if (isCompressed) {
      _blockDecoder!
        ..reset(blockBytes)
        ..decode(_blockMaxSize, _independent);
    } else {
      output.addBytes(blockBytes, 0, blockBytes.length);
    }
    _pending.cursor = p;
    _flush(output.drain(), emit);
    return true;
  }

  bool _finishFrame(final void Function(Uint8List) emit) {
    final output = _output!;
    _flush(output.finish(), emit);

    if (_contentChecksumFlag) {
      if (_pending.available < 4) return false;
      if (_pending.u32(_pending.cursor) != _contentSink!.digest()) {
        throw Lz4FormatException('Content checksum mismatch');
      }
      _pending.cursor += 4;
    }
    if (_expectedContentSize != null && output.length != _expectedContentSize) {
      throw Lz4FormatException(
        'Decompressed size ${output.length} != expected $_expectedContentSize',
      );
    }
    // Frame validated — in verified mode, release the held output now.
    final hold = _hold;
    if (hold != null) {
      if (hold.isNotEmpty) emit(hold.takeBytes());
      _hold = null;
    }
    _inFrame = false;
    _sawEndMark = false;
    _contentSink = null;
    _output = null;
    _blockDecoder = null;
    return true;
  }

  void _flush(final Uint8List bytes, final void Function(Uint8List) emit) {
    if (bytes.isEmpty) return;
    _contentSink?.add(bytes);
    _limit.record(bytes.length);
    final hold = _hold;
    if (hold != null) {
      hold.add(bytes); // verified mode: release only after the frame validates
    } else {
      emit(bytes);
    }
  }
}

class _FrameReader {
  _FrameReader(final Uint8List data) : _data = data;

  final Uint8List _data;
  int _offset = 0;

  Uint8List readBytes(final int length) {
    if (_offset + length > _data.length) {
      throw Lz4FormatException('Unexpected end of input');
    }
    final bytes = Uint8List.sublistView(_data, _offset, _offset + length);
    _offset += length;
    return bytes;
  }

  int readUint32() {
    final bytes = readBytes(4);
    return ByteUtils.readUint32LE(bytes, 0);
  }

  bool get isAtEnd => _offset == _data.length;

  /// Bytes left to read.
  int get remaining => _data.length - _offset;

  /// Reads a frame header, throwing if the input ends inside it.
  Lz4Header header() {
    final header = lz4Header(_data, _offset, _data.length);
    if (header == null) {
      throw Lz4FormatException('Unexpected end of input');
    }
    _offset += header.length;
    return header;
  }
}

class _BlockDecoder {
  _BlockDecoder(this._output);

  final ByteSink _output;
  late Uint8List _block;

  void reset(final Uint8List block) {
    _block = block;
  }

  /// Decodes the block. [capacity], when given, is the Block Maximum Size of
  /// the enclosing frame: decoding stops with an error before the block's
  /// output would exceed it. When [independent], matches may not reach back
  /// before the block's own output.
  void decode([final int? capacity, final bool independent = false]) {
    var index = 0;
    final limit = _block.length;
    final end = capacity == null ? null : _output.length + capacity;
    final floor = independent ? _output.length : 0;

    while (index < limit) {
      final token = _block[index++];

      // Literal length.
      var literalLength = token >> 4;
      if (literalLength == 15) {
        var complete = false;
        while (index < limit) {
          final value = _block[index++];
          literalLength += value;
          if (value != 255) {
            complete = true;
            break;
          }
        }
        if (!complete) {
          throw Lz4FormatException(
            'Unexpected end while reading literal length extension',
          );
        }
      }

      if (literalLength > 0) {
        if (index + literalLength > limit) {
          throw Lz4FormatException('Literal length exceeds block size');
        }
        _checkCapacity(end, literalLength, capacity);
        _output.addBytes(_block, index, literalLength);
        index += literalLength;
      }

      if (index >= limit) {
        break;
      }

      if (index + 1 >= limit) {
        throw Lz4FormatException('Truncated offset in block');
      }
      final offset = ByteUtils.readUint16LE(_block, index);
      index += 2;

      // Per LZ4 spec: offset 0 is invalid and must be rejected to prevent
      // information disclosure (reading uninitialized buffer content)
      if (offset == 0) {
        throw Lz4FormatException(
          'Invalid match offset: 0 (offset must be at least 1)',
        );
      }
      if (offset > _output.length - floor) {
        throw Lz4FormatException(
          'Invalid match offset: $offset exceeds output length '
          '${_output.length - floor}',
        );
      }

      var matchLength = token & 0x0F;
      if (matchLength == 15) {
        var complete = false;
        while (index < limit) {
          final value = _block[index++];
          matchLength += value;
          if (value != 255) {
            complete = true;
            break;
          }
        }
        if (!complete) {
          throw Lz4FormatException(
            'Unexpected end while reading match length extension',
          );
        }
      }
      matchLength += lz4MinMatch;

      _checkCapacity(end, matchLength, capacity);
      _output.copyFromHistory(offset, matchLength);
    }

    if (index != limit) {
      throw Lz4FormatException('Block was not fully decoded');
    }
  }

  void _checkCapacity(final int? end, final int count, final int? capacity) {
    if (end != null && _output.length + count > end) {
      throw Lz4FormatException(
        'Block decodes past the maximum block size $capacity',
      );
    }
  }
}
