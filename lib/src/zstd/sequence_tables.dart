import 'dart:typed_data';

import 'backward_bit_reader.dart';
import 'fse_decoder.dart';
import 'sequence_constants.dart' as seq;
import 'zstd_common.dart';

enum SequenceComponent { literalLength, offset, matchLength }

class SequenceSymbol {
  final int symbol;
  final int baseValue;
  final int additionalBits;
  final int numberOfBits;
  final int nextState;

  const SequenceSymbol({
    required this.symbol,
    required this.baseValue,
    required this.additionalBits,
    required this.numberOfBits,
    required this.nextState,
  });
}

/// Represents an FSE decoding table for sequence components (LL/Off/ML).
///
/// Besides [entries], the table is held as one typed array per field, indexed
/// by state, so the sequence loop reads plain integers instead of objects.
class SequenceCodingTable {
  final int tableLog;
  final List<SequenceSymbol> entries;
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

  SequenceCodingTable._({
    required this.tableLog,
    required this.entries,
    required this.isPredefined,
  }) : symbols = Uint8List.fromList([for (final e in entries) e.symbol]),
       bases = Uint32List.fromList([for (final e in entries) e.baseValue]),
       extras = Uint8List.fromList([for (final e in entries) e.additionalBits]),
       widths = Uint8List.fromList([for (final e in entries) e.numberOfBits]),
       nexts = Uint16List.fromList([for (final e in entries) e.nextState]);

  factory SequenceCodingTable.rleSymbol(
    final SequenceComponent component,
    final int symbolIndex,
  ) {
    return SequenceCodingTable._(
      tableLog: 0,
      entries: [
        _symbolForComponent(
          component,
          symbolIndex,
          numberOfBits: 0,
          nextState: 0,
        ),
      ],
      isPredefined: false,
    );
  }

  factory SequenceCodingTable.fromFse(
    final int tableLog,
    final List<FseStateEntry> entries,
    final SequenceComponent component, {
    final bool isPredefined = false,
  }) {
    final symbols = List<SequenceSymbol>.generate(entries.length, (
      final index,
    ) {
      final entry = entries[index];
      return _symbolForComponent(
        component,
        entry.symbol,
        numberOfBits: entry.numberOfBits,
        nextState: entry.baseline,
      );
    }, growable: false);

    return SequenceCodingTable._(
      tableLog: tableLog,
      entries: List<SequenceSymbol>.unmodifiable(symbols),
      isPredefined: isPredefined,
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

SequenceSymbol _symbolForComponent(
  final SequenceComponent component,
  final int symbolIndex, {
  required final int numberOfBits,
  required final int nextState,
}) {
  final base = _baseValueFor(component, symbolIndex);
  final extraBits = _extraBitsFor(component, symbolIndex);
  return SequenceSymbol(
    symbol: symbolIndex,
    baseValue: base,
    additionalBits: extraBits,
    numberOfBits: numberOfBits,
    nextState: nextState,
  );
}

int _baseValueFor(final SequenceComponent component, final int symbolIndex) {
  switch (component) {
    case SequenceComponent.literalLength:
      if (symbolIndex < 0 || symbolIndex >= seq.literalLengthBase.length) {
        throw ZstdFormatException(
          'Literal length symbol out of range: $symbolIndex',
        );
      }
      return seq.literalLengthBase[symbolIndex];
    case SequenceComponent.offset:
      if (symbolIndex < 0 || symbolIndex >= seq.offsetBase.length) {
        throw ZstdFormatException('Offset symbol out of range: $symbolIndex');
      }
      return seq.offsetBase[symbolIndex];
    case SequenceComponent.matchLength:
      if (symbolIndex < 0 || symbolIndex >= seq.matchLengthBase.length) {
        throw ZstdFormatException(
          'Match length symbol out of range: $symbolIndex',
        );
      }
      return seq.matchLengthBase[symbolIndex];
  }
}

int _extraBitsFor(final SequenceComponent component, final int symbolIndex) {
  switch (component) {
    case SequenceComponent.literalLength:
      if (symbolIndex < 0 || symbolIndex >= seq.literalLengthBits.length) {
        throw ZstdFormatException(
          'Literal length bits index out of range: $symbolIndex',
        );
      }
      return seq.literalLengthBits[symbolIndex];
    case SequenceComponent.offset:
      if (symbolIndex < 0 || symbolIndex >= seq.offsetBits.length) {
        throw ZstdFormatException(
          'Offset bits index out of range: $symbolIndex',
        );
      }
      return seq.offsetBits[symbolIndex];
    case SequenceComponent.matchLength:
      if (symbolIndex < 0 || symbolIndex >= seq.matchLengthBits.length) {
        throw ZstdFormatException(
          'Match length bits index out of range: $symbolIndex',
        );
      }
      return seq.matchLengthBits[symbolIndex];
  }
}

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
    final decoder = FseDecoder();
    decoder.buildTable(List<int>.from(normalizedCounters), tableLog);
    return SequenceCodingTable.fromFse(
      tableLog,
      decoder.tableEntries,
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
    final decoder = FseDecoder();
    decoder.buildTable(counts, tableLog);
    final table = SequenceCodingTable.fromFse(
      tableLog,
      decoder.tableEntries,
      component,
    );
    return _SequenceTableResult(table, nextOffset);
  }
}
