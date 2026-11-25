import 'dart:typed_data';
import 'sequence_constants.dart' as seq;
import 'sequences.dart';
import '../util/bit_stream.dart';

// Predefined (mode 0) FSE tables are built from compile-time constants and are
// immutable during encoding, so they are built once and shared across blocks.
final FseCompressionTable _predefinedLlTable = FseCompressionTable.create(
  seq.llDefaultNorm,
  seq.llDefaultNormLog,
  35,
);
final FseCompressionTable _predefinedOfTable = FseCompressionTable.create(
  seq.ofDefaultNorm,
  seq.ofDefaultNormLog,
  31,
);
final FseCompressionTable _predefinedMlTable = FseCompressionTable.create(
  seq.mlDefaultNorm,
  seq.mlDefaultNormLog,
  52,
);

/// The offset code of an `Offset_Value` (RFC 8878 section 3.1.1.3.2.1.1):
/// 1-3 for a repeat offset, the distance plus 3 otherwise. Code `n` covers
/// values `2^n .. 2^(n+1) - 1`, so it is the value's highest set bit.
int _offsetSymbol(final int value) {
  final symbol = value.bitLength - 1;
  if (value < 1 || symbol >= seq.offsetBase.length) {
    throw StateError('Unable to encode offset value $value');
  }
  return symbol;
}

/// Codes of literal and match lengths below 1024, from [_baseSymbol].
final Uint8List _literalCodes = _codes(seq.literalLengthBase);
final Uint8List _matchCodes = _codes(seq.matchLengthBase);

Uint8List _codes(final List<int> bases) =>
    Uint8List.fromList([for (var i = 0; i < 1024; i++) _baseSymbol(bases, i)]);

int _literalSymbol(final int length) => length < 1024
    ? _literalCodes[length]
    : _baseSymbol(seq.literalLengthBase, length);

int _matchSymbol(final int length) => length < 1024
    ? _matchCodes[length]
    : _baseSymbol(seq.matchLengthBase, length);

