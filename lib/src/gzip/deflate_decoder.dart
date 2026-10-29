import 'dart:typed_data';
import '../exceptions.dart';
import '../util/growable_buffer.dart';
import 'deflate_common.dart';
import 'deflate_reader.dart';
import 'huffman_tables.dart';
import '../util/platform.dart';

// The length and distance tables as typed arrays, for [DeflateDecoder]'s fast
// loop: cheaper to index than constant lists.
final _lengthBase = Uint16List.fromList(lengthBase);
final _lengthExtraBits = Uint8List.fromList(lengthExtraBits);
final _distanceBase = Uint16List.fromList(distanceBase);
final _distanceExtraBits = Uint8List.fromList(distanceExtraBits);

/// Room [DeflateDecoder]'s fast loop keeps past the output position: the
/// longest match (258) plus 8 for word copies that run past its end.
const _slack = 258 + 8;

/// DEFLATE decompression decoder implementing RFC 1951
///
/// Decompresses DEFLATE-compressed data by parsing block headers,
/// decoding Huffman codes, and reconstructing the original data.
class DeflateDecoder {
  /// Maximum output size (null = unlimited)
  final int? maxSize;

  /// Expected output size, used to size the output buffer up front (for
  /// example a GZIP trailer's ISIZE). Only a hint: output may differ.
  final int? hint;

  /// Creates a DEFLATE decoder with optional size limit
  DeflateDecoder({this.maxSize, this.hint});

  /// Decodes DEFLATE-compressed data
  ///
  /// Returns the decompressed data as a byte array. Throws
  /// [DeflateFormatException] if the input is invalid or corrupted, and
  /// [LimitException] if the output would exceed [maxSize].
  Uint8List decompress(final Uint8List data) {
    return decompressWithPosition(data).$1;
  }

  /// Decodes DEFLATE-compressed data and returns bytes consumed
  ///
  /// Returns a record containing:
  /// - The decompressed data as a byte array
  /// - The number of bytes consumed from input (aligned to byte boundary)
  ///
  /// This is useful for GZIP concatenated members where you need to know
  /// where the next member starts.
  (Uint8List, int) decompressWithPosition(final Uint8List data) {
    final input = DeflateReader(data);
    // Uint8List-backed (doubling) buffer instead of a boxed growable <int>;
    // back-references use copyFromHistory rather than sublist allocations.
    var capacity = hint ?? 0;
    final limit = maxSize;
    if (limit != null && capacity > limit) capacity = limit;
    // DEFLATE expands at most 1032:1, so a larger hint cannot be right.
    if (capacity > data.length * 1032) capacity = data.length * 1032;
    final output = GrowableBuffer(capacity > 1024 ? capacity : 1024);

    var isFinal = false;

    while (!isFinal) {
      // Read block header
      isFinal = input.read(1) == 1;
      final blockType = input.read(2);

      switch (blockType) {
        case 0: // Stored block
          _readStoredBlock(input, output);
          break;
        case 1: // Fixed Huffman block
          _readFixedHuffmanBlock(input, output);
          break;
        case 2: // Dynamic Huffman block
          _readDynamicHuffmanBlock(input, output);
          break;
        default:
          throw DeflateFormatException('Invalid block type: $blockType');
      }
    }

    // Align to byte boundary to get accurate consumed count
    input.align();

    return (output.toBytes(), input.position);
  }

  /// Reads a stored (uncompressed) block
  void _readStoredBlock(
    final DeflateReader input,
    final GrowableBuffer output,
  ) {
    // Skip to byte boundary
    input.align();

    // Read length and verify one's complement
    final stored = input.read(16);
    final complement = input.read(16);

    if ((stored ^ complement) != 0xFFFF) {
      throw DeflateFormatException('Stored block length mismatch');
    }

    // Check size limit before reading block
    final limit = maxSize;
    if (limit != null && output.length + stored > limit) {
      throw LimitException(limit);
    }

    // Copy the literal bytes in bulk
    output.addBytes(input.take(stored));
  }

