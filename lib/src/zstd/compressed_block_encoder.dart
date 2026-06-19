import 'dart:typed_data';
import '../util/growable_buffer.dart';
import 'compressed_block_decoder.dart';
import 'fse_encoder.dart';
import 'huffman_encoder.dart';
import 'match_finder.dart';
import 'sequence_constants.dart' as seq;
import 'sequence_encoder.dart';

/// Compressed block encoder for Zstd
///
/// Encodes a block using:
/// - Huffman-compressed literals (or raw if Huffman doesn't compress well)
/// - FSE-compressed sequences (literal lengths, offsets, match lengths)
class CompressedBlockEncoder {
  /// Search depth for match finding (higher = better compression, slower)
  final int searchDepth;

  /// Whether to validate encoded blocks by decompressing them
  ///
  /// When enabled, each block is decompressed immediately after compression
  /// to verify correctness. This doubles CPU work but is useful for debugging.
  final bool validate;

  String? lastValidationError;
  String? lastValidationStack;

  /// Creates a compressed block encoder with specified search depth
  CompressedBlockEncoder({this.searchDepth = 32, this.validate = false});

  /// Encode a block using compressed format
  ///
  /// Returns the encoded block data (without block header)
  Uint8List encodeBlock(final Uint8List input) {
    if (input.isEmpty) {
      return Uint8List(0);
    }

    try {
      final matchFinder = MatchFinder(searchDepth: searchDepth);
      final matchResult = matchFinder.findMatches(input);
      final matches = matchResult.$1;
      final trailingLiterals = matchResult.$2;

      if (matches.isEmpty) {
        return Uint8List(0);
      }

      final literals = matchFinder.extractLiterals(
        input,
        matches,
        trailingLiterals,
      );

      final literalSection = _encodeLiteralSection(literals);
      final sequencesSection = _encodeSequencesSectionFse(matches);

      final output = Uint8List(literalSection.length + sequencesSection.length);
      output.setRange(0, literalSection.length, literalSection);
      output.setRange(literalSection.length, output.length, sequencesSection);

      if (validate && !_validateEncodedBlock(output, input)) {
        lastValidationError ??= 'Unknown validation error';
        return Uint8List(0);
      }
      lastValidationError = null;

      return output;
    } catch (_) {
      // Fall back to raw block when compressed encoding fails
      return Uint8List(0);
    }
  }

  Uint8List _encodeLiteralSection(final Uint8List literals) {
    // Try Huffman compression first for larger literal sections
    if (literals.length >= 64) {
      final huffman = _encodeHuffmanLiterals(literals);
      if (huffman != null && huffman.length < literals.length) {
        return huffman;
      }
    }
    return _encodeRawLiteralsOnly(literals);
  }

  /// Encode literals using Huffman compression
  ///
  /// Returns null if Huffman compression is not beneficial
  Uint8List? _encodeHuffmanLiterals(final Uint8List literals) {
    if (literals.isEmpty) return null;

    // Count symbol frequencies
    final counts = List.filled(256, 0);
    var maxSym = 0;
    for (final b in literals) {
      counts[b]++;
      if (b > maxSym) maxSym = b;
    }

    // Check if we have enough symbol diversity for Huffman
    var distinct = 0;
    for (final c in counts) {
      if (c > 0) distinct++;
    }
    if (distinct < 2) return null; // Single symbol, use RLE instead

    // Build Huffman table
    final encoder = HuffmanEncoder();
    try {
      encoder.buildFromCounts(counts, maxSym);
    } catch (_) {
      return null;
    }

    // The current Huffman weights encoder only supports the direct 4-bit
    // representation, whose header can encode at most 128 weights.
    if (maxSym + 1 > 128) {
      return null;
    }

    // Encode weights header
    final header = encoder.encodeWeightsHeader(maxSym + 1);

    // Encode literals (use 4 streams for larger inputs)
    Uint8List? encoded;
    final use4Streams = literals.length >= 256;
    if (use4Streams) {
      encoded = encoder.encode4Streams(literals);
    } else {
      encoded = encoder.encodeSingle(literals);
    }
    if (encoded == null) return null;

    // Calculate total compressed size
    final totalCompressed = header.length + encoded.length;

    // Only use Huffman if it actually compresses
    if (totalCompressed >= literals.length) return null;

    // Build literals section header + data
    return _buildHuffmanLiteralSection(
      literals.length,
      totalCompressed,
      header,
      encoded,
      use4Streams,
    );
  }

