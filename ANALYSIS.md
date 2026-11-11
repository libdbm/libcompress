# Codebase Architecture & Technical Analysis (`libcompress` v2.1.0)

---

## 1. Architecture & Design Patterns

### Overall Structure & File Organization
The repository is a zero-dependency, pure-Dart library targeting Dart SDK `^3.8.1` across both native VM (64-bit integers) and Web (`dart2js` / `dart2wasm`) runtimes:

```
lib/
├── libcompress.dart                 # Public barrel export (hides internal helpers)
└── src/
    ├── compression_codec.dart       # Abstract base class for synchronous block codecs
    ├── compression_stream_codec.dart# Abstract base class for chunked Stream<Uint8List> codecs
    ├── compression_options.dart     # Base options + fail-fast argument validators
    ├── codec_factory.dart           # Factory & CodecType enum
    ├── exceptions.dart              # Exception hierarchy & guardFormat boundary
    ├── lz4/                         # LZ4 frame, raw block, and Hadoop codecs + HC chains
    ├── snappy/                      # Snappy raw block & framing (CRC32C) codecs
    ├── gzip/                        # GZIP (RFC 1952) & raw DEFLATE (RFC 1951) codecs
    ├── zstd/                        # Zstandard (RFC 8878) FSE, Huffman, and sequence codecs
    ├── noop/                        # Pass-through block and stream codecs
    └── util/                        # Shared buffers, bitstreams, hashes (CRC32/C, XXH32/64), pumps
bin/
└── libcompress.dart                 # Full-featured CLI tool with atomic temp-file writes
```

### Design Patterns Identified
1. **Strategy Pattern**: [`CompressionCodec`](lib/src/compression_codec.dart) and [`CompressionStreamCodec`](lib/src/compression_stream_codec.dart) define uniform synchronous (`Uint8List -> Uint8List`) and asynchronous (`Stream<Uint8List> -> Stream<Uint8List>`) compression strategies.
2. **Simple Factory Pattern**: [`CodecFactory`](lib/src/codec_factory.dart) centralizes codec instantiation via `CodecFactory.codec` and `CodecFactory.streaming`, propagating tenant safety limits (`maxSize`, `maxBufferSize`, `verified`).
3. **Adapter / Stream Transformer Pattern**:
   - [`IncrementalDecoder`](lib/src/util/incremental_decoder.dart) and `IncrementalDecompressTransformer` adapt stateful push-based chunk decoders into Dart's `StreamTransformer<Uint8List, Uint8List>`.
   - [`StreamCompressor`](lib/src/util/stream_compressor.dart) and `compressStream` adapt stateful block-linked encoders (`header()`, `addChunk()`, `finish()`) into backpressure-aware streams via [`pumpBytes`](lib/src/util/stream_pump.dart).
4. **Polymorphic Sink / Decorator Pattern**:
   - [`ByteSink`](lib/src/util/byte_sink.dart) and `DirectSink` abstract the output target so `_BlockDecoder` and [`CompressedBlockDecoder`](lib/src/zstd/compressed_block_decoder.dart) can emit into either a whole-output [`GrowableBuffer`](lib/src/util/growable_buffer.dart) or a sliding-window [`WindowBuffer`](lib/src/util/window_buffer.dart).
   - `BlockOutput` decorates a `ByteSink` to enforce per-block regenerated size limits.
5. **Conditional Platform Compilation**: [`xxh64.dart`](lib/src/util/xxh64.dart) exports [`xxh64_native.dart`](lib/src/util/xxh64_native.dart) on `dart.library.io` (wrapping 64-bit `int` arithmetic) and [`xxh64_web.dart`](lib/src/util/xxh64_web.dart) on JS targets (split 32-bit `_hi`/`_lo` registers with 16-bit products to stay within IEEE-754 $2^{53}$ precision).