  /// Reads a block compressed with fixed Huffman codes
  void _readFixedHuffmanBlock(
    final DeflateReader input,
    final GrowableBuffer output,
  ) {
    // Reuse the shared fixed Huffman decode tables (RFC 1951 constants)
    _decodeHuffmanBlock(
      input,
      output,
      fixedLiteralDecoder,
      fixedDistanceDecoder,
    );
  }

  /// Reads a block compressed with dynamic Huffman codes
  void _readDynamicHuffmanBlock(
    final DeflateReader input,
    final GrowableBuffer output,
  ) {
    final (literals, distances) = readDynamicTables(input);
    _decodeHuffmanBlock(input, output, literals, distances);
  }

  /// Decodes a Huffman-coded block
  void _decodeHuffmanBlock(
    final DeflateReader input,
    final GrowableBuffer output,
    final HuffmanDecoder literalDecoder,
    final HuffmanDecoder distanceDecoder,
  ) {
    if (wide) {
      final done = _inflate(input, output, literalDecoder, distanceDecoder);
      if (done) return;
    }

    final limit = maxSize;

    while (true) {
      final symbol = input.decode(literalDecoder);

      if (symbol < 256) {
        // Literal byte
        if (limit != null && output.length >= limit) {
          throw LimitException(limit);
        }
        output.addByte(symbol);
      } else if (symbol == endBlock) {
        // End of block
        break;
      } else if (symbol <= 285) {
        // Length/distance pair
        final code = symbol - 257;

        // Decode length
        var length = lengthBase[code];
        final extra = lengthExtraBits[code];
        if (extra > 0) {
          length += input.read(extra);
        }

        // Check size limit before copy
        final limit = maxSize;
        if (limit != null && output.length + length > limit) {
          throw LimitException(limit);
        }

        // Decode distance
        final distanceCode = input.decode(distanceDecoder);
        if (distanceCode >= 30) {
          throw DeflateFormatException('Invalid distance code: $distanceCode');
        }

        var distance = distanceBase[distanceCode];
        final distanceExtra = distanceExtraBits[distanceCode];
        if (distanceExtra > 0) {
          distance += input.read(distanceExtra);
        }

        // Copy from history
        if (distance > output.length) {
          throw DeflateFormatException(
            'Distance exceeds output size: distance=$distance, '
            'outputLength=${output.length}, length=$length, distanceCode=$distanceCode',
          );
        }

        // Copy from history (handles overlapping copies internally).
        output.copyFromHistory(distance, length);
      } else {
        throw DeflateFormatException('Invalid literal/length symbol: $symbol');
      }
    }
  }

