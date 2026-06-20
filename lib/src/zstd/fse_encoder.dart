import 'dart:typed_data';
import 'dart:math' as math;

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

  /// Check if distribution is suitable for predefined tables
  bool shouldUsePredefined(final List<int> predefined, final int predefinedLog) {
    if (total < 16) return true; // Too few samples

    // Compare entropy of custom vs predefined
    final custom = _entropy(counts, total);
    final predefinedEntropy = _estimatePredefinedEntropy(predefined, predefinedLog);

    // Use predefined if custom isn't significantly better (>5% improvement)
    return custom >= predefinedEntropy * 0.95;
  }

  double _entropy(final List<int> freq, final int t) {
    if (t == 0) return 0;
    var h = 0.0;
    for (final f in freq) {
      if (f > 0) {
        final p = f / t;
        h -= p * (math.log(p) / math.ln2);
      }
    }
    return h;
  }

  double _estimatePredefinedEntropy(final List<int> norm, final int log) {
    final size = 1 << log;
    return _entropy(norm, size);
  }
}

/// Forward bit writer for FSE table header encoding
///
/// Writes bits LSB-first to match the decoder's forward bit reader.
class ForwardBitWriter {
  int _buffer = 0;
  int _bits = 0;
  final _bytes = <int>[];

  void write(final int value, final int count) {
    if (count <= 0) return;
    _buffer |= (value & ((1 << count) - 1)) << _bits;
    _bits += count;
    _flush();
  }

  void _flush() {
    while (_bits >= 8) {
      _bytes.add(_buffer & 0xFF);
      _buffer >>= 8;
      _bits -= 8;
    }
  }

  Uint8List finish() {
    if (_bits > 0) {
      _bytes.add(_buffer & ((1 << _bits) - 1));
    }
    return Uint8List.fromList(_bytes);
  }

  int get size => _bytes.length + ((_bits + 7) >> 3);
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

  /// Build FSE encoding table from symbol frequencies
  void build(final List<int> freq, final int maxLog, final int maxSym) {
    maxSymbol = maxSym;

    // Calculate total frequency
    var total = 0;
    var distinct = 0;
    for (var i = 0; i <= maxSym; i++) {
      if (i < freq.length && freq[i] > 0) {
        total += freq[i];
        distinct++;
      }
    }

    if (total == 0) {
      throw ArgumentError('No symbols to encode');
    }

    // Calculate optimal table log (minimum of maxLog and log2(total))
    tableLog = _optimalLog(total, distinct, maxLog);
    final size = 1 << tableLog;

    // Normalize frequencies to sum to tableSize
    normalized = _normalize(freq, total, size, maxSym);
  }

  int _optimalLog(final int total, final int distinct, final int maxLog) {
    var log = 5; // FSE_MIN_TABLELOG
    while (log < maxLog && (1 << log) < distinct * 2) {
      log++;
    }
    return math.min(log, maxLog);
  }

  List<int> _normalize(
    final List<int> freq,
    final int total,
    final int size,
    final int maxSym,
  ) {
    final norm = List<int>.filled(maxSym + 1, 0);
    var assigned = 0;

    // Assign proportional counts, minimum 1 for non-zero frequencies
    // Use -1 for symbols with very low frequency (probability < 1)
    for (var i = 0; i <= maxSym; i++) {
      final f = i < freq.length ? freq[i] : 0;
      if (f > 0) {
        var count = (f * size + total - 1) ~/ total; // Round up
        if (count == 0) {
          count = -1; // Mark as "less than 1" per RFC
          assigned += 1;
        } else {
          count = math.max(1, count);
          assigned += count;
        }
        norm[i] = count;
      }
    }

    // Adjust to match exact table size
    var diff = size - assigned;
    if (diff > 0) {
      // Add to most frequent symbols
      for (var i = 0; i <= maxSym && diff > 0; i++) {
        if (norm[i] > 0) {
          norm[i]++;
          diff--;
        }
      }
    } else if (diff < 0) {
      // Remove from least important (but keep at least 1)
      for (var i = maxSym; i >= 0 && diff < 0; i--) {
        if (norm[i] > 1) {
          final reduce = math.min(-diff, norm[i] - 1);
          norm[i] -= reduce;
          diff += reduce;
        }
      }
    }

    return norm;
  }

