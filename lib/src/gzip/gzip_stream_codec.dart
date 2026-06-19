import 'dart:typed_data';

import '../compression_stream_codec.dart';
import '../util/bit_stream.dart';
import '../util/stream_compress_transformer.dart';
import '../util/stream_decompress_transformer.dart';
import 'deflate_common.dart';
import 'gzip_codec.dart';
import 'gzip_frame.dart';
import 'huffman_tables.dart';

/// Default maximum buffer size for stream decoders (64MB)
const int defaultMaxBufferSize = 64 * 1024 * 1024;

/// Gzip streaming codec
///
/// Provides stream-based compression and decompression for GZIP.
/// Each chunk emitted during compression is a complete, independent
/// GZIP member that can be concatenated (per RFC 1952, multiple members
/// are allowed).
class GzipStreamCodec extends CompressionStreamCodec {
  /// Compression level (1-9)
  final int level;

  /// Maximum decompressed size per member (prevents OOM attacks)
  final int? maxSize;

  /// Maximum buffer size for compressed data before rejecting
  final int maxBufferSize;

  /// Chunk size for buffering input during compression
  final int chunkSize;

  /// Creates a GZIP streaming codec
  GzipStreamCodec({
    this.level = 6,
    this.maxSize = gzipDefaultMaxDecompressedSize,
    this.maxBufferSize = defaultMaxBufferSize,
    this.chunkSize = 1024 * 1024, // 1MB default
  });

  @override
  String get name => 'GZIP';

  @override
  Stream<Uint8List> compress(final Stream<Uint8List> input) {
    return StreamCompressTransformer(
      chunkSize: chunkSize,
      compress: (data) => GzipFrame.compress(data, level: level),
    ).bind(input);
  }

  @override
  Stream<Uint8List> decompress(final Stream<Uint8List> input) {
    return _GzipDecompressTransformer(
      maxSize: maxSize,
      maxBufferSize: maxBufferSize,
    ).bind(input);
  }
}

