import 'dart:math' as math;
import 'dart:typed_data';

import '../util/byte_utils.dart';
import '../util/growable_buffer.dart';
import '../util/lz77_common.dart';
import '../util/stream_compressor.dart';
import '../util/xxh32.dart';
import 'lz4_common.dart';

class Lz4Encoder {
  Lz4Encoder({
    this.level = 1,
    this.checksum = true,
    this.blockSize = lz4DefaultBlockSize,
  }) {
    if (blockSize <= 0) {
      throw ArgumentError.value(blockSize, 'blockSize', 'Must be positive');
    }
  }

  final int level;
  final bool checksum;
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
    if (checksum) {
      flag |= 0x04;
    }

    final blockSizeCode = blockSizeCodeFromSize(blockSize);
    final bd = blockSizeCode << 4;

    output[pos++] = flag;
    output[pos++] = bd;

    final headerDescriptor = Uint8List.fromList([flag, bd]);
    output[pos++] = lz4HeaderChecksum(headerDescriptor);

    // Reusable buffer for block compression, no larger than the input needs.
    final span = math.max(1, math.min(blockSize, input.length));
    final blockBuffer = Uint8List(span + (span ~/ 255) + 16);

    var cursor = 0;
    while (cursor < input.length) {
      final chunkSize = math.min(blockSize, input.length - cursor);
      final chunk = Uint8List.sublistView(input, cursor, cursor + chunkSize);

      final compressedLen = level >= 2
          ? _compressHC(chunk, blockBuffer, 0, level)
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

    if (checksum) {
      final digest = lz4ContentChecksum(input);
      ByteUtils.writeUint32LEAt(output, pos, digest);
      pos += 4;
    }

    return trim(output, pos);
  }

  /// Compresses [input] as a single raw LZ4 block (no frame header, block-size
  /// prefix, end mark, or checksum). This is the bare LZ77 token stream defined
  /// by the LZ4 block format, suitable for containers that supply their own
  /// framing (e.g. Parquet `LZ4_RAW`). Use [compress] for the standard frame.
  Uint8List compressBlock(final Uint8List input) {
    // As LZ4_compress_default: one token with no literals.
    if (input.isEmpty) return Uint8List(1);
    final out = Uint8List(input.length + (input.length ~/ 255) + 16);
    final length = level >= 2
        ? _compressHC(input, out, 0, level)
        : _compressBlock(input, out);
    return trim(out, length);
  }

  /// Compresses [input] in Hadoop block framing as Arrow writes it: one outer
  /// block holding one inner chunk.
  Uint8List compressHadoop(final Uint8List input) {
    final block = compressBlock(input);
    final out = Uint8List(8 + block.length);
    ByteData.sublistView(out)
      ..setUint32(0, input.length)
      ..setUint32(4, block.length);
    out.setRange(8, out.length, block);
    return out;
  }