### Adherence to SOLID Principles
- **Single Responsibility (SRP)**: High adherence. Framing (e.g., [`GzipFrame`](lib/src/gzip/gzip_frame.dart)), block compression ([`DeflateEncoder`](lib/src/gzip/deflate_encoder.dart)), LZ77 match finding ([`Lz77Encoder`](lib/src/gzip/lz77_encoder.dart)), and entropy coding ([`HuffmanTreeBuilder`](lib/src/util/huffman.dart), [`FseEncoder`](lib/src/zstd/fse_encoder.dart)) are cleanly separated.
- **Open/Closed (OCP)**: `CompressionCodec` and `CompressionStreamCodec` are marked `abstract base class`, and concrete codecs are `final class`, preventing external fragile subclassing while allowing new codecs to implement the base contracts. However, `CodecType` is a closed enum rather than a pluggable registry.
- **Liskov Substitution (LSP)**: Strong behavioral subtyping across codecs, including [`NoopCodec`](lib/src/noop/noop_codec.dart) enforcing `maxSize` and `size` checks identically to real codecs. Minor violation in [`CompressionOptions`](lib/src/compression_options.dart): [`SnappyOptions`](lib/src/snappy/snappy_codec.dart), [`GzipOptions`](lib/src/gzip/gzip_codec.dart), and [`DeflateOptions`](lib/src/gzip/deflate_codec.dart) inherit `checksum` and/or `level` fields from `CompressionOptions` that they silently ignore.
- **Interface Segregation (ISP)** & **Dependency Inversion (DIP)**: Decoders depend on narrow interfaces (`ByteSink`, `DirectSink`, `IncrementalDecoder`, `StreamCompressor`) rather than concrete buffer or stream implementations.

---

## 2. Algorithmic Efficiency & Complexity

### Core Algorithms & Complexity Matrix

| Component | Key Function / Class | Time Complexity | Space Complexity | Notes |
|---|---|---|---|---|
| **LZ4 Fast (L1)** | `Lz4Encoder._compressBlock` | $\mathcal{O}(n)$ | $\mathcal{O}(\min(n, 2^{16}))$ | Direct-mapped 16-bit hash table (`Int32List`), 4-byte match checks. |
| **LZ4 HC (L2–L9)** | `_compressHC` / `_Chain.find` | $\mathcal{O}(n \cdot 2^{\text{level}-1} \cdot L)$ worst, $\mathcal{O}(n \cdot d)$ avg | $\mathcal{O}(\min(n, 2^{16}))$ | Searches hash chain up to $d = 2^{\text{level}-1}$ (256 at L9) with lazy match deferral. |
| **LZ4 Decode** | `Lz4Decoder._decompressExact` | $\mathcal{O}(n + m)$ | $\mathcal{O}(m)$ block / $\mathcal{O}(W)$ stream | $W = 64\text{ KB}$ window in `Lz4IncrementalDecoder`. |
| **Snappy Encode** | `SnappyEncoder._compressBlock` | $\mathcal{O}(n)$ | $\mathcal{O}(\min(n, 2^{14}))$ | Uses skip-step acceleration (`skip += skip >> 5`) on incompressible runs. |
| **Snappy Decode** | `SnappyDecoder.decompress` | $\mathcal{O}(n + m)$ | $\mathcal{O}(m)$ raw / $\mathcal{O}(64\text{ KB})$ stream | Uses 64-bit word loads/stores on VM (`wide == true`). |
| **DEFLATE LZ77** | `Lz77Encoder.tokenize` | $\mathcal{O}(n \cdot C \cdot M)$ worst ($C \le 4096, M \le 258$) | $\mathcal{O}(W + T)$ ($W=32\text{ KB}$) | Greedy at L1–L3, lazy at L4–L9 with `good`/`nice`/`chain` cutoffs. |
| **Huffman Build** | `HuffmanTreeBuilder.computeLimitedCodeLengths` | $\mathcal{O}(I \cdot \Sigma \log \Sigma)$ ($\Sigma \le 286$) | $\mathcal{O}(\Sigma)$ | Iterative frequency halving until max depth $\le \text{maxBits}$. |
| **DEFLATE Decode** | `DeflateDecoder._inflate` | $\mathcal{O}(n + m)$ | $\mathcal{O}(m)$ block / $\mathcal{O}(32\text{ KB})$ stream | Two-level lookup table (9-bit root + subtables) gives $\mathcal{O}(1)$ per symbol. |
| **Zstd Match** | `MatchFinder.findMatches` | $\mathcal{O}(n \cdot D \cdot M)$ ($D \le 1024, M \le 64\text{ KB}$) | $\mathcal{O}(2^{17} + 2^{16})$ | 64-bit XOR + `bitLength` trailing-zero trick on VM for 8-byte comparisons. |
| **Zstd FSE & Huff** | `SequenceEncoder.encodeSequences` | $\mathcal{O}(S + 2^{\text{tableLog}})$ | $\mathcal{O}(S + 2^{\text{tableLog}})$ | Backward bitstreams for Huffman (1- or 4-stream) and FSE state machines. |
| **Checksums** | `CrcTables.update`, `XXH32`, `XXH64` | $\mathcal{O}(n)$ | $\mathcal{O}(1)$ | Slice-by-8 CRC tables (8 KB per polynomial); 4-lane stripe accumulators for XXH. |

