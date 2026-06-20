import 'dart:math' as math;
import 'dart:typed_data';

import '../util/byte_utils.dart';
import '../util/lz77_common.dart';
import '../util/xxh32.dart';
import 'lz4_common.dart';

class Lz4Encoder {
  Lz4Encoder({
    this.level = 1,
    this.enableContentChecksum = true,
    this.blockSize = lz4DefaultBlockSize,
  }) {
    if (blockSize <= 0) {
      throw ArgumentError.value(blockSize, 'blockSize', 'Must be positive');
    }
  }

  final int level;
  final bool enableContentChecksum;
  final int blockSize;

  Uint8List compress(final Uint8List input) {
    // Estimate output size: header (7-19) + blocks + end mark (4) + checksum (4)
    // Worst case per block: 4-byte header + uncompressed data
    final estimated = 32 + input.length + (input.length ~/ blockSize + 1) * 4;
    final output = Uint8List(estimated);
    var pos = 0;

    // Frame header.
    ByteUtils.writeUint32LEAt(output, pos, lz4FrameMagic);
    pos += 4;

    var flag = 0x40; // Version 01.
    flag |= 0x20; // Independent blocks.
    if (enableContentChecksum) {
      flag |= 0x04;
    }

    final blockSizeCode = blockSizeCodeFromSize(blockSize);
    final bd = blockSizeCode << 4;

    output[pos++] = flag;
    output[pos++] = bd;

    final headerDescriptor = Uint8List.fromList([flag, bd]);
    output[pos++] = lz4HeaderChecksum(headerDescriptor);

    // Reusable buffer for block compression
    final blockBuffer = Uint8List(blockSize + (blockSize ~/ 255) + 16);

    var cursor = 0;
    while (cursor < input.length) {
      final chunkSize = math.min(blockSize, input.length - cursor);
      final chunk = Uint8List.sublistView(input, cursor, cursor + chunkSize);

      final compressedLen = level >= 9
          ? _compressBlockHC(chunk, blockBuffer)
          : _compressBlock(chunk, blockBuffer);
      final useCompressed = compressedLen < chunk.length && chunk.isNotEmpty;

      if (useCompressed) {
        ByteUtils.writeUint32LEAt(output, pos, compressedLen);
        pos += 4;
        output.setRange(pos, pos + compressedLen, blockBuffer);
        pos += compressedLen;
      } else {
        ByteUtils.writeUint32LEAt(output, pos, chunk.length | 0x80000000);
        pos += 4;
        output.setRange(pos, pos + chunk.length, chunk);
        pos += chunk.length;
      }

      cursor += chunkSize;
    }

    // End mark.
    ByteUtils.writeUint32LEAt(output, pos, 0);
    pos += 4;

    if (enableContentChecksum) {
      final checksum = lz4ContentChecksum(input);
      ByteUtils.writeUint32LEAt(output, pos, checksum);
      pos += 4;
    }

    return Uint8List.sublistView(output, 0, pos);
  }

  /// Compresses a block using high-compression mode (level >= 9)
  /// Writes to [out] buffer and returns the number of bytes written.
  int _compressBlockHC(final Uint8List input, final Uint8List out) {
    if (input.isEmpty) {
      out[0] = 0;
      return 1;
    }

    final hashTable = List<int>.filled(lz4HashTableSize, -1);
    final chainTable = List<int>.filled(lz4MaxOffset + 1, -1);
    var op = 0;
    final end = input.length;
    final limit = end - lz4MFLimit;
    final matchLimit = end - lz4LastLiterals;
    var anchor = 0;
    var index = 0;

    while (index <= limit) {
      final hash = LZ77Hash.lz4Hash(input, index, 32 - lz4HashLog);
      final candidate = hashTable[hash];
      hashTable[hash] = index;

      if (index - candidate < lz4MaxOffset) {
        chainTable[index & lz4OffsetMask] = candidate;
      }

      var bestMatchLength = 0;
      var bestMatchOffset = 0;

      var currentCandidate = candidate;
      var attempts = 0;
      while (currentCandidate >= 0 &&
          (index - currentCandidate) < lz4MaxOffset &&
          attempts < lz4MaxHcProbeAttempts) {
        if (currentCandidate + 4 <= input.length &&
            ByteUtils.readUint32LE(input, currentCandidate) ==
                ByteUtils.readUint32LE(input, index)) {
          var matchLength = lz4MinMatch;
          while (index + matchLength < matchLimit &&
              input[index + matchLength] ==
                  input[currentCandidate + matchLength]) {
            matchLength++;
          }

          if (matchLength > bestMatchLength) {
            bestMatchLength = matchLength;
            bestMatchOffset = index - currentCandidate;
          }
        }
        currentCandidate = chainTable[currentCandidate & lz4OffsetMask];
        attempts++;
      }

      if (bestMatchLength < lz4MinMatch) {
        index++;
        continue;
      }

      final matchIndex = index;
      index += bestMatchLength;

      final literalLength = matchIndex - anchor;
      final tokenIndex = op++;

      op = _encodeLiteralLength(out, op, tokenIndex, literalLength);

      if (literalLength > 0) {
        out.setRange(op, op + literalLength, input, anchor);
        op += literalLength;
      }

      ByteUtils.writeUint16LEAt(out, op, bestMatchOffset);
      op += 2;

      op = _encodeMatchLength(out, op, tokenIndex, bestMatchLength);

      anchor = index;
    }

    final remaining = end - anchor;
    if (remaining > 0) {
      final tokenIndex = op++;
      op = _encodeLiteralLength(out, op, tokenIndex, remaining);
      out.setRange(op, op + remaining, input, anchor);
      op += remaining;
    }

    return op;
  }

