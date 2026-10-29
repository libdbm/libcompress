import 'dart:typed_data';

import 'zstd_common.dart';

/// Finite State Entropy (FSE) decoder for Zstandard
///
/// FSE is a form of Asymmetric Numeral Systems (ANS) used by Zstd
/// for compressing symbol distributions efficiently.
class FseDecoder {
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

      final int bits = _accuracyLog - (nextState.bitLength - 1);
      final int baseline = (nextState << bits) - _tableSize;
      _table[state] = FseStateEntry(symbol, bits, baseline);
    }
  }

  int _tableStep(final int size) => (size >> 1) + (size >> 3) + 3;

  List<FseStateEntry> get tableEntries => _table;

  int get tableLog => _accuracyLog;
}

/// FSE state table entry
class FseStateEntry {
  final int symbol;
  final int numberOfBits;
  final int baseline;

  FseStateEntry(this.symbol, this.numberOfBits, this.baseline);
}

/// Reads an FSE table description (RFC 8878 §4.1.1) from `data[offset..end)`:
/// the accuracy log, at most [maxTableLog], then normalized counts for symbols
/// up to [maxSymbolValue]. Returns the counts, the accuracy log and the offset
/// after the description. Used for sequence tables and Huffman weights.
(List<int>, int, int) readNormalizedCounts(
  final Uint8List data,
  final int offset,
  final int blockEnd,
  final int maxSymbolValue,
  final int maxTableLog,
) {
  final reader = _ForwardBitReader(data, offset, blockEnd);

  final tableLog = reader.readBits(4) + 5; // FSE_MIN_TABLELOG
  if (tableLog > maxTableLog) {
    throw ZstdFormatException(
      'FSE accuracy log $tableLog exceeds maximum $maxTableLog',
    );
  }
  var remaining = (1 << tableLog) + 1;
  var threshold = 1 << tableLog;
  var width = tableLog + 1;
  var symbol = 0;
  var previousZero = false;

  final counts = List<int>.filled(maxSymbolValue + 1, 0);

  while (symbol <= maxSymbolValue && remaining > 1) {
    if (previousZero) {
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
        throw ZstdFormatException('Zero run exceeds symbol capacity');
      }
      previousZero = false;
      continue;
    }

    if (symbol > maxSymbolValue) {
      break;
    }

    final max = (2 * threshold - 1) - remaining;
    int count;
    final bitsMinusOne = width - 1;
    final value = bitsMinusOne > 0 ? reader.peekBits(bitsMinusOne) : 0;
    if (value < max) {
      if (bitsMinusOne > 0) {
        reader.skipBits(bitsMinusOne);
      }
      count = value;
    } else {
      final fullValue = reader.readBits(width);
      count = fullValue;
      if (fullValue >= threshold) {
        count -= max;
      }
    }

    count -= 1;

    if (count >= 0) {
      remaining -= count;
    } else {
      remaining += count;
    }

    if (symbol <= maxSymbolValue) {
      counts[symbol] = count;
    }
    symbol++;
    previousZero = count == 0;

    if (remaining < threshold) {
      if (remaining <= 1) {
        break;
      }
      width = remaining.bitLength;
      threshold = 1 << (width - 1);
    }
  }

  if (remaining != 1) {
    throw ZstdFormatException(
      'Invalid normalized counts (remaining=$remaining)',
    );
  }
  final highestSymbol = symbol - 1;
  if (highestSymbol > maxSymbolValue) {
    throw ZstdFormatException('Normalized counts reference invalid symbol');
  }

  final nextOffset = offset + reader.bytesConsumed;
  if (nextOffset > blockEnd) {
    throw ZstdFormatException('Normalized counts exceed block boundary');
  }

  return (counts, tableLog, nextOffset);
}

class _ForwardBitReader {
  final Uint8List _data;
  final int _end;
  final int _start;
  int _bytePos;
  int _bitBuffer = 0;
  int _bitsAvailable = 0;

  _ForwardBitReader(this._data, final int offset, final int end)
    : _end = end,
      _start = offset,
      _bytePos = offset;

  int _ensureBits(final int count) {
    while (_bitsAvailable < count) {
      if (_bytePos >= _end) {
        throw ZstdFormatException(
          'Unexpected end of data in an FSE table description',
        );
      }
      _bitBuffer |= _data[_bytePos++] << _bitsAvailable;
      _bitsAvailable += 8;
    }
    return _bitsAvailable;
  }

  int readBits(final int count) {
    if (count == 0) return 0;
    _ensureBits(count);
    final value = _bitBuffer & ((1 << count) - 1);
    _bitBuffer >>= count;
    _bitsAvailable -= count;
    return value;
  }

  int peekBits(final int count) {
    if (count == 0) return 0;
    _ensureBits(count);
    return _bitBuffer & ((1 << count) - 1);
  }

  void skipBits(final int count) {
    if (count == 0) return;
    _ensureBits(count);
    _bitBuffer >>= count;
    _bitsAvailable -= count;
  }

  int get bitsConsumed => (_bytePos - _start) * 8 - _bitsAvailable;

  int get bytesConsumed => (bitsConsumed + 7) >> 3;
}