*(Here $n$ = input size, $m$ = decompressed size, $S$ = sequence count, $T$ = token count.)*

### Performance Bottlenecks & Redundant Operations Identified
1. **Per-Token / Per-Match Boxed Heap Allocations in Encoders**:
   - In [`Lz77Encoder`](lib/src/gzip/lz77_encoder.dart), every literal or match allocates a boxed `LiteralToken` or `MatchToken` into a `List<Token>`. For a 64 KB block of incompressible data, this allocates 65,535 objects on the heap.
   - In [`DeflateEncoder.writeBlock`](lib/src/gzip/deflate_encoder.dart), `encodeLength` and `encodeDistance` are called **twice** per `MatchToken` (once in `_Counts` and again in `_writeDynamic` / `writeFixedBlock`), allocating `LengthCode` and `DistanceCode` objects each time.
   - Similarly, Zstd's [`MatchFinder.findMatches`](lib/src/zstd/match_finder.dart) allocates a `List<ZstdMatch>`, and [`SequenceSymbols.from`](lib/src/zstd/sequence_encoder.dart) plus `SequenceEncoder._buildTokens` iterate over `matches` twice, allocating three `List<int>` arrays and a `List<_SequenceToken>` of 9-field objects (plus `_OffsetEncoding` per match).
2. **`GzipIncrementalDecoder` Uses Slow Symbol-by-Symbol Checkpoint Loop**:
   - While `DeflateDecoder._inflate` has a fast 64-bit register loop when `next <= end - 16`, [`GzipIncrementalDecoder._runDeflate`](lib/src/gzip/gzip_incremental_decoder.dart) decodes every single symbol through `_decodeOneSymbol` even when megabytes of buffered input are available in `_pending`.
3. **Sub-Optimal Period-Doubling Copy Missing in `WindowBuffer` and `Lz4Decoder._decompressExact`**:
   - `GrowableBuffer.copyFromHistory`, `DeflateDecoder._inflate`, and `CompressedBlockDecoder` use period-doubling `setRange` when `distance < length` and `length > 32`.
   - However, `WindowBuffer.copyFromHistory` and `Lz4Decoder._decompressExact` fall back to a byte-by-byte `for` loop whenever `1 < distance < length`.
4. **Unnecessary Allocation in `ZstdIncrementalDecoder._decodeNextBlock`**:
   - [`zstd_decoder.dart`](lib/src/zstd/zstd_decoder.dart) allocates a `Uint8List.fromList([_pending[...], ...])` on every block just to call `ZstdBlockHeader.parse(..., 0)`, instead of passing `(_pending.bytes, _pending.cursor)`.
5. **Lack of Early-Exit (`niceLength`) in Zstd `MatchFinder`**:
   - Unlike `Lz77Encoder._find` which stops searching the chain once `length >= nice`, `MatchFinder.findMatches` always walks all `searchDepth` candidates (up to 1024 at L17–22) even after finding a 64 KB match.
6. **GZIP Block Decoder Hint Misreads Multi-Member Inputs**:
   - In [`GzipFrame._decompressMember`](lib/src/gzip/gzip_frame.dart), `hint` always reads the last 4 bytes of `data` (`data[data.length - 4..]`). For concatenated GZIP members, the first member uses the last member's `ISIZE` as its initial buffer capacity hint, and for a single member $\ge 4\text{ GB}$ (`ISIZE` mod $2^{32}$), `hint` is truncated.

---

## 3. Code Quality & Maintainability

### Readability, Naming & Documentation
- **Strengths**:
  - Public API documentation is exemplary—clear explanations of block vs. streaming memory models, `verified: true` semantics, Parquet codec mappings, and thread/isolate safety.
  - Strict lints in [`analysis_options.yaml`](analysis_options.yaml) (`prefer_final_locals`, `prefer_final_parameters`, `avoid_dynamic_calls`, `cancel_subscriptions`, `close_sinks`).
  - Thoughtful cross-platform comments explaining *why* arithmetic is written a certain way (e.g., avoiding `<< 24` or 64-bit shifts on `dart2js`).