  /// Compresses a block using standard mode (level < 9)
  /// Writes to [out] buffer and returns the number of bytes written.
  int _compressBlock(final Uint8List input, final Uint8List out) {
    if (input.isEmpty) {
      out[0] = 0;
      return 1;
    }

    final hashTable = List<int>.filled(lz4HashTableSize, -1);
    var op = 0;
    final end = input.length;
    final limit = end - lz4MFLimit;
    final matchLimit = end - lz4LastLiterals;
    var anchor = 0;
    var index = 0;

    while (index <= limit) {
      final hash = LZ77Hash.lz4Hash(input, index, 32 - lz4HashLog);
      final candidate = hashTable[hash];
      hashTable[hash] = index;

      var match = false;
      if (index + lz4MinMatch <= matchLimit &&
          candidate >= 0 &&
          (index - candidate) <= lz4MaxOffset &&
          ByteUtils.readUint32LE(input, candidate) ==
              ByteUtils.readUint32LE(input, index)) {
        match = true;
      }

      if (!match) {
        index++;
        continue;
      }

      final matchIndex = index;

      index += lz4MinMatch;
      var refIndex = candidate + lz4MinMatch;

      while (index < matchLimit && input[index] == input[refIndex]) {
        index++;
        refIndex++;
      }

      final literalLength = matchIndex - anchor;
      final matchLength = index - matchIndex;

      final tokenIndex = op++;

      op = _encodeLiteralLength(out, op, tokenIndex, literalLength);

      if (literalLength > 0) {
        out.setRange(op, op + literalLength, input, anchor);
        op += literalLength;
      }

      final offset = matchIndex - candidate;
      ByteUtils.writeUint16LEAt(out, op, offset);
      op += 2;

      op = _encodeMatchLength(out, op, tokenIndex, matchLength);

      anchor = index;

      if (index - 2 >= 0 && index - 2 <= limit) {
        hashTable[LZ77Hash.lz4Hash(input, index - 2, 32 - lz4HashLog)] =
            index - 2;
      }
      if (index - 1 >= 0 && index - 1 <= limit) {
        hashTable[LZ77Hash.lz4Hash(input, index - 1, 32 - lz4HashLog)] =
            index - 1;
      }
    }

    final remaining = end - anchor;
    if (remaining > 0) {
      final tokenIndex = op++;
      op = _encodeLiteralLength(out, op, tokenIndex, remaining);
      out.setRange(op, op + remaining, input, anchor);
      op += remaining;
    }

    return op;
  }

  /// Encodes literal length into buffer, returns new position after length bytes.
  static int _encodeLiteralLength(
    final Uint8List out,
    int pos,
    final int tokenIndex,
    final int literalLength,
  ) {
    final nibble = literalLength < 15 ? literalLength : 15;
    out[tokenIndex] = nibble << 4;
    if (literalLength >= 15) {
      pos = _writeLength(out, pos, literalLength - 15);
    }
    return pos;
  }

  /// Encodes match length into token byte and writes extension bytes.
  /// Returns new position after writing any extension bytes.
  static int _encodeMatchLength(
    final Uint8List out,
    int pos,
    final int tokenIndex,
    final int matchLength,
  ) {
    final adjusted = matchLength - lz4MinMatch;
    final nibble = adjusted < 15 ? adjusted : 15;
    out[tokenIndex] |= nibble;
    if (adjusted >= 15) {
      pos = _writeLength(out, pos, adjusted - 15);
    }
    return pos;
  }

  /// Writes extended length bytes, returns new position.
  static int _writeLength(final Uint8List out, int pos, int length) {
    while (length >= 255) {
      out[pos++] = 255;
      length -= 255;
    }
    out[pos++] = length;
    return pos;
  }
}

/// Stateful, block-linked LZ4 frame encoder for streaming compression.
///
/// Emits one frame with linked blocks (the independent-blocks flag is cleared),
/// so each block's matches can reference the previous 64 KB of output across
/// chunk boundaries — better ratio than an independent frame per chunk. Carries
/// the last 64 KB as a window; peak input memory is ~64 KB plus one block.
class StreamingLz4Encoder {
  StreamingLz4Encoder({
    this.level = 1,
    this.contentChecksum = true,
    this.blockSize = lz4DefaultBlockSize,
  });

