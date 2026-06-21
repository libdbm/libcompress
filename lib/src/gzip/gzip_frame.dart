import 'dart:typed_data';
import 'dart:convert';
import '../exceptions.dart';
import '../util/crc32.dart';
import 'deflate_encoder.dart';
import 'deflate_decoder.dart';

// Re-export exception from centralized location
export '../exceptions.dart' show GzipFormatException;

/// Runs [body] under the GZIP error contract: any DEFLATE (or other)
/// [CompressionFormatException], or a `StateError`/`RangeError` from malformed
/// input, surfaces as a [GzipFormatException] (message preserved), so callers
/// catching the codec-specific exception don't miss DEFLATE-level failures.
T gzipBoundary<T>(T Function() body) {
  try {
    return body();
  } on GzipFormatException {
    rethrow;
  } on CompressionFormatException catch (e) {
    // DEFLATE-level (or other) format errors surface under the GZIP contract.
    throw GzipFormatException(e.message);
  } on FormatException catch (e) {
    throw GzipFormatException(e.message.toString());
  } on ArgumentError catch (e) {
    throw GzipFormatException(e.message?.toString() ?? e.toString());
  } on StateError catch (e) {
    throw GzipFormatException(e.message);
  }
  // Other errors (library bugs) propagate unchanged — see [guardFormat].
}

/// GZIP file format implementation (RFC 1952)
///
/// Handles GZIP header and trailer around DEFLATE-compressed data.
class GzipFrame {
  /// Magic number ID1 (0x1F)
  static const int id1 = 0x1F;

  /// Magic number ID2 (0x8B)
  static const int id2 = 0x8B;

  /// Compression method (8 = DEFLATE)
  static const int cmDeflate = 8;

  /// Flag: file is probably ASCII text
  static const int ftext = 0x01;

  /// Flag: CRC16 present for header
  static const int fhcrc = 0x02;

  /// Flag: extra fields present
  static const int fextra = 0x04;

  /// Flag: original filename present
  static const int fname = 0x08;

  /// Flag: comment present
  static const int fcomment = 0x10;

  /// Operating system: Unix
  static const int osUnix = 3;

  /// Operating system: unknown
  static const int osUnknown = 255;

  /// Compresses data with GZIP framing
  ///
  /// Returns complete GZIP file including header, compressed data, and trailer.
  static Uint8List compress(
    Uint8List data, {
    int level = 6,
    String? filename,
    String? comment,
    int? modificationTime,
  }) {
    final output = BytesBuilder(copy: false);

    // Build header
    final flags = _buildFlags(filename: filename, comment: comment);
    final mtime = modificationTime ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);

    // Write header
    output.addByte(id1);
    output.addByte(id2);
    output.addByte(cmDeflate);
    output.addByte(flags);

    // Modification time (32-bit, little-endian)
    output.addByte(mtime & 0xFF);
    output.addByte((mtime >> 8) & 0xFF);
    output.addByte((mtime >> 16) & 0xFF);
    output.addByte((mtime >> 24) & 0xFF);

    // Extra flags (compression level indicator)
    final xfl = level >= 9 ? 2 : (level <= 1 ? 4 : 0);
    output.addByte(xfl);

    // Operating system
    output.addByte(osUnix);

    // Optional fields
    if (filename != null) {
      final bytes = utf8.encode(filename);
      output.add(bytes);
      output.addByte(0); // Null terminator
    }

    if (comment != null) {
      final bytes = utf8.encode(comment);
      output.add(bytes);
      output.addByte(0); // Null terminator
    }

    // Compress data
    final encoder = DeflateEncoder(level: level);
    final compressed = encoder.compress(data);
    output.add(compressed);

    // Write trailer
    final crc = Crc32.hash(data);
    final isize = data.length & 0xFFFFFFFF;

    // CRC32 (32-bit, little-endian)
    output.addByte(crc & 0xFF);
    output.addByte((crc >> 8) & 0xFF);
    output.addByte((crc >> 16) & 0xFF);
    output.addByte((crc >> 24) & 0xFF);

    // ISIZE (32-bit, little-endian)
    output.addByte(isize & 0xFF);
    output.addByte((isize >> 8) & 0xFF);
    output.addByte((isize >> 16) & 0xFF);
    output.addByte((isize >> 24) & 0xFF);