### Code Smells & Duplication
1. **Duplicated Fast-Path Loops vs. Fallback Loops**:
   - [`DeflateDecoder`](lib/src/gzip/deflate_decoder.dart) has both `_decodeHuffmanBlock` and `_inflate`.
   - [`CompressedBlockDecoder._decodeAndExecuteSequences`](lib/src/zstd/compressed_block_decoder.dart) has a 180-line VM fast loop followed by a 115-line general loop that duplicates all repeat-offset and match-copy logic.
   - [`Lz4Decoder`](lib/src/lz4/lz4_decoder.dart) duplicates block decoding between `_decompressExact` and `_BlockDecoder.decode`, and [`Lz4Encoder`](lib/src/lz4/lz4_encoder.dart) duplicates L1 block encoding between `_compressBlock` and `StreamingLz4Encoder._compressLinked`.
2. **Redundant Wrapper Class**:
   - [`ZstdCompressor`](lib/src/zstd/zstd_compressor.dart) is a pure pass-through wrapper around [`ZstdEncoder`](lib/src/zstd/zstd_encoder.dart) with identical constructor fields and a single method `compress(data)`.
3. **Mutable Module-Level Globals in `xxh64_web.dart`**:
   - [`xxh64_web.dart`](lib/src/util/xxh64_web.dart) uses top-level mutable `int _hi = 0; int _lo = 0;` as return registers for 64-bit arithmetic helpers. While Dart JS is single-threaded, module-level mutable state is fragile if any helper call order is refactored.

### Error Handling & Edge-Case Management
- **Strong Error Boundary Design**: [`guardFormat`](lib/src/exceptions.dart) intentionally converts `StateError`, `FormatException`, and non-range `ArgumentError` into codec-specific `CompressionFormatException`s while letting `RangeError` / `IndexError` / `TypeError` propagate untouched so real decoder bugs are never masked as "corrupt input".
- **Observability Hooks in Zstd**: [`CompressedBlockEncoder`](lib/src/zstd/compressed_block_encoder.dart) provides `strict`, `validate`, `fallbacks`, and `onFallback` so silent raw-block fallback on unexpected encoder errors can be monitored or made fatal.

---

## 4. Security & Robustness

### Decompression Bomb & OOM Protections
- **Pre-Allocation Bounds Checking**:
  - Default `maxSize` (256 MB) and `maxBufferSize` (64 MB) are enforced across all block and streaming codecs.
  - [`SnappyDecoder.decompress`](lib/src/snappy/snappy_decoder.dart) validates that the varint-declared uncompressed length does not exceed the theoretical maximum expansion ($\lfloor \text{body} \times \frac{64}{3} \rfloor$) *before* allocating the output buffer.
  - [`ZstdDecoder._decompressFrame`](lib/src/zstd/zstd_decoder.dart) clamps initial allocation to `10 * inputRemaining` (up to `limit`) so a forged 200 MB `Frame_Content_Size` header on a 20-byte payload cannot trigger an immediate 200 MB allocation.
  - [`BytePending.append`](lib/src/util/byte_pending.dart) checks `available + data.length > limit` *before* copying incoming stream chunks.
- **Unverified vs. Verified Streaming**:
  - Clearly documented and supported via `verified: true` in `Lz4StreamCodec`, `GzipStreamCodec`, and `ZstdStreamCodec`, preventing downstream consumers from acting on decompressed prefix bytes before the frame/member checksum validates.

### Subtle Correctness & Robustness Bugs Found
1. **BUG: Zstd Encoder Fails to Encode Compressed Blocks with Byte Values $\ge 129$ via Huffman (`maxSym > 128`)**:
   - In [`CompressedBlockEncoder._encodeHuffmanLiterals`](lib/src/zstd/compressed_block_encoder.dart):
     ```dart
     if (maxSym > 128) {
       return null;
     }
     ```
   - Because direct 4-bit Huffman weight headers in Zstd only allow up to 128 weights (`headerByte = 127 + numWeights`, max 255) and FSE-compressed Huffman weight headers are not implemented in `HuffmanEncoder`, **any block containing a single UTF-8 non-ASCII byte or binary byte (`> 0x80`) completely disables Huffman literal compression** and falls back to raw uncompressed literals.
