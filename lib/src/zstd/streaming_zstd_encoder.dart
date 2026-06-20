import 'dart:math' as math;
import 'dart:typed_data';

import '../util/xxh64.dart';
import 'compressed_block_encoder.dart';
import 'zstd_common.dart';

/// Stateful, single-frame Zstd encoder for streaming compression.
///
/// Emits one window-descriptor frame (no baked-in content size) whose blocks
/// share a 64 KB history, so matches reference prior chunks across block
/// boundaries — better ratio than an independent frame per chunk. Each chunk is
/// split into <=64 KB blocks; each block is matched against `history + block`
/// (combined <= the 128 KB declared window), so absolute offsets stay within
/// the window. The content checksum (XXH64 low 32 bits) is streamed.
class StreamingZstdEncoder {
  StreamingZstdEncoder({this.level = 3, this.checksum = false, this.validate = false});

  final int level;
  final bool checksum;
  final bool validate;

  // Declared window is 128 KB (combined history + block stays within it).
  static const int _windowByte = 56; // encodes 128 KB (exponent 7, mantissa 0)
  static const int _blockInput = 1 << 16; // 64 KB max block input

  late final CompressedBlockEncoder _encoder = CompressedBlockEncoder(
    searchDepth: _searchDepth(level),
    minMatch: level >= 6 ? 3 : 4,
    validate: validate,
  );

  Uint8List _history = Uint8List(0); // last <=64 KB of input (match window)
  final Xxh64Sink _sink = Xxh64Sink(); // content checksum over all input

  /// Frame header: magic + descriptor + window descriptor (no content size).
  Uint8List header() {
    final descriptor = checksum ? 0x04 : 0x00; // FCS=0, not single-segment
    return Uint8List.fromList([
      ..._u32le(zstdMagicNumber),
      descriptor,
      _windowByte,
    ]);
  }

  /// Compresses [data] (split into <=64 KB linked blocks) and returns the
  /// frame block bytes produced.
  Uint8List addChunk(final Uint8List data) {
    final out = BytesBuilder(copy: false);
    var off = 0;
    while (off < data.length) {
      final n = math.min(_blockInput, data.length - off);
      out.add(_emitBlock(Uint8List.sublistView(data, off, off + n)));
      off += n;
    }
    return out.takeBytes();
  }

  /// Writes the final (empty) block and the optional content checksum.
  Uint8List finish() {
    final out = BytesBuilder(copy: false);
    out.add(_blockHeader(last: true, type: 0, size: 0)); // empty raw, last
    if (checksum) out.add(_u32le(_sink.digestLow32()));
    return out.takeBytes();
  }

  Uint8List _emitBlock(final Uint8List piece) {
    _sink.add(piece);
    final combined = _concat(_history, piece);
    final from = _history.length;
    final compressed = _encoder.encodeBlock(combined, from: from);

    final out = BytesBuilder(copy: false);
    if (compressed.isNotEmpty && compressed.length < piece.length) {
      out.add(_blockHeader(last: false, type: 2, size: compressed.length));
      out.add(compressed);
    } else {
      out.add(_blockHeader(last: false, type: 0, size: piece.length));
      out.add(piece);
    }
    // Retain the last 64 KB as the window for the next block's matches.
    _history = _tail(combined, _blockInput);
    return out.takeBytes();
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

  static Uint8List _concat(final Uint8List a, final Uint8List b) {
    final out = Uint8List(a.length + b.length);
    out.setRange(0, a.length, a);
    out.setRange(a.length, out.length, b);
    return out;
  }

  static Uint8List _tail(final Uint8List b, final int n) {
    if (b.length <= n) return Uint8List.fromList(b);
    return Uint8List.fromList(Uint8List.sublistView(b, b.length - n));
  }

  static Uint8List _u32le(final int v) => Uint8List.fromList([
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ]);
}
