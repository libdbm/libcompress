import 'dart:typed_data';

import '../exceptions.dart';
import '../util/byte_pending.dart';
import '../util/crc32.dart';
import '../util/incremental_decoder.dart';
import '../util/output_limit.dart';
import '../util/window_buffer.dart';
import 'deflate_common.dart';
import 'deflate_reader.dart';
import 'gzip_frame.dart';
import 'huffman_tables.dart';

/// DEFLATE back-reference window (RFC 1951): 32 KB.
const int _deflateWindow = 1 << 15;

/// Output produced since the last drain that triggers another drain while
/// decoding, so one large input chunk is emitted in bounded pieces.
const int _drainInterval = 1 << 16;

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

  _Phase _phase = _Phase.header;

  // DEFLATE state (persists across chunk arrivals within a member).
  int _bitOffset = 0; // bit offset within _pending[_pending.cursor]
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

  // How far the FNAME/FCOMMENT search got, so a long field split across
  // chunks is scanned once.
  var _scan = GzipHeaderScan();

  // True until a non-empty chunk arrives: empty input is an error.
  bool _empty = true;

  @override
  void add(final Uint8List input, final void Function(Uint8List) emit) {
    if (input.isNotEmpty) _empty = false;
    _pending.append(input, maxBufferSize);
    guardFormat(() => _drive(emit), GzipFormatException.new, limit: maxSize);
  }

  @override
  void close(final void Function(Uint8List) emit) {
    guardFormat(() => _drive(emit), GzipFormatException.new, limit: maxSize);
    if (_empty) {
      throw GzipFormatException('Empty GZIP stream');
    }
    if (_phase != _Phase.header || _pending.available != 0) {
      throw GzipFormatException('Incomplete GZIP member at end of stream');
    }
  }

  void _drive(final void Function(Uint8List) emit) {
    var progressed = true;
    while (progressed) {
      switch (_phase) {
        case _Phase.header:
          progressed = _pending.available > 0 && _parseHeader();
          break;
        case _Phase.deflate:
          progressed = _runDeflate(emit);
          break;
        case _Phase.trailer:
          progressed = _parseTrailer(emit);
          break;
      }
    }
    _pending.compact();
  }

  bool _parseHeader() {
    final length = GzipFrame.header(
      _pending.bytes,
      _pending.cursor,
      _pending.length,
      _scan,
    );
    if (length == null) return false;
    final p = _pending.cursor + length;

    // Begin the member's DEFLATE stream.
    _scan = GzipHeaderScan();
    _pending.cursor = p;
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

  bool _runDeflate(final void Function(Uint8List) emit) {
    final output = _output!;
    final input = DeflateReader(
      _pending.bytes,
      start: _pending.cursor,
      end: _pending.length,
      bit: _bitOffset,
      partial: true,
    );

    var madeProgress = false;
    var drained = output.length;
    void drain() {
      if (output.length - drained >= _drainInterval) {
        _emit(output.drain(), emit);
        drained = output.length;
      }
    }

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
          drain();
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
              final stored = input.read(16);
              final complement = input.read(16);
              if ((stored ^ complement) != 0xFFFF) {
                throw DeflateFormatException('Stored block length mismatch');
              }
              _blockStored = true;
              _storedRemaining = stored;
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
          // Safe mid-loop: output holds only complete symbols, and a rewind
          // to [mark] discards nothing already written.
          drain();
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

  /// Persists the reader's position (whole bytes into [_pending.cursor], the residual
  /// bit offset into [_bitOffset]) and emits any drained output, updating
  /// CRC/ISIZE.
  void _commit(
    final DeflateReader input,
    final WindowBuffer output,
    final void Function(Uint8List) emit,
  ) {
    final consumed = input.consumed;
    _pending.cursor += consumed >> 3;
    _bitOffset = consumed & 7;
    _emit(output.drain(), emit);
  }

  bool _parseTrailer(final void Function(Uint8List) emit) {
    if (_pending.available < 8) return false;
    // Drain the window tail (held until validation in verified mode).
    _emit(_output!.finish(), emit);

    final p = _pending.cursor;
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

    _pending.cursor += 8;
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
}