2. **BUG: Zstd FSE Normalization Can Fail When All 32 Offset Symbols Are Present**:
   - In [`FseEncoder._normalize`](lib/src/zstd/fse_encoder.dart):
     - Each used symbol is rounded up via `(f * size + total - 1) ~/ total`, which guarantees `assigned >= size` (`diff <= 0`).
     - However, `maxLog` for offsets is 5 (`size = 32`) while `distinct` can be up to 32 (`maxSym = 31`). If `distinct == 32` with `size == 32` and a symbol has `f > 1`, `assigned > 32`, and if no symbol has `norm[i] > 1` left to reduce, `sum(norm)` will not equal `size`, causing `FseEncoder.encodeHeader` to emit a malformed table.
3. **BUG: `StreamingZstdEncoder` Emits One Zstd Block Per Small Stream Chunk**:
   - [`StreamingZstdEncoder.addChunk`](lib/src/zstd/streaming_zstd_encoder.dart) immediately emits every partial chunk as a Zstd block. If a caller feeds a `Stream` yielding 64-byte chunks (e.g., network socket lines), `StreamingZstdEncoder` emits a separate Zstd block for every 64-byte chunk instead of buffering up to `blockSize` (128 KB) like `StreamingLz4Encoder` and `StreamingDeflateEncoder` do.
4. **Potential CLI Symlink / Signal Cleanup Issue**:
   - In [`bin/libcompress.dart`](bin/libcompress.dart), `_tempPath` writes to `$output.tmp-$pid`. If the process is killed via `SIGINT`/`SIGTERM`, the `.tmp-$pid` file is left on disk. Also, `_same` calls `File(first).resolveSymbolicLinksSync()`, which can throw `FileSystemException` if `first` is a broken symlink or special FIFO/device file before `_buffered` runs.

---

## 5. Actionable Recommendations (Prioritized)

### High Priority

#### H1. Implement FSE-Compressed Huffman Weight Headers in Zstd (or Support `maxSym > 128`)
Currently, `CompressedBlockEncoder._encodeHuffmanLiterals` aborts Huffman literal coding whenever `maxSym > 128` (any binary data or UTF-8 text with non-ASCII characters). Implementing FSE-compressed Huffman weights (RFC 8878 §4.2.1.2) using the existing `FseEncoder` and `FseCompressionTable` (with `maxLog = 6`, `maxSymbol = 12`) unlocks Huffman literal compression for all 256 byte values:

```dart
// In lib/src/zstd/huffman_encoder.dart:
Uint8List encodeWeightsHeader(final int maxSym) {
  final weights = getWeights(maxSym);
  final count = maxSym; // Last symbol's weight is implicit

  // Direct 4-bit representation works when count <= 127 (header byte 128..254)
  if (count <= 127) {
    final size = 1 + (count + 1) ~/ 2;
    final output = Uint8List(size);
    output[0] = 127 + count;
    for (var i = 0; i < count; i += 2) {
      final w1 = weights[i];
      final w2 = i + 1 < count ? weights[i + 1] : 0;
      output[1 + i ~/ 2] = (w1 << 4) | w2;
    }
    return output;
  }

  // For count > 127 (up to 255), FSE-compress the weights stream (RFC 8878 §4.2.1.2)
  final stats = FseEncoder.stats(weights, maxTableLog);
  final fse = FseEncoder()..build(stats.counts, 6, stats.maxSymbol);
  final headerBytes = fse.encodeHeader();
  final table = FseCompressionTable.create(
    fse.normalized,
    fse.tableLog,
    stats.maxSymbol,
  );
  final stream = BitStreamWriter();
  // Interleaved 2-state backward FSE encoding of weights[0..count-1]
  var state1 = table.begin(weights[count - 1]);
  var state2 = table.begin(weights[count - 2]);
  for (var i = count - 3; i >= 0; i--) {
    if (((count - 1 - i) & 1) == 1) {
      state1 = table.encode(stream, state1, weights[i]);
    } else {
      state2 = table.encode(stream, state2, weights[i]);
    }
  }
  if ((count & 1) == 0) {
    table.finish(stream, state2);
    table.finish(stream, state1);
  } else {
    table.finish(stream, state1);
    table.finish(stream, state2);
  }
  stream.writeBits(1, 1); // Sentinel bit
  final body = stream.toBytes();
  final fseSize = headerBytes.length + body.length;
  return Uint8List(1 + fseSize)
    ..[0] = fseSize
    ..setRange(1, 1 + headerBytes.length, headerBytes)
    ..setRange(1 + headerBytes.length, 1 + fseSize, body);
}
```