  /// Encode normalized counters to bitstream per RFC 8878 Section 4.1.1
  ///
  /// Format:
  /// - 4 bits: Accuracy_Log - 5
  /// - Variable bits per symbol: count encoding with optional zero runs
  Uint8List encodeHeader() {
    final cached = _header;
    if (cached != null) return cached;

    final writer = ForwardBitWriter();

    // Write accuracy log (tableLog - 5)
    writer.write(tableLog - 5, 4);

    final size = 1 << tableLog;
    var remaining = size + 1;
    var threshold = size;
    var nbBits = tableLog + 1;
    var symbol = 0;
    var prevZero = false;

    while (symbol <= maxSymbol && remaining > 1) {
      // Zero run encoding: only after a symbol with count=0
      if (prevZero) {
        // Count consecutive zeros starting at current symbol
        var zeros = 0;
        while (symbol + zeros <= maxSymbol && normalized[symbol + zeros] == 0) {
          zeros++;
        }

        // Encode zero run: 2-bit codes, 3=continue, 0/1/2=terminal
        var z = zeros;
        while (z >= 3) {
          writer.write(3, 2);
          z -= 3;
        }
        writer.write(z, 2);

        symbol += zeros;
        prevZero = false;
        continue;
      }

      if (symbol > maxSymbol) break;

      final count = normalized[symbol];
      final value = count + 1; // Shift by 1 to allow -1 representation

      // Calculate max for variable-length encoding
      final max = (2 * threshold - 1) - remaining;

      // Encode value using variable-length code
      if (value < max) {
        // Short form: value fits in nbBits-1 bits
        writer.write(value, nbBits - 1);
      } else if (value < threshold) {
        // Medium form: need full nbBits, but value < threshold
        // Decoder peeks nbBits-1, sees >= max, reads full nbBits
        writer.write(value, nbBits);
      } else {
        // Long form: value >= threshold, add max before writing
        // Decoder reads nbBits, sees >= threshold, subtracts max
        writer.write(value + max, nbBits);
      }

      // Update remaining
      if (count < 0) {
        remaining -= 1;
      } else {
        remaining -= count;
      }

      // Track if this was a zero for next iteration
      prevZero = count == 0;

      // Update threshold AFTER remaining update (matches decoder)
      while (remaining < threshold && remaining > 1) {
        nbBits--;
        threshold >>= 1;
      }

      symbol++;
    }

    return _header = writer.finish();
  }

  /// Check if encoding will be smaller than predefined
  bool isBeneficial(final int predefinedHeaderSize) {
    // Estimate encoded size
    final header = encodeHeader();
    return header.length < predefinedHeaderSize;
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
  return ((llMode & 0x03) << 6) | ((ofMode & 0x03) << 4) | ((mlMode & 0x03) << 2);
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
      35,
    );
    final (ofMode, ofEnc) = _selectOne(
      ofStats,
      ofPredefined,
      ofPredefinedLog,
      31,
    );
    final (mlMode, mlEnc) = _selectOne(
      mlStats,
      mlPredefined,
      mlPredefinedLog,
      52,
    );

    return (llMode, ofMode, mlMode, llEnc, ofEnc, mlEnc);
  }

  (int, FseEncoder?) _selectOne(
    final SymbolStats stats,
    final List<int> predefined,
    final int predefinedLog,
    final int maxSym,
  ) {
    // Mode 1: RLE if single symbol
    if (stats.isRle) {
      return (1, null);
    }

    // Check if predefined is good enough
    if (stats.shouldUsePredefined(predefined, predefinedLog)) {
      return (0, null);
    }

    // Mode 2: Build custom FSE table
    final enc = FseEncoder();
    enc.build(stats.counts, predefinedLog, maxSym);

    // Verify custom table overhead isn't too high
    final header = enc.encodeHeader();
    if (header.length > 12) {
      // Custom table overhead too high, use predefined
      return (0, null);
    }

    return (2, enc);
  }
}
