import 'dart:typed_data';

import '../exceptions.dart';
import '../util/growable_buffer.dart';
import 'bit_reader.dart';
import 'meta_block.dart';

/// Reads the stream header (RFC 7932 section 9.1) and returns `WBITS`
/// (10..24). The window is `(1 << WBITS) - 16` bytes.
int readWindowBits(final BitReader reader) {
  if (reader.bit() == 0) return 16;
  final high = reader.bits(3);
  if (high != 0) return 17 + high;
  final low = reader.bits(3);
  if (low == 1) {
    throw const BrotliFormatException(
      'Large-window Brotli streams are not supported',
    );
  }
  return low == 0 ? 17 : 8 + low;
}

/// The kind of a meta-block (RFC 7932 section 9.2).
enum MetaBlockKind {
  /// The final, empty meta-block (`ISLAST` and `ISLASTEMPTY`).
  end,

  /// Metadata, skipped by the decoder.
  metadata,

  /// `MLEN` stored bytes.
  uncompressed,

  /// `MLEN` bytes of prefix-coded commands.
  compressed,
}

/// A decoded meta-block header. [length] is `MLEN` for data meta-blocks and
/// `MSKIPLEN` for metadata.
typedef MetaBlockHeader = ({MetaBlockKind kind, bool last, int length});

/// Reads one meta-block header, up to and excluding the data. For metadata
/// and uncompressed meta-blocks the reader is left at the byte boundary where
/// the bytes begin, with the padding checked.
MetaBlockHeader readMetaBlockHeader(final BitReader reader) {
  final last = reader.bit() == 1;
  if (last && reader.bit() == 1) {
    return (kind: MetaBlockKind.end, last: true, length: 0);
  }
  final nibbles = reader.bits(2);
  if (nibbles == 3) {
    if (reader.bit() != 0) {
      throw const BrotliFormatException('Reserved metadata bit is set');
    }
    final count = reader.bits(2);
    var length = 0;
    for (var i = 0; i < count; i++) {
      final byte = reader.bits(8);
      if (i == count - 1 && count > 1 && byte == 0) {
        throw const BrotliFormatException('MSKIPLEN has a leading zero byte');
      }
      length |= byte << (8 * i);
    }
    if (count > 0) length++;
    _pad(reader);
    return (kind: MetaBlockKind.metadata, last: last, length: length);
  }
  final digits = nibbles + 4;
  var length = 0;
  for (var i = 0; i < digits; i++) {
    final nibble = reader.bits(4);
    if (i == digits - 1 && digits > 4 && nibble == 0) {
      throw const BrotliFormatException('MLEN has a leading zero nibble');
    }
    length |= nibble << (4 * i);
  }
  length++;
  if (!last && reader.bit() == 1) {
    _pad(reader);
    return (kind: MetaBlockKind.uncompressed, last: false, length: length);
  }
  return (kind: MetaBlockKind.compressed, last: last, length: length);
}

void _pad(final BitReader reader) {
  if (reader.align() != 0) {
    throw const BrotliFormatException('Non-zero padding bits');
  }
}

/// Whole-buffer Brotli decoder (RFC 7932).
class BrotliDecoder {
  BrotliDecoder({this.maxSize, this.size});

  /// Cap on decoded output, or null for unlimited.
  final int? maxSize;

  /// Expected output size, used to size the output buffer.
  final int? size;

  /// Decodes the single Brotli stream in [data]. Bytes after the stream are
  /// an error.
  Uint8List decompress(final Uint8List data) {
    return guardFormat(
      () => _decode(data),
      BrotliFormatException.new,
      limit: maxSize,
    );
  }

  Uint8List _decode(final Uint8List data) {
    final reader = BitReader(data);
    // The expected size presizes the output, but never past the cap: the
    // size comes from the caller, possibly from untrusted metadata.
    final cap = maxSize;
    final hint = size ?? data.length * 4;
    final output = History(cap != null && cap < hint ? cap : hint, cap);
    final state = StreamState(readWindowBits(reader), output);
    while (true) {
      final header = readMetaBlockHeader(reader);
      switch (header.kind) {
        case MetaBlockKind.end:
          break;
        case MetaBlockKind.metadata:
          reader.discard(header.length);
        case MetaBlockKind.uncompressed:
          output.reserve(header.length);
          reader.copy(output.bytes, output.length, header.length);
          output.length += header.length;
        case MetaBlockKind.compressed:
          decodeCompressed(reader, state, header.length);
      }
      if (header.last) break;
    }
    _pad(reader);
    if (!reader.done) {
      throw const BrotliFormatException('Trailing bytes after the stream');
    }
    return trim(output.bytes, output.length);
  }
}
