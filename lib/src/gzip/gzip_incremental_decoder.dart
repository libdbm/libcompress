import 'dart:typed_data';

import '../exceptions.dart';
import '../util/bit_stream.dart';
import '../util/crc32.dart';
import '../util/incremental_decompress_transformer.dart';
import '../util/window_buffer.dart';
import 'deflate_common.dart';
import 'gzip_frame.dart';
import 'huffman_tables.dart';

/// DEFLATE back-reference window (RFC 1951): 32 KB.
const int _deflateWindow = 1 << 15;

enum _Phase { header, deflate, trailer }

/// Incremental, memory-bounded GZIP decoder.
///
/// Unlike the whole-member decoder, this decodes the DEFLATE stream as bytes
/// arrive and emits output as it goes, retaining only a 32 KB back-reference
/// window. The DEFLATE bit loop is resumable: it checkpoints the bit position
/// before each unit (block header / symbol) and, when the current input runs
/// out mid-unit, rewinds and waits for more input. CRC32 and ISIZE are streamed
/// and validated at each member's trailer. Supports concatenated members.
class GzipIncrementalDecoder implements IncrementalDecoder {
  GzipIncrementalDecoder({this.maxSize, required this.maxBufferSize});

  final int? maxSize;
  final int maxBufferSize;

  final List<int> _pending = <int>[];
  int _cursor = 0; // fully-consumed byte boundary in _pending

  _Phase _phase = _Phase.header;

  // DEFLATE state (persists across chunk arrivals within a member).
  int _bitOffset = 0; // bit offset within _pending[_cursor]
  bool _blockReady = false; // current Huffman block decoders are built
  bool _blockFinal = false;
  bool _blockStored = false;
  int _storedRemaining = 0;
  HuffmanDecoder? _litDecoder;
  HuffmanDecoder? _distDecoder;
  bool _deflateDone = false;

  // Per-member output + checksums.
  WindowBuffer? _output;
  int _crc = 0xFFFFFFFF;
  int _isize = 0; // total bytes mod 2^32

  int get _avail => _pending.length - _cursor;

  @override
  void add(final Uint8List input, final void Function(Uint8List) emit) {
    _pending.addAll(input);
    if (_avail > maxBufferSize) {
      throw GzipFormatException(
        'Stream buffer exceeded $maxBufferSize bytes - '
        'frame too large or malformed',
      );
    }
    _drive(emit);
  }

  @override
  void close(final void Function(Uint8List) emit) {
    _drive(emit);
    if (_phase != _Phase.header || _avail != 0) {
      throw GzipFormatException('Incomplete GZIP member at end of stream');
    }
  }

  void _drive(final void Function(Uint8List) emit) {
    var progressed = true;
    while (progressed) {
      switch (_phase) {
        case _Phase.header:
          progressed = _avail > 0 && _parseHeader();
          break;
        case _Phase.deflate:
          progressed = _runDeflate(emit);
          break;
        case _Phase.trailer:
          progressed = _parseTrailer(emit);
          break;
      }
    }
    _compact();
  }

  bool _parseHeader() {
    if (_avail < 10) return false;
    var p = _cursor;
    if (_pending[p] != GzipFrame.id1 || _pending[p + 1] != GzipFrame.id2) {
      throw GzipFormatException('Invalid GZIP magic number at offset $p');
    }
    if (_pending[p + 2] != GzipFrame.cmDeflate) {
      throw GzipFormatException('Unsupported compression method: ${_pending[p + 2]}');
    }
    final flags = _pending[p + 3];
    p += 10; // magic(2) + cm(1) + flg(1) + mtime(4) + xfl(1) + os(1)

    if ((flags & GzipFrame.fextra) != 0) {
      if (_pending.length < p + 2) return false;
      final xlen = _pending[p] | (_pending[p + 1] << 8);
      p += 2;
      if (_pending.length < p + xlen) return false;
      p += xlen;
    }
    if ((flags & GzipFrame.fname) != 0) {
      final end = _findZero(p);
      if (end < 0) return false;
      p = end + 1;
    }
    if ((flags & GzipFrame.fcomment) != 0) {
      final end = _findZero(p);
      if (end < 0) return false;
      p = end + 1;
    }
    if ((flags & GzipFrame.fhcrc) != 0) {
      if (_pending.length < p + 2) return false;
      p += 2;
    }

    // Begin the member's DEFLATE stream.
    _cursor = p;
    _bitOffset = 0;
    _phase = _Phase.deflate;
    _blockReady = false;
    _blockStored = false;
    _blockFinal = false;
    _deflateDone = false;
    _litDecoder = null;
    _distDecoder = null;
    _output = WindowBuffer(_deflateWindow, maxSize: maxSize);
    _crc = 0xFFFFFFFF;
    _isize = 0;
    return true;
  }

