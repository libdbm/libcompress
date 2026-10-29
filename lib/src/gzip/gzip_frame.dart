import 'dart:typed_data';
import 'dart:convert';
import 'dart:math' as math;
import '../exceptions.dart';
import '../util/crc32.dart';
import 'deflate_encoder.dart';
import 'deflate_decoder.dart';

// Re-export exception from centralized location
export '../exceptions.dart' show GzipFormatException;

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

  /// Compresses data with GZIP framing
  ///
  /// Returns complete GZIP file including header, compressed data, and trailer.
  static Uint8List compress(
    final Uint8List data, {
    required final int mtime,
    final int level = 6,
    final String? filename,
    final String? comment,
  }) {
    return (BytesBuilder(copy: false)
          ..add(
            headerBytes(
              level: level,
              mtime: mtime,
              filename: filename,
              comment: comment,
            ),
          )
          ..add(DeflateEncoder(level: level).compress(data))
          ..add(trailerBytes(Crc32.hash(data), data.length)))
        .takeBytes();
  }

  /// A member header: magic, CM, FLG, MTIME, XFL (from [level]) and OS, then
  /// the NUL-terminated [filename] and [comment] when given.
  static Uint8List headerBytes({
    required final int level,
    required final int mtime,
    final String? filename,
    final String? comment,
  }) {
    final flags =
        (filename != null ? fname : 0) | (comment != null ? fcomment : 0);
    final xfl = level >= 9 ? 2 : (level <= 1 ? 4 : 0);
    final output = BytesBuilder(copy: false)
      ..add([
        id1, id2, cmDeflate, flags, //
        mtime & 0xFF, (mtime >> 8) & 0xFF, (mtime >> 16) & 0xFF,
        (mtime >> 24) & 0xFF,
        xfl, osUnix,
      ]);
    for (final field in [filename, comment]) {
      if (field != null) {
        output
          ..add(utf8.encode(field))
          ..addByte(0);
      }
    }
    return output.takeBytes();
  }

  /// A member trailer: the CRC-32 of the content and its size modulo 2^32,
  /// both little-endian.
  static Uint8List trailerBytes(final int crc, final int size) =>
      Uint8List.fromList([
        for (var shift = 0; shift < 32; shift += 8) (crc >> shift) & 0xFF,
        for (var shift = 0; shift < 32; shift += 8) (size >> shift) & 0xFF,
      ]);

  /// Parses the member header at `data[offset..end)` for the one-shot and
  /// incremental decoders. Returns its length, or null when more bytes are
  /// needed; [scan], when given, carries the FNAME/FCOMMENT search across
  /// calls so a long field arriving in pieces is scanned once. Throws once the
  /// bytes present are invalid.
  static int? header(
    final Uint8List data,
    final int offset,
    final int end, [
    final GzipHeaderScan? scan,
  ]) {
    if (end - offset < 10) return null;
    if (data[offset] != id1 || data[offset + 1] != id2) {
      throw GzipFormatException(
        'Invalid GZIP magic number at position $offset',
      );
    }
    if (data[offset + 2] != cmDeflate) {
      throw GzipFormatException(
        'Unsupported compression method: ${data[offset + 2]}',
      );
    }
    final flags = data[offset + 3];
    if ((flags & 0xE0) != 0) {
      throw GzipFormatException(
        'Reserved GZIP FLG bits set: 0x${flags.toRadixString(16)}',
      );
    }
    var position = offset + 10; // magic, CM, FLG, MTIME, XFL, OS

    if ((flags & fextra) != 0) {
      if (end < position + 2) return null;
      final xlen = data[position] | (data[position + 1] << 8);
      position += 2 + xlen;
      if (end < position) return null;
    }
    // FNAME and FCOMMENT are each NUL-terminated.
    for (final flag in [fname, fcomment]) {
      if ((flags & flag) == 0) continue;
      final name = scan?.name;
      if (flag == fname && name != null) {
        position = offset + name;
        continue;
      }
      var index = math.max(position, offset + (scan?.searched ?? 0));
      while (index < end && data[index] != 0) {
        index++;
      }
      if (index == end) {
        scan?.searched = end - offset;
        return null;
      }
      position = index + 1;
      if (flag == fname) scan?.name = position - offset;
    }
    if ((flags & fhcrc) != 0) {
      if (end < position + 2) return null;
      // CRC16 is the lower 16 bits of CRC32 of header bytes
      final expected =
          Crc32.hash(Uint8List.sublistView(data, offset, position)) & 0xFFFF;
      final actual = data[position] | (data[position + 1] << 8);
      if (actual != expected) {
        throw GzipFormatException(
          'Header CRC mismatch: expected 0x${expected.toRadixString(16)}, '
          'got 0x${actual.toRadixString(16)}',
        );
      }
      position += 2;
    }
    return position - offset;
  }

  /// Decompresses every member of [data] (RFC 1952 allows concatenated
  /// members) into one output, checking each member's CRC-32 and ISIZE. The
  /// output may not exceed [maxSize] in total.
  static Uint8List decompress(final Uint8List data, {final int? maxSize}) =>
      guardFormat(
        () => _decompress(data, maxSize: maxSize),
        GzipFormatException.new,
        limit: maxSize,
      );

  static Uint8List _decompress(final Uint8List data, {final int? maxSize}) {
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
        throw GzipFormatException(
          'Incomplete GZIP member at position $position',
        );
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
    final Uint8List data,
    int offset,
    final int? maxSize,
  ) {
    final start = offset;

    final length = header(data, offset, data.length);
    if (length == null) {
      throw GzipFormatException('Truncated GZIP header at position $start');
    }
    offset += length;

    // Decompress the DEFLATE stream and get bytes consumed
    final compressedStart = offset;
    final compressedData = Uint8List.sublistView(data, compressedStart);
    // The last member's ISIZE ends the input: a size hint for the output.
    final hint = data.length >= 4
        ? data[data.length - 4] |
              (data[data.length - 3] << 8) |
              (data[data.length - 2] << 16) |
              (data[data.length - 1] << 24)
        : null;
    final decoder = DeflateDecoder(maxSize: maxSize, hint: hint);
    final (decompressed, consumed) = decoder.decompressWithPosition(
      compressedData,
    );
    offset = compressedStart + consumed;

    // Read and validate trailer (CRC32 + ISIZE)
    if (offset + 8 > data.length) {
      throw GzipFormatException('Truncated GZIP trailer');
    }

    // Read CRC32
    final expectedCrc =
        data[offset] |
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
    final expectedSize =
        data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
    offset += 4;

    // Verify size (modulo 2^32)
    final actualSize = decompressed.length & 0xFFFFFFFF;
    if (actualSize != expectedSize) {
      throw GzipFormatException(
        'Size mismatch: expected $expectedSize, got $actualSize',
      );
    }

    return (decompressed, offset - start);
  }
}

/// How far [GzipFrame.header] got through a member's FNAME and FCOMMENT on
/// earlier calls, as offsets from the member start.
class GzipHeaderScan {
  /// Where FNAME ends (after its NUL), once found.
  int? name;

  /// Bytes searched for the terminator of the field still open.
  int searched = 0;
}
