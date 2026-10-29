import 'dart:typed_data';
import 'sequence_constants.dart' as seq;
import 'match_finder.dart';
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

/// The offset code of absolute [offset] (RFC 8878 §3.1.1.3.2.1.1): Offset_Value
/// is offset + 3, and code `n` covers values `2^n .. 2^(n+1) - 1`, so the code
/// is the highest set bit of offset + 3 (`offsetBase[n]` is `2^n - 3`).
int _offsetSymbol(final int offset) {
  final symbol = (offset + 3).bitLength - 1;
  if (offset < 1 || symbol >= seq.offsetBase.length) {
    throw StateError('Unable to encode offset $offset');
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
  /// Returns the encoded bitstream (excluding sequence count header)
  Uint8List encodeSequences(final List<ZstdMatch> matches) {
    if (matches.isEmpty) {
      return Uint8List(0);
    }

    final tokens = _buildTokens(matches);
    final stream = BitStreamWriter();
    final count = tokens.length;

    // Initialize states from last sequence's symbols (no bits written yet)
    // RLE mode (mode 1) doesn't need state tracking
    var mlState = _mlTable?.begin(tokens[count - 1].matchSymbol) ?? 0;
    var ofState = _ofTable?.begin(tokens[count - 1].offsetSymbol) ?? 0;
    var llState = _llTable?.begin(tokens[count - 1].literalSymbol) ?? 0;

    // Write first sequence's extra bits (literal length, match length, offset)
    final first = tokens[count - 1];
    stream.writeBits(first.literalExtraValue, first.literalExtraBits);
    stream.writeBits(first.matchExtraValue, first.matchExtraBits);
    stream.writeBits(first.offsetAdditional, first.offsetExtraBits);

    // Encode remaining sequences in reverse order
    if (count >= 2) {
      for (var i = count - 2; i >= 0; i--) {
        final token = tokens[i];

        // Write state transition bits (offset, match, literal order)
        // RLE mode doesn't write state bits - symbol is constant
        if (_ofTable != null) {
          ofState = _ofTable.encode(stream, ofState, token.offsetSymbol);
        }
        if (_mlTable != null) {
          mlState = _mlTable.encode(stream, mlState, token.matchSymbol);
        }
        if (_llTable != null) {
          llState = _llTable.encode(stream, llState, token.literalSymbol);
        }

        // Write extra bits (the writer emits whole bytes as it goes)
        stream.writeBits(token.literalExtraValue, token.literalExtraBits);
        stream.writeBits(token.matchExtraValue, token.matchExtraBits);
        stream.writeBits(token.offsetAdditional, token.offsetExtraBits);
      }
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

  List<_SequenceToken> _buildTokens(final List<ZstdMatch> matches) {
    final tokens = <_SequenceToken>[];

    for (final match in matches) {
      final llSymbol = _literalSymbol(match.literalLength);
      final mlSymbol = _matchSymbol(match.length);
      final offsetEncoding = _encodeOffsetSymbol(match.offset);

      final llBase = seq.literalLengthBase[llSymbol];
      final mlBase = seq.matchLengthBase[mlSymbol];

      tokens.add(
        _SequenceToken(
          literalSymbol: llSymbol,
          literalExtraBits: _literalExtraBits(llSymbol),
          literalExtraValue: match.literalLength - llBase,
          matchSymbol: mlSymbol,
          matchExtraBits: _matchExtraBits(mlSymbol),
          matchExtraValue: match.length - mlBase,
          offsetSymbol: offsetEncoding.symbol,
          offsetExtraBits: offsetEncoding.bits,
          offsetAdditional: offsetEncoding.value,
        ),
      );
    }

    return tokens;
  }

  int _literalExtraBits(final int symbol) =>
      symbol < seq.literalLengthBits.length ? seq.literalLengthBits[symbol] : 0;

  int _matchExtraBits(final int symbol) =>
      symbol < seq.matchLengthBits.length ? seq.matchLengthBits[symbol] : 0;

  _OffsetEncoding _encodeOffsetSymbol(final int offset) {
    // Encode absolute offsets only. Repeat-offset symbols are frame stateful
    // across blocks; this encoder builds each block independently.
    final symbol = _offsetSymbol(offset);
    final base = seq.offsetBase[symbol];
    final bits = seq.offsetBits[symbol];
    final value = offset - base;

    return _OffsetEncoding(symbol: symbol, bits: bits, value: value);
  }
}

class _OffsetEncoding {
  final int symbol;
  final int bits;
  final int value;

  const _OffsetEncoding({
    required this.symbol,
    required this.bits,
    required this.value,
  });
}

/// Extracted sequence symbols for FSE table building
class SequenceSymbols {
  final List<int> literalLengths;
  final List<int> offsets;
  final List<int> matchLengths;

  const SequenceSymbols({
    required this.literalLengths,
    required this.offsets,
    required this.matchLengths,
  });

  /// Extract actual symbols from matches including repeat offset handling.
  ///
  /// This must be used to compute FSE statistics to ensure they match
  /// what SequenceEncoder will actually encode.
  factory SequenceSymbols.from(final List<ZstdMatch> matches) {
    final llSymbols = <int>[];
    final ofSymbols = <int>[];
    final mlSymbols = <int>[];
    // Absolute offsets only, as SequenceEncoder writes them.
    for (final match in matches) {
      llSymbols.add(_literalSymbol(match.literalLength));
      mlSymbols.add(_matchSymbol(match.length));
      ofSymbols.add(_offsetSymbol(match.offset));
    }

    return SequenceSymbols(
      literalLengths: llSymbols,
      offsets: ofSymbols,
      matchLengths: mlSymbols,
    );
  }
}

class _SequenceToken {
  final int literalSymbol;
  final int literalExtraBits;
  final int literalExtraValue;
  final int matchSymbol;
  final int matchExtraBits;
  final int matchExtraValue;
  final int offsetSymbol;
  final int offsetExtraBits;
  final int offsetAdditional;

  const _SequenceToken({
    required this.literalSymbol,
    required this.literalExtraBits,
    required this.literalExtraValue,
    required this.matchSymbol,
    required this.matchExtraBits,
    required this.matchExtraValue,
    required this.offsetSymbol,
    required this.offsetExtraBits,
    required this.offsetAdditional,
  });
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