  /// Returns the index of the next zero byte at/after [from], or -1 if the
  /// terminator hasn't arrived yet.
  int _findZero(final int from) {
    for (var i = from; i < _pending.length; i++) {
      if (_pending[i] == 0) return i;
    }
    return -1;
  }

  bool _runDeflate(final void Function(Uint8List) emit) {
    final output = _output!;
    final input = BitStreamReader(_pending, start: _cursor, end: _pending.length)
      ..seek(BitPosition(0, _bitOffset));

    var madeProgress = false;
    {
      while (!_deflateDone) {
        if (_blockStored) {
          // Copy stored-block bytes; each copied byte is committed.
          while (_storedRemaining > 0) {
            if (input.isEndOfStream) {
              _commit(input, output, emit);
              return madeProgress;
            }
            output.addByte(input.readBits(8));
            _storedRemaining--;
            madeProgress = true;
          }
          _blockStored = false;
          if (_blockFinal) _deflateDone = true;
          continue;
        }

        if (!_blockReady) {
          // Parse the next block header (atomic: rewind on exhaustion).
          final mark = input.position;
          try {
            _blockFinal = input.readBits(1) == 1;
            final type = input.readBits(2);
            switch (type) {
              case 0:
                input.flushToByte();
                final len = input.readBits(8) | (input.readBits(8) << 8);
                final nlen = input.readBits(8) | (input.readBits(8) << 8);
                if ((len ^ nlen) != 0xFFFF) {
                  throw DeflateFormatException('Stored block length mismatch');
                }
                _blockStored = true;
                _storedRemaining = len;
                break;
              case 1:
                _litDecoder = fixedLiteralDecoder;
                _distDecoder = fixedDistanceDecoder;
                _blockReady = true;
                break;
              case 2:
                _parseDynamicTables(input);
                _blockReady = true;
                break;
              default:
                throw DeflateFormatException('Invalid block type: $type');
            }
          } on StateError {
            input.seek(mark);
            _commit(input, output, emit);
            return madeProgress;
          }
          madeProgress = true;
          continue;
        }

        // Decode one Huffman symbol; rewind if it can't complete.
        final mark = input.position;
        try {
          final done = _decodeOneSymbol(input, output);
          madeProgress = true;
          if (done) {
            // End of block.
            _blockReady = false;
            if (_blockFinal) _deflateDone = true;
          }
        } on StateError {
          input.seek(mark);
          _commit(input, output, emit);
          return madeProgress;
        }
      }

      // Final block decoded: align to the trailer byte boundary.
      input.flushToByte();
      _commit(input, output, emit);
      _phase = _Phase.trailer;
      return true;
    }
  }

  /// Decodes one literal/match. Returns true at end-of-block.
  bool _decodeOneSymbol(final BitStreamReader input, final WindowBuffer output) {
    final symbol = _decodeSymbol(input, _litDecoder!);
    if (symbol < 256) {
      output.addByte(symbol);
      return false;
    }
    if (symbol == endBlock) {
      return true;
    }
    if (symbol > 285) {
      throw DeflateFormatException('Invalid literal/length symbol: $symbol');
    }
    final code = symbol - 257;
    var length = lengthBase[code];
    final extra = lengthExtraBits[code];
    if (extra > 0) length += input.readBits(extra);

    final distanceCode = _decodeSymbol(input, _distDecoder!);
    if (distanceCode >= 30) {
      throw DeflateFormatException('Invalid distance code: $distanceCode');
    }
    var distance = distanceBase[distanceCode];
    final distExtra = distanceExtraBits[distanceCode];
    if (distExtra > 0) distance += input.readBits(distExtra);

    if (distance > output.length || distance > _deflateWindow) {
      throw DeflateFormatException(
        'Distance $distance exceeds output ${output.length}',
      );
    }
    output.copyFromHistory(distance, length);
    return false;
  }

