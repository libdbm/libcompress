import 'dart:typed_data';

import 'zstd_common.dart';

/// Finite State Entropy (FSE) decoder for Zstandard
///
/// FSE is a form of Asymmetric Numeral Systems (ANS) used by Zstd
/// for compressing symbol distributions efficiently.
class FseDecoder {
  /// Decode FSE normalized counters from bitstream per RFC 8878 Section 4.1.1
  /// When [skipInitialBits] is true (for Huffman weights), skip the first 4 bits
  /// which contain the accuracy log
  static (List<int>, int) decodeNormalizedCounters(
    Uint8List data,
    int offset,
    int maxSymbolValue,
    int tableLog, {
    int skipBits = 0,
  }) {
    final counters = List<int>.filled(maxSymbolValue + 1, 0);
    final reader = FseBitReader(data, offset);

    // Skip initial bits if requested (e.g., skip accuracy log)
    if (skipBits > 0) {
      reader.readBits(skipBits);
    }

    // Per RFC 8878: remaining starts at tableSize + 1
    var remaining = (1 << tableLog) + 1;
    var threshold = 1 << tableLog;
    var nbBits = tableLog + 1;
    var symbol = 0;
    var prevZero = false;

    while (symbol <= maxSymbolValue && remaining > 1) {
      // Handle zero-run encoding for consecutive zeros
      if (prevZero) {
        var zeros = 0;
        while (true) {
          final code = reader.readBits(2);
          if (code == 3) {
            zeros += 3;
          } else {
            zeros += code;
            break;
          }
        }
        symbol += zeros;
        if (symbol > maxSymbolValue + 1) {
          throw ZstdFormatException('FSE: Zero run exceeds symbol capacity');
        }
        prevZero = false;
        continue;
      }

      if (symbol > maxSymbolValue) {
        break;
      }

      // RFC 8878: max = (2 * threshold - 1) - remaining
      final max = (2 * threshold - 1) - remaining;
      int count;
      final bitsMinusOne = nbBits - 1;
      final value = bitsMinusOne > 0 ? reader.peekBits(bitsMinusOne) : 0;

      if (value < max) {
        if (bitsMinusOne > 0) {
          reader.skipBits(bitsMinusOne);
        }
        count = value;
      } else {
        final fullValue = reader.readBits(nbBits);
        count = fullValue;
        if (fullValue >= threshold) {
          count -= max;
        }
      }

      // Apply bias: count - 1
      count -= 1;

      // Update remaining (use absolute value per Java implementation)
      remaining -= count.abs();

      if (symbol <= maxSymbolValue) {
        counters[symbol] = count;
      }
      symbol++;
      prevZero = count == 0;

      // Update threshold when remaining shrinks
      if (remaining < threshold) {
        if (remaining <= 1) {
          break;
        }
        nbBits = _highBit32(remaining) + 1;
        threshold = 1 << (nbBits - 1);
      }
    }

    // Verify remaining is exactly 1
    if (remaining != 1) {
      throw ZstdFormatException(
        'FSE: Invalid normalized counters - remaining=$remaining (should be 1)',
      );
    }

    // bytesConsumed already returns absolute offset, so don't add offset again
    return (counters, reader.bytesConsumed);
  }

  static int _highBit32(int value) {
    if (value <= 0) return 0;
    return value.bitLength - 1;
  }

  /// FSE state entry containing symbol and number of bits to read
  late List<FseStateEntry> _table;
  late int _accuracyLog;
  late int _tableSize;

  /// Build FSE decoding table from normalized frequencies
  void buildTable(final List<int> normalizedCounters, final int accuracyLog) {
    _accuracyLog = accuracyLog;
    _tableSize = 1 << accuracyLog;
    _table = List<FseStateEntry>.filled(_tableSize, FseStateEntry(0, 0, 0));

    final tableMask = _tableSize - 1;
    final step = _tableStep(_tableSize);
    final symbols = List<int?>.filled(_tableSize, null, growable: false);
    final symbolNext = List<int>.filled(
      normalizedCounters.length,
      0,
      growable: false,
    );

    var highThreshold = _tableSize - 1;
    var position = 0;

    // Reserve positions for RLE symbols (-1 frequency) first so they don't get overwritten
    for (var symbol = 0; symbol < normalizedCounters.length; symbol++) {
      if (normalizedCounters[symbol] == -1) {
        symbols[highThreshold] = symbol;
        highThreshold--;
        symbolNext[symbol] = 1;
      }
    }

    for (var symbol = 0; symbol < normalizedCounters.length; symbol++) {
      final frequency = normalizedCounters[symbol];
      if (frequency <= 0) {
        if (frequency == -1) {
          continue;
        }
        continue;
      }

      symbolNext[symbol] = frequency;

      for (var i = 0; i < frequency; i++) {
        // Find next free position
        var attempts = 0;
        while (symbols[position] != null) {
          position = (position + step) & tableMask;
          attempts++;
          if (attempts > _tableSize * 2) {
            throw ZstdFormatException(
              'FSE: Unable to find free position in table '
              '(symbol=$symbol, i=$i, freq=$frequency, tableSize=$_tableSize, '
              'position=$position, highThreshold=$highThreshold)',
            );
          }
        }

        symbols[position] = symbol;
        position = (position + step) & tableMask;
      }
    }

    for (var state = 0; state < _tableSize; state++) {
      final symbol = symbols[state];
      if (symbol == null) {
        throw ZstdFormatException(
          'FSE: Incomplete decoding table (null symbol at state $state)',
        );
      }

      var nextState = symbolNext[symbol];
      if (nextState <= 0) {
        // Should not happen, but guard to avoid crashes.
        nextState = 1;
      }
      symbolNext[symbol] = nextState + 1;

      final int nbBits = _accuracyLog - _highBit32(nextState);
      final int baseline = (nextState << nbBits) - _tableSize;
      _table[state] = FseStateEntry(symbol, nbBits, baseline);
    }
  }