/// Transformer for GZIP decompression
class _GzipDecompressTransformer
    extends StreamDecompressTransformer<GzipFormatException> {
  _GzipDecompressTransformer({
    super.maxSize,
    required super.maxBufferSize,
  });

  @override
  int get minFrameSize => 10;

  @override
  bool isValidStart(final List<int> buffer, final int offset) =>
      buffer[offset] == GzipFrame.id1 && buffer[offset + 1] == GzipFrame.id2;

  @override
  FrameParseResult? tryParseFrame(final List<int> buffer, final int offset) =>
      _tryParseMember(buffer, offset);

  @override
  Uint8List decompress(final Uint8List frame) =>
      GzipFrame.decompress(frame, maxSize: maxSize);

  @override
  GzipFormatException createBufferError() => GzipFormatException(
        'Stream buffer exceeded $maxBufferSize bytes - '
        'frame too large or malformed',
      );

  @override
  GzipFormatException createMagicError(final List<int> buffer, final int offset) =>
      GzipFormatException('Invalid GZIP magic number at offset $offset');

  @override
  GzipFormatException createIncompleteError() =>
      GzipFormatException('Incomplete GZIP member at end of stream');

  /// Try to parse a complete GZIP member at offset, return null if incomplete
  ///
  /// Uses efficient boundary detection by parsing DEFLATE block headers
  /// to find where the stream ends, rather than re-decompressing.
  FrameParseResult? _tryParseMember(final List<int> buffer, final int offset) {
    if (buffer.length - offset < 10) return null;

    var pos = offset;

    // Magic
    if (buffer[pos++] != GzipFrame.id1 || buffer[pos++] != GzipFrame.id2) {
      return null;
    }

    // Compression method
    pos++;

    // Flags
    final flags = buffer[pos++];

    // Skip MTIME, XFL, OS
    pos += 6;

    // FEXTRA
    if ((flags & GzipFrame.fextra) != 0) {
      if (buffer.length < pos + 2) return null;
      final xlen = buffer[pos] | (buffer[pos + 1] << 8);
      pos += 2;
      if (buffer.length < pos + xlen) return null;
      pos += xlen;
    }

    // FNAME (null-terminated)
    if ((flags & GzipFrame.fname) != 0) {
      while (pos < buffer.length && buffer[pos] != 0) {
        pos++;
      }
      if (pos >= buffer.length) return null;
      pos++; // Skip null terminator
    }

    // FCOMMENT (null-terminated)
    if ((flags & GzipFrame.fcomment) != 0) {
      while (pos < buffer.length && buffer[pos] != 0) {
        pos++;
      }
      if (pos >= buffer.length) return null;
      pos++; // Skip null terminator
    }

    // FHCRC
    if ((flags & GzipFrame.fhcrc) != 0) {
      if (buffer.length < pos + 2) return null;
      pos += 2;
    }

    // Find DEFLATE stream end by parsing block headers
    final deflateStart = pos;
    final end = _findDeflateEnd(buffer, deflateStart);
    if (end == null) return null;

    // Need 8 more bytes for trailer (CRC32 + ISIZE)
    final memberEnd = end + 8;
    if (buffer.length < memberEnd) return null;

    final length = memberEnd - offset;
    final frame = Uint8List.fromList(buffer.sublist(offset, memberEnd));
    return FrameParseResult(frame, length);
  }

  /// Find the end of a DEFLATE stream by parsing block headers
  ///
  /// Returns byte position after the final block, or null if incomplete.
  /// This parses block structure without fully decompressing.
  int? _findDeflateEnd(final List<int> buffer, final int start) {
    try {
      // Single bulk copy of the tail into a typed array, rather than a
      // List<int> sublist followed by a second Uint8List.fromList copy.
      final length = buffer.length - start;
      final data = Uint8List(length)..setRange(0, length, buffer, start);
      final input = BitStreamReader(data);

      var final_ = false;
      while (!final_) {
        // Need at least 3 bits for block header
        if (input.isEndOfStream) return null;

        try {
          final_ = input.readBits(1) == 1;
          final type = input.readBits(2);

          switch (type) {
            case 0: // Stored block
              input.flushToByte();
              final len = input.readBits(16);
              input.readBits(16); // NLEN
              // Skip literal data
              for (var i = 0; i < len; i++) {
                input.readBits(8);
              }
              break;

            case 1: // Fixed Huffman
              _skipHuffmanBlock(input, true);
              break;

            case 2: // Dynamic Huffman
              _skipHuffmanBlock(input, false);
              break;

            default:
              return null; // Invalid block type
          }
        } catch (_) {
          return null; // Incomplete data
        }
      }

      // Align to byte boundary after final block
      input.flushToByte();

      // Return byte position after final block
      return start + input.bytePosition;
    } catch (_) {
      return null;
    }
  }

  /// Skip over a Huffman-encoded block without fully decoding
  void _skipHuffmanBlock(final BitStreamReader input, final bool fixed) {
    HuffmanDecoder literalDecoder;
    HuffmanDecoder distanceDecoder;

    if (fixed) {
      literalDecoder = fixedLiteralDecoder;
      distanceDecoder = fixedDistanceDecoder;
    } else {
      // Parse dynamic tables
      final hlit = input.readBits(5) + 257;
      final hdist = input.readBits(5) + 1;
      final hclen = input.readBits(4) + 4;

      // Read code length code lengths
      final clLengths = List<int>.filled(19, 0);
      for (var i = 0; i < hclen; i++) {
        clLengths[codeLengthOrder[i]] = input.readBits(3);
      }

      final clDecoder = buildDecoder(clLengths);

      // Decode literal/length and distance code lengths
      final codeLengths = <int>[];
      while (codeLengths.length < hlit + hdist) {
        final symbol = _decodeSymbol(input, clDecoder);

        if (symbol < 16) {
          codeLengths.add(symbol);
        } else if (symbol == 16) {
          if (codeLengths.isEmpty) throw FormatException('Invalid repeat');
          final previous = codeLengths.last;
          final repeat = input.readBits(2) + 3;
          for (var i = 0; i < repeat; i++) {
            codeLengths.add(previous);
          }
        } else if (symbol == 17) {
          final repeat = input.readBits(3) + 3;
          for (var i = 0; i < repeat; i++) {
            codeLengths.add(0);
          }
        } else if (symbol == 18) {
          final repeat = input.readBits(7) + 11;
          for (var i = 0; i < repeat; i++) {
            codeLengths.add(0);
          }
        }
      }

      literalDecoder = buildDecoder(codeLengths.sublist(0, hlit));
      distanceDecoder = buildDecoder(codeLengths.sublist(hlit, hlit + hdist));
    }

    // Decode symbols until end-of-block
    while (true) {
      final symbol = _decodeSymbol(input, literalDecoder);

      if (symbol < 256) {
        // Literal - just skip
        continue;
      } else if (symbol == endBlock) {
        break;
      } else if (symbol <= 285) {
        // Length code - read extra bits
        final code = symbol - 257;
        final extra = lengthExtraBits[code];
        if (extra > 0) input.readBits(extra);

        // Distance code
        final distCode = _decodeSymbol(input, distanceDecoder);
        if (distCode < 30) {
          final distExtra = distanceExtraBits[distCode];
          if (distExtra > 0) input.readBits(distExtra);
        }
      }
    }
  }

  int _decodeSymbol(final BitStreamReader input, final HuffmanDecoder decoder) {
    var code = 0;
    var bits = 0;

    while (bits < 15) {
      final bit = input.readBits(1);
      code = (code << 1) | bit;
      bits++;

      final symbol = decoder.decode(code, bits);
      if (symbol != null) return symbol;
    }

    throw FormatException('Invalid Huffman code');
  }
}
