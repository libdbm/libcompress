import 'dart:typed_data';

import 'backward_bit_reader.dart';
import 'fse_decoder.dart';
import 'sequence_constants.dart' as seq;
import 'zstd_common.dart';

enum SequenceComponent { literalLength, offset, matchLength }

/// An FSE decoding table for one sequence component (LL/Off/ML), held as one
/// typed array per field, indexed by state, so the sequence loop reads plain
/// integers.
class SequenceCodingTable {
  final int tableLog;
  final bool isPredefined;

  /// Symbol per state.
  final Uint8List symbols;

  /// Base value per state (offset bases reach 2^31, so 32 unsigned bits).
  final Uint32List bases;

  /// Additional (extra value) bits per state.
  final Uint8List extras;

  /// Bits read for the next state, per state.
  final Uint8List widths;

  /// Baseline of the next state, per state.
  final Uint16List nexts;

  SequenceCodingTable._(
    this.tableLog,
    this.isPredefined,
    this.symbols,
    this.bases,
    this.extras,
    this.widths,
    this.nexts,
  );

  /// A table of one state that always decodes [symbol] (RLE mode).
  factory SequenceCodingTable.rleSymbol(
    final SequenceComponent component,
    final int symbol,
  ) {
    final (baseTable, bitTable) = _tablesFor(component);
    return SequenceCodingTable._(
      0,
      false,
      Uint8List(1)..[0] = symbol,
      Uint32List(1)..[0] = baseTable[symbol],
      Uint8List(1)..[0] = bitTable[symbol],
      Uint8List(1),
      Uint16List(1),
    );
  }

  /// The decoding table of the normalized [counts] at accuracy log [log]
  /// (RFC 8878 section 4.1.1), built straight into the typed arrays: symbols
  /// with a count of -1 take the last states, the rest are spread with the
  /// standard step over the states below them, and each state gets the bits
  /// and baseline of its next state.
  ///
  /// [readNormalizedCounts] only returns counts that fill the table exactly,
  /// and the step is odd, so the spread visits each free state once.
  factory SequenceCodingTable.fromCounts(
    final List<int> counts,
    final int log,
    final SequenceComponent component, {
    final bool isPredefined = false,
  }) {
    final (baseTable, bitTable) = _tablesFor(component);
    final size = 1 << log;
    final mask = size - 1;
    final step = (size >> 1) + (size >> 3) + 3;
    final symbols = Uint8List(size);
    final next = Int32List(counts.length);

    var high = size - 1;
    for (var symbol = 0; symbol < counts.length; symbol++) {
      if (counts[symbol] == -1) {
        symbols[high--] = symbol;
        next[symbol] = 1;
      }
    }
    var position = 0;
    for (var symbol = 0; symbol < counts.length; symbol++) {
      final frequency = counts[symbol];
      if (frequency <= 0) continue;
      next[symbol] = frequency;
      for (var i = 0; i < frequency; i++) {
        symbols[position] = symbol;
        do {
          position = (position + step) & mask;
        } while (position > high);
      }
    }

    final bases = Uint32List(size);
    final extras = Uint8List(size);
    final widths = Uint8List(size);
    final nexts = Uint16List(size);
    for (var state = 0; state < size; state++) {
      final symbol = symbols[state];
      final following = next[symbol]++;
      final bits = log - (following.bitLength - 1);
      bases[state] = baseTable[symbol];
      extras[state] = bitTable[symbol];
      widths[state] = bits;
      nexts[state] = (following << bits) - size;
    }
    return SequenceCodingTable._(
      log,
      isPredefined,
      symbols,
      bases,
      extras,
      widths,
      nexts,
    );
  }

  bool get isRle => tableLog == 0;

  int initializeState(final BackwardBitReader reader) {
    if (tableLog == 0) {
      return 0;
    }
    return reader.readBits(tableLog);
  }
}

class _SequenceTableResult {
  final SequenceCodingTable table;
  final int nextOffset;

  _SequenceTableResult(this.table, this.nextOffset);
}

/// The base values and extra bits of [component]'s codes.
(List<int>, List<int>) _tablesFor(final SequenceComponent component) =>
    switch (component) {
      SequenceComponent.literalLength => (
        seq.literalLengthBase,
        seq.literalLengthBits,
      ),
      SequenceComponent.offset => (seq.offsetBase, seq.offsetBits),
      SequenceComponent.matchLength => (
        seq.matchLengthBase,
        seq.matchLengthBits,
      ),
    };

/// The literal length, offset and match length decoding tables of a
/// sequences section (RFC 8878 §3.1.1.3.2.1), keeping the last of each for
/// Repeat mode.
class SequenceTables {
  SequenceCodingTable? _cachedLiteralLengthTable;
  SequenceCodingTable? _cachedOffsetTable;
  SequenceCodingTable? _cachedMatchLengthTable;

  /// Clear cached state (should be called between frames)
  void reset() {
    _cachedLiteralLengthTable = null;
    _cachedOffsetTable = null;
    _cachedMatchLengthTable = null;
  }

