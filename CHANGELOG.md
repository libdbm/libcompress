## 2.0.0

A breaking release: one consistent public API, Parquet's legacy LZ4 codec, and correctness fixes found by
differential fuzzing against the `zstd`, `lz4`, `gzip` and `snzip` tools.

### Migrating from 1.x

| 1.x | 2.0.0 |
|-----|-------|
| `maxDecompressedSize:` (LZ4, GZIP, Zstd, `CodecFactory.codec`) | `maxSize:` |
| `enableContentChecksum:` (LZ4), `enableChecksum:` (Zstd) | `checksum:` |
| `CodecFactory.defaultMaxDecompressedSize` | `CodecFactory.defaultMaxSize` |
| `Lz4Codec().compressBlock(data)` / `decompressBlock(data, maxSize: n)` | `Lz4Codec(format: Lz4Format.raw).compress(data)` / `Lz4Codec(format: Lz4Format.raw, maxSize: n).decompress(data)` |
| `SnappyCodec(framing: true)` / `SnappyOptions(framing: true)` | `SnappyCodec(format: SnappyFormat.framed)` / `SnappyOptions(format: SnappyFormat.framed)` |
| `codec.supports(CodecMode.stream)`, `CodecFactory.supports(...)` | Removed: every codec supports block and stream use |
| `CompressionLevel` | Removed |
| `on Lz4FormatException` etc. for a size-limit breach | `on LimitException` (still a `CompressionFormatException`) |
| `guardFormat`, `validate*`, `zstd_common.dart` (frame/block header types, magic numbers), `SnappyIncrementalDecoder`, top-level `defaultMaxBufferSize` and per-codec default constants | No longer exported |
| Implementing or extending `CompressionCodec` / `CompressionStreamCodec` freely | The bases are `abstract base class` (extend only); the concrete codecs are `final` |
| GZIP header MTIME was the current time | MTIME defaults to 0 (reproducible output); pass `mtime:` |
| Empty input decoded to empty output (LZ4; GZIP/Zstd streams) | Empty input is an error for every codec except noop |
| CLI overwrote outputs, printed status and errors to stdout, exited 1 on `--help` | See CLI below |
| `CodecType.parse('GZIP')` threw | Case is ignored, so `CodecType.parse(codec.name)` works |
| Options classes accepted invalid block sizes, chunk sizes and MTIME until `fromOptions` | They throw `ArgumentError` when constructed |

### Added

- **`decompress(data, size: n)`** on every codec: decoding stops once output would exceed `n`, and output of any
  other length is rejected. Intended for Parquet pages, whose uncompressed size is known.
- **`Lz4Format.hadoop`**: Hadoop block framing, Parquet's legacy `LZ4` codec. Written as Arrow does (one block, one
  chunk); several blocks and chunks are decoded, each chunk on its own. Tested on pages written by parquet-mr
  (`LZ4`) and parquet-cpp (`LZ4_RAW`, and older `LZ4` pages written as bare blocks, which decode with
  `Lz4Format.raw`), from apache/parquet-testing.
- **`Lz4Format`/`SnappyFormat`** enums select the format of `Lz4Codec` and `SnappyCodec`.
- **`LimitException`**, with the `limit` that was exceeded: the configured cap, not the budget left in a stream.
- **`DeflateFormatException` is a `GzipFormatException`**, so GZIP callers catch DEFLATE errors too.
- **GZIP `mtime`** on `GzipCodec`, `GzipOptions` and `GzipStreamCodec`.
- **`ZstdOptions.strict` and `ZstdOptions.onFallback`**, carried by `ZstdCodec.fromOptions`.
- **`fromOptions` on every stream codec** (`Lz4StreamCodec`, `SnappyStreamCodec`, `GzipStreamCodec`,
  `ZstdStreamCodec`).
- **`GzipStreamCodec` `filename` and `comment`**, as on `GzipCodec`; a NUL in either is rejected.
- **`NoopFormatException`**: `NoopCodec.decompress(data, size: n)` with fewer than `n` bytes.
- **Noop codecs enforce `maxSize`**, including when created through `CodecFactory`.
- **CLI**:
  - `-f` is required to overwrite, and the input is never used as the output;
  - `-` means stdin/stdout;
  - `--raw` and `--hadoop` formats;
  - each codec's default level, and `--level N` (1-22 for Zstd);
  - status and errors go to stderr;
  - `--help` exits 0, and usage errors exit 2.

### Performance

Measured with `benchmark/codec_benchmark.dart` (MB/s of uncompressed data, Dart VM, before -> after; `tasks/` holds
the full tables):

