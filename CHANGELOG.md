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

