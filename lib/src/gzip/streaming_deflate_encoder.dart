import 'dart:math' as math;
import 'dart:typed_data';

import '../util/bit_stream.dart';
import 'deflate_common.dart';
import 'deflate_encoder.dart';

/// Stateful, sliding-window DEFLATE encoder for streaming compression.
///
/// Unlike [DeflateEncoder] (whole-buffer), this carries a 32 KB history across
/// chunks so matches can span chunk boundaries, and emits non-final DEFLATE
/// blocks as data arrives. Each call rebuilds the match buffer as
/// `window + carry + chunk` (the window is the last ≤32 KB of already-emitted
/// bytes; the carry is held-back lookahead), tokenizes the new region, emits a
/// block, and retains the trailing window + carry — so peak input memory is
/// roughly 32 KB plus one chunk.
class StreamingDeflateEncoder {
  StreamingDeflateEncoder({this.level = 6})
    : _blocks = DeflateEncoder(level: level);

  final int level;
  final DeflateEncoder _blocks; // reused only for token-based block writing
  final BitStreamWriter _out = BitStreamWriter();

  Uint8List _window = Uint8List(0); // emitted history for back-references
  Uint8List _carry = Uint8List(0); // bytes held back for lookahead

  /// Feeds a chunk; returns the DEFLATE bytes produced (may be empty if the
  /// chunk is too small to process yet).
  Uint8List addChunk(final Uint8List chunk) => _process(chunk, isFinal: false);

  /// Flushes the final block and returns the remaining DEFLATE bytes
  /// (byte-aligned).
  Uint8List finish() => _process(Uint8List(0), isFinal: true);

  Uint8List _process(final Uint8List chunk, {required final bool isFinal}) {
    final buf = _concat(_window, _carry, chunk);
    final start = _window.length;
    final limit = isFinal ? buf.length : buf.length - maxMatch;

    if (limit <= start && !isFinal) {
      // Not enough lookahead yet — keep accumulating in the carry.
      _carry = Uint8List.sublistView(buf, start);
      _carry = Uint8List.fromList(_carry);
      return Uint8List(0);
    }

    final (tokens, endPos) = _tokenize(buf, start, limit);

    if (tokens.isNotEmpty || isFinal) {
      if (level <= 3) {
        _blocks.writeFixedBlock(_out, tokens, isFinal: isFinal);
      } else {
        _blocks.writeDynamicBlock(_out, tokens, isFinal: isFinal);
      }
    }
    if (isFinal) _out.flushToByte();

    // Retain the last 32 KB of emitted bytes (window) and any unprocessed tail.
    final winStart = math.max(0, endPos - maxDistance);
    _window = Uint8List.fromList(Uint8List.sublistView(buf, winStart, endPos));
    _carry = Uint8List.fromList(Uint8List.sublistView(buf, endPos));

    return _out.takeBytes();
  }

  /// Tokenizes `buf[start..limit)` (a match may extend past [limit] into the
  /// held-back lookahead). Matches reference the preceding 32 KB. Returns the
  /// tokens and the position reached.
  (List<Token>, int) _tokenize(
    final Uint8List buf,
    final int start,
    final int limit,
  ) {
    final tokens = <Token>[];
    final head = Int32List(hashSize)..fillRange(0, hashSize, -1);
    final prev = Int32List(windowSize)..fillRange(0, windowSize, -1);

    // Seed the hash with the window preceding [start] so matches can reach it.
    final winStart = math.max(0, start - maxDistance);
    for (var i = winStart; i < start; i++) {
      _insert(buf, i, head, prev);
    }

    var pos = start;
    while (pos < limit) {
      final match = _findMatch(buf, pos, head, prev);
      if (match != null) {
        final (len, dist) = match;
        tokens.add(MatchToken(len, dist));
        final end = pos + len;
        for (var i = pos; i < end; i++) {
          _insert(buf, i, head, prev);
        }
        pos = end;
      } else {
        tokens.add(LiteralToken(buf[pos]));
        _insert(buf, pos, head, prev);
        pos++;
      }
    }
    return (tokens, pos);
  }

  void _insert(
    final Uint8List buf,
    final int pos,
    final Int32List head,
    final Int32List prev,
  ) {
    if (pos + minMatch > buf.length) return;
    final h = hash(buf, pos);
    prev[pos & (windowSize - 1)] = head[h];
    head[h] = pos;
  }

  (int, int)? _findMatch(
    final Uint8List buf,
    final int pos,
    final Int32List head,
    final Int32List prev,
  ) {
    if (pos + minMatch > buf.length) return null;
    final maxLen = math.min(maxMatch, buf.length - pos);
    var candidate = head[hash(buf, pos)];
    var bestLen = 0;
    var bestDist = 0;
    var attempts = 0;
    const maxAttempts = 128;

    while (candidate >= 0 && attempts < maxAttempts) {
      final distance = pos - candidate;
      if (distance > maxDistance || distance < 1) break;
      if (pos + bestLen < buf.length &&
          buf[candidate + bestLen] == buf[pos + bestLen]) {
        var len = 0;
        while (len < maxLen && buf[candidate + len] == buf[pos + len]) {
          len++;
        }
        if (len > bestLen) {
          bestLen = len;
          bestDist = distance;
          if (len >= maxMatch) break;
        }
      }
      candidate = prev[candidate & (windowSize - 1)];
      attempts++;
    }

    return bestLen >= minMatch ? (bestLen, bestDist) : null;
  }

  static Uint8List _concat(
    final Uint8List a,
    final Uint8List b,
    final Uint8List c,
  ) {
    final out = Uint8List(a.length + b.length + c.length);
    out.setRange(0, a.length, a);
    out.setRange(a.length, a.length + b.length, b);
    out.setRange(a.length + b.length, out.length, c);
    return out;
  }
}
