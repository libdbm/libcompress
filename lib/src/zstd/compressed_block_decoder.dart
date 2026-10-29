import 'dart:typed_data';

import '../util/byte_sink.dart';
import 'backward_bit_reader.dart';
import 'literals_decoder.dart';
import 'sequence_tables.dart';
import 'zstd_common.dart';
import '../util/platform.dart';

export 'sequence_tables.dart' show SequenceComponent;

/// The output of one block: writes go to [output] and may not take it past
/// [end], the block's maximum size.
class BlockOutput implements ByteSink {
  BlockOutput(this.output, final int maxBlockSize)
    : end = output.length + maxBlockSize;

  final ByteSink output;
  final int end;

  @override
  int get length => output.length;

  void _check(final int count) {
    if (count < 0 || count > end - length) {
      throw ZstdFormatException('Regenerated block exceeds maximum block size');
    }
  }

  @override
  void addByte(final int byte) {
    _check(1);
    output.addByte(byte);
  }

  @override
  void addBytes(
    final List<int> bytes, [
    final int offset = 0,
    final int? count,
  ]) {
    final size = count ?? bytes.length - offset;
    _check(size);
    output.addBytes(bytes, offset, size);
  }

  @override
  void copyFromHistory(final int distance, final int length) {
    _check(length);
    output.copyFromHistory(distance, length);
  }
}

/// Decoder for Zstd compressed blocks
///
/// Maintains state for Huffman tree persistence to support "treeless" mode
/// where blocks can reuse the Huffman tree from a previous block.
class CompressedBlockDecoder {
  CompressedBlockDecoder() {
    reset();
  }

  final LiteralsDecoder _literals = LiteralsDecoder();
  final SequenceTables _tables = SequenceTables();

  /// Clear cached state (should be called between frames)
  void reset() {
    _literals.reset();
    _tables.reset();
  }

  /// Decode a compressed block
  ///
  /// [windowSize] is used to validate that match offsets don't exceed
  /// the declared window size. If null, no window size validation is performed.
  void decodeBlock(
    final Uint8List data,
    final int offset,
    final int blockSize,
    final ByteSink output,
    final List<int> previousOffsets, {
    final int? windowSize,
  }) {
    final blockEnd = offset + blockSize;

    if (blockEnd > data.length) {
      throw ZstdFormatException(
        'Compressed block extends beyond input data: '
        'offset=$offset, blockSize=$blockSize, dataLength=${data.length}',
      );
    }

    var pos = offset;

    // Decode literals section
    final literalsResult = _literals.decode(data, pos, blockEnd);
    final literals = literalsResult.$1;
    pos = literalsResult.$2;

    // Decode and execute the sequences section in a single pass (no
    // intermediate per-sequence objects or second traversal).
    _decodeAndExecuteSequencesSection(
      data,
      pos,
      blockEnd,
      literals,
      output,
      previousOffsets,
      windowSize,
    );
  }

  void _decodeAndExecuteSequencesSection(
    final Uint8List data,
    int offset,
    final int blockEnd,
    final Uint8List literals,
    final ByteSink output,
    final List<int> previousOffsets,
    final int? windowSize,
  ) {
    if (offset >= blockEnd) {
      throw ZstdFormatException('Missing Number_of_Sequences');
    }

    // Read sequence count
    final firstByte = data[offset++];
    var numSequences = 0;

    if (firstByte == 0) {
      output.addBytes(literals, 0, literals.length);
      return;
    } else if (firstByte < 128) {
      numSequences = firstByte;
    } else if (firstByte < 255) {
      if (offset >= blockEnd) {
        throw ZstdFormatException('Incomplete sequence count header');
      }
      numSequences = ((firstByte - 128) << 8) + data[offset++];
    } else {
      if (offset + 2 > blockEnd) {
        throw ZstdFormatException('Incomplete sequence count header');
      }
      numSequences = data[offset] + (data[offset + 1] << 8) + 0x7F00;
      offset += 2;
    }

    if (numSequences == 0) {
      output.addBytes(literals, 0, literals.length);
      return;
    }

    if (offset >= blockEnd) {
      throw ZstdFormatException('Missing sequence compression modes');
    }
    final modes = data[offset++];
    if (modes & 0x03 != 0) {
      throw ZstdFormatException('Sequence compression modes reserved bits set');
    }

    final (literalLengthTable, offsetTable, matchLengthTable, next) = _tables
        .read(data, offset, blockEnd, modes);
    offset = next;

    if (offset > blockEnd) {
      throw ZstdFormatException('Sequence headers exceed block boundary');
    }

    _decodeAndExecuteSequences(
      data,
      offset,
      blockEnd,
      numSequences,
      literalLengthTable,
      offsetTable,
      matchLengthTable,
      literals,
      output,
      previousOffsets,
      windowSize,
    );
  }