#### H2. Buffer Small Chunks in `StreamingZstdEncoder`
Modify [`StreamingZstdEncoder`](lib/src/zstd/streaming_zstd_encoder.dart) to accumulate incoming chunks in `_cur` until `_len - _hist == blockSize` (and flush the final partial block in `finish()` with `last: true`), avoiding one Zstd block per tiny stream event and eliminating the trailing empty raw block when input is non-empty:

```dart
// In StreamingZstdEncoder:
int _len = 0; // end of buffered unencoded bytes in _cur

@override
Uint8List addChunk(final Uint8List data) {
  _sink.add(data);
  final out = BytesBuilder(copy: false);
  var off = 0;
  while (off < data.length) {
    final space = (_hist + blockSize) - _len;
    final copyCount = math.min(space, data.length - off);
    _cur.setRange(_len, _len + copyCount, data, off);
    _len += copyCount;
    off += copyCount;
    if (_len - _hist == blockSize) {
      out.add(_flushBufferedBlock(last: false));
    }
  }
  return out.takeBytes();
}
```

#### H3. Eliminate Per-Token Heap Allocations in DEFLATE & Zstd Encoders
Replace `List<Token>` in [`Lz77Encoder`](lib/src/gzip/lz77_encoder.dart) and `List<ZstdMatch>` / `List<_SequenceToken>` in [`MatchFinder`](lib/src/zstd/match_finder.dart) + [`SequenceEncoder`](lib/src/zstd/sequence_encoder.dart) with flat `Uint32List` / `Int32List` buffers reused across blocks.
- For DEFLATE, a single packed `Uint32List` can encode a token as `distance << 16 | length` (where `distance == 0` means literal byte `length`), eliminating 100% of `LiteralToken`, `MatchToken`, `LengthCode`, and `DistanceCode` allocations.

### Medium Priority

#### M1. Enable Fast-Loop Inflate in `GzipIncrementalDecoder`
In [`GzipIncrementalDecoder._runDeflate`](lib/src/gzip/gzip_incremental_decoder.dart), invoke the 64-bit register fast loop (from `DeflateDecoder._inflate` generalized to `DirectSink`) whenever `wide && input.end - input.position >= 16`, falling back to `_decodeOneSymbol` only for the last $< 16$ bytes of the currently buffered chunk.

#### M2. Add `niceLength` Early Exit & Repeat Offsets to Zstd Encoder
1. Add a level-dependent `niceLength` (e.g., 32–256) to `MatchFinder.findMatches` so high levels (`L12`–`L22`) break out of the hash chain loop immediately upon finding a match $\ge \text{niceLength}$.
2. Track `rep0, rep1, rep2` in `MatchFinder` and `SequenceEncoder` to emit repeat-offset codes (`0` and `1`), which significantly improves Zstd compression ratios on structured/tabular data (such as Parquet pages) at near-zero CPU cost.

#### M3. Unify Duplicated Copy-From-History Logic
Extract the period-doubling overlapping copy from `GrowableBuffer.copyFromHistory` into a shared helper in [`byte_utils.dart`](lib/src/util/byte_utils.dart) and use it in `WindowBuffer.copyFromHistory` and `Lz4Decoder._decompressExact`.

### Low Priority
- **L1**: Remove [`ZstdCompressor`](lib/src/zstd/zstd_compressor.dart) and call `ZstdEncoder` directly from `ZstdCodec`.
- **L2**: Parse `ZstdBlockHeader` directly from `(_pending.bytes, _pending.cursor)` in `ZstdIncrementalDecoder._decodeNextBlock` without allocating a 3-byte `Uint8List`.
- **L3**: Fix `GzipFrame._decompressMember` so the `ISIZE` hint is only used when `offset == headerLength` and avoid over-trusting hints from multi-member streams.

---

## 6. Comparisons to Similar Systems & Competitive Landscape

