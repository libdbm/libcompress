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

## 1.1.0

- Major cleanup and bug fixes.
- Better streaming and more deterministic behavior

## 1.2.0

- **LZ4**: `Lz4Codec.compressBlock`/`decompressBlock` expose the raw LZ4 block format (the bare LZ77 token stream, no frame header/checksum) for containers that supply their own framing.

## 1.2.1

- **crc32**: Expose `crc32.dart` via the public API.


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