  /// Compresses a block using standard mode (level 1)
  /// Writes to [out] buffer and returns the number of bytes written.
  int _compressBlock(final Uint8List input, final Uint8List out) {
    if (input.isEmpty) {
      out[0] = 0;
      return 1;
    }

    final log = _hashLog(input.length);
    final shift = 32 - log;
    final hashTable = Int32List(1 << log)..fillRange(0, 1 << log, -1);
    var op = 0;
    final end = input.length;
    final limit = end - lz4MFLimit;
    final matchLimit = end - lz4LastLiterals;
    var anchor = 0;
    var index = 0;

    while (index <= limit) {
      final hash = LZ77Hash.lz4Hash(input, index, shift);
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
        hashTable[LZ77Hash.lz4Hash(input, index - 2, shift)] = index - 2;
      }
      if (index - 1 >= 0 && index - 1 <= limit) {
        hashTable[LZ77Hash.lz4Hash(input, index - 1, shift)] = index - 1;
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
/// so each block's matches can reference the previous 64 KB of input. Input is
/// buffered into blocks of [blockSize], so how it is split into chunks does not
/// change the output; peak input memory is 64 KB plus one block. Levels 2-9 use
/// high-compression mode, as [Lz4Encoder] does.
class StreamingLz4Encoder implements StreamCompressor {
  StreamingLz4Encoder({
    this.level = 1,
    this.contentChecksum = true,
    this.blockSize = lz4DefaultBlockSize,
  });

  final int level;
  final bool contentChecksum;
  final int blockSize;

  /// The window (the last <= 64 KB already compressed, before [_start])
  /// followed by input not yet compressed, up to [_length].
  Uint8List _buffer = Uint8List(0);
  int _start = 0;
  int _length = 0;
  final Xxh32Sink _sink = Xxh32Sink(); // content checksum over all input

  /// The 7-byte LZ4 frame header (magic + FLG/BD + header checksum), with the
  /// independent-blocks flag cleared (blocks are linked).
  @override
  Uint8List header() {
    var flag = 0x40; // version 01; bit 0x20 (independent blocks) cleared
    if (contentChecksum) flag |= 0x04;
    final bd = blockSizeCodeFromSize(blockSize) << 4;
    return Uint8List.fromList([
      ...(ByteUtils.uint32LE(lz4FrameMagic)),
      flag,
      bd,
      lz4HeaderChecksum([flag, bd]),
    ]);
  }

  /// Buffers [data], compressing each block as it fills, and returns the frame
  /// block bytes produced (empty until a block fills).
  @override
  Uint8List addChunk(final Uint8List data) {
    _sink.add(data);
    final out = BytesBuilder(copy: false);
    var offset = 0;
    while (offset < data.length) {
      final count = math.min(
        blockSize - (_length - _start),
        data.length - offset,
      );
      _reserve(_length + count);
      _buffer.setRange(_length, _length + count, data, offset);
      _length += count;
      offset += count;
      if (_length - _start == blockSize) out.add(_emitBlock());
    }
    return out.takeBytes();
  }

  /// Compresses the last partial block, then writes the end mark and
  /// (optional) content checksum.
  @override
  Uint8List finish() {
    final out = BytesBuilder(copy: false);
    if (_length > _start) out.add(_emitBlock());
    out.add(ByteUtils.uint32LE(0)); // end mark
    if (contentChecksum) out.add(ByteUtils.uint32LE(_sink.digest()));
    return out.takeBytes();
  }

  /// Grows [_buffer] to hold [size] bytes, by doubling up to the window plus
  /// one block.
  void _reserve(final int size) {
    if (size <= _buffer.length) return;
    var capacity = math.max(_buffer.length * 2, 1024);
    capacity = math.min(math.max(capacity, size), lz4MaxOffset + blockSize);
    _buffer = Uint8List(capacity)..setRange(0, _length, _buffer);
  }

  /// Compresses the pending input as one block, then keeps its last 64 KB as
  /// the window for the next block.
  Uint8List _emitBlock() {
    final data = Uint8List.sublistView(_buffer, 0, _length);
    final size = _length - _start;
    final Uint8List out;
    if (level >= 2) {
      final block = Uint8List(size + size ~/ 255 + 16);
      final count = _compressHC(data, block, _start, level);
      out = _frame(block, count, data, size);
    } else {
      final block = _compressLinked(data, _start);
      out = _frame(block, block.length, data, size);
    }
    final keep = math.min(_length, lz4MaxOffset);
    _buffer.setRange(0, keep, _buffer, _length - keep);
    _start = keep;
    _length = keep;
    return out;
  }

  /// A frame block: the first [count] bytes of [block] when smaller than the
  /// [size] pending bytes at the end of [data], else those bytes stored.
  static Uint8List _frame(
    final Uint8List block,
    final int count,
    final Uint8List data,
    final int size,
  ) {
    final compressed = count < size;
    final length = compressed ? count : size;
    final out = Uint8List(4 + length);
    ByteUtils.writeUint32LEAt(out, 0, compressed ? count : size | 0x80000000);
    if (compressed) {
      out.setRange(4, 4 + count, block);
    } else {
      out.setRange(4, 4 + size, data, data.length - size);
    }
    return out;
  }

  /// LZ4-compresses `data[start..]`, with matches allowed to reference back into
  /// the preceding window (down to `start - 64 KB`). Returns the block bytes.
  Uint8List _compressLinked(final Uint8List data, final int start) {
    final span = data.length - start;
    final out = Uint8List(span + span ~/ 255 + 16);
    final hashTable = Int32List(lz4HashTableSize)
      ..fillRange(0, lz4HashTableSize, -1);
    var op = 0;
    final end = data.length;
    final limit = end - lz4MFLimit;
    final matchLimit = end - lz4LastLiterals;
    var anchor = start;
    var index = start;

    // Seed the hash with the window so matches can reach into prior blocks.
    final windowStart = math.max(0, start - lz4MaxOffset);
    for (var i = windowStart; i + 4 <= data.length && i < start; i++) {
      hashTable[LZ77Hash.lz4Hash(data, i, 32 - lz4HashLog)] = i;
    }

    while (index <= limit) {
      final hash = LZ77Hash.lz4Hash(data, index, 32 - lz4HashLog);
      final candidate = hashTable[hash];
      hashTable[hash] = index;

      if (index + lz4MinMatch > matchLimit ||
          candidate < 0 ||
          (index - candidate) > lz4MaxOffset ||
          ByteUtils.readUint32LE(data, candidate) !=
              ByteUtils.readUint32LE(data, index)) {
        index++;
        continue;
      }

      final matchIndex = index;
      index += lz4MinMatch;
      var refIndex = candidate + lz4MinMatch;
      while (index < matchLimit && data[index] == data[refIndex]) {
        index++;
        refIndex++;
      }

      final literalLength = matchIndex - anchor;
      final matchLength = index - matchIndex;
      final tokenIndex = op++;
      op = Lz4Encoder._encodeLiteralLength(out, op, tokenIndex, literalLength);
      if (literalLength > 0) {
        out.setRange(op, op + literalLength, data, anchor);
        op += literalLength;
      }
      ByteUtils.writeUint16LEAt(out, op, matchIndex - candidate);
      op += 2;
      op = Lz4Encoder._encodeMatchLength(out, op, tokenIndex, matchLength);
      anchor = index;

      if (index - 2 >= start && index - 2 <= limit) {
        hashTable[LZ77Hash.lz4Hash(data, index - 2, 32 - lz4HashLog)] =
            index - 2;
      }
      if (index - 1 >= start && index - 1 <= limit) {
        hashTable[LZ77Hash.lz4Hash(data, index - 1, 32 - lz4HashLog)] =
            index - 1;
      }
    }

    final remaining = end - anchor;
    if (remaining > 0) {
      final tokenIndex = op++;
      op = Lz4Encoder._encodeLiteralLength(out, op, tokenIndex, remaining);
      out.setRange(op, op + remaining, data, anchor);
      op += remaining;
    }

    return Uint8List.sublistView(out, 0, op);
  }
}

/// Compresses `input[start..]` as one block in high-compression mode (levels
/// 2-9), with matches reaching back into the preceding 64 KB of [input]: every
/// position goes into a hash chain searched up to `1 << (level - 1)` candidates
/// deep (4 at level 3 to 256 at level 9, as in lz4), and a match is deferred
/// while the next position has a longer one.
/// Writes to [out] buffer and returns the number of bytes written.
int _compressHC(
  final Uint8List input,
  final Uint8List out,
  final int start,
  final int level,
) {
  if (start == input.length) {
    out[0] = 0;
    return 1;
  }

  final chain = _Chain(
    input,
    1 << (level - 1),
    math.max(0, start - lz4MaxOffset),
  );
  var op = 0;
  final end = input.length;
  final limit = end - lz4MFLimit;
  var anchor = start;
  var index = start;

  while (index <= limit) {
    if (!chain.find(index)) {
      index++;
      continue;
    }
    var length = chain.length;
    var offset = chain.offset;
    while (index < limit && chain.find(index + 1) && chain.length > length) {
      index++;
      length = chain.length;
      offset = chain.offset;
    }

    final literalLength = index - anchor;
    final tokenIndex = op++;

    op = Lz4Encoder._encodeLiteralLength(out, op, tokenIndex, literalLength);

    if (literalLength > 0) {
      out.setRange(op, op + literalLength, input, anchor);
      op += literalLength;
    }

    ByteUtils.writeUint16LEAt(out, op, offset);
    op += 2;

    op = Lz4Encoder._encodeMatchLength(out, op, tokenIndex, length);

    index += length;
    anchor = index;
  }

  final remaining = end - anchor;
  if (remaining > 0) {
    final tokenIndex = op++;
    op = Lz4Encoder._encodeLiteralLength(out, op, tokenIndex, remaining);
    out.setRange(op, op + remaining, input, anchor);
    op += remaining;
  }

  return op;
}

/// Hash table size (log2) for a block of [length] bytes: the smallest power of
/// two holding every position, from 2^8 up to the full 2^16 used for large
/// blocks, so small pages do not allocate and clear a 64K-entry table.
int _hashLog(final int length) =>
    math.max(8, math.min(lz4HashLog, (length - 1).bitLength));

/// Hash chains over every position of a block, for the HC compressor. A search
/// leaves the longest match found in [length] and [offset].
class _Chain {
  _Chain(this.input, this.depth, this._next) : _log = _hashLog(input.length) {
    _heads = Int32List(1 << _log)..fillRange(0, 1 << _log, -1);
    // Positions are below the input length, so a small input needs only as
    // many chain slots as positions.
    _mask = math.min(lz4MaxOffset + 1, 1 << _log) - 1;
    _links = Int32List(_mask + 1);
  }

  final Uint8List input;
  final int depth;
  final int _log;
  late final int _mask;
  late final Int32List _heads;
  late final Int32List _links;

  /// The next position to insert.
  int _next;

  int length = 0;
  int offset = 0;

  /// Searches for the longest match at [index], inserting every position up
  /// to it first. Returns whether one of at least [lz4MinMatch] bytes exists.
  bool find(final int index) {
    final shift = 32 - _log;
    while (_next <= index) {
      final hash = LZ77Hash.lz4Hash(input, _next, shift);
      _links[_next & _mask] = _heads[hash];
      _heads[hash] = _next;
      _next++;
    }

    final bound = input.length - lz4LastLiterals;
    final head = ByteUtils.readUint32LE(input, index);
    var best = lz4MinMatch - 1;
    var candidate = _links[index & _mask];
    for (
      var attempts = 0;
      attempts < depth && candidate >= 0 && index - candidate <= lz4MaxOffset;
      attempts++
    ) {
      if (index + best < bound &&
          input[candidate + best] == input[index + best] &&
          ByteUtils.readUint32LE(input, candidate) == head) {
        var size = lz4MinMatch;
        while (index + size < bound &&
            input[index + size] == input[candidate + size]) {
          size++;
        }
        if (size > best) {
          best = size;
          offset = index - candidate;
        }
      }
      candidate = _links[candidate & _mask];
    }
    length = best;
    return best >= lz4MinMatch;
  }
}