  /// Decodes symbols with the bit buffer held in locals (up to 63 bits on the
  /// VM) and writes straight into [output]'s backing array, while at least 16
  /// input bytes remain (a symbol needs at most 48 bits). Returns true at the
  /// end of the block; otherwise hands the exact bit position back to [input]
  /// for the general loop to finish the block.
  bool _inflate(
    final DeflateReader input,
    final GrowableBuffer output,
    final HuffmanDecoder literalDecoder,
    final HuffmanDecoder distanceDecoder,
  ) {
    final data = input.data;
    final view = ByteData.sublistView(data);
    final guard = input.end - 16;
    final literals = literalDecoder.table;
    final literalRoot = literalDecoder.root;
    final literalMask = (1 << literalRoot) - 1;
    final distances = distanceDecoder.table;
    final distanceRoot = distanceDecoder.root;
    final distanceMask = (1 << distanceRoot) - 1;
    final limit = maxSize ?? -1;

    var (next, hold, count) = input.state;
    output.reserve(_slack);
    var out = output.bytes;
    var words = ByteData.sublistView(out);
    var op = output.length;
    var done = false;
    // Below this, a symbol can be written without growing [out] or reaching
    // [limit].
    var stop = _stop(out.length, limit);

    while (next <= guard) {
      if (count < 48) {
        // One 8-byte load: the bits above [count] it overlaps are the same
        // input bits, so OR-ing them again changes nothing.
        hold |= view.getUint64(next, Endian.little) << count;
        final bytes = (63 - count) >> 3;
        next += bytes;
        count += bytes << 3;
      }
      if (op >= stop) {
        if (op + _slack > out.length) {
          output.length = op;
          output.reserve(_slack);
          out = output.bytes;
          words = ByteData.sublistView(out);
        }
        stop = _stop(out.length, limit);
      }

      var entry = literals[hold & literalMask];
      if (entry & 16 != 0) {
        entry =
            literals[(entry >> 5) +
                ((hold >>> literalRoot) & ((1 << (entry & 0xF)) - 1))];
      }
      if (entry == 0) throw DeflateFormatException('Invalid Huffman code');
      final used = entry & 0xF;
      hold >>>= used;
      count -= used;
      final symbol = entry >> 5;

      if (symbol < 256) {
        if (op == limit) throw LimitException(limit);
        out[op++] = symbol;
        continue;
      }
      if (symbol == endBlock) {
        done = true;
        break;
      }
      if (symbol > 285) {
        throw DeflateFormatException('Invalid literal/length symbol: $symbol');
      }

      final code = symbol - 257;
      final extra = _lengthExtraBits[code];
      final length = _lengthBase[code] + (hold & ((1 << extra) - 1));
      hold >>>= extra;
      count -= extra;
      if (limit >= 0 && op + length > limit) throw LimitException(limit);

      var distanceEntry = distances[hold & distanceMask];
      if (distanceEntry & 16 != 0) {
        distanceEntry =
            distances[(distanceEntry >> 5) +
                ((hold >>> distanceRoot) & ((1 << (distanceEntry & 0xF)) - 1))];
      }
      if (distanceEntry == 0) {
        throw DeflateFormatException('Invalid Huffman code');
      }
      final distanceUsed = distanceEntry & 0xF;
      hold >>>= distanceUsed;
      count -= distanceUsed;
      final distanceCode = distanceEntry >> 5;
      if (distanceCode >= 30) {
        throw DeflateFormatException('Invalid distance code: $distanceCode');
      }
      final distanceExtra = _distanceExtraBits[distanceCode];
      final distance =
          _distanceBase[distanceCode] + (hold & ((1 << distanceExtra) - 1));
      hold >>>= distanceExtra;
      count -= distanceExtra;

      if (distance > op) {
        throw DeflateFormatException(
          'Distance exceeds output size: distance=$distance, '
          'outputLength=$op, length=$length, distanceCode=$distanceCode',
        );
      }
      final from = op - distance;
      if (distance >= 8 && length <= 32) {
        // 8 bytes at a time: each word read was written before, and up to 7
        // bytes past the match are overwritten later (the slack keeps them
        // inside [out]).
        for (var i = 0; i < length; i += 8) {
          words.setUint64(
            op + i,
            words.getUint64(from + i, Endian.little),
            Endian.little,
          );
        }
      } else if (distance >= length) {
        out.setRange(op, op + length, out, from);
      } else if (distance == 1) {
        out.fillRange(op, op + length, out[from]);
      } else if (length <= 32) {
        for (var i = 0; i < length; i++) {
          out[op + i] = out[from + i];
        }
      } else {
        // Doubling copies of whole periods, as GrowableBuffer.copyFromHistory.
        var copied = distance;
        out.setRange(op, op + distance, out, from);
        while (copied < length) {
          final count = copied < length - copied ? copied : length - copied;
          out.setRange(op + copied, op + copied + count, out, from);
          copied += count;
        }
      }
      op += length;
    }

    output.length = op;
    // The 8-byte loads leave input bits above [count]; hand back only the
    // counted ones.
    input.resume(next, hold & ((1 << count) - 1), count);
    return done;
  }

  /// The output position at which [_inflate] must grow its buffer or check
  /// the limit: [_slack] short of the capacity, and no later
  /// than [limit] (-1 for none).
  static int _stop(final int capacity, final int limit) {
    final room = capacity - _slack;
    return limit >= 0 && limit < room ? limit : room;
  }
}