  /// Reads the three tables at [offset] for the compression [modes] byte;
  /// returns them and the offset after their descriptions.
  (SequenceCodingTable, SequenceCodingTable, SequenceCodingTable, int) read(
    final Uint8List data,
    int offset,
    final int blockEnd,
    final int modes,
  ) {
    final literalLengthsMode = modes >> 6;
    final offsetsMode = (modes >> 4) & 0x03;
    final matchLengthsMode = (modes >> 2) & 0x03;

    final llTableResult = _readSequenceTable(
      data,
      offset,
      blockEnd,
      literalLengthsMode,
      _cachedLiteralLengthTable,
      _predefinedLiteralLengthTable,
      SequenceComponent.literalLength,
      maxSymbolValue: 35,
    );
    final literalLengthTable = llTableResult.table;
    offset = llTableResult.nextOffset;
    if (literalLengthsMode != 3) {
      _cachedLiteralLengthTable = literalLengthTable;
    }

    final ofTableResult = _readSequenceTable(
      data,
      offset,
      blockEnd,
      offsetsMode,
      _cachedOffsetTable,
      _predefinedOffsetTable,
      SequenceComponent.offset,
      maxSymbolValue: 31,
    );
    final offsetTable = ofTableResult.table;
    offset = ofTableResult.nextOffset;
    if (offsetsMode != 3) {
      _cachedOffsetTable = offsetTable;
    }

    final mlTableResult = _readSequenceTable(
      data,
      offset,
      blockEnd,
      matchLengthsMode,
      _cachedMatchLengthTable,
      _predefinedMatchLengthTable,
      SequenceComponent.matchLength,
      maxSymbolValue: 52,
    );
    final matchLengthTable = mlTableResult.table;
    offset = mlTableResult.nextOffset;
    if (matchLengthsMode != 3) {
      _cachedMatchLengthTable = matchLengthTable;
    }

    return (literalLengthTable, offsetTable, matchLengthTable, offset);
  }

  static final SequenceCodingTable _predefinedLiteralLengthTable =
      _buildPredefinedTable(
        seq.llDefaultNorm,
        seq.llDefaultNormLog,
        SequenceComponent.literalLength,
        isPredefined: true,
      );

  static final SequenceCodingTable _predefinedOffsetTable =
      _buildPredefinedTable(
        seq.ofDefaultNorm,
        seq.ofDefaultNormLog,
        SequenceComponent.offset,
        isPredefined: true,
      );

  static final SequenceCodingTable _predefinedMatchLengthTable =
      _buildPredefinedTable(
        seq.mlDefaultNorm,
        seq.mlDefaultNormLog,
        SequenceComponent.matchLength,
        isPredefined: true,
      );

  static SequenceCodingTable _buildPredefinedTable(
    final List<int> normalizedCounters,
    final int tableLog,
    final SequenceComponent component, {
    required final bool isPredefined,
  }) {
    return SequenceCodingTable.fromCounts(
      normalizedCounters,
      tableLog,
      component,
      isPredefined: isPredefined,
    );
  }

  _SequenceTableResult _readSequenceTable(
    final Uint8List data,
    final int offset,
    final int blockEnd,
    final int mode,
    final SequenceCodingTable? cached,
    final SequenceCodingTable predefined,
    final SequenceComponent component, {
    required final int maxSymbolValue,
  }) {
    // RFC 8878 Section 3.1.1.3.2.1:
    // Mode 0: Predefined
    // Mode 1: RLE
    // Mode 2: FSE compressed
    // Mode 3: Repeat (reuse from previous block)
    switch (mode) {
      case 0:
        return _SequenceTableResult(predefined, offset);
      case 1:
        if (offset >= blockEnd) {
          throw ZstdFormatException('RLE sequence table missing symbol byte');
        }
        final symbol = data[offset];
        if (symbol > maxSymbolValue) {
          throw ZstdFormatException(
            'RLE sequence symbol $symbol exceeds max $maxSymbolValue',
          );
        }
        return _SequenceTableResult(
          SequenceCodingTable.rleSymbol(component, symbol),
          offset + 1,
        );
      case 2:
        final result = _readFseSequenceTable(
          data,
          offset,
          blockEnd,
          maxSymbolValue,
          component,
        );
        return result;
      case 3:
        if (cached == null) {
          throw ZstdFormatException(
            'Repeat sequence table requested but none cached',
          );
        }
        return _SequenceTableResult(cached, offset);
      default:
        throw ZstdFormatException('Unsupported sequence table mode: $mode');
    }
  }

  _SequenceTableResult _readFseSequenceTable(
    final Uint8List data,
    final int offset,
    final int blockEnd,
    final int maxSymbolValue,
    final SequenceComponent component,
  ) {
    // RFC 8878 caps the FSE accuracy log per component (LL/ML 9, OF 8); reject
    // anything larger before a 1<<tableLog table is allocated.
    final maxTableLog = component == SequenceComponent.offset ? 8 : 9;
    final (counts, tableLog, nextOffset) = readNormalizedCounts(
      data,
      offset,
      blockEnd,
      maxSymbolValue,
      maxTableLog,
    );
    final table = SequenceCodingTable.fromCounts(counts, tableLog, component);
    return _SequenceTableResult(table, nextOffset);
  }
}