  int _tableStep(int size) => (size >> 1) + (size >> 3) + 3;

  List<FseStateEntry> get tableEntries => _table;

  int get tableLog => _accuracyLog;

  /// Decode next symbol and update state
  int decodeSymbol(FseState state, FseBitReader reader) {
    final entry = _table[state.value];
    final symbol = entry.symbol;

    // Read bits and update state
    final bits = reader.readBits(entry.numberOfBits);
    state.value = entry.baseline + bits;

    return symbol;
  }

  /// Get symbol for current state without reading bits or updating state
  int peekSymbol(FseState state) {
    return _table[state.value].symbol;
  }

  /// Check how many bits would be needed to update from current state
  int bitsNeeded(FseState state) {
    return _table[state.value].numberOfBits;
  }

  /// Decode symbol with soft EOF handling - treats missing bits as zeros
  /// Returns (symbol, bool) where bool is false if stream exhausted
  (int, bool) decodeSymbolSafe(FseState state, FseBitReader reader) {
    final entry = _table[state.value];
    final symbol = entry.symbol;
    final needed = entry.numberOfBits;

    // Check if we have enough bits
    if (!reader.hasBits(needed)) {
      // Read what we can, pad with zeros
      final available = reader.availableBits;
      final bits = available > 0 ? reader.readBitsUnchecked(available) : 0;
      state.value = entry.baseline + bits;
      return (symbol, false);
    }

    final bits = reader.readBits(needed);
    state.value = entry.baseline + bits;
    return (symbol, true);
  }

  /// Initialize state from bit stream
  FseState initializeState(FseBitReader reader) {
    return FseState(reader.readBits(_accuracyLog));
  }
}

/// FSE state for decoding
class FseState {
  int value;
  FseState(this.value);
}

/// FSE state table entry
class FseStateEntry {
  final int symbol;
  final int numberOfBits;
  final int baseline;

  FseStateEntry(this.symbol, this.numberOfBits, this.baseline);
}

/// Bit reader for FSE decoding (reads bits forward/LSB first)
class FseBitReader {
  final Uint8List _data;
  final int _endOffset;
  int _offset;
  int _bitBuffer;
  int _bitsInBuffer;

  /// Get current byte offset
  int get offset => _offset;

  FseBitReader(this._data, int offset, [int? endOffset])
    : _offset = offset,
      _endOffset = endOffset ?? _data.length,
      _bitBuffer = 0,
      _bitsInBuffer = 0;

  /// Read specified number of bits
  int readBits(final int count) {
    while (_bitsInBuffer < count) {
      if (_offset >= _endOffset) {
        throw ZstdFormatException('FSE bit reader: unexpected end of data');
      }
      _bitBuffer |= _data[_offset++] << _bitsInBuffer;
      _bitsInBuffer += 8;
    }

    final result = _bitBuffer & ((1 << count) - 1);
    _bitBuffer >>= count;
    _bitsInBuffer -= count;
    return result;
  }

  /// Peek bits without consuming
  int peekBits(final int count) {
    while (_bitsInBuffer < count) {
      if (_offset >= _endOffset) {
        return _bitBuffer & ((1 << count) - 1);
      }
      _bitBuffer |= _data[_offset++] << _bitsInBuffer;
      _bitsInBuffer += 8;
    }
    return _bitBuffer & ((1 << count) - 1);
  }

  /// Skip bits after peeking
  void skipBits(final int count) {
    _bitBuffer >>= count;
    _bitsInBuffer -= count;
  }

  /// Number of bytes consumed from the input
  int get bytesConsumed => _offset - (_bitsInBuffer ~/ 8);

  /// Check if more data available
  bool get hasMoreData => _offset < _endOffset || _bitsInBuffer > 0;

  /// Check if we have at least N bits available
  bool hasBits(final int count) {
    if (_bitsInBuffer >= count) return true;
    // Check if we can load more
    final bitsNeeded = count - _bitsInBuffer;
    final bytesNeeded = (bitsNeeded + 7) ~/ 8;
    return _offset + bytesNeeded <= _endOffset;
  }

  /// Get number of bits currently available without loading more
  int get availableBits {
    final bitsFromBuffer = _bitsInBuffer;
    final bytesRemaining = _endOffset - _offset;
    return bitsFromBuffer + (bytesRemaining * 8);
  }

  /// Read bits without checking bounds (caller must verify with hasBits first)
  int readBitsUnchecked(final int count) {
    while (_bitsInBuffer < count && _offset < _endOffset) {
      _bitBuffer |= _data[_offset++] << _bitsInBuffer;
      _bitsInBuffer += 8;
    }
    final result = _bitBuffer & ((1 << count) - 1);
    _bitBuffer >>= count;
    _bitsInBuffer -= count;
    return result;
  }
}
