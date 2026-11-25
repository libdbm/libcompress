import 'dart:typed_data';
import 'dart:math' as math;
import '../util/bit_stream.dart';

/// FSE encoder state for a symbol
class FseState {
  final int symbol;
  final int baseline;
  final int bits;

  const FseState({
    required this.symbol,
    required this.baseline,
    required this.bits,
  });
}

/// Statistics for a sequence component (LL, OF, ML)
class SymbolStats {
  final List<int> counts;
  final int total;
  final int maxSymbol;
  final int distinct;

  const SymbolStats({
    required this.counts,
    required this.total,
    required this.maxSymbol,
    required this.distinct,
  });

  /// Check if RLE mode is beneficial (single dominant symbol)
  bool get isRle => distinct == 1;

  /// The estimated bits to code the counted symbols with the normalized
  /// [table] of accuracy log [accuracy]: each symbol costs `accuracy -
  /// log2(weight)` bits, a `-1` weight counting as 1. A counted symbol absent
  /// from the table makes the cost infinite.
  double cost(final List<int> table, final int accuracy) {
    var bits = 0.0;
    for (var symbol = 0; symbol < counts.length; symbol++) {
      if (counts[symbol] == 0) continue;
      final weight = symbol < table.length ? table[symbol] : 0;
      if (weight == 0) return double.infinity;
      bits +=
          counts[symbol] *
          (accuracy - math.log(weight < 0 ? 1 : weight) / math.ln2);
    }
    return bits;
  }
}

/// Finite State Entropy (FSE) encoder for Zstandard
///
/// FSE is a form of Asymmetric Numeral Systems (ANS) used for
/// efficient symbol compression.
class FseEncoder {
  late List<int> normalized;
  late int tableLog;
  late int maxSymbol;

  // Cached header bytes: encodeHeader is called once to measure the size and
  // again to emit; the result is deterministic from normalized + tableLog.
  Uint8List? _header;

  /// Gather statistics from symbol occurrences
  static SymbolStats stats(final List<int> symbols, final int maxSym) {
    final counts = List<int>.filled(maxSym + 1, 0);
    var total = 0;
    var max = 0;
    var distinct = 0;

    for (final s in symbols) {
      if (s <= maxSym) {
        if (counts[s] == 0) distinct++;
        counts[s]++;
        total++;
        if (s > max) max = s;
      }
    }

    return SymbolStats(
      counts: counts,
      total: total,
      maxSymbol: max,
      distinct: distinct,
    );
  }

  /// Normalizes `freq[0..maxSym]` to a table: the log follows the number of
  /// samples, as zstd's `FSE_optimalTableLog` does, capped at [maxLog]; counts
  /// are rounded to the nearest value (at least 1) and the remainder goes to
  /// the most frequent symbol.
  void build(final List<int> freq, final int maxLog, final int maxSym) {
    maxSymbol = maxSym;
    _header = null;
    var total = 0;
    var distinct = 0;
    var largest = 0;
    for (var i = 0; i <= maxSym; i++) {
      if (i < freq.length && freq[i] > 0) {
        total += freq[i];
        distinct++;
        if (freq[i] > freq[largest]) largest = i;
      }
    }
    if (total == 0) {
      throw ArgumentError('No symbols to encode');
    }
    var log = math.min(
      maxLog,
      math.max(5, math.max(1, total - 1).bitLength - 2),
    );
    while ((1 << log) < distinct && log < maxLog) {
      log++;
    }
    tableLog = log;
    final size = 1 << log;
    final norm = List<int>.filled(maxSym + 1, 0);
    var assigned = 0;
    for (var i = 0; i <= maxSym; i++) {
      final f = i < freq.length ? freq[i] : 0;
      if (f > 0) {
        final count = math.max(1, (f * size + total ~/ 2) ~/ total);
        assigned += count;
        norm[i] = count;
      }
    }
    var difference = size - assigned;
    if (norm[largest] + difference >= 1) {
      norm[largest] += difference;
    } else {
      while (difference < 0) {
        var biggest = -1;
        for (var i = 0; i <= maxSym; i++) {
          if (norm[i] > 1 && (biggest < 0 || norm[i] > norm[biggest])) {
            biggest = i;
          }
        }
        final reduce = math.min(-difference, norm[biggest] - 1);
        norm[biggest] -= reduce;
        difference += reduce;
      }
    }
    normalized = norm;
  }

