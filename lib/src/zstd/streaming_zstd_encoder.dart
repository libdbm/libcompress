import 'dart:math' as math;
import 'dart:typed_data';

import '../util/stream_compressor.dart';
import '../util/xxh64.dart';
import 'compressed_block_encoder.dart';
import 'zstd_common.dart';

/// Stateful, single-frame Zstd encoder for streaming compression.
///
/// Emits one window-descriptor frame (no baked-in content size) whose blocks
/// share up to [blockSize] of history, so matches reference prior chunks across
/// block boundaries — better ratio than an independent frame per chunk. Each
/// chunk is split into <=[blockSize] blocks; each block is matched against
/// `history + block` (combined <= the declared window, ~2x [blockSize]), so
/// absolute offsets stay within the window. The content checksum (XXH64 low 32
/// bits) is streamed.
class StreamingZstdEncoder implements StreamCompressor {
  StreamingZstdEncoder({
    this.level = 3,
    this.checksum = false,
    this.validate = false,
    this.blockSize = zstdMaxBlockSize,
    this.strict = false,
    this.onFallback,
  }) : assert(blockSize > 0 && blockSize <= zstdMaxBlockSize);

  final int level;
  final bool checksum;
  final bool validate;

  /// Max input bytes per block (<= [zstdMaxBlockSize], default 128 KB). Smaller
  /// blocks lower latency/memory; larger blocks improve ratio.
  final int blockSize;

  /// Fail loud on an unexpected compressed-block encode error instead of
  /// silently falling back to a raw block. See [CompressedBlockEncoder.strict].
  final bool strict;

  /// Observability hook for silent raw-block fallbacks (see [fallbacks]).
  final void Function(Object error, StackTrace stackTrace)? onFallback;

  // Declared window = smallest power of two >= 2*blockSize, so the combined
  // `history (<=blockSize) + block (<=blockSize)` always fits and absolute
  // match offsets stay below it.
  late final int _windowByte = _windowByteFor(blockSize);

  late final CompressedBlockEncoder _encoder = CompressedBlockEncoder(
    searchDepth: _searchDepth(level),
    minMatch: level >= 6 ? 3 : 4,
    validate: validate,
    strict: strict,
    onFallback: onFallback,
  );

  /// Number of blocks that fell back to raw output due to an unexpected encode
  /// error (0 in healthy operation; >0 signals a compression regression).
  int get fallbacks => _encoder.fallbacks;

  // Two reused, ping-ponged window buffers. The active buffer holds
  // `history (<=blockSize) at [0.._hist)` followed by the appended piece, and is
  // matched in place (native element access, bounded by `end`). After each block
  // the next history is copied into the *other* buffer (non-overlapping) and the
  // buffers swap — no per-block concat/tail allocation.
  late Uint8List _cur = Uint8List(2 * blockSize);
  late Uint8List _alt = Uint8List(2 * blockSize);
  int _hist = 0; // bytes of history at the front of _cur (<= blockSize)

  final Xxh64Sink _sink = Xxh64Sink(); // content checksum over all input

  /// Frame header: magic + descriptor + window descriptor (no content size).
  @override
  Uint8List header() {
    final descriptor = checksum ? 0x04 : 0x00; // FCS=0, not single-segment
    return Uint8List.fromList([
      ..._u32le(zstdMagicNumber),
      descriptor,
      _windowByte,
    ]);
  }

  /// Compresses [data] (split into <=[blockSize] linked blocks) and returns the
  /// frame block bytes produced.
  @override
  Uint8List addChunk(final Uint8List data) {
    final out = BytesBuilder(copy: false);
    var off = 0;
    while (off < data.length) {
      final n = math.min(blockSize, data.length - off);
      out.add(_emitBlock(Uint8List.sublistView(data, off, off + n)));
      off += n;
    }
    return out.takeBytes();
  }

  /// Writes the final (empty) block and the optional content checksum.
  @override
  Uint8List finish() {
    final out = BytesBuilder(copy: false);
    out.add(_blockHeader(last: true, type: 0, size: 0)); // empty raw, last
    if (checksum) out.add(_u32le(_sink.digestLow32()));
    return out.takeBytes();
  }

  Uint8List _emitBlock(final Uint8List piece) {
    _sink.add(piece);
    final pieceLen = piece.length;

    // Append the piece after the front-anchored history in the active buffer.
    // _hist + pieceLen <= 2*blockSize == buffer length.
    _cur.setRange(_hist, _hist + pieceLen, piece);
    final total = _hist + pieceLen;

    // Match over the native buffer directly (fast element access), bounded to
    // the live region via `end` — no view/copy. Identical bytes/layout to the
    // old concatenated buffer, so the output is unchanged.
    final compressed = _encoder.encodeBlock(_cur, from: _hist, end: total);

    final out = BytesBuilder(copy: false);
    if (compressed.isNotEmpty && compressed.length < pieceLen) {
      out.add(_blockHeader(last: false, type: 2, size: compressed.length));
      out.add(compressed);
    } else {
      out.add(_blockHeader(last: false, type: 0, size: pieceLen));
      out.add(piece);
    }

    // Copy the last <=blockSize bytes as the next block's history into the
    // alternate buffer (non-overlapping) and swap. No allocation.
    final newHist = math.min(blockSize, total);
    _alt.setRange(0, newHist, _cur, total - newHist);
    final swap = _cur;
    _cur = _alt;
    _alt = swap;
    _hist = newHist;
    return out.takeBytes();
  }

  /// Window-descriptor byte for the smallest power-of-two window >= 2*[block]
  /// (mantissa 0). zstd's minimum window is 1 KB, so the exponent is clamped at
  /// 0; with [block] <= 128 KB the exponent is at most 8 (256 KB window).
  static int _windowByteFor(final int block) {
    final target = 2 * block;
    var exponent = 0;
    while ((1 << (10 + exponent)) < target) {
      exponent++;
    }
    return exponent << 3;
  }

  /// 3-byte little-endian block header: last(1) | type(2) | size(21).
  Uint8List _blockHeader({required final bool last, required final int type, required final int size}) {
    final h = (last ? 1 : 0) | (type << 1) | (size << 3);
    return Uint8List.fromList([h & 0xFF, (h >> 8) & 0xFF, (h >> 16) & 0xFF]);
  }

  static int _searchDepth(final int level) {
    if (level <= 1) return 4;
    if (level <= 2) return 8;
    if (level <= 3) return 32;
    if (level <= 4) return 48;
    if (level <= 5) return 64;
    if (level <= 6) return 96;
    if (level <= 9) return 128;
    if (level <= 12) return 256;
    if (level <= 16) return 512;
    return 1024;
  }

  static Uint8List _u32le(final int v) => Uint8List.fromList([
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ]);
}