  void _parseDynamicTables(final BitStreamReader input) {
    final hlit = input.readBits(5) + 257;
    final hdist = input.readBits(5) + 1;
    final hclen = input.readBits(4) + 4;

    final clLengths = List<int>.filled(19, 0);
    for (var i = 0; i < hclen; i++) {
      clLengths[codeLengthOrder[i]] = input.readBits(3);
    }
    final clDecoder = buildDecoder(clLengths);

    final codeLengths = <int>[];
    final total = hlit + hdist;
    while (codeLengths.length < total) {
      final symbol = _decodeSymbol(input, clDecoder);
      if (symbol < 16) {
        codeLengths.add(symbol);
      } else if (symbol == 16) {
        if (codeLengths.isEmpty) {
          throw DeflateFormatException('Invalid repeat code at start');
        }
        final previous = codeLengths.last;
        var repeat = input.readBits(2) + 3;
        if (repeat > total - codeLengths.length) repeat = total - codeLengths.length;
        for (var i = 0; i < repeat; i++) {
          codeLengths.add(previous);
        }
      } else if (symbol == 17) {
        var repeat = input.readBits(3) + 3;
        if (repeat > total - codeLengths.length) repeat = total - codeLengths.length;
        for (var i = 0; i < repeat; i++) {
          codeLengths.add(0);
        }
      } else if (symbol == 18) {
        var repeat = input.readBits(7) + 11;
        if (repeat > total - codeLengths.length) repeat = total - codeLengths.length;
        for (var i = 0; i < repeat; i++) {
          codeLengths.add(0);
        }
      } else {
        throw DeflateFormatException('Invalid code length symbol: $symbol');
      }
    }

    _litDecoder = buildDecoder(codeLengths.sublist(0, hlit));
    _distDecoder = buildDecoder(codeLengths.sublist(hlit, hlit + hdist));
  }

  int _decodeSymbol(final BitStreamReader input, final HuffmanDecoder decoder) {
    var code = 0;
    var bits = 0;
    while (bits < 15) {
      code = (code << 1) | input.readBits(1);
      bits++;
      final symbol = decoder.decode(code, bits);
      if (symbol != null) return symbol;
    }
    throw DeflateFormatException('Invalid Huffman code');
  }

  /// Persists the reader's position (rounding down to a byte; the residual bit
  /// offset is kept) and emits any drained output, updating CRC/ISIZE.
  void _commit(
    final BitStreamReader input,
    final WindowBuffer output,
    final void Function(Uint8List) emit,
  ) {
    _cursor += input.bytePosition;
    _bitOffset = input.bitOffset;
    _emit(output.drain(), emit);
  }

  bool _parseTrailer(final void Function(Uint8List) emit) {
    if (_avail < 8) return false;
    // Emit the window tail before validating.
    _emit(_output!.finish(), emit);

    final p = _cursor;
    final expectedCrc = _pending[p] |
        (_pending[p + 1] << 8) |
        (_pending[p + 2] << 16) |
        (_pending[p + 3] << 24);
    final expectedSize = _pending[p + 4] |
        (_pending[p + 5] << 8) |
        (_pending[p + 6] << 16) |
        (_pending[p + 7] << 24);

    final actualCrc = _crc ^ 0xFFFFFFFF;
    if (actualCrc != expectedCrc) {
      throw GzipFormatException(
        'CRC mismatch: expected 0x${expectedCrc.toRadixString(16)}, '
        'got 0x${actualCrc.toRadixString(16)}',
      );
    }
    if (_isize != expectedSize) {
      throw GzipFormatException('Size mismatch: expected $expectedSize, got $_isize');
    }

    _cursor += 8;
    _phase = _Phase.header; // next concatenated member, if any
    _output = null;
    return true;
  }

  void _emit(final Uint8List bytes, final void Function(Uint8List) emit) {
    if (bytes.isEmpty) return;
    _crc = Crc32.update(bytes, _crc);
    _isize = (_isize + bytes.length) & 0xFFFFFFFF;
    emit(bytes);
  }

  void _compact() {
    if (_cursor > 0 && (_cursor >= _pending.length || _cursor >= 8192)) {
      _pending.removeRange(0, _cursor);
      _cursor = 0;
    }
  }
}
