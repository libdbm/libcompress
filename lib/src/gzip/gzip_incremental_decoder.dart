import 'dart:typed_data';

import '../exceptions.dart';
import '../util/byte_pending.dart';
import '../util/crc32.dart';
import '../util/incremental_decompress_transformer.dart';
import '../util/output_limit.dart';
import '../util/window_buffer.dart';
import 'deflate_common.dart';
import 'deflate_reader.dart';
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
  GzipIncrementalDecoder({
    this.maxSize,
    required this.maxBufferSize,
    this.verified = false,
  });

  final int? maxSize;
  final int maxBufferSize;

  /// When true, a member's output is withheld until its CRC32/ISIZE trailer
  /// validates, then flushed — so a downstream consumer never receives bytes
  /// from a member that later fails integrity. Memory rises to one member's
  /// output (bounded by [maxSize]); the default (false) emits as it decodes.
  final bool verified;

  // Holds a member's output in verified mode until the trailer validates.
  BytesBuilder? _hold;

  // Cumulative output limit across all concatenated members (the public stream
  // contract caps total output, not per-member output).
  late final OutputLimit _limit = OutputLimit(maxSize);

  final BytePending _pending = BytePending();
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
    // Reject before appending so an oversized chunk can't force the
    // allocation/copy in _pending.add ahead of the limit check.
    if (_avail + input.length > maxBufferSize) {
      throw GzipFormatException(
        'Stream buffer would exceed $maxBufferSize bytes - '
        'frame too large or malformed',
      );
    }
    _pending.add(input);
    gzipBoundary(() => _drive(emit));
  }

  @override
  void close(final void Function(Uint8List) emit) {
    gzipBoundary(() => _drive(emit));
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
    final memberStart = _cursor;
    var p = _cursor;
    if (_pending[p] != GzipFrame.id1 || _pending[p + 1] != GzipFrame.id2) {
      throw GzipFormatException('Invalid GZIP magic number at offset $p');
    }
    if (_pending[p + 2] != GzipFrame.cmDeflate) {
      throw GzipFormatException(
        'Unsupported compression method: ${_pending[p + 2]}',
      );
    }
    final flags = _pending[p + 3];
    if ((flags & 0xE0) != 0) {
      throw GzipFormatException(
        'Reserved GZIP FLG bits set: 0x${flags.toRadixString(16)}',
      );
    }
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
      // Validate the header CRC16 (low 16 bits of CRC32 over the header bytes),
      // matching the block decoder rather than silently skipping it.
      final expected = Crc32.hash(_pending.slice(memberStart, p)) & 0xFFFF;
      final actual = _pending[p] | (_pending[p + 1] << 8);
      if (actual != expected) {
        throw GzipFormatException(
          'Header CRC mismatch: expected 0x${expected.toRadixString(16)}, '
          'got 0x${actual.toRadixString(16)}',
        );
      }
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
    // Per-member buffer capped at the remaining cumulative budget, so many
    // small members can't collectively exceed maxSize.
    _output = WindowBuffer(_deflateWindow, maxSize: _limit.remaining);
    _hold = verified ? BytesBuilder(copy: false) : null;
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
    final input = DeflateReader(
      _pending.bytes,
      start: _cursor,
      end: _pending.length,
      bit: _bitOffset,
      partial: true,
    );

    var madeProgress = false;
    while (!_deflateDone) {
      if (_blockStored) {
        // Copy the stored bytes that have arrived; each copied byte is
        // committed.
        final available = input.available;
        final count = _storedRemaining < available
            ? _storedRemaining
            : available;
        if (count > 0) {
          output.addBytes(input.take(count));
          _storedRemaining -= count;
          madeProgress = true;
        }
        if (_storedRemaining > 0) {
          _commit(input, output, emit);
          return madeProgress;
        }
        _blockStored = false;
        if (_blockFinal) _deflateDone = true;
        continue;
      }

      if (!_blockReady) {
        // Parse the next block header (atomic: rewind on exhaustion).
        final mark = input.consumed;
        try {
          _blockFinal = input.read(1) == 1;
          final type = input.read(2);
          switch (type) {
            case 0:
              input.align();
              final len = input.read(16);
              final nlen = input.read(16);
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
              final (literals, distances) = readDynamicTables(input);
              _litDecoder = literals;
              _distDecoder = distances;
              _blockReady = true;
              break;
            default:
              throw DeflateFormatException('Invalid block type: $type');
          }
        } on StateError {
          input.rewind(mark);
          _commit(input, output, emit);
          return madeProgress;
        }
        madeProgress = true;
        continue;
      }

      // Decode symbols until the block ends; a symbol that cannot complete
      // rewinds to the last checkpoint. Each symbol reads all its bits before
      // writing output, so a rewind never leaves partial output behind.
      var mark = input.consumed;
      try {
        while (true) {
          final done = _decodeOneSymbol(input, output);
          mark = input.consumed;
          madeProgress = true;
          if (done) {
            _blockReady = false;
            if (_blockFinal) _deflateDone = true;
            break;
          }
        }
      } on StateError {
        input.rewind(mark);
        _commit(input, output, emit);
        return madeProgress;
      }
    }

    // Final block decoded: align to the trailer byte boundary.
    input.align();
    _commit(input, output, emit);
    _phase = _Phase.trailer;
    return true;
  }

  /// Decodes one literal/match. Returns true at end-of-block.
  bool _decodeOneSymbol(final DeflateReader input, final WindowBuffer output) {
    final symbol = input.decode(_litDecoder!);
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
    if (extra > 0) length += input.read(extra);

    final distanceCode = input.decode(_distDecoder!);
    if (distanceCode >= 30) {
      throw DeflateFormatException('Invalid distance code: $distanceCode');
    }
    var distance = distanceBase[distanceCode];
    final distExtra = distanceExtraBits[distanceCode];
    if (distExtra > 0) distance += input.read(distExtra);

    if (distance > output.length || distance > _deflateWindow) {
      throw DeflateFormatException(
        'Distance $distance exceeds output ${output.length}',
      );
    }
    output.copyFromHistory(distance, length);
    return false;
  }

  /// Persists the reader's position (whole bytes into [_cursor], the residual
  /// bit offset into [_bitOffset]) and emits any drained output, updating
  /// CRC/ISIZE.
  void _commit(
    final DeflateReader input,
    final WindowBuffer output,
    final void Function(Uint8List) emit,
  ) {
    final consumed = input.consumed;
    _cursor += consumed >> 3;
    _bitOffset = consumed & 7;
    _emit(output.drain(), emit);
  }

  bool _parseTrailer(final void Function(Uint8List) emit) {
    if (_avail < 8) return false;
    // Drain the window tail (held until validation in verified mode).
    _emit(_output!.finish(), emit);

    final p = _cursor;
    final expectedCrc =
        _pending[p] |
        (_pending[p + 1] << 8) |
        (_pending[p + 2] << 16) |
        (_pending[p + 3] << 24);
    final expectedSize =
        _pending[p + 4] |
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
      throw GzipFormatException(
        'Size mismatch: expected $expectedSize, got $_isize',
      );
    }

    // Member validated — in verified mode, release the held output now.
    final hold = _hold;
    if (hold != null) {
      if (hold.isNotEmpty) emit(hold.takeBytes());
      _hold = null;
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
    _limit.record(bytes.length);
    final hold = _hold;
    if (hold != null) {
      hold.add(
        bytes,
      ); // verified mode: release only after the trailer validates
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
