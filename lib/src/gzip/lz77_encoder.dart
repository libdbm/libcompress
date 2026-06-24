import 'dart:typed_data';
import 'dart:math' as math;
import 'deflate_common.dart';

/// LZ77 sliding window encoder for DEFLATE compression
///
/// Implements the LZ77 algorithm to find repeated sequences in the input
/// and replace them with length/distance pairs.
class Lz77Encoder {
  /// Hash table for finding matches (maps hash to position)
  final Int32List _hashTable = Int32List(hashSize);

  /// Previous position chain for hash collisions
  final Int32List _prev = Int32List(windowSize);

  /// Maximum lazy match attempts
  final int _lazyMatchLevel;

  /// Whether to use lazy matching for better compression
  final bool _lazyMatching;

  Lz77Encoder({int lazyMatchLevel = 4, bool lazyMatching = true})
    : _lazyMatchLevel = lazyMatchLevel,
      _lazyMatching = lazyMatching {
    // Initialize hash table to -1 (no position)
    for (var i = 0; i < _hashTable.length; i++) {
      _hashTable[i] = -1;
    }
  }

  /// Compresses input data using LZ77 algorithm
  ///
  /// Returns a list of tokens (literals and matches) that can be
  /// encoded using Huffman coding.
  List<Token> compress(Uint8List data) {
    final tokens = <Token>[];

    var pos = 0;
    while (pos < data.length) {
      final match = _findLongestMatch(data, pos);

      if (match != null && match.length >= minMatch) {
        // Check for lazy matching
        if (_lazyMatching && pos + 1 < data.length) {
          final nextMatch = _findLongestMatch(data, pos + 1);
          if (nextMatch != null &&
              nextMatch.length > match.length + _lazyMatchLevel) {
            // Better match at next position, emit literal and use that
            tokens.add(LiteralToken(data[pos]));
            _updateHash(data, pos);
            pos++;
            tokens.add(MatchToken(nextMatch.length, nextMatch.distance));
            // Update hash for all positions in the match
            for (var i = 0; i < nextMatch.length; i++) {
              if (pos + i < data.length) {
                _updateHash(data, pos + i);
              }
            }
            pos += nextMatch.length;
            continue;
          }
        }

        // Use the match
        tokens.add(MatchToken(match.length, match.distance));
        // Update hash for all positions in the match
        for (var i = 0; i < match.length; i++) {
          if (pos + i < data.length) {
            _updateHash(data, pos + i);
          }
        }
        pos += match.length;
      } else {
        // No match found, emit literal
        tokens.add(LiteralToken(data[pos]));
        _updateHash(data, pos);
        pos++;
      }
    }

    return tokens;
  }

  /// Finds the longest match at the given position
  _Match? _findLongestMatch(Uint8List data, int pos) {
    if (pos + minMatch > data.length) {
      return null;
    }

    final h = hash(data, pos);
    var chainPos = _hashTable[h];

    var bestLength = 0;
    var bestDistance = 0;

    var attempts = 0;
    const maxAttempts = 128; // Limit search depth

    while (attempts < maxAttempts) {
      // Check for invalid chain position
      if (chainPos < 0) {
        break;
      }

      final distance = pos - chainPos;

      // Check if distance is within window
      if (distance > maxDistance || distance < 1) {
        break;
      }

      // Check if we can beat the current best match
      // First verify we have enough data for the comparison
      if (chainPos + bestLength < data.length &&
          pos + bestLength < data.length &&
          data[chainPos + bestLength] == data[pos + bestLength]) {
        final len = _matchLength(data, chainPos, pos);

        if (len > bestLength) {
          bestLength = len;
          bestDistance = distance;

          // Maximum match found
          if (len >= maxMatch) {
            break;
          }
        }
      }

      // Follow chain to previous occurrence
      final prevIndex = chainPos & (windowSize - 1);
      chainPos = _prev[prevIndex];
      attempts++;

      // Stop if we hit an invalid chain position
      if (chainPos < 0) {
        break;
      }
    }

    if (bestLength >= minMatch) {
      return _Match(bestLength, bestDistance);
    }

    return null;
  }

  /// Computes the length of a match between two positions
  int _matchLength(Uint8List data, int pos1, int pos2) {
    final maxLen = math.min(maxMatch, data.length - pos2);
    var len = 0;

    while (len < maxLen && data[pos1 + len] == data[pos2 + len]) {
      len++;
    }

    return len;
  }

  /// Updates hash table and chain for a position
  void _updateHash(Uint8List data, int pos) {
    if (pos + 2 >= data.length) {
      return;
    }

    final h = hash(data, pos);
    final windowPos = pos & (windowSize - 1);

    // Chain this position to previous occurrence of same hash
    _prev[windowPos] = _hashTable[h];

    // Update hash table with this position
    _hashTable[h] = pos;
  }

  /// Resets the encoder state for a new block
  void reset() {
    for (var i = 0; i < _hashTable.length; i++) {
      _hashTable[i] = -1;
    }
    for (var i = 0; i < _prev.length; i++) {
      _prev[i] = -1;
    }
  }
}

/// Represents a match found by the LZ77 encoder
class _Match {
  final int length;
  final int distance;

  _Match(this.length, this.distance);
}
