import 'dart:typed_data';
import 'sequence_constants.dart' as seq;
import 'match_finder.dart';

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

  /// Create encoder with predefined tables (mode 0 for all)
  SequenceEncoder() {
    _llTable = FseCompressionTable.create(
      seq.llDefaultNorm,
      seq.llDefaultNormLog,
      35,
    );
    _ofTable = FseCompressionTable.create(
      seq.ofDefaultNorm,
      seq.ofDefaultNormLog,
      28,
    );
    _mlTable = FseCompressionTable.create(
      seq.mlDefaultNorm,
      seq.mlDefaultNormLog,
      52,
    );
  }

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
      _llTable = FseCompressionTable.create(
        seq.llDefaultNorm,
        seq.llDefaultNormLog,
        35,
      );
    } else if (llMode == 2 && llNorm != null && llLog != null) {
      _llTable = FseCompressionTable.create(llNorm, llLog, 35);
    } else {
      _llTable = null;
    }

    // Build OF table
    if (ofMode == 0) {
      _ofTable = FseCompressionTable.create(
        seq.ofDefaultNorm,
        seq.ofDefaultNormLog,
        31,
      );
    } else if (ofMode == 2 && ofNorm != null && ofLog != null) {
      _ofTable = FseCompressionTable.create(ofNorm, ofLog, 31);
    } else {
      _ofTable = null;
    }

    // Build ML table
    if (mlMode == 0) {
      _mlTable = FseCompressionTable.create(
        seq.mlDefaultNorm,
        seq.mlDefaultNormLog,
        52,
      );
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
    final stream = BitOutputStream();
    final count = tokens.length;

    // Initialize states from last sequence's symbols (no bits written yet)
    // RLE mode (mode 1) doesn't need state tracking
    var mlState = _mlTable?.begin(tokens[count - 1].matchSymbol) ?? 0;
    var ofState = _ofTable?.begin(tokens[count - 1].offsetSymbol) ?? 0;
    var llState = _llTable?.begin(tokens[count - 1].literalSymbol) ?? 0;

    // Write first sequence's extra bits (literal length, match length, offset)
    final first = tokens[count - 1];
    stream.addBits(first.literalExtraValue, first.literalExtraBits);
    stream.addBits(first.matchExtraValue, first.matchExtraBits);
    stream.addBits(first.offsetAdditional, first.offsetExtraBits);
    stream.flush();

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

        // Flush if needed (when bits accumulate)
        final totalBits =
            token.offsetExtraBits +
            token.matchExtraBits +
            token.literalExtraBits;
        if (totalBits >= 64 - 7 - 17) {
          // 17 = 6+5+6 table logs
          stream.flush();
        }

        // Write extra bits
        stream.addBits(token.literalExtraValue, token.literalExtraBits);
        if (token.literalExtraBits + token.matchExtraBits > 24) {
          stream.flush();
        }

        stream.addBits(token.matchExtraValue, token.matchExtraBits);
        if (totalBits > 56) {
          stream.flush();
        }

        stream.addBits(token.offsetAdditional, token.offsetExtraBits);
        stream.flush();
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

    return stream.close();
  }

  List<_SequenceToken> _buildTokens(final List<ZstdMatch> matches) {
    final tokens = <_SequenceToken>[];
    final previousOffsets = [1, 4, 8];

    for (final match in matches) {
      final llSymbol = _getLiteralLengthSymbol(match.literalLength);
      final mlSymbol = _getMatchLengthSymbol(match.length);
      final offsetEncoding = _encodeOffsetSymbol(
        match.literalLength,
        match.offset,
        previousOffsets,
      );

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

  int _getLiteralLengthSymbol(final int length) {
    for (var i = 0; i < seq.literalLengthBase.length; i++) {
      if (i == seq.literalLengthBase.length - 1) return i;
      if (length >= seq.literalLengthBase[i] &&
          length < seq.literalLengthBase[i + 1]) {
        return i;
      }
    }
    return seq.literalLengthBase.length - 1;
  }

  int _getMatchLengthSymbol(final int length) {
    for (var i = 0; i < seq.matchLengthBase.length; i++) {
      if (i == seq.matchLengthBase.length - 1) return i;
      if (length >= seq.matchLengthBase[i] &&
          length < seq.matchLengthBase[i + 1]) {
        return i;
      }
    }
    return seq.matchLengthBase.length - 1;
  }

  int _literalExtraBits(final int symbol) =>
      symbol < seq.literalLengthBits.length ? seq.literalLengthBits[symbol] : 0;

  int _matchExtraBits(final int symbol) =>
      symbol < seq.matchLengthBits.length ? seq.matchLengthBits[symbol] : 0;

  _OffsetEncoding _encodeOffsetSymbol(
    final int literalLength,
    final int offset,
    final List<int> previousOffsets,
  ) {
    // Encode absolute offsets only. Repeat-offset symbols are frame stateful
    // across blocks; this encoder builds each block independently.
    final symbol = _getAbsoluteOffsetSymbol(offset);
    final base = seq.offsetBase[symbol];
    final bits = seq.offsetBits[symbol];
    final value = offset - base;

    previousOffsets[2] = previousOffsets[1];
    previousOffsets[1] = previousOffsets[0];
    previousOffsets[0] = offset;

    return _OffsetEncoding(symbol: symbol, bits: bits, value: value);
  }

  int _getAbsoluteOffsetSymbol(final int offset) {
    // Symbols 0-1 are repeat offset codes, symbols 2+ are absolute offsets
    // Symbol 2: base=1, bits=2 → range 1-4
    // Symbol 3: base=5, bits=3 → range 5-12
    // etc.
    for (var i = seq.offsetBase.length - 1; i >= 2; i--) {
      final base = seq.offsetBase[i];
      final bits = seq.offsetBits[i];
      final max = base + ((1 << bits) - 1);
      if (offset >= base && offset <= max) {
        return i;
      }
    }
    throw StateError('Unable to encode offset $offset');
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
    final prevOffsets = [1, 4, 8];

    for (final match in matches) {
      llSymbols.add(_getLiteralLengthSymbol(match.literalLength));
      mlSymbols.add(_getMatchLengthSymbol(match.length));
      ofSymbols.add(
        _encodeOffsetSymbol(match.literalLength, match.offset, prevOffsets),
      );
    }

    return SequenceSymbols(
      literalLengths: llSymbols,
      offsets: ofSymbols,
      matchLengths: mlSymbols,
    );
  }

  static int _getLiteralLengthSymbol(final int length) {
    for (var i = 0; i < seq.literalLengthBase.length; i++) {
      if (i == seq.literalLengthBase.length - 1) return i;
      if (length >= seq.literalLengthBase[i] &&
          length < seq.literalLengthBase[i + 1]) {
        return i;
      }
    }
    return seq.literalLengthBase.length - 1;
  }

  static int _getMatchLengthSymbol(final int length) {
    for (var i = 0; i < seq.matchLengthBase.length; i++) {
      if (i == seq.matchLengthBase.length - 1) return i;
      if (length >= seq.matchLengthBase[i] &&
          length < seq.matchLengthBase[i + 1]) {
        return i;
      }
    }
    return seq.matchLengthBase.length - 1;
  }

  static int _encodeOffsetSymbol(
    final int literalLength,
    final int offset,
    final List<int> prevOffsets,
  ) {
    // Keep FSE statistics aligned with SequenceEncoder: absolute offsets only.
    final symbol = _getAbsoluteOffsetSymbol(offset);
    prevOffsets[2] = prevOffsets[1];
    prevOffsets[1] = prevOffsets[0];
    prevOffsets[0] = offset;
    return symbol;
  }

  static int _getAbsoluteOffsetSymbol(final int offset) {
    for (var i = seq.offsetBase.length - 1; i >= 2; i--) {
      final base = seq.offsetBase[i];
      final bits = seq.offsetBits[i];
      final max = base + ((1 << bits) - 1);
      if (offset >= base && offset <= max) return i;
    }
    throw StateError('Unable to encode offset $offset');
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
        final maxBitsOut = log - _highestBit(count - 1);
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

  static int _highestBit(final int value) {
    if (value == 0) return 0;
    return value.bitLength - 1;
  }

  /// Get initial state for a symbol (no bits written)
  int begin(final int symbol) {
    final outputBits = (_deltaNumberOfBits[symbol] + (1 << 15)) >> 16;
    final base =
        ((outputBits << 16) - _deltaNumberOfBits[symbol]) >> outputBits;
    return _nextState[base + _deltaFindState[symbol]];
  }

  /// Encode symbol: write low bits of state, return next state
  int encode(final BitOutputStream stream, final int state, final int symbol) {
    final outputBits = (state + _deltaNumberOfBits[symbol]) >> 16;
    stream.addBits(state, outputBits);
    return _nextState[(state >> outputBits) + _deltaFindState[symbol]];
  }

  /// Write final state bits
  void finish(final BitOutputStream stream, final int state) {
    stream.addBits(state, tableLog);
    stream.flush();
  }
}

/// Bit output stream matching Java BitOutputStream behavior
class BitOutputStream {
  BigInt _container = BigInt.zero;
  int _bitCount = 0;
  final _bytes = <int>[];

  /// Add bits to the stream (LSB accumulation)
  void addBits(final int value, final int bits) {
    if (bits <= 0) return;
    final mask = (BigInt.one << bits) - BigInt.one;
    _container |= (BigInt.from(value) & mask) << _bitCount;
    _bitCount += bits;
  }

  /// Flush complete bytes to output
  void flush() {
    final bytes = _bitCount >> 3;
    for (var i = 0; i < bytes; i++) {
      _bytes.add((_container & BigInt.from(0xFF)).toInt());
      _container >>= 8;
    }
    _bitCount &= 7;
  }

  /// Close stream: add end marker, flush, return bytes
  Uint8List close() {
    // Add end marker bit
    addBits(1, 1);
    flush();

    // Flush remaining bits
    if (_bitCount > 0) {
      final mask = (BigInt.one << _bitCount) - BigInt.one;
      _bytes.add((_container & mask).toInt());
    }

    return Uint8List.fromList(_bytes);
  }
}