/// Largest index `i` with `bases[i] <= value`, for the strictly-increasing
/// literal-length and match-length base tables. Binary search replacing the
/// previous per-match linear scans; result is identical.
int _baseSymbol(final List<int> bases, final int value) {
  var lo = 0;
  var hi = bases.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (bases[mid] <= value) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

/// Sequence encoder using FSE with configurable tables
///
/// This implementation follows the Java aircompressor library's approach:
/// - Sequences are written forward but read backward by the decoder
/// - First sequence initializes states without writing state bits
/// - Subsequent sequences write state transition bits then extra bits
/// - Final states are written at the end, followed by end marker
class SequenceEncoder {
  late final FseCompressionTable? _llTable;
  late final FseCompressionTable? _ofTable;
  late final FseCompressionTable? _mlTable;

  /// Create encoder with custom modes and optional custom tables
  ///
  /// Mode 0: Predefined tables
  /// Mode 1: RLE (single symbol)
  /// Mode 2: Custom FSE tables (pass normalized counts + log)
  SequenceEncoder.withModes({
    required final int llMode,
    required final int ofMode,
    required final int mlMode,
    final List<int>? llNorm,
    final List<int>? ofNorm,
    final List<int>? mlNorm,
    final int? llLog,
    final int? ofLog,
    final int? mlLog,
  }) {
    // Build LL table
    if (llMode == 0) {
      _llTable = _predefinedLlTable;
    } else if (llMode == 2 && llNorm != null && llLog != null) {
      _llTable = FseCompressionTable.create(llNorm, llLog, 35);
    } else {
      _llTable = null;
    }

    // Build OF table
    if (ofMode == 0) {
      _ofTable = _predefinedOfTable;
    } else if (ofMode == 2 && ofNorm != null && ofLog != null) {
      _ofTable = FseCompressionTable.create(ofNorm, ofLog, 31);
    } else {
      _ofTable = null;
    }

    // Build ML table
    if (mlMode == 0) {
      _mlTable = _predefinedMlTable;
    } else if (mlMode == 2 && mlNorm != null && mlLog != null) {
      _mlTable = FseCompressionTable.create(mlNorm, mlLog, 52);
    } else {
      _mlTable = null;
    }
  }

  /// Encode sequences using tANS/FSE with configured tables
  ///
  /// [codes] must hold the codes of [sequences] (see [SequenceCodes]).
  /// Returns the encoded bitstream (excluding sequence count header)
  Uint8List encodeSequences(
    final Sequences sequences,
    final SequenceCodes codes,
  ) {
    final count = sequences.count;
    if (count == 0) {
      return Uint8List(0);
    }

    final literalCodes = codes.literals;
    final offsetCodes = codes.offsets;
    final matchCodes = codes.matches;
    final stream = BitStreamWriter();

    // Initialize states from last sequence's symbols (no bits written yet)
    // RLE mode (mode 1) doesn't need state tracking
    final last = count - 1;
    var mlState = _mlTable?.begin(matchCodes[last]) ?? 0;
    var ofState = _ofTable?.begin(offsetCodes[last]) ?? 0;
    var llState = _llTable?.begin(literalCodes[last]) ?? 0;

    // Write first sequence's extra bits (literal length, match length, offset)
    _writeExtras(stream, sequences, codes, last);

    // Encode remaining sequences in reverse order
    for (var i = count - 2; i >= 0; i--) {
      // Write state transition bits (offset, match, literal order)
      // RLE mode doesn't write state bits - symbol is constant
      if (_ofTable != null) {
        ofState = _ofTable.encode(stream, ofState, offsetCodes[i]);
      }
      if (_mlTable != null) {
        mlState = _mlTable.encode(stream, mlState, matchCodes[i]);
      }
      if (_llTable != null) {
        llState = _llTable.encode(stream, llState, literalCodes[i]);
      }

      // Write extra bits (the writer emits whole bytes as it goes)
      _writeExtras(stream, sequences, codes, i);
    }

    // Write final states (skip for RLE mode)
    if (_mlTable != null) {
      _mlTable.finish(stream, mlState);
    }
    if (_ofTable != null) {
      _ofTable.finish(stream, ofState);
    }
    if (_llTable != null) {
      _llTable.finish(stream, llState);
    }

    // End-of-stream marker bit, then pad to a byte.
    stream.writeBits(1, 1);
    return stream.toBytes();
  }

  /// Writes the extra bits of sequence [index]: literal length, match length,
  /// then offset (the `Offset_Value` less `2^code`).
  void _writeExtras(
    final BitStreamWriter stream,
    final Sequences sequences,
    final SequenceCodes codes,
    final int index,
  ) {
    final literal = codes.literals[index];
    stream.writeBits(
      sequences.literals[index] - seq.literalLengthBase[literal],
      _literalExtraBits(literal),
    );
    final match = codes.matches[index];
    stream.writeBits(
      sequences.lengths[index] - seq.matchLengthBase[match],
      _matchExtraBits(match),
    );
    final offset = codes.offsets[index];
    stream.writeBits(
      sequences.offsets[index] - (1 << offset),
      seq.offsetBits[offset],
    );
  }

  int _literalExtraBits(final int symbol) =>
      symbol < seq.literalLengthBits.length ? seq.literalLengthBits[symbol] : 0;

  int _matchExtraBits(final int symbol) =>
      symbol < seq.matchLengthBits.length ? seq.matchLengthBits[symbol] : 0;
}

/// The literal-length, offset and match-length codes of a block's
/// [Sequences], computed once for both the FSE statistics and the encoder.
///
/// The lists are reused from block to block, so only the first
/// `sequences.count` entries are codes, and only until the next [compute].
final class SequenceCodes {
  Uint8List _literals = Uint8List(0);
  Uint8List _offsets = Uint8List(0);
  Uint8List _matches = Uint8List(0);

  /// Literal-length codes (0..35).
  Uint8List get literals => _literals;

  /// Offset codes (0..31), from `Offset_Value`s.
  Uint8List get offsets => _offsets;

  /// Match-length codes (0..52).
  Uint8List get matches => _matches;

  /// Computes the codes of [sequences].
  void compute(final Sequences sequences) {
    final count = sequences.count;
    if (_literals.length < count) {
      _literals = Uint8List(count);
      _offsets = Uint8List(count);
      _matches = Uint8List(count);
    }
    final literals = sequences.literals;
    final offsets = sequences.offsets;
    final lengths = sequences.lengths;
    for (var i = 0; i < count; i++) {
      _literals[i] = _literalSymbol(literals[i]);
      _offsets[i] = _offsetSymbol(offsets[i]);
      _matches[i] = _matchSymbol(lengths[i]);
    }
  }
}

/// FSE compression table following Java aircompressor implementation
class FseCompressionTable {
  final int tableLog;
  final List<int> _nextState;
  final List<int> _deltaNumberOfBits;
  final List<int> _deltaFindState;

  FseCompressionTable._(
    this.tableLog,
    this._nextState,
    this._deltaNumberOfBits,
    this._deltaFindState,
  );

  factory FseCompressionTable.create(
    final List<int> normalized,
    final int log,
    final int maxSymbol,
  ) {
    final tableSize = 1 << log;
    final table = List<int>.filled(tableSize, 0);
    var highThreshold = tableSize - 1;

    // Symbol start positions
    final cumulative = List<int>.filled(maxSymbol + 2, 0);
    for (var i = 1; i <= maxSymbol + 1; i++) {
      if (i - 1 < normalized.length && normalized[i - 1] == -1) {
        cumulative[i] = cumulative[i - 1] + 1;
        table[highThreshold--] = i - 1;
      } else {
        final count = (i - 1 < normalized.length) ? normalized[i - 1] : 0;
        cumulative[i] = cumulative[i - 1] + (count < 0 ? 0 : count);
      }
    }

    // Spread symbols
    final step = (tableSize >> 1) + (tableSize >> 3) + 3;
    final mask = tableSize - 1;
    var position = 0;

    for (var symbol = 0; symbol <= maxSymbol; symbol++) {
      final count = (symbol < normalized.length && normalized[symbol] > 0)
          ? normalized[symbol]
          : 0;
      for (var i = 0; i < count; i++) {
        table[position] = symbol;
        do {
          position = (position + step) & mask;
        } while (position > highThreshold);
      }
    }

    // Build nextState table
    final cumulativeCopy = List<int>.from(cumulative);
    final nextState = List<int>.filled(tableSize, 0);
    for (var i = 0; i < tableSize; i++) {
      final symbol = table[i];
      nextState[cumulativeCopy[symbol]++] = tableSize + i;
    }

    // Build symbol transformation tables
    final deltaNumberOfBits = List<int>.filled(maxSymbol + 1, 0);
    final deltaFindState = List<int>.filled(maxSymbol + 1, 0);
    var total = 0;

    for (var symbol = 0; symbol <= maxSymbol; symbol++) {
      final count = (symbol < normalized.length) ? normalized[symbol] : 0;
      if (count == 0) {
        deltaNumberOfBits[symbol] = ((log + 1) << 16) - tableSize;
      } else if (count == -1 || count == 1) {
        deltaNumberOfBits[symbol] = (log << 16) - tableSize;
        deltaFindState[symbol] = total - 1;
        total++;
      } else if (count > 1) {
        final maxBitsOut = log - ((count - 1).bitLength - 1);
        final minStatePlus = count << maxBitsOut;
        deltaNumberOfBits[symbol] = (maxBitsOut << 16) - minStatePlus;
        deltaFindState[symbol] = total - count;
        total += count;
      }
    }

    return FseCompressionTable._(
      log,
      nextState,
      deltaNumberOfBits,
      deltaFindState,
    );
  }

  /// Get initial state for a symbol (no bits written)
  int begin(final int symbol) {
    final outputBits = (_deltaNumberOfBits[symbol] + (1 << 15)) >> 16;
    final base =
        ((outputBits << 16) - _deltaNumberOfBits[symbol]) >> outputBits;
    return _nextState[base + _deltaFindState[symbol]];
  }

  /// Encode symbol: write low bits of state, return next state
  int encode(final BitStreamWriter stream, final int state, final int symbol) {
    final outputBits = (state + _deltaNumberOfBits[symbol]) >> 16;
    stream.writeBits(state, outputBits);
    return _nextState[(state >> outputBits) + _deltaFindState[symbol]];
  }

  /// Write final state bits
  void finish(final BitStreamWriter stream, final int state) {
    stream.writeBits(state, tableLog);
  }
}