  /// Encode normalized counters to bitstream per RFC 8878 Section 4.1.1
  ///
  /// Format:
  /// - 4 bits: Accuracy_Log - 5
  /// - Variable bits per symbol: count encoding with optional zero runs
  Uint8List encodeHeader() {
    final cached = _header;
    if (cached != null) return cached;

    final writer = BitStreamWriter();

    // Write accuracy log (tableLog - 5)
    writer.writeBits(tableLog - 5, 4);

    final size = 1 << tableLog;
    var remaining = size + 1;
    var threshold = size;
    var width = tableLog + 1;
    var symbol = 0;
    var previousZero = false;

    while (symbol <= maxSymbol && remaining > 1) {
      // Zero run encoding: only after a symbol with count=0
      if (previousZero) {
        // Count consecutive zeros starting at current symbol
        var zeros = 0;
        while (symbol + zeros <= maxSymbol && normalized[symbol + zeros] == 0) {
          zeros++;
        }

        // Encode zero run: 2-bit codes, 3=continue, 0/1/2=terminal
        var z = zeros;
        while (z >= 3) {
          writer.writeBits(3, 2);
          z -= 3;
        }
        writer.writeBits(z, 2);

        symbol += zeros;
        previousZero = false;
        continue;
      }

      if (symbol > maxSymbol) break;

      final count = normalized[symbol];
      final value = count + 1; // Shift by 1 to allow -1 representation

      // Calculate max for variable-length encoding
      final max = (2 * threshold - 1) - remaining;

      // Encode value using variable-length code
      if (value < max) {
        // Short form: value fits in width-1 bits
        writer.writeBits(value, width - 1);
      } else if (value < threshold) {
        // Medium form: need full width, but value < threshold
        // Decoder peeks width-1, sees >= max, reads full width
        writer.writeBits(value, width);
      } else {
        // Long form: value >= threshold, add max before writing
        // Decoder reads width, sees >= threshold, subtracts max
        writer.writeBits(value + max, width);
      }

      // Update remaining
      if (count < 0) {
        remaining -= 1;
      } else {
        remaining -= count;
      }

      // Track if this was a zero for next iteration
      previousZero = count == 0;

      // Update threshold AFTER remaining update (matches decoder)
      while (remaining < threshold && remaining > 1) {
        width--;
        threshold >>= 1;
      }

      symbol++;
    }

    return _header = writer.toBytes();
  }
}

/// Encodes a sequence symbol mode byte from individual modes
///
/// Format per RFC 8878 Section 3.1.1.3.2.1:
/// - Bits 7-6: Literal_Lengths_Mode
/// - Bits 5-4: Offsets_Mode
/// - Bits 3-2: Match_Lengths_Mode
/// - Bits 1-0: Reserved (must be 0)
int encodeSymbolMode(final int llMode, final int ofMode, final int mlMode) {
  return ((llMode & 0x03) << 6) |
      ((ofMode & 0x03) << 4) |
      ((mlMode & 0x03) << 2);
}

/// Determines best encoding mode for each component
class EncodingModeSelector {
  final SymbolStats llStats;
  final SymbolStats ofStats;
  final SymbolStats mlStats;

  EncodingModeSelector({
    required this.llStats,
    required this.ofStats,
    required this.mlStats,
  });

  /// Mode 0: Predefined tables
  /// Mode 1: RLE (single symbol)
  /// Mode 2: FSE compressed (custom table)
  /// Mode 3: Repeat from previous block

  (int, int, int, FseEncoder?, FseEncoder?, FseEncoder?) select({
    required final List<int> llPredefined,
    required final int llPredefinedLog,
    required final List<int> ofPredefined,
    required final int ofPredefinedLog,
    required final List<int> mlPredefined,
    required final int mlPredefinedLog,
  }) {
    final (llMode, llEnc) = _selectOne(
      llStats,
      llPredefined,
      llPredefinedLog,
      _literalLog,
      35,
    );
    final (ofMode, ofEnc) = _selectOne(
      ofStats,
      ofPredefined,
      ofPredefinedLog,
      _offsetLog,
      31,
    );
    final (mlMode, mlEnc) = _selectOne(
      mlStats,
      mlPredefined,
      mlPredefinedLog,
      _matchLog,
      52,
    );

    return (llMode, ofMode, mlMode, llEnc, ofEnc, mlEnc);
  }

  /// Largest accuracy logs of custom literal-length, offset and match-length
  /// tables, as zstd.
  static const int _literalLog = 9;
  static const int _offsetLog = 8;
  static const int _matchLog = 9;

  /// Mode 1 (RLE) for a single symbol; otherwise whichever of 0 (predefined)
  /// and 2 (custom, its description included) costs fewer estimated bits.
  (int, FseEncoder?) _selectOne(
    final SymbolStats stats,
    final List<int> predefined,
    final int predefinedLog,
    final int most,
    final int maxSym,
  ) {
    if (stats.isRle) {
      return (1, null);
    }
    final fixed = stats.cost(predefined, predefinedLog);
    if (stats.total < 16) {
      return (0, null);
    }
    final enc = FseEncoder()..build(stats.counts, most, maxSym);
    final custom =
        stats.cost(enc.normalized, enc.tableLog) +
        enc.encodeHeader().length * 8;
    return custom < fixed ? (2, enc) : (0, null);
  }
}