    return output.takeBytes();
  }

  /// Decompresses GZIP-formatted data
  ///
  /// Handles both single-member and concatenated multi-member GZIP files
  /// as allowed by RFC 1952. Returns the decompressed data from all members
  /// concatenated together. Validates CRC and size for each member.
  ///
  /// [maxSize] limits total output to prevent OOM attacks (null = unlimited).
  static Uint8List decompress(Uint8List data, {int? maxSize}) =>
      gzipBoundary(() => _decompress(data, maxSize: maxSize));

  static Uint8List _decompress(Uint8List data, {int? maxSize}) {
    if (data.length < 10) {
      throw GzipFormatException('Invalid GZIP header: too short');
    }

    final result = BytesBuilder(copy: false);
    var position = 0;
    var total = 0;

    // Process each member (RFC 1952 allows concatenated members)
    while (position < data.length) {
      // Check for minimum member size
      if (position + 10 > data.length) {
        throw GzipFormatException('Incomplete GZIP member at position $position');
      }

      // Calculate remaining size limit for this member
      final remaining = maxSize != null ? maxSize - total : null;

      // Decompress one member
      final (memberData, memberLen) = _decompressMember(
        data,
        position,
        remaining,
      );

      result.add(memberData);
      total += memberData.length;
      position += memberLen;
    }

    return result.takeBytes();
  }

  /// Decompresses a single GZIP member starting at [offset]
  ///
  /// Returns a record containing:
  /// - The decompressed data
  /// - The total byte length of this member (header + compressed + trailer)
  static (Uint8List, int) _decompressMember(
    Uint8List data,
    int offset,
    int? maxSize,
  ) {
    final start = offset;

    // Verify magic numbers
    if (data[offset++] != id1 || data[offset++] != id2) {
      throw GzipFormatException('Invalid GZIP magic number at position $start');
    }

    // Check compression method
    final cm = data[offset++];
    if (cm != cmDeflate) {
      throw GzipFormatException('Unsupported compression method: $cm');
    }

    // Read flags
    final flags = data[offset++];
    if ((flags & 0xE0) != 0) {
      throw GzipFormatException('Reserved GZIP FLG bits set: 0x${flags.toRadixString(16)}');
    }

    // Skip modification time (4 bytes)
    offset += 4;

    // Skip extra flags and OS
    offset += 2;

    // Skip optional fields
    if ((flags & fextra) != 0) {
      if (offset + 2 > data.length) {
        throw GzipFormatException('Invalid FEXTRA field');
      }
      final xlen = data[offset] | (data[offset + 1] << 8);
      offset += 2;
      if (offset + xlen > data.length) {
        throw GzipFormatException('Truncated FEXTRA field');
      }
      offset += xlen;
    }

    if ((flags & fname) != 0) {
      // Skip filename (null-terminated)
      while (offset < data.length && data[offset] != 0) {
        offset++;
      }
      if (offset >= data.length) {
        throw GzipFormatException('Truncated FNAME field: missing NUL terminator');
      }
      offset++; // Skip null terminator
    }

    if ((flags & fcomment) != 0) {
      // Skip comment (null-terminated)
      while (offset < data.length && data[offset] != 0) {
        offset++;
      }
      if (offset >= data.length) {
        throw GzipFormatException('Truncated FCOMMENT field: missing NUL terminator');
      }
      offset++; // Skip null terminator
    }

    if ((flags & fhcrc) != 0) {
      // Validate header CRC16
      if (offset + 2 > data.length) {
        throw GzipFormatException('Truncated FHCRC field');
      }

      // CRC16 is the lower 16 bits of CRC32 of header bytes
      final headerCrc = Crc32.hash(Uint8List.sublistView(data, start, offset));
      final expectedCrc16 = headerCrc & 0xFFFF;
      final actualCrc16 = data[offset] | (data[offset + 1] << 8);

      if (actualCrc16 != expectedCrc16) {
        throw GzipFormatException(
          'Header CRC mismatch: expected 0x${expectedCrc16.toRadixString(16)}, '
          'got 0x${actualCrc16.toRadixString(16)}',
        );
      }

      offset += 2;
    }

    // Decompress the DEFLATE stream and get bytes consumed
    final compressedStart = offset;
    final compressedData = Uint8List.sublistView(data, compressedStart);
    final decoder = DeflateDecoder(maxSize: maxSize);
    final (decompressed, consumed) = decoder.decompressWithPosition(compressedData);
    offset = compressedStart + consumed;

    // Read and validate trailer (CRC32 + ISIZE)
    if (offset + 8 > data.length) {
      throw GzipFormatException('Truncated GZIP trailer');
    }

    // Read CRC32
    final expectedCrc = data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
    offset += 4;

    // Verify CRC
    final actualCrc = Crc32.hash(decompressed);
    if (actualCrc != expectedCrc) {
      throw GzipFormatException(
        'CRC mismatch: expected 0x${expectedCrc.toRadixString(16)}, '
        'got 0x${actualCrc.toRadixString(16)}',
      );
    }

    // Read ISIZE (original file size mod 2^32)
    final expectedSize = data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
    offset += 4;

    // Verify size (modulo 2^32)
    final actualSize = decompressed.length & 0xFFFFFFFF;
    if (actualSize != expectedSize) {
      throw GzipFormatException('Size mismatch: expected $expectedSize, got $actualSize');
    }

    return (decompressed, offset - start);
  }

  /// Builds flags byte from options
  static int _buildFlags({String? filename, String? comment}) {
    var flags = 0;
    if (filename != null) flags |= fname;
    if (comment != null) flags |= fcomment;
    return flags;
  }
}