  final int level;
  final bool contentChecksum;
  final int blockSize;

  Uint8List _window = Uint8List(0); // last <=64 KB of emitted output
  final Xxh32Sink _sink = Xxh32Sink(); // content checksum over all input

  /// The 7-byte LZ4 frame header (magic + FLG/BD + header checksum), with the
  /// independent-blocks flag cleared (blocks are linked).
  Uint8List header() {
    var flag = 0x40; // version 01; bit 0x20 (independent blocks) cleared
    if (contentChecksum) flag |= 0x04;
    final bd = blockSizeCodeFromSize(blockSize) << 4;
    return Uint8List.fromList([
      ...(_u32le(lz4FrameMagic)),
      flag,
      bd,
      lz4HeaderChecksum([flag, bd]),
    ]);
  }

  /// Compresses [data] (split into <=blockSize linked blocks) and returns the
  /// frame block bytes produced.
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

  /// Writes the end mark and (optional) content checksum.
  Uint8List finish() {
    final out = BytesBuilder(copy: false);
    out.add(_u32le(0)); // end mark
    if (contentChecksum) out.add(_u32le(_sink.digest()));
    return out.takeBytes();
  }

  Uint8List _emitBlock(final Uint8List piece) {
    _sink.add(piece);
    final buf = _concat(_window, piece);
    final start = _window.length;
    final block = _compressLinked(buf, start);

    final out = BytesBuilder(copy: false);
    if (block.length < piece.length) {
      out.add(_u32le(block.length));
      out.add(block);
    } else {
      out.add(_u32le(piece.length | 0x80000000));
      out.add(piece);
    }
    // Retain the last 64 KB as the window for the next block's matches.
    _window = _tail(buf, lz4MaxOffset);
    return out.takeBytes();
  }

  /// LZ4-compresses `buf[start..]`, with matches allowed to reference back into
  /// the preceding window (down to `start - 64 KB`). Returns the block bytes.
  Uint8List _compressLinked(final Uint8List buf, final int start) {
    final span = buf.length - start;
    final out = Uint8List(span + (span >> 8) + 64);
    final hashTable = List<int>.filled(lz4HashTableSize, -1);
    var op = 0;
    final end = buf.length;
    final limit = end - lz4MFLimit;
    final matchLimit = end - lz4LastLiterals;
    var anchor = start;
    var index = start;

    // Seed the hash with the window so matches can reach into prior blocks.
    final windowStart = math.max(0, start - lz4MaxOffset);
    for (var i = windowStart; i + 4 <= buf.length && i < start; i++) {
      hashTable[LZ77Hash.lz4Hash(buf, i, 32 - lz4HashLog)] = i;
    }

    while (index <= limit) {
      final hash = LZ77Hash.lz4Hash(buf, index, 32 - lz4HashLog);
      final candidate = hashTable[hash];
      hashTable[hash] = index;

      if (index + lz4MinMatch > matchLimit ||
          candidate < 0 ||
          (index - candidate) > lz4MaxOffset ||
          ByteUtils.readUint32LE(buf, candidate) !=
              ByteUtils.readUint32LE(buf, index)) {
        index++;
        continue;
      }

      final matchIndex = index;
      index += lz4MinMatch;
      var refIndex = candidate + lz4MinMatch;
      while (index < matchLimit && buf[index] == buf[refIndex]) {
        index++;
        refIndex++;
      }

      final literalLength = matchIndex - anchor;
      final matchLength = index - matchIndex;
      final tokenIndex = op++;
      op = Lz4Encoder._encodeLiteralLength(out, op, tokenIndex, literalLength);
      if (literalLength > 0) {
        out.setRange(op, op + literalLength, buf, anchor);
        op += literalLength;
      }
      ByteUtils.writeUint16LEAt(out, op, matchIndex - candidate);
      op += 2;
      op = Lz4Encoder._encodeMatchLength(out, op, tokenIndex, matchLength);
      anchor = index;

      if (index - 2 >= start && index - 2 <= limit) {
        hashTable[LZ77Hash.lz4Hash(buf, index - 2, 32 - lz4HashLog)] = index - 2;
      }
      if (index - 1 >= start && index - 1 <= limit) {
        hashTable[LZ77Hash.lz4Hash(buf, index - 1, 32 - lz4HashLog)] = index - 1;
      }
    }

    final remaining = end - anchor;
    if (remaining > 0) {
      final tokenIndex = op++;
      op = Lz4Encoder._encodeLiteralLength(out, op, tokenIndex, remaining);
      out.setRange(op, op + remaining, buf, anchor);
      op += remaining;
    }

    return Uint8List.sublistView(out, 0, op);
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
