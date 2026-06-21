import 'dart:typed_data';

import '../util/byte_utils.dart';
import '../util/crc32c.dart';
import 'snappy_decoder.dart';

/// Snappy framing caps a single chunk's uncompressed data at 64 KB.
const int _maxChunkUncompressed = 65536;

/// Snappy streaming (framing format) decoder
///
/// Implements the Snappy framing format specification for streaming decompression.
/// Handles multiple chunks, skippable chunks, and proper error handling.
///
/// Reference: https://github.com/google/snappy/blob/main/framing_format.txt
class SnappyStreamDecoder {
  /// Stream identifier chunk type
  static const int chunkTypeStreamIdentifier = 0xff;

  /// Compressed data chunk type
  static const int chunkTypeCompressed = 0x00;

  /// Uncompressed data chunk type
  static const int chunkTypeUncompressed = 0x01;

  /// Padding chunk type
  static const int chunkTypePadding = 0xfe;

  /// Maximum allowed uncompressed size per chunk
  final int maxUncompressedSize;

  /// Whether we've seen a stream identifier (for incremental decoding)
  bool _seenIdentifier = false;

  /// Whether the mandatory leading stream identifier has been decoded.
  bool get seenIdentifier => _seenIdentifier;

  /// Creates a streaming decoder
  ///
  /// [maxUncompressedSize] sets the safety limit for decompressed chunks
  SnappyStreamDecoder({
    this.maxUncompressedSize = SnappyDecoder.defaultMaxSize,
  });

  /// Reset decoder state for a new stream
  void reset() {
    _seenIdentifier = false;
  }

  /// Decompress a single chunk incrementally
  ///
  /// For streaming use, call this method for each chunk as it arrives.
  /// The first chunk must be a stream identifier, subsequent chunks are data.
  /// Returns the decompressed data for data chunks, or empty for identifier/padding.
  Uint8List decompressChunk(final Uint8List data) {
    if (data.isEmpty) {
      throw SnappyFormatException('Cannot decompress empty chunk');
    }

    final chunk = _readChunk(data, 0);
    if (chunk.totalSize != data.length) {
      throw SnappyFormatException(
        'Chunk data contains extra bytes: expected ${chunk.totalSize}, got ${data.length}',
      );
    }

    return _processChunk(chunk, 0);
  }

  /// Process a single chunk and return decompressed data
  Uint8List _processChunk(final _Chunk chunk, final int offset) {
    switch (chunk.type) {
      case chunkTypeStreamIdentifier:
        _validateStreamIdentifier(chunk.data);
        _seenIdentifier = true;
        return Uint8List(0); // Identifier produces no output

      case chunkTypeCompressed:
        if (!_seenIdentifier) {
          throw SnappyFormatException(
            'Compressed chunk at offset $offset before stream identifier',
          );
        }
        return _decompressChunkData(chunk);

      case chunkTypeUncompressed:
        if (!_seenIdentifier) {
          throw SnappyFormatException(
            'Uncompressed chunk at offset $offset before stream identifier',
          );
        }
        return _processUncompressedChunkData(chunk);

      case chunkTypePadding:
        // Padding is ignored (spec: decompressors must not verify content)
        return Uint8List(0);

      default:
        if (chunk.type >= 0x02 && chunk.type <= 0x7f) {
          // Reserved unskippable chunk
          throw SnappyFormatException(
            'Unsupported unskippable chunk type: 0x${chunk.type.toRadixString(16)} '
            'at offset $offset',
          );
        } else if (chunk.type >= 0x80 && chunk.type <= 0xfd) {
          // Reserved skippable chunk - ignore
          return Uint8List(0);
        } else {
          throw SnappyFormatException(
            'Invalid chunk type: 0x${chunk.type.toRadixString(16)} at offset $offset',
          );
        }
    }
  }

  /// Decompress compressed chunk data and return result
  Uint8List _decompressChunkData(final _Chunk chunk) {
    if (chunk.length < 4) {
      throw SnappyFormatException('Compressed chunk too small for checksum');
    }

    // Read checksum (first 4 bytes, little-endian; readUint32LE is non-negative
    // on both VM and dart2js, matching the masked CRC it's compared against).
    final checksum = ByteUtils.readUint32LE(chunk.data, 0);

    // Decompress the data (after checksum), bounded by the 64 KB per-chunk
    // spec limit (and any smaller configured cap).
    final compressed = Uint8List.sublistView(chunk.data, 4);
    final chunkLimit = maxUncompressedSize < _maxChunkUncompressed
        ? maxUncompressedSize
        : _maxChunkUncompressed;
    final decompressed = SnappyDecoder.decompress(
      compressed,
      maxUncompressedSize: chunkLimit,
    );

    // Validate checksum against uncompressed data
    final actualChecksum = Crc32c.mask(Crc32c.hash(decompressed));
    if (checksum != actualChecksum) {
      throw SnappyFormatException(
        'Checksum mismatch for compressed chunk: '
        'expected 0x${checksum.toRadixString(16)}, '
        'got 0x${actualChecksum.toRadixString(16)}',
      );
    }

    return decompressed;
  }