  /// Build the complete Huffman literals section
  ///
  /// Header format (decoder reads as little-endian):
  /// - Bits 0-1: Literals_Block_Type (2 = Compressed)
  /// - Bits 2-3: Size_Format
  /// - Bits 4+: Regenerated_Size, then Compressed_Size
  Uint8List _buildHuffmanLiteralSection(
    final int regeneratedSize,
    final int compressedSize,
    final Uint8List weightsHeader,
    final Uint8List compressedStreams,
    final bool use4Streams,
  ) {
    const type = 2; // Compressed_Literals_Block

    // Choose format based on size requirements
    // Format 0/1: 10-bit sizes (max 1023), 3 bytes
    // Format 2: 14-bit sizes (max 16383), 4 bytes
    // Format 3: 18-bit sizes (max 262143), 5 bytes

    int sizeFormat;
    int headerSize;
    int bitsPerSize;

    if (regeneratedSize < 1024 && compressedSize < 1024) {
      sizeFormat = use4Streams ? 1 : 0;
      headerSize = 3;
      bitsPerSize = 10;
    } else if (regeneratedSize < 16384 && compressedSize < 16384) {
      sizeFormat = 2; // Always 4 streams for format 2
      headerSize = 4;
      bitsPerSize = 14;
    } else {
      sizeFormat = 3; // Always 4 streams for format 3
      headerSize = 5;
      bitsPerSize = 18;
    }

    // Build header as little-endian value. This can require more than 32 bits
    // for size format 3, so avoid JS bitwise operators after dart2js.
    final sizeMask = (BigInt.one << bitsPerSize) - BigInt.one;
    var header = BigInt.from((type & 0x03) | ((sizeFormat & 0x03) << 2));
    header |= (BigInt.from(regeneratedSize) & sizeMask) << 4;
    header |= (BigInt.from(compressedSize) & sizeMask) << (4 + bitsPerSize);

    final output = Uint8List(
      headerSize + weightsHeader.length + compressedStreams.length,
    );

    // Convert to bytes (little-endian).
    for (var i = 0; i < headerSize; i++) {
      output[i] = ((header >> (i * 8)) & BigInt.from(0xff)).toInt();
    }

    var pos = headerSize;
    output.setRange(pos, pos + weightsHeader.length, weightsHeader);
    pos += weightsHeader.length;
    output.setRange(pos, pos + compressedStreams.length, compressedStreams);

    return output;
  }

  /// Encode raw literals section (header + payload)
  Uint8List _encodeRawLiteralsOnly(final Uint8List literals) {
    final output = <int>[];

    // Literals section header - Raw format
    final size = literals.length;
    if (size < 32) {
      // Small raw: Bits[0-1]=00 (raw), Bits[2-3]=00 (format), Bits[4-8]=size (5 bits)
      output.add((size << 3) | 0x00);
    } else if (size < 4096) {
      // Medium raw: Bits[0-1]=00 (raw), Bits[2-3]=01 (format), Bits[4-15]=size (12 bits)
      // Byte 1: bits 0-3 = 0100, bits 4-7 = size[0:3]
      // Byte 2: bits 0-7 = size[4:11]
      output.add(((size & 0x0F) << 4) | 0x04);
      output.add((size >> 4) & 0xFF);
    } else {
      // Large raw: Bits[0-1]=00 (raw), Bits[2-3]=11 (format), Bits[4-23]=size (20 bits)
      // Byte 1: bits 0-3 = 1100, bits 4-7 = size[0:3]
      // Byte 2: bits 0-7 = size[4:11]
      // Byte 3: bits 0-7 = size[12:19]
      output.add(((size & 0x0F) << 4) | 0x0C);
      output.add((size >> 4) & 0xFF);
      output.add((size >> 12) & 0xFF);
    }

    output.addAll(literals);

    return Uint8List.fromList(output);
  }