| Path | Before | After |
|------|-------:|------:|
| LZ4 raw decode with `size:` (house.jpg / geo.protodata / world192) | 11900 / 1720 / 354 | 22170 / 4367 / 643 |
| LZ4 raw compress, 1 KB page | 14 | 290 |
| LZ4 frame compress, 1 KB page | 4.5 | 280 |
| LZ4 frame decode without a content size (1 KB / 8 KB / 64 KB page) | 7 / 49 / 206 | 522 / 498 / 424 |
| Snappy raw decode (world192 / geo.protodata) | 436 / 2566 | about 700 / 3306 |
| Snappy framed decode (geo.protodata), with slice-by-8 CRC32C | 300 | 1027 |
| GZIP decode (bible.txt) | 167 | about 310 |
| GZIP decode, 20,000 dynamic blocks with 15-bit codes | 17x zlib | under 3x zlib |
| Zstd decode (world192 / bible / geo.protodata) | 127 / 125 / 557 | 314 / 310 / 2091 |
| Zstd streaming decode, 8 MB window (one-shot is itself 2x faster) | 49-53% of one-shot | about 80% of one-shot |
| Zstd compress, 1 KB page | 1.0 | 32 |
| Zstd compress (world192 / bible.txt / geo.protodata) | 20 / 15 / 35 | 41 / 30 / 99 |
| XXH64 on the web (4 MB checksum, node) | 447 ms | 47 ms |
| LZ4 stream compress, world192 in 1 KB chunks | 813 ms | 21 ms |
| Snappy compress (world192 / house.jpg / 1 MB random) | 199 / 140 / 128 | 223 / 5088 / 2569 |

Small results no longer pin large buffers: compressing 1 MB of zeros with LZ4 returned 4 KB that kept a 1 MB
allocation alive.

### Compression

| Codec | Change | Before | After |
|-------|--------|-------:|------:|
| LZ4 level 9 (world192 / geo.protodata) | Every position in the hash chain, lazy matching, offset 65535 | 967667 / 17209 | 801190 / 15567 (`lz4 -9`: 787449 / 15388) |
| LZ4 levels 2-8 | High-compression mode with chain depth `2^(level-1)`; they were the same as level 1 | 1069746 (world192) | 919699 (level 2) to 803489 (level 8) |
| `Lz4StreamCodec` level 9 (world192, 64 KB chunks) | The level is honoured; it was ignored | 1052323 | 801572 |
| GZIP levels 1 / 6 / 9 (world192) | zlib's per-level match settings, matches across blocks, dynamic Huffman at every level (`GzipCodec` and `GzipStreamCodec`) | 977124 / 814410 / 819236 | 902962 / 718924 / 715887 (`gzip`: 903087 / 719196 / 716191) |
| GZIP levels 1 / 6 / 9 (bible.txt) | As above | 1560329 / 1279319 / 1289738 | 1491469 / 1192107 / 1177455 (`gzip`: 1491084 / 1191907 / 1177372) |
| Snappy framed (geo.protodata / world192) | The reference encoder loop: skips ahead on misses, chains copies, splits long copies 64/60 | 27581 / 1249348 | 23354 / 1224693 (`snzip`: 23169 / 1198914) |
| GZIP, 1 MB of random bytes | Each block is written stored, fixed or dynamic, whichever is smallest | 1050123 (level 1) | 1048677 (+0.01%) |

`Lz4StreamCodec` buffers input into whole blocks of `blockSize`, so its output no longer depends on how the input is
chunked, and a block is emitted only once `blockSize` bytes are pending (or at the end). `GzipStreamCodec` does the
same with 64 KB DEFLATE blocks: 300-byte chunks of bible.txt were 13% larger and 6x slower than one chunk, and are
now identical; a single 32 MB chunk no longer builds tokens for the whole chunk at once.

### Fixed

- **LZ4**: a frame or Hadoop block arriving after `maxSize` was used up exactly could still decode up to 1 KB.
- **LZ4**: frames flagged as independent blocks accepted matches into earlier blocks (`lz4` rejects them).
- **Snappy (framing)**: chunks before the stream identifier were accepted; a chunk over 64 KB raised a size-limit
  error naming 65536 instead of `SnappyFormatException`, and an uncompressed chunk over `maxSize` raised
  `SnappyFormatException` instead of `LimitException`.
- **GZIP**: `maxSize` could be exceeded by literals near the end of the input; a NUL in `filename` or `comment`
  wrote an unreadable header and is now rejected.
- **Zstd**: Huffman literals in 4 streams with fewer than 6 literals, and Huffman weights of 14 or 15, raised
  `RangeError`/`IndexError`; an empty RLE literals section was rejected although valid; a compressed block without
  its sequence count was accepted; the streaming decoder buffered whole skippable frames.
- **Zstd**: corrupt frames are rejected instead of decoded to wrong bytes:
  - Huffman and sequence bitstreams must be consumed exactly (RFC 8878 §4.2.2, §3.1.1.3.2.1.2); this is stricter
    than libzstd 1.5.7's 4-stream path;
  - the last sequence is no longer dropped on overflow;
  - reserved bits, Repeat mode before any table, a first offset past the start, a repeat offset of 0, and a
    sequence that needs more literals than exist are all rejected.