  /// Process uncompressed chunk data and return result
  Uint8List _processUncompressedChunkData(final _Chunk chunk) {
    if (chunk.length < 4) {
      throw SnappyFormatException('Uncompressed chunk too small for checksum');
    }

    // Read checksum (first 4 bytes, little-endian; readUint32LE is non-negative
    // on both VM and dart2js, matching the masked CRC it's compared against).
    final checksum = ByteUtils.readUint32LE(chunk.data, 0);

    // Get uncompressed data (after checksum)
    final uncompressed = Uint8List.sublistView(chunk.data, 4);

    // Validate maximum size (the 64 KB per-chunk spec limit and any smaller cap)
    final chunkLimit = maxUncompressedSize < _maxChunkUncompressed
        ? maxUncompressedSize
        : _maxChunkUncompressed;
    if (uncompressed.length > chunkLimit) {
      throw SnappyFormatException(
        'Uncompressed chunk size ${uncompressed.length} exceeds maximum $chunkLimit',
      );
    }

    // Validate checksum
    final actualChecksum = Crc32c.mask(Crc32c.hash(uncompressed));
    if (checksum != actualChecksum) {
      throw SnappyFormatException(
        'Checksum mismatch for uncompressed chunk: '
        'expected 0x${checksum.toRadixString(16)}, '
        'got 0x${actualChecksum.toRadixString(16)}',
      );
    }

    return uncompressed;
  }

  /// Decompress data in Snappy framing format
  ///
  /// Processes all chunks in the stream and returns concatenated output.
  /// Properly handles stream identifiers, skippable chunks, and padding.
  Uint8List decompress(final Uint8List data) {
    if (data.isEmpty) {
      throw SnappyFormatException('Cannot decompress empty stream');
    }

    // Reset state for batch decompression
    reset();

    var cursor = 0;
    var total = 0;
    // Typed accumulator (no per-byte boxing / final fromList copy) for large
    // framed streams.
    final output = BytesBuilder(copy: false);

    while (cursor < data.length) {
      final chunk = _readChunk(data, cursor);
      final decompressed = _processChunk(chunk, cursor);
      total += decompressed.length;
      // Cumulative cap across all chunks (each chunk alone is bounded by
      // maxUncompressedSize, but an unbounded number of chunks is not).
      if (total > maxUncompressedSize) {
        throw SnappyFormatException(
          'Decompressed size $total exceeds maximum allowed size $maxUncompressedSize',
        );
      }
      output.add(decompressed);
      cursor += chunk.totalSize;
    }

    if (!_seenIdentifier) {
      throw SnappyFormatException('Stream missing required stream identifier');
    }

    return output.takeBytes();
  }

  /// Read a chunk from the stream at the specified offset
  _Chunk _readChunk(final Uint8List data, final int offset) {
    if (offset + 4 > data.length) {
      throw SnappyFormatException('Incomplete chunk header at offset $offset');
    }

    final type = data[offset];
    final length = data[offset + 1] |
        (data[offset + 2] << 8) |
        (data[offset + 3] << 16);

    // Total chunk size = 4-byte header + length bytes
    final totalSize = 4 + length;

    if (offset + totalSize > data.length) {
      throw SnappyFormatException(
        'Chunk length $length at offset $offset exceeds data bounds',
      );
    }

    final chunkData = Uint8List.sublistView(data, offset + 4, offset + 4 + length);

    return _Chunk(type, length, totalSize, chunkData);
  }

  /// Validate stream identifier chunk
  void _validateStreamIdentifier(final Uint8List data) {
    if (data.length != 6) {
      throw SnappyFormatException('Invalid stream identifier length: ${data.length}');
    }

    // Expected: "sNaPpY" = [0x73, 0x4e, 0x61, 0x50, 0x70, 0x59]
    if (data[0] != 0x73 ||
        data[1] != 0x4e ||
        data[2] != 0x61 ||
        data[3] != 0x50 ||
        data[4] != 0x70 ||
        data[5] != 0x59) {
      throw SnappyFormatException('Invalid stream identifier content');
    }
  }

}

/// Internal representation of a chunk
class _Chunk {
  final int type;
  final int length;
  final int totalSize;
  final Uint8List data;

  _Chunk(this.type, this.length, this.totalSize, this.data);
}
