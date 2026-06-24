# libcompress

A pure Dart compression library with native implementations of LZ4, Snappy, GZIP, and Zstd algorithms. No native 
dependencies - works on all Dart platforms.

## Features

- **LZ4 Compression**: Fast compression/decompression with LZ4 Frame format
  - Block-based compression with configurable block sizes (64KB, 256KB, 1MB, 4MB)
  - Optional content checksums using XXH32
  - High-compression (HC) mode with levels 1-9
  - Compatible with command-line `lz4` tool

- **Snappy Compression**: High-speed compression optimized for throughput
  - Raw block format with varint length prefix
  - Framing format compatible with `snzip` CLI
  - Configurable chunk sizes up to 64KB

- **GZIP Compression**: Full DEFLATE implementation (RFC 1952)
  - Pure Dart DEFLATE encoder/decoder
  - Compression levels 1-9
  - Optional filename/comment metadata
  - CRC32 verification
  - Compatible with `gzip` command-line tool

- **Zstd Compression**: Zstandard implementation (RFC 8878)
  - Compressed blocks with Huffman/FSE entropy coding
  - Sequence encoding (literal lengths, offsets, match lengths)
  - Repeat offset optimization
  - Hash chain match finding with configurable depth
  - Compression levels 1-22
  - Optional XXH64 content checksums
  - Compatible with the `zstd` command-line tool for non-dictionary frames
  - **Not supported:** dictionary-compressed frames (frames with a Dictionary_ID
    are rejected) and the legacy (pre-v0.8) frame formats

- **Stream Processing**: All codecs support stream-based compression/decompression

## Usage

```dart
import 'package:libcompress/libcompress.dart';

void main() async {
  final data = Uint8List.fromList([1, 2, 3, 4, 5, ...]);

  // Block-based compression using factory
  final codec = CodecFactory.codec(CodecType.lz4);
  final compressed = codec.compress(data);
  final decompressed = codec.decompress(compressed);

  // Direct codec instantiation with options
  final zstd = ZstdCodec(level: 6, enableChecksum: true);
  final zstdCompressed = zstd.compress(data);

  // Stream-based compression
  final streamCodec = CodecFactory.streaming(CodecType.gzip);
  final compressedStream = streamCodec.compress(inputStream);
  await for (final chunk in compressedStream) {
    // Process compressed chunks
  }

  // Check codec capabilities
  if (codec.supports(CodecMode.stream)) {
    final stream = CodecFactory.streaming(CodecType.lz4);
  }

  // Parse codec type from string (e.g., from config)
  final type = CodecType.parse('snappy');
  final snappyCodec = CodecFactory.codec(type);
}
```

## CLI Tool

The library includes a command-line interface:

```bash
# Run from package directory
dart run :libcompress [options] <input> <output>

# Compress with LZ4 (default)
dart run :libcompress input.txt output.lz4

# Decompress
dart run :libcompress -d output.lz4 restored.txt

# Use different codecs
dart run :libcompress --zstd -9 input.txt output.zst
dart run :libcompress --gzip input.txt output.gz
dart run :libcompress --snappy input.txt output.sz

# Stream mode for large files
dart run :libcompress --stream --lz4 largefile.bin compressed.lz4

# LZ4 with custom block size
dart run :libcompress --lz4 -9 --block-size 1M input.txt output.lz4
```

## Implementation Details

### LZ4
- 16-bit hash table for match finding
- 4-byte minimum match length
- 65KB maximum back-reference distance
- Frame format with magic number `0x184D2204`
- HC mode uses hash chains for better compression

### Snappy
- 14-bit hash table (16384 entries)
- 4-byte minimum match length
- Three copy offset formats: 1-byte, 2-byte, and 4-byte
- Optional framing format with CRC32c checksums

### GZIP
- Full DEFLATE implementation with Huffman coding
- Dynamic and fixed Huffman tables
- LZ77 match finding with configurable window
- CRC32 integrity verification

### Zstd
- FSE (Finite State Entropy) encoding
- Huffman-compressed literals
- Hash chain match finding (depth 4-1024 based on level)
- Repeat offset tracking for better compression
- 128KB maximum block size per spec

## Testing

```bash
# Run all tests
dart test

# Run specific codec tests
dart test test/lz4_codec_test.dart
dart test test/zstd_cli_compatibility_test.dart

# Run benchmarks (requires CLI tools installed)
RUN_BENCHMARKS=1 dart test test/benchmark_test.dart
```

## CLI Compatibility

All codecs produce output compatible with standard command-line tools:

| Codec  | CLI Tool | Verified |
|--------|----------|----------|
| LZ4    | `lz4`    | ✓        |
| Snappy | `snzip`  | ✓        |
| GZIP   | `gzip`   | ✓        |
| Zstd   | `zstd`   | ✓        |

Bidirectional compatibility: library output can be decompressed by CLI tools, and CLI output can be decompressed by
the library. One exception: **Zstd dictionary-compressed frames** (produced with `zstd -D`) are not supported and are
rejected on decode.

## Security

- All decompressors enforce a `maxSize` limit by default to prevent decompression-bomb / OOM attacks. Passing
  `null` disables the limit (unlimited output) and should be used only with **trusted** input.
- Stream decompressors additionally cap buffered compressed input (default 64MB), rejecting oversized chunks
  before allocating them.
- **For untrusted or large input, prefer the streaming APIs**: block decode builds the whole output (up to the
  cap) and verifies trailers/checksums only at the end, so corrupt data can still consume CPU and memory up to the
  limit before rejection. Streaming decode is incremental and bounded; use `verified: true` when all-or-nothing
  integrity (no output emitted until the trailer validates) is required.
- Block size validation per format specifications
- No dictionary support (prevents dictionary-based attacks)

## References

- [LZ4 Frame Format](https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md)
- [Snappy Format](https://github.com/google/snappy/blob/main/format_description.txt)
- [RFC 1952 - GZIP](https://datatracker.ietf.org/doc/html/rfc1952)
- [RFC 1951 - DEFLATE](https://datatracker.ietf.org/doc/html/rfc1951)
- [RFC 8878 - Zstandard](https://datatracker.ietf.org/doc/html/rfc8878)

## License

See LICENSE file for details.