  /// Encode sequences section using FSE with optimal table selection
  Uint8List _encodeSequencesSectionFse(List<ZstdMatch> matches) {
    final output = <int>[];

    // Write sequence count per RFC 8878 Section 3.1.1.3.2.1.1
    final count = matches.length;
    if (count < 128) {
      output.add(count);
    } else if (count < 0x7F00) {
      output.add(128 + (count >> 8));
      output.add(count & 0xFF);
    } else {
      output.add(0xFF);
      final adjusted = count - 0x7F00;
      output.add(adjusted & 0xFF);
      output.add((adjusted >> 8) & 0xFF);
    }

    // Gather symbol statistics using SequenceSymbols to ensure correct
    // offset symbols including repeat offset handling (symbols 0, 1)
    final symbols = SequenceSymbols.from(matches);

    final llStats = FseEncoder.stats(symbols.literalLengths, 35);
    final ofStats = FseEncoder.stats(symbols.offsets, 31);
    final mlStats = FseEncoder.stats(symbols.matchLengths, 52);

    // Select optimal encoding mode for each component
    final selector = EncodingModeSelector(
      llStats: llStats,
      ofStats: ofStats,
      mlStats: mlStats,
    );

    final (llMode, ofMode, mlMode, llEnc, ofEnc, mlEnc) = selector.select(
      llPredefined: seq.llDefaultNorm,
      llPredefinedLog: seq.llDefaultNormLog,
      ofPredefined: seq.ofDefaultNorm,
      ofPredefinedLog: seq.ofDefaultNormLog,
      mlPredefined: seq.mlDefaultNorm,
      mlPredefinedLog: seq.mlDefaultNormLog,
    );

    // Write symbol compression modes byte
    output.add(encodeSymbolMode(llMode, ofMode, mlMode));

    // Write table descriptions per RFC 8878 Section 3.1.1.3.2.1
    // Order: LL, OF, ML. Each gets FSE table (mode 2) or RLE byte (mode 1)

    // Literal Lengths table
    if (llMode == 2 && llEnc != null) {
      output.addAll(llEnc.encodeHeader());
    } else if (llMode == 1) {
      output.add(_findRleSymbol(llStats));
    }

    // Offsets table
    if (ofMode == 2 && ofEnc != null) {
      output.addAll(ofEnc.encodeHeader());
    } else if (ofMode == 1) {
      output.add(_findRleSymbol(ofStats));
    }

    // Match Lengths table
    if (mlMode == 2 && mlEnc != null) {
      output.addAll(mlEnc.encodeHeader());
    } else if (mlMode == 1) {
      output.add(_findRleSymbol(mlStats));
    }

    // Encode sequences using appropriate tables
    final encoder = SequenceEncoder.withModes(
      llMode: llMode,
      ofMode: ofMode,
      mlMode: mlMode,
      llNorm: llEnc?.normalized,
      ofNorm: ofEnc?.normalized,
      mlNorm: mlEnc?.normalized,
      llLog: llEnc?.tableLog,
      ofLog: ofEnc?.tableLog,
      mlLog: mlEnc?.tableLog,
    );

    final bits = encoder.encodeSequences(matches);
    output.addAll(bits);

    return Uint8List.fromList(output);
  }

  int _findRleSymbol(final SymbolStats stats) {
    for (var i = 0; i < stats.counts.length; i++) {
      if (stats.counts[i] > 0) return i;
    }
    return 0;
  }

  bool _validateEncodedBlock(Uint8List blockData, Uint8List source) {
    final decoder = CompressedBlockDecoder();
    final previousOffsets = [1, 4, 8];
    final buffer = GrowableBuffer(source.length);

    try {
      decoder.decodeBlock(
        blockData,
        0,
        blockData.length,
        buffer,
        previousOffsets,
      );
      final decoded = buffer.toBytes();
      if (decoded.length != source.length) {
        return false;
      }
      for (var i = 0; i < decoded.length; i++) {
        if (decoded[i] != source[i]) {
          return false;
        }
      }
      lastValidationError = null;
      lastValidationStack = null;
      return true;
    } catch (error, stack) {
      lastValidationError = error.toString();
      lastValidationStack = stack.toString();
      return false;
    }
  }
}
