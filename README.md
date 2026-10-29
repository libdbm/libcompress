# libcompress

A pure Dart compression library with native implementations of LZ4, Snappy, GZIP, and Zstd algorithms. No native
dependencies - works on all Dart platforms (VM and web).

## Features

- **LZ4 Compression**: Fast compression/decompression in three formats (`Lz4Format`)
  - `frame` (default): the LZ4 frame format, compatible with the command-line `lz4` tool. Block sizes 64KB, 256KB,
    1MB, 4MB; optional XXH32 content checksums; skippable frames are skipped; the legacy frame format (`lz4 -l`) is
    not supported
  - `raw`: a single bare LZ4 block (Parquet `LZ4_RAW`)
  - `hadoop`: Hadoop block framing (Parquet's legacy `LZ4` codec)
  - Compression levels 1-9: level 1 is the fast compressor; levels 2-9 use high-compression (HC) mode, with level 9
    within 2% of `lz4 -9`

- **Snappy Compression**: High-speed compression optimized for throughput, in two formats (`SnappyFormat`)
  - `raw` (default): a block with a varint length prefix (Parquet `SNAPPY`)
  - `framed`: the framing format with CRC32C checksums, compatible with `snzip`; chunk sizes up to 64KB

- **GZIP Compression**: Full DEFLATE implementation (RFC 1951/1952)
  - Pure Dart DEFLATE encoder/decoder
  - Compression levels 1-9
  - Optional filename/comment metadata; `mtime` defaults to 0 so output depends only on the input
  - CRC32 verification
  - Compatible with `gzip` command-line tool

- **Zstd Compression**: Zstandard implementation (RFC 8878)
  - Compressed blocks with Huffman/FSE entropy coding
  - Sequence encoding (literal lengths, offsets, match lengths)
  - Repeat offsets decoded (the encoder emits absolute offsets)
  - Hash chain match finding, with the search depth set by the level
  - Compression levels 1-22
  - Optional XXH64 content checksums
  - Content above 8MB is written with an 8MB window rather than as a single segment
  - Compatible with the `zstd` command-line tool for non-dictionary frames
  - **Not supported:** dictionary-compressed frames (frames with a non-zero Dictionary_ID
    are rejected) and the legacy (pre-v0.8) frame formats

- **Stream Processing**: every codec has a stream codec for its framed format (LZ4 frame, Snappy framing, GZIP,
  Zstd); raw and Hadoop blocks are block-only

## Usage

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:libcompress/libcompress.dart';

void main() async {
  final data = Uint8List.fromList('Hello, compression!'.codeUnits);

  // Block-based compression using factory
  final codec = CodecFactory.codec(CodecType.lz4);
  final compressed = codec.compress(data);
  final decompressed = codec.decompress(compressed);

  // Direct codec instantiation with options
  final zstd = ZstdCodec(level: 6, checksum: true);
  final zstdCompressed = zstd.compress(data);

  // Stream-based compression of a file
  final streamCodec = CodecFactory.streaming(CodecType.gzip);
  final input = File('data.txt').openRead().map(Uint8List.fromList);
  final output = File('data.txt.gz').openWrite();
  await output.addStream(streamCodec.compress(input));
  await output.close();

  // Parse codec type from string (e.g., from config)
  final type = CodecType.parse('snappy');
  final snappyCodec = CodecFactory.codec(type);
}
```

### Parquet pages

Parquet records each page's uncompressed size. Pass it as `size`: decoding stops as soon as the output would exceed
it, and output of any other length is rejected.

| Parquet codec | libcompress codec |
|---------------|-------------------|
| `SNAPPY`      | `SnappyCodec()` |
| `GZIP`        | `GzipCodec()` |
| `LZ4`         | `Lz4Codec(format: Lz4Format.hadoop)` |
| `LZ4_RAW`     | `Lz4Codec(format: Lz4Format.raw)` |
| `ZSTD`        | `ZstdCodec()` |

```dart
final codec = Lz4Codec(format: Lz4Format.raw);
final page = codec.decompress(compressedPage, size: uncompressedPageSize);
```

### Errors and limits

Malformed input raises a `CompressionFormatException` subclass (`Lz4FormatException`, `GzipFormatException`,
`ZstdFormatException`, `SnappyFormatException`). Exceeding a limit (a codec's `maxSize`, an expected `size`, or a
stream's `maxBufferSize`) raises `LimitException`, which is also a `CompressionFormatException` and carries the
`limit` that was exceeded:

```dart
try {
  final page = codec.decompress(data, size: expected);
} on LimitException catch (e) {
  print('Too large: limit is ${e.limit} bytes');
} on CompressionFormatException catch (e) {
  print('Corrupt data: ${e.message}');
}
```

## CLI Tool

The library includes a command-line interface. Use `-` for stdin or stdout; status and errors go to stderr. Usage
errors exit with 2 and processing failures with 1.

```bash
# Run from package directory
dart run :libcompress [options] <input> <output>

# Compress with LZ4 (default)
dart run :libcompress input.txt output.lz4

# Decompress, overwriting an existing output
dart run :libcompress -d -f output.lz4 restored.txt

# Use different codecs
dart run :libcompress --zstd -9 input.txt output.zst
dart run :libcompress --zstd --level 19 input.txt output.zst
dart run :libcompress --gzip input.txt output.gz
dart run :libcompress --snappy input.txt output.sz

# Raw and Hadoop formats (Parquet)
dart run :libcompress --lz4 --raw input.bin page.lz4raw
dart run :libcompress --lz4 --hadoop input.bin page.lz4

# Pipes
dart run :libcompress --zstd - - < input.txt > output.zst

# Stream mode for large files (framed formats only)
dart run :libcompress --stream --lz4 largefile.bin compressed.lz4

# LZ4 with custom block size
dart run :libcompress --lz4 -9 --block-size 1M input.txt output.lz4
```

## Implementation Details

### LZ4
- 16-bit hash table for match finding
- 4-byte minimum match length
- 64KB maximum back-reference distance
- Frame format with magic number `0x184D2204`; blocks are checked against the frame's Block Maximum Size
- HC mode inserts every position into hash chains, searched `2^(level-1)` candidates deep (4 at level 3, 256 at
  level 9, as in lz4), and defers a match while the next position has a longer one; offsets reach 65535

### Snappy
- 14-bit hash table (16384 entries)
- 4-byte minimum match length
- The reference encoder's match search (wider steps after misses) and copy split; ratio within about 2% of `snzip`
- The encoder writes 1- and 2-byte offset copies; the decoder also reads 4-byte offsets
- Optional framing format with CRC32C checksums

### GZIP
- Full DEFLATE implementation with Huffman coding
- Stored, fixed and dynamic Huffman blocks (the encoder writes whichever is smallest)
- LZ77 match finding with zlib's per-level settings (greedy at levels 1-3, lazy at 4-9); matches reach back 32 KB
  across blocks, and every level is within 0.5% of `gzip` at the same level
- CRC32 integrity verification

### Zstd
- FSE (Finite State Entropy) encoding
- Huffman-compressed literals
- Hash chain match finding (depth 4-1024 based on level)
- Repeat offsets are decoded; the encoder emits absolute offsets only
- 128KB maximum block size per spec
- Huffman and sequence bitstreams must be consumed exactly (RFC 8878), so corrupt frames are rejected rather than
  decoded to wrong bytes

## Testing

```bash
# Run all tests
dart test

# Run specific codec tests
dart test test/lz4_codec_test.dart
dart test test/zstd_codec_test.dart

# Differential fuzzing against the lz4, gzip, snzip and zstd tools
RUN_FUZZ=1 dart test -N "differential fuzz"

# Large tests (e.g. a 200MB Zstd frame)
RUN_LARGE=1 dart test test/zstd_codec_test.dart

# Run benchmarks (requires CLI tools installed)
RUN_BENCHMARKS=1 dart test test/benchmark_test.dart
dart run benchmark/codec_benchmark.dart
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
