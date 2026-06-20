import 'dart:math' as math;
import 'dart:typed_data';

import '../util/byte_sink.dart';
import '../util/byte_utils.dart';
import '../util/incremental_decompress_transformer.dart';
import '../util/window_buffer.dart';
import '../util/xxh32.dart';
import 'lz4_common.dart';

class Lz4Decoder {
  /// Maximum allowed decompressed size (prevents OOM attacks)
  /// Set to null for unlimited (not recommended for untrusted input)
  final int? maxSize;

  /// Creates a decoder with optional size limit
  ///
  /// [maxSize] defaults to [lz4DefaultMaxDecompressedSize] (256MB).
  /// Set to null to allow unlimited output (use with trusted input only).
  Lz4Decoder({this.maxSize = lz4DefaultMaxDecompressedSize});

  Uint8List decompress(Uint8List input) {
    if (input.isEmpty) {
      return Uint8List(0);
    }

    final reader = _FrameReader(input);

    final magic = reader.readUint32();
    if (magic != lz4FrameMagic) {
      throw Lz4FormatException(
        'Invalid LZ4 frame magic: 0x${magic.toRadixString(16)}',
      );
    }

    final flag = reader.readByte();
    final version = flag >> 6;
    if (version != 0x01) {
      throw Lz4FormatException('Unsupported LZ4 frame version $version');
    }
    if ((flag & 0x02) != 0) {
      throw Lz4FormatException('Reserved bit set in LZ4 FLG byte');
    }

    final blockChecksumFlag = (flag & 0x10) != 0;
    final contentSizeFlag = (flag & 0x08) != 0;
    final contentChecksumFlag = (flag & 0x04) != 0;
    final dictIdFlag = (flag & 0x01) != 0;
    final bd = reader.readByte();
    final blockMaxSizeCode = (bd >> 4) & 0x07;
    final blockMaxSize = blockSizeFromCode(blockMaxSizeCode);
    // Both independent and linked (dependent) blocks decode correctly: a single
    // shared output buffer is used, and LZ4 match offsets are <= 64 KB.
    final headerBytes = <int>[flag, bd];

    int? expectedContentSize;
    if (contentSizeFlag) {
      final sizeBytes = reader.readBytes(8);
      headerBytes.addAll(sizeBytes);
      var contentSize = 0;
      for (var i = 0; i < 8; i++) {
        contentSize |= sizeBytes[i] << (8 * i);
      }
      expectedContentSize = contentSize;

      // Validate declared content size against limit early
      if (maxSize != null && contentSize > maxSize!) {
        throw Lz4FormatException(
          'Declared content size $contentSize exceeds '
          'maximum allowed size $maxSize',
        );
      }
    }

    if (dictIdFlag) {
      final dictBytes = reader.readBytes(4);
      headerBytes.addAll(dictBytes);
      final dictId = ByteUtils.readUint32LE(dictBytes, 0);
      if (dictId != 0) {
        throw Lz4FormatException('External dictionaries are not supported');
      }
    }

    final headerChecksum = reader.readByte();
    final expectedHeaderChecksum = lz4HeaderChecksum(headerBytes);
    if (headerChecksum != expectedHeaderChecksum) {
      throw Lz4FormatException('Invalid LZ4 header checksum');
    }

    var initialCapacity = expectedContentSize != null
        ? math.max(256, math.min(expectedContentSize, blockMaxSize * 2))
        : blockMaxSize;
    if (maxSize != null && initialCapacity > maxSize!) {
      initialCapacity = maxSize!;
    }
    final output = GrowableBuffer(initialCapacity, maxSize);
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
        blockDecoder.decode();
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

    if (!reader.isAtEnd) {
      throw Lz4FormatException('Trailing bytes after LZ4 frame');
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
/// Emits one block at a time (LZ4 frame blocks are independent), so peak
/// memory is roughly one block plus its decoded output rather than the whole
/// frame and its whole output. Verifies the header checksum, optional
/// per-block checksums, and the optional content checksum (streamed via
/// [Xxh32Sink]). Supports concatenated frames, matching the streaming codec.
class Lz4IncrementalDecoder implements IncrementalDecoder {
  Lz4IncrementalDecoder({this.maxSize, required this.maxBufferSize});

  final int? maxSize;
  final int maxBufferSize;

  final List<int> _pending = <int>[];
  int _cursor = 0;

  bool _inFrame = false;
  bool _blockChecksum = false;
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

  int get _avail => _pending.length - _cursor;

  int _u32(final int o) =>
      _pending[o] +
      _pending[o + 1] * 0x100 +
      _pending[o + 2] * 0x10000 +
      _pending[o + 3] * 0x1000000;

  @override
  void add(final Uint8List input, final void Function(Uint8List) emit) {
    _pending.addAll(input);
    if (_avail > maxBufferSize) {
      throw Lz4FormatException(
        'Stream buffer exceeded $maxBufferSize bytes - '
        'frame too large or malformed',
      );
    }
    _drive(emit);
  }

  @override
  void close(final void Function(Uint8List) emit) {
    _drive(emit);
    if (_inFrame || _avail != 0) {
      throw Lz4FormatException('Incomplete LZ4 frame at end of stream');
    }
  }

  void _drive(final void Function(Uint8List) emit) {
    var progressed = true;
    while (progressed) {
      if (!_inFrame) {
        progressed = _avail > 0 && _parseHeader();
      } else if (_sawEndMark) {
        progressed = _finishFrame(emit);
      } else {
        progressed = _decodeBlock(emit);
      }
    }
    _compact();
  }

  bool _parseHeader() {
    if (_avail < 6) return false;
    final base = _cursor;
    final magic = _u32(base);
    if (magic != lz4FrameMagic) {
      throw Lz4FormatException(
        'Invalid LZ4 frame magic: 0x${magic.toRadixString(16)}',
      );
    }
    final flag = _pending[base + 4];
    if (flag >> 6 != 0x01) {
      throw Lz4FormatException('Unsupported LZ4 frame version ${flag >> 6}');
    }
    if ((flag & 0x02) != 0) {
      throw Lz4FormatException('Reserved bit set in LZ4 FLG byte');
    }
    final bd = _pending[base + 5];
    final contentSizeFlag = (flag & 0x08) != 0;
    final dictIdFlag = (flag & 0x01) != 0;
    final needed = 6 + (contentSizeFlag ? 8 : 0) + (dictIdFlag ? 4 : 0) + 1;
    if (_avail < needed) return false;

    final headerBytes = <int>[flag, bd];
    var p = base + 6;
    int? expectedContentSize;
    if (contentSizeFlag) {
      var size = 0;
      for (var i = 0; i < 8; i++) {
        final b = _pending[p + i];
        headerBytes.add(b);
        size |= b << (8 * i);
      }
      p += 8;
      expectedContentSize = size;
      if (maxSize != null && size > maxSize!) {
        throw Lz4FormatException(
          'Declared content size $size exceeds maximum allowed size $maxSize',
        );
      }
    }
    if (dictIdFlag) {
      for (var i = 0; i < 4; i++) {
        headerBytes.add(_pending[p + i]);
      }
      if (_u32(p) != 0) {
        throw Lz4FormatException('External dictionaries are not supported');
      }
      p += 4;
    }
    if (_pending[p] != lz4HeaderChecksum(headerBytes)) {
      throw Lz4FormatException('Invalid LZ4 header checksum');
    }
    p += 1;

    _cursor = p;
    _inFrame = true;
    _sawEndMark = false;
    _blockChecksum = (flag & 0x10) != 0;
    _contentChecksumFlag = (flag & 0x04) != 0;
    _blockMaxSize = blockSizeFromCode((bd >> 4) & 0x07);
    _expectedContentSize = expectedContentSize;
    _contentSink = _contentChecksumFlag ? Xxh32Sink() : null;
    _output = WindowBuffer(1 << 16); // 64 KB LZ4 window
    _blockDecoder = _BlockDecoder(_output!);
    return true;
  }

  bool _decodeBlock(final void Function(Uint8List) emit) {
    if (_avail < 4) return false;
    final sizeField = _u32(_cursor);
    if (sizeField == 0) {
      _cursor += 4;
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
    if (_avail < 4 + blockSize + trailer) return false;

    final start = _cursor + 4;
    final blockBytes =
        Uint8List.fromList(_pending.sublist(start, start + blockSize));
    var p = start + blockSize;
    if (_blockChecksum) {
      if (_u32(p) != XXH32.hash(blockBytes)) {
        throw Lz4FormatException('Block checksum mismatch');
      }
      p += 4;
    }

    final output = _output!;
    if (isCompressed) {
      _blockDecoder!
        ..reset(blockBytes)
        ..decode();
    } else {
      output.addBytes(blockBytes, 0, blockBytes.length);
    }
    if (maxSize != null && output.length > maxSize!) {
      throw Lz4FormatException(
        'Decompressed size ${output.length} exceeds maximum allowed size $maxSize',
      );
    }
    _cursor = p;
    _flush(output.drain(), emit);
    return true;
  }

  bool _finishFrame(final void Function(Uint8List) emit) {
    final output = _output!;
    _flush(output.finish(), emit);

    if (_contentChecksumFlag) {
      if (_avail < 4) return false;
      if (_u32(_cursor) != _contentSink!.digest()) {
        throw Lz4FormatException('Content checksum mismatch');
      }
      _cursor += 4;
    }
    if (_expectedContentSize != null && output.length != _expectedContentSize) {
      throw Lz4FormatException(
        'Decompressed size ${output.length} != expected $_expectedContentSize',
      );
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
    emit(bytes);
  }

  void _compact() {
    if (_cursor > 0 && (_cursor >= _pending.length || _cursor >= 8192)) {
      _pending.removeRange(0, _cursor);
      _cursor = 0;
    }
  }
}

class _FrameReader {
  _FrameReader(Uint8List data) : _data = data;

  final Uint8List _data;
  int _offset = 0;

  int readByte() {
    if (_offset >= _data.length) {
      throw Lz4FormatException('Unexpected end of input');
    }
    return _data[_offset++];
  }

  Uint8List readBytes(int length) {
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
}

class _BlockDecoder {
  _BlockDecoder(this._output);

  final ByteSink _output;
  late Uint8List _block;

  void reset(Uint8List block) {
    _block = block;
  }

  void decode() {
    var index = 0;
    final limit = _block.length;

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
            'Invalid match offset: 0 (offset must be at least 1)');
      }
      if (offset > _output.length) {
        throw Lz4FormatException(
            'Invalid match offset: $offset exceeds output length ${_output.length}');
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
              'Unexpected end while reading match length extension');
        }
      }
      matchLength += lz4MinMatch;

      _output.copyFromHistory(offset, matchLength);
    }

    if (index != limit) {
      throw Lz4FormatException('Block was not fully decoded');
    }
  }
}
