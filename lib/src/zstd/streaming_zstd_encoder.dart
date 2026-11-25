import 'dart:math' as math;
import 'dart:typed_data';

import '../util/stream_compressor.dart';
import '../util/xxh64.dart';
import 'compressed_block_encoder.dart';
import 'zstd_common.dart';
import '../util/byte_utils.dart';

/// Stateful, single-frame Zstd encoder for streaming compression.
///
/// Emits one window-descriptor frame (no baked-in content size) whose blocks
/// share up to [blockSize] of history, so matches reference prior chunks across
/// block boundaries — better ratio than an independent frame per chunk. Input
/// is buffered into blocks of [blockSize] bytes, so the output does not depend
/// on how the input is split into chunks; the last, partial block is written by
/// [finish]. Each block is matched against `history + block` (combined <= the
/// declared window, ~2x [blockSize]), so absolute offsets stay within the
/// window. The content checksum (XXH64 low 32 bits) is streamed.
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

  late final CompressedBlockEncoder _encoder = CompressedBlockEncoder.level(
    level,
    validate: validate,
    strict: strict,
    onFallback: onFallback,
  );

  /// Number of blocks that fell back to raw output due to an unexpected encode
  /// error (0 in healthy operation; >0 signals a compression regression).
  int get fallbacks => _encoder.fallbacks;

  // Two reused, ping-ponged window buffers. The active buffer holds
  // `history (<=blockSize) at [0.._hist)` followed by the buffered input up to
  // `_length`, and is matched in place (native element access, bounded by
  // `end`). After each block the next history is copied into the *other*
  // buffer (non-overlapping) and the buffers swap — no per-block concat/tail
  // allocation.
  late Uint8List _cur = Uint8List(2 * blockSize);
  late Uint8List _alt = Uint8List(2 * blockSize);
  int _hist = 0; // bytes of history at the front of _cur (<= blockSize)
  int _length = 0; // end of the buffered input in _cur (<= _hist + blockSize)

  final Xxh64Sink _sink = Xxh64Sink(); // content checksum over all input

  /// Frame header: magic + descriptor + window descriptor (no content size).
  @override
  Uint8List header() {
    final descriptor = checksum ? 0x04 : 0x00; // FCS=0, not single-segment
    _encoder.start();
    return Uint8List.fromList([
      ...ByteUtils.uint32LE(zstdMagicNumber),
      descriptor,
      _windowByte,
    ]);
  }

  /// Buffers [data] and returns the bytes of each block it completes (empty
  /// until [blockSize] bytes have arrived).
  @override
  Uint8List addChunk(final Uint8List data) {
    _sink.add(data);
    final out = BytesBuilder(copy: false);
    var offset = 0;
    while (offset < data.length) {
      final count = math.min(_hist + blockSize - _length, data.length - offset);
      _cur.setRange(_length, _length + count, data, offset);
      _length += count;
      offset += count;
      if (_length - _hist == blockSize) out.add(_emitBlock(last: false));
    }
    return out.takeBytes();
  }

  /// Writes the buffered input as the last block (an empty raw block when
  /// nothing is buffered) and the optional content checksum.
  @override
  Uint8List finish() {
    final out = BytesBuilder(copy: false);
    if (_length > _hist) {
      out.add(_emitBlock(last: true));
    } else {
      out.add(_blockHeader(last: true, type: 0, size: 0)); // empty raw, last
    }
    if (checksum) out.add(ByteUtils.uint32LE(_sink.digestLow32()));
    return out.takeBytes();
  }

  /// Encodes the buffered input `_cur[_hist.._length)` as one block.
  Uint8List _emitBlock({required final bool last}) {
    final total = _length;
    final size = total - _hist;

    // Match over the native buffer directly (fast element access), bounded to
    // the live region via `end` — no view/copy.
    final compressed = _encoder.encodeBlock(_cur, from: _hist, end: total);

    final out = BytesBuilder(copy: false);
    if (compressed.isNotEmpty && compressed.length < size) {
      out.add(_blockHeader(last: last, type: 2, size: compressed.length));
      out.add(compressed);
    } else {
      // The decoder keeps neither this block's repeat offsets nor its tree.
      _encoder.discard();
      out.add(_blockHeader(last: last, type: 0, size: size));
      // A copy: _cur is overwritten by later blocks.
      out.add(_cur.sublist(_hist, total));
    }

    // Copy the last <=blockSize bytes as the next block's history into the
    // alternate buffer (non-overlapping) and swap. No allocation.
    final history = math.min(blockSize, total);
    _alt.setRange(0, history, _cur, total - history);
    final swap = _cur;
    _cur = _alt;
    _alt = swap;
    _hist = history;
    _length = history;
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
  Uint8List _blockHeader({
    required final bool last,
    required final int type,
    required final int size,
  }) {
    final h = (last ? 1 : 0) | (type << 1) | (size << 3);
    return Uint8List.fromList([h & 0xFF, (h >> 8) & 0xFF, (h >> 16) & 0xFF]);
  }
}