  void _decodeAndExecuteSequences(
    final Uint8List data,
    final int bitstreamStart,
    final int blockEnd,
    final int count,
    final SequenceCodingTable literalLengthTable,
    final SequenceCodingTable offsetTable,
    final SequenceCodingTable matchLengthTable,
    final Uint8List literals,
    final ByteSink output,
    final List<int> previousOffsets,
    final int? windowSize,
  ) {
    final reader = BackwardBitReader(data, bitstreamStart, blockEnd);

    // Initialize states: LL, OF, ML (in that order per RFC 8878)
    var llState = literalLengthTable.initializeState(reader);
    var ofState = offsetTable.initializeState(reader);
    var mlState = matchLengthTable.initializeState(reader);

    // Table fields as typed arrays indexed by state, and the frame's repeat
    // offsets in locals for the block (written back below).
    final llBases = literalLengthTable.bases;
    final llExtras = literalLengthTable.extras;
    final llWidths = literalLengthTable.widths;
    final llNexts = literalLengthTable.nexts;
    final ofSymbols = offsetTable.symbols;
    final ofBases = offsetTable.bases;
    final ofExtras = offsetTable.extras;
    final ofWidths = offsetTable.widths;
    final ofNexts = offsetTable.nexts;
    final mlBases = matchLengthTable.bases;
    final mlExtras = matchLengthTable.extras;
    final mlWidths = matchLengthTable.widths;
    final mlNexts = matchLengthTable.nexts;
    var rep0 = previousOffsets[0];
    var rep1 = previousOffsets[1];
    var rep2 = previousOffsets[2];

    var literalPos = 0;
    final last = count - 1;
    var first = 0;

    // On the VM, decode while at least 16 bitstream bytes remain with the
    // 64-bit window in locals, writing straight into the output's array. A
    // sequence reads at most 89 bits, so each reload within it is a full
    // 8-byte load. The loop below finishes the block from the same position.
    if (wide && output is BlockOutput && output.output is DirectSink) {
      final sink = output.output as DirectSink;
      final view = ByteData.sublistView(data);
      final minimum = bitstreamStart + 16;
      var current = reader.current;
      var consumed = reader.consumed;
      var container = 0;
      var out = sink.bytes;
      var op = sink.position;
      // Indices in [out]: the oldest byte a match may read, the last byte
      // writable without reserving, and the block's end.
      var floor = sink.floor;
      var room = sink.room;
      var end = output.end - (sink.length - op);

      while (first < last) {
        final next = current - (consumed >> 3);
        if (next < minimum) break;
        current = next;
        consumed &= 7;
        container = view.getUint64(current, Endian.little);

        final ofCode = ofSymbols[ofState];
        final ofExtra = ofExtras[ofState];
        var offsetValue = ofBases[ofState];
        if (ofExtra > 0) {
          offsetValue += (container << consumed) >>> (64 - ofExtra);
          consumed += ofExtra;
        }

        current -= consumed >> 3;
        consumed &= 7;
        container = view.getUint64(current, Endian.little);
        final mlExtra = mlExtras[mlState];
        var matchLength = mlBases[mlState];
        if (mlExtra > 0) {
          matchLength += (container << consumed) >>> (64 - mlExtra);
          consumed += mlExtra;
        }
        final llExtra = llExtras[llState];
        var literalLength = llBases[llState];
        if (llExtra > 0) {
          literalLength += (container << consumed) >>> (64 - llExtra);
          consumed += llExtra;
        }

        current -= consumed >> 3;
        consumed &= 7;
        container = view.getUint64(current, Endian.little);
        final llWidth = llWidths[llState];
        var llNext = llNexts[llState];
        if (llWidth > 0) {
          llNext += (container << consumed) >>> (64 - llWidth);
          consumed += llWidth;
        }
        final mlWidth = mlWidths[mlState];
        var mlNext = mlNexts[mlState];
        if (mlWidth > 0) {
          mlNext += (container << consumed) >>> (64 - mlWidth);
          consumed += mlWidth;
        }
        final ofWidth = ofWidths[ofState];
        var ofNext = ofNexts[ofState];
        if (ofWidth > 0) {
          ofNext += (container << consumed) >>> (64 - ofWidth);
          consumed += ofWidth;
        }
        llState = llNext;
        mlState = mlNext;
        ofState = ofNext;

        if (literalPos + literalLength > literals.length) {
          throw ZstdFormatException(
            'Sequence needs $literalLength literals but only '
            '${literals.length - literalPos} remain',
          );
        }
        final size = literalLength + matchLength;
        if (size > end - op) {
          throw ZstdFormatException(
            'Regenerated block exceeds maximum block size',
          );
        }
        if (op + size > room) {
          sink.position = op;
          sink.reserve(size);
          out = sink.bytes;
          op = sink.position;
          floor = sink.floor;
          room = sink.room;
          end = output.end - (sink.length - op);
        }
        if (literalLength <= 16) {
          for (var i = 0; i < literalLength; i++) {
            out[op + i] = literals[literalPos + i];
          }
        } else {
          out.setRange(op, op + literalLength, literals, literalPos);
        }
        op += literalLength;
        literalPos += literalLength;

        if (matchLength > 0) {
          // As the loop below: offset codes 0 and 1 select repeat offsets.
          var repeat = ofCode == 0 ? 0 : (ofCode == 1 ? offsetValue : 4);
          if (ofCode <= 1 && literalLength == 0) repeat++;
          final int offset;
          if (repeat <= 3) {
            final temp = switch (repeat) {
              0 => rep0,
              1 => rep1,
              2 => rep2,
              _ => rep0 - 1,
            };
            if (temp == 0) {
              throw ZstdFormatException('Repeat offset resolves to 0');
            }
            switch (repeat) {
              case 1:
                rep1 = rep0;
                rep0 = temp;
              case 2:
              case 3:
                rep2 = rep1;
                rep1 = rep0;
                rep0 = temp;
            }
            offset = temp;
          } else {
            rep2 = rep1;
            rep1 = rep0;
            rep0 = offsetValue;
            offset = offsetValue;
          }
          if (windowSize != null && offset > windowSize) {
            throw ZstdFormatException(
              'Match offset $offset exceeds window size $windowSize',
            );
          }
          if (offset > op - floor) {
            throw ZstdFormatException(
              'Match offset $offset exceeds available ${op - floor} '
              '(literalLength=$literalLength, matchLength=$matchLength)',
            );
          }
          final from = op - offset;
          if (offset >= matchLength) {
            if (matchLength <= 16) {
              for (var i = 0; i < matchLength; i++) {
                out[op + i] = out[from + i];
              }
            } else {
              out.setRange(op, op + matchLength, out, from);
            }
          } else if (offset == 1) {
            out.fillRange(op, op + matchLength, out[from]);
          } else if (matchLength <= 32) {
            for (var i = 0; i < matchLength; i++) {
              out[op + i] = out[from + i];
            }
          } else {
            // Doubling copies of whole periods.
            var copied = offset;
            out.setRange(op, op + offset, out, from);
            while (copied < matchLength) {
              final count = copied < matchLength - copied
                  ? copied
                  : matchLength - copied;
              out.setRange(op + copied, op + copied + count, out, from);
              copied += count;
            }
          }
          op += matchLength;
        }
        first++;
      }

      sink.position = op;
      reader.resume(current, consumed);
    }

    for (var seqIndex = first; seqIndex < count; seqIndex++) {
      // Reload bits at start of each sequence
      reader.load();
      if (reader.isOverflow) {
        throw ZstdFormatException(
          'Bitstream overflow at sequence $seqIndex of $count',
        );
      }

      // Step 1: Look up symbols from current states (NO bit reads)
      final ofCode = ofSymbols[ofState];
      final ofExtra = ofExtras[ofState];
      final mlExtra = mlExtras[mlState];
      final llExtra = llExtras[llState];

      // Step 2: Read offset extra bits first
      final offsetValue =
          ofBases[ofState] + (ofExtra > 0 ? reader.readBits(ofExtra) : 0);

      // The 64-bit window holds ~57 readable bits after a reload, but offset +
      // ML + LL extra bits + the three FSE state transitions can exceed that.
      // Reload after the (largest) offset bits and again before the state
      // updates so no read segment overruns the window (which would otherwise
      // read zeros and silently corrupt output). load() is a transparent refill
      // — it preserves the logical bit position — so this never changes the
      // result for sequences that already fit.
      reader.load();

      // Steps 3-4: match length, then literal length extra bits
      final matchLength =
          mlBases[mlState] + (mlExtra > 0 ? reader.readBits(mlExtra) : 0);
      final literalLength =
          llBases[llState] + (llExtra > 0 ? reader.readBits(llExtra) : 0);

      // Step 5: Update states by reading bits (LL, ML, OF order per RFC)
      // Don't update on last sequence
      if (seqIndex < last) {
        reader.load();
        final llWidth = llWidths[llState];
        llState =
            llNexts[llState] + (llWidth > 0 ? reader.readBits(llWidth) : 0);
        final mlWidth = mlWidths[mlState];
        mlState =
            mlNexts[mlState] + (mlWidth > 0 ? reader.readBits(mlWidth) : 0);
        final ofWidth = ofWidths[ofState];
        ofState =
            ofNexts[ofState] + (ofWidth > 0 ? reader.readBits(ofWidth) : 0);
      }

      // Step 6: Execute immediately — copy literals, then the match. The
      // repeat-offset state evolves in sequence order exactly as before, so
      // fusing decode and execution is behaviour-preserving.
      if (literalLength > 0) {
        if (literalPos + literalLength > literals.length) {
          throw ZstdFormatException(
            'Sequence needs $literalLength literals but only '
            '${literals.length - literalPos} remain',
          );
        }
        output.addBytes(literals, literalPos, literalLength);
        literalPos += literalLength;
      }
      if (matchLength > 0) {
        // Offset codes 0 and 1 select repeat offsets (RFC 8878 §3.1.1.5);
        // with no literals the choice shifts by one.
        var repeat = ofCode == 0 ? 0 : (ofCode == 1 ? offsetValue : 4);
        if (ofCode <= 1 && literalLength == 0) repeat++;
        final int offset;
        if (repeat <= 3) {
          final temp = switch (repeat) {
            0 => rep0,
            1 => rep1,
            2 => rep2,
            _ => rep0 - 1,
          };
          if (temp == 0) {
            throw ZstdFormatException('Repeat offset resolves to 0');
          }
          switch (repeat) {
            case 1:
              rep1 = rep0;
              rep0 = temp;
            case 2:
              rep2 = rep1;
              rep1 = rep0;
              rep0 = temp;
            case 3:
              rep2 = rep1;
              rep1 = rep0;
              rep0 = temp;
          }
          offset = temp;
        } else {
          // Absolute offset: update history with new offset
          rep2 = rep1;
          rep1 = rep0;
          rep0 = offsetValue;
          offset = offsetValue;
        }
        if (windowSize != null && offset > windowSize) {
          throw ZstdFormatException(
            'Match offset $offset exceeds window size $windowSize',
          );
        }
        final available = output.length;
        if (offset > available) {
          throw ZstdFormatException(
            'Match offset $offset exceeds available $available '
            '(literalLength=$literalLength, matchLength=$matchLength)',
          );
        }
        output.copyFromHistory(offset, matchLength);
      }
    }

    previousOffsets[0] = rep0;
    previousOffsets[1] = rep1;
    previousOffsets[2] = rep2;

    reader.finish();

    // Copy any remaining literals after the last sequence.
    if (literalPos < literals.length) {
      output.addBytes(literals, literalPos, literals.length - literalPos);
    }
  }
}