| Library / System | Platform Support | Codecs Supported | True Streaming (Bounded Memory) | Parquet Raw/Hadoop Support | Security Caps (`maxSize` / Bomb Guard) | Performance Profile |
|---|---|---|---|---|---|---|
| **`libcompress` (This Repo)** | **All Dart** (VM, AOT, `dart2js`, `dart2wasm`) | LZ4 (L1–9), Snappy, GZIP, Raw DEFLATE, Zstd (L1–22) | **Yes** (Incremental 32–128 KB window + `verified` mode) | **Yes** (`LZ4_RAW`, `LZ4` Hadoop, `SNAPPY`, `GZIP`, `ZSTD`) | **Built-in** (`maxSize`, `maxBufferSize`, pre-alloc checks) | Fast pure Dart (64-bit word loops on VM, safe 53-bit math on JS) |
| **`dart:io` (`gzip` / `zlib`)** | Dart VM only (No Web) | GZIP, Zlib, Raw DEFLATE | Yes (Native C `zlib`) | GZIP only | Manual | Fastest for GZIP on VM (C FFI), unavailable on Web |
| **`package:archive`** | All Dart | GZIP, Zlib, Deflate, BZip2, XZ, LZW | Partial (mostly whole-buffer oriented) | Partial | Limited | Slower on DEFLATE/LZ4; heavier dependency footprint |
| **`package:es_compression`** | Dart VM only (FFI prebuilts) | Brotli, LZ4, Zstd | Yes (Native FFI) | Frame only | Manual | Native C speed, breaks on Web & complicates cross-compilation |

### Competitive Pros & Cons
- **Pros**:
  - **Zero FFI / Native Dependencies**: Works out-of-the-box on Flutter Web (`dart2js` / `dart2wasm`), Flutter mobile/desktop, and server-side Dart without native build hooks or binary distribution issues.
  - **First-Class Apache Parquet / Arrow Ecosystem Support**: Directly implements `Lz4Format.raw`, `Lz4Format.hadoop`, `SnappyFormat.raw`, and `decompress(data, size: expected)` with exact-size fast paths (`Lz4Decoder._decompressExact`).
  - **Security-First Design**: Unlike `package:archive` or `dart:io`, decompression bomb limits (`LimitException`), input buffer caps, and `verified: true` trailer-withholding are first-class citizens.
- **Cons**:
  - **Throughput vs. Native SIMD**: Pure Dart cannot use hardware SIMD (`pshufb` / NEON / AVX2) or hardware `crc32c` instructions, so raw throughput is naturally $2\times$–$5\times$ lower than C `liblz4` / `libzstd` / `zlib-ng`.
  - **Zstd Feature Subset**: Lacks dictionary support (`zstd -D`), FSE-compressed Huffman weights (`maxSym > 128`), repeat-offset encoding, and repeat-table mode (`Mode 3`) on the encoder side.

---

## 7. Suggestions for Feature Gaps, Correctness, and Performance

1. **Feature Gaps**:
   - **Zstd Dictionary Support (RFC 8878 §5)**: Supporting raw content dictionaries and formatted Zstd dictionaries (`ZstdCodec(dictionary: ...)`), which is critical for small-payload compression (e.g., JSON/Protobuf RPC messages or database rows).
   - **Streaming Raw DEFLATE (`DeflateStreamCodec`) & Zlib Framing (RFC 1950)**: Adding a 2-byte header + Adler-32 trailer (`ZlibCodec`) and exposing `StreamingDeflateEncoder` + incremental DEFLATE decoding as a `DeflateStreamCodec` (useful for ZIP streaming, HTTP `deflate`, and WebSocket `permessage-deflate`).
   - **LZ4 Block Checksums & Content Size on Encode**: `Lz4Encoder` currently decodes `blockChecksum` and `contentSize` in `Lz4Decoder`, but does not offer options to write the 8-byte `Content_Size` in the frame header during block `compress()` or optional per-block XXH32 checksums.
2. **Correctness Improvements**:
   - Fix the Zstd `maxSym > 128` Huffman weight limitation (**H1**) so UTF-8 and binary literals are Huffman-compressed.
   - Guard `FseEncoder._normalize` when `distinct == size` or `diff != 0` by using `-1` (probability $< 1$) states or increasing `tableLog`.
3. **Performance Improvements**:
   - **Typed-Array Token Buffers**: Removing boxed `Token` / `ZstdMatch` / `_SequenceToken` allocations (**H3**) will cut GC pressure and improve GZIP and Zstd compression throughput by ~20–35%.
   - **8-Byte Word Copy in `Lz4Decoder._decompressExact` & `_BlockDecoder`**: Apply the same `wide` 64-bit `ByteData.getUint64`/`setUint64` wild-copy optimization used in `SnappyDecoder` and `DeflateDecoder._inflate` to LZ4 decoding.
