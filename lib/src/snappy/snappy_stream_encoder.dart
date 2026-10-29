import 'dart:typed_data';

import '../util/crc32c.dart';
import 'snappy_encoder.dart';

/// Snappy streaming (framing format) encoder
///
/// Implements the Snappy framing format specification for streaming compression.
/// Splits input into chunks of maximum 65536 bytes and compresses each independently.
///
/// Reference: https://github.com/google/snappy/blob/main/framing_format.txt
class SnappyStreamEncoder {
  /// Maximum uncompressed bytes per chunk (spec limit)
  static const int maxChunkSize = 65536;

  /// Stream identifier chunk type
  static const int chunkTypeStreamIdentifier = 0xff;

  /// Compressed data chunk type
  static const int chunkTypeCompressed = 0x00;

  /// Uncompressed data chunk type
  static const int chunkTypeUncompressed = 0x01;

  /// Chunk size for splitting input data
  final int chunkSize;

  /// Creates a streaming encoder with specified chunk size
  ///
  /// [chunkSize] must not exceed 65536 bytes (spec limit)
  SnappyStreamEncoder({this.chunkSize = maxChunkSize}) {
    if (chunkSize <= 0 || chunkSize > maxChunkSize) {
      throw ArgumentError(
        'chunkSize must be between 1 and $maxChunkSize, got $chunkSize',
      );
    }
  }

  /// Compress data using Snappy framing format
  ///
  /// Splits input into chunks and compresses each independently.
  /// Always writes stream identifier as first chunk.
  Uint8List compress(final Uint8List data) {
    final output = BytesBuilder(copy: false);

    // Write stream identifier (always first)
    _writeStreamIdentifier(output);

    // Handle empty input
    if (data.isEmpty) {
      return output.takeBytes();
    }

    // Split data into chunks and compress each
    var offset = 0;
    while (offset < data.length) {
      final remaining = data.length - offset;
      final length = remaining < chunkSize ? remaining : chunkSize;
      final chunk = Uint8List.sublistView(data, offset, offset + length);

      _compressChunk(output, chunk);
      offset += length;
    }

    return output.takeBytes();
  }

  /// Compress a single chunk without stream identifier
  ///
  /// Use this for streaming when you've already written the header.
  /// Returns just the compressed chunk (type + length + checksum + data).
  Uint8List compressChunkOnly(final Uint8List data) {
    if (data.isEmpty) return Uint8List(0);

    final output = BytesBuilder(copy: false);

    // Split into chunks if needed
    var offset = 0;
    while (offset < data.length) {
      final remaining = data.length - offset;
      final length = remaining < chunkSize ? remaining : chunkSize;
      final chunk = Uint8List.sublistView(data, offset, offset + length);

      _compressChunk(output, chunk);
      offset += length;
    }

    return output.takeBytes();
  }

  /// Get the stream identifier bytes
  Uint8List get streamIdentifier {
    final output = BytesBuilder(copy: false);
    _writeStreamIdentifier(output);
    return output.takeBytes();
  }

  /// Write stream identifier chunk
  void _writeStreamIdentifier(final BytesBuilder output) {
    // Stream identifier: 0xff 0x06 0x00 0x00 "sNaPpY"
    output.add([
      chunkTypeStreamIdentifier,
      0x06, 0x00, 0x00, // length = 6
      0x73, 0x4e, 0x61, 0x50, 0x70, 0x59, // "sNaPpY"
    ]);
  }

  /// Compress a single chunk
  void _compressChunk(final BytesBuilder output, final Uint8List chunk) {
    final compressed = SnappyEncoder.compress(chunk);
    final checksum = Crc32c.hash(chunk);

    // Use compressed if smaller, otherwise use uncompressed
    if (compressed.length < chunk.length) {
      _writeChunk(output, chunkTypeCompressed, compressed, checksum);
    } else {
      _writeChunk(output, chunkTypeUncompressed, chunk, checksum);
    }
  }

  /// Write a data chunk (compressed or uncompressed)
  void _writeChunk(
    final BytesBuilder output,
    final int chunkType,
    final Uint8List data,
    final int checksum,
  ) {
    final maskedChecksum = Crc32c.mask(checksum);
    // Chunk length includes 4-byte checksum + data
    final length = data.length + 4;

    // Validate chunk length doesn't exceed spec limits
    if (chunkType == chunkTypeCompressed && length > 16777215) {
      throw StateError('Compressed chunk too large: $length bytes');
    }
    if (chunkType == chunkTypeUncompressed && length > 65540) {
      throw StateError('Uncompressed chunk too large: $length bytes');
    }

    // Write chunk header: type (1 byte) + length (3 bytes, little-endian)
    final header = Uint8List(8);
    header[0] = chunkType;
    header[1] = length & 0xff;
    header[2] = (length >> 8) & 0xff;
    header[3] = (length >> 16) & 0xff;
    // Masked CRC32C, little-endian.
    header[4] = maskedChecksum & 0xff;
    header[5] = (maskedChecksum >> 8) & 0xff;
    header[6] = (maskedChecksum >> 16) & 0xff;
    header[7] = (maskedChecksum >> 24) & 0xff;
    output.add(header);

    // Write data
    output.add(data);
  }
}