- **Zstd**: literals larger than a block are rejected before they are allocated.
- **Zstd**: content above 8 MB is written with an 8 MB window, so `zstd -d` decodes it without `--memory`.
- **Zstd (web)**: frames with a window of 4 GB or more were rejected under dart2js.
- **Zstd**: FSE-compressed Huffman weights from libzstd 1.5.6 (as written by DuckDB) decode; blocks are checked
  against Block_Maximum_Size; Dictionary_ID 0 is accepted.
- **LZ4**: the streaming encoder overflowed its buffer on a 4 MB block with no matches.
- **LZ4**: blocks that decode past the frame's Block Maximum Size are rejected, which also bounds streaming memory.
- **LZ4**: skippable frames are skipped, and legacy frames get a clear error.
- **GZIP**: streaming decode emits output in pieces of at most 64 KB when given one large chunk, and parses a long
  FNAME or FCOMMENT in linear time.
- **Streams**: a source that cannot be listened to fails the output stream instead of raising an uncaught error.
- **Snappy**: the encoder allocates less and no longer returns a view pinning a worst-case buffer; overlapping copies
  avoid a division per byte.
- Out-of-bounds errors inside a decoder are no longer reported as corrupt input, so a decoder bug stays visible.

## 1.3.0

- **Breaking:** removed `Crc32.combine`, which returned incorrect values.
- **Zstd**: levels 6-22 no longer fall back to raw blocks when a match reaches the end of a block (an out-of-bounds read was caught and silently degraded the ratio).
- **Zstd**: Huffman-compressed literals are used for text again. Code lengths are now limited to 11 bits (RFC 8878) instead of failing for deep trees, and the weights header no longer writes the implicit last weight, which cost one extra bit per literal.
- **GZIP**: dynamic Huffman blocks can no longer receive an over-subscribed (undecodable) code when code lengths have to be limited to 15 bits.
- **GZIP**: the streaming decoder reports a `maxSize` breach as "Decompressed size exceeds maximum" instead of "Incomplete GZIP member at end of stream", and stops buffering input once the limit is hit.
- **Snappy**: raw decoding rejects a declared length larger than the input could expand to (64 bytes per 3 input bytes) before allocating it, and all Snappy decoders now share the 256 MB default limit (the internal decoders used 100 MB).
- **GZIP**: block decompression uses table-driven Huffman decoding and bulk stored-block copies (about 3.8x faster: 59 -> 220 MB/s on bible.txt, AOT).
- **GZIP**: streaming decompression uses the same table-driven decoder (about 3.7x faster: 53 -> 198 MB/s on bible.txt in 64 KB chunks, AOT) and copies stored blocks in bulk.
- **Zstd**: XXH64 content checksums use native 64-bit integer arithmetic on the VM instead of `BigInt` (decoding a checksummed frame: 25 -> 183 MB/s on bible.txt, AOT). JavaScript targets keep the `BigInt` implementation.
- **Zstd (web)**: compression under dart2js no longer produces corrupt frames for inputs of about 20 KB and up (the sequence bit writer exceeded 32 bits, which JavaScript shifts truncate). The web parity test now covers a 600 KB input and checksummed Zstd frames.

## 1.2.1

- **crc32**: Expose `crc32.dart` via the public API.

## 1.2.0

- **LZ4**: `Lz4Codec.compressBlock`/`decompressBlock` expose the raw LZ4 block format (the bare LZ77 token stream, no frame header/checksum) for containers that supply their own framing.

## 1.1.0

- Major cleanup and bug fixes.
- Better streaming and more deterministic behavior

## 1.0.0

- Initial release with pure Dart compression implementations (no native dependencies; runs on the Dart VM and dart2js/web)
- **LZ4**: Full frame format support with configurable block sizes (64K, 256K, 1M, 4M) and compression levels 1-9 (HC mode); block decode accepts concatenated frames
- **Snappy**: Raw block format and streaming (framing) format with CRC32C checksums
- **GZIP**: Pure Dart DEFLATE implementation with compression levels 1-9, optional filename/comment metadata, multi-member support
- **Zstd**: Practical subset of RFC 8878 with FSE/Huffman entropy coding, sequence encoding, repeat offsets, and compression levels 1-22 (dictionary-compressed frames are not supported and are rejected on decode)
- Stream-based APIs for all codecs via `CompressionStreamCodec`, with backpressure and an optional `verified` (all-or-nothing) mode that withholds output until checksums validate
- Common codec interface via `CompressionCodec`; `CodecFactory.codec`/`streaming` accept `maxDecompressedSize`/`maxBufferSize`/`verified` for central limit enforcement
- Security: all decompressors enforce a configurable `maxDecompressedSize` (cumulative across frames/members); streaming decode is incremental and memory-bounded
- Observability: Zstd exposes a compressed-block fallback counter, `onFallback` hook, and opt-in `strict` mode
- CLI tool (`libcompress`) for all codecs, with atomic output (temp file + rename, cleanup on error) and an opt-in `--verified` flag
- CLI compatibility verified with the native lz4, gzip, snzip, and zstd tools
