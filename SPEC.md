# Spec: encoder fixes from ANALYSIS.md

Status: draft, 2026-11-11. Scope: the ANALYSIS.md findings confirmed by
measurement and selected for fixing. Every other finding is recorded in the
appendix with its verification result.

## 1. Objective

| ID | Defect | Measured effect (this tree) |
|----|--------|-----------------------------|
| T1 | DEFLATE and Zstd encoders allocate one heap object per token, per match and per length/distance code | Every literal and match in a block becomes a boxed object. A 64 KB block of incompressible data creates about 65,000 `LiteralToken`s. Each DEFLATE match then allocates 4 more objects (`LengthCode` and `DistanceCode`, once for counting and once for writing). Each Zstd match allocates a `ZstdMatch`, a 9-field `_SequenceToken` and an `_OffsetEncoding` |
| Z1 | `CompressedBlockEncoder._encodeHuffmanLiterals` falls back to raw literals whenever any literal byte is `> 128` | Level 3, 64 KB skewed text over bytes 32..95: 45,221 bytes. The same input with **one** byte set to 200: 64,029 bytes (+42%). The same distribution shifted to 160..223: 63,995 bytes |
| Z2 | `StreamingZstdEncoder.addChunk` emits one block per input chunk, with no buffering | 256 KB compressible input: 51 bytes when fed as 128 KB chunks, 40,982 bytes when fed as 64-byte chunks (about 800x) |

Z1 hits every binary payload, including Parquet pages, which are the primary
consumer. Z2 hits any `ZstdStreamCodec` user whose source produces small
events (sockets, line readers, `File.openRead` with small buffers). T1 costs
compression throughput and GC pressure on every GZIP, DEFLATE and Zstd encode.

None of the fixes changes the public API. The tokens, `ZstdMatch` and the
encoder classes involved are all internal (not exported by
`lib/libcompress.dart`). The decoder already supports FSE-compressed Huffman
weights (`literals_decoder.dart:456`).

## 2. Assumptions

1. Each part lands as its own commit. Recommended order: **T1, Z1, Z2**. T1
   must not change output, so it is easiest to verify against an unchanged
   parent before Z1 and Z2 change the Zstd output.
2. Project priority for Zstd is "compatible and safe", not ratio parity. Z1
   and Z2 are in scope because they are pathological losses (raw output on
   compressible data), not tuning. Repeat offsets, `niceLength` and lazy
   matching for Zstd (ANALYSIS M2) stay out of scope.
3. The ANALYSIS.md sample code is a sketch only. It has known errors (see
   4.4) and is not to be copied.

## 3. Part T1: remove per-token heap allocations

T1 is a pure refactor. **Compressed output must be byte-identical** to the
parent commit for every codec, level, block size and input.

### 3.1 DEFLATE tokens

Current: `Lz77Encoder.tokenize` returns `(List<Token>, int)` of boxed
`LiteralToken` / `MatchToken` (`deflate_common.dart:240`).
`DeflateEncoder.writeBlock`, `writeFixedBlock`, `writeDynamicBlock`,
`_writeDynamic` and `_Counts` iterate the list with `is` checks.

Required:

1. `Lz77Encoder` owns one `Uint32List` token buffer, grown on demand and
   reused across calls. `tokenize` writes into it and returns
   `(Uint32List tokens, int count, int end)`. The buffer contents are only
   valid until the next `tokenize` call; document this on the method.
2. Packing: a literal is its byte value (`0..255`); a match is
   `distance << 9 | length` (`length` 3..258 fits 9 bits, `distance` 1..32768
   fits 16 bits). `token >> 9 == 0` means literal. Every value stays below
   `2^25`, so it is exact on dart2js with no sign issues (the ANALYSIS
   proposal `distance << 16` reaches `2^31`).
3. The block writers take `(Uint32List tokens, int count)` in place of
   `List<Token>`. `StreamingDeflateEncoder` (`streaming_deflate_encoder.dart:73`)
   is the second caller and changes the same way.
4. Remove `Token`, `LiteralToken` and `MatchToken` once nothing uses them.

### 3.2 DEFLATE length and distance codes

Current: `encodeLength` / `encodeDistance` (`deflate_common.dart:151`,
`:165`) return new `LengthCode` / `DistanceCode` objects, and each match calls
both twice (in `_Counts` and in the writer).

Required:

1. Replace them with `int` lookups on the existing tables
   (`_lengthCodeFor`, `_distanceCodeFor`). Callers read extra bits and extra
   values from `lengthExtraBits` / `lengthBase` and `distanceExtraBits` /
   `distanceBase`, which already exist.
2. The range checks become `assert`s: the match finder produces only valid
   lengths and distances, so an out-of-range value is a programming error.
3. Remove `LengthCode` and `DistanceCode` once nothing uses them.
4. Computing codes twice per match (count pass, write pass) is acceptable
   once the lookups no longer allocate. Do not add a cache for them.

### 3.3 Zstd matches and sequences

Current: `MatchFinder.findMatches` returns `List<ZstdMatch>`.
`SequenceSymbols.from` builds three growable `List<int>` of symbols, and
`SequenceEncoder._buildTokens` computes the same symbols again into a
`List<_SequenceToken>`, with an `_OffsetEncoding` per match.

Required:

1. `MatchFinder` owns reusable typed buffers for sequences (`offsets`,
   `lengths`, `literals` as `Int32List`, grown on demand) and `findMatches`
   returns the count plus the trailing literals. As in 3.1, the contents are
   valid until the next call. `extractLiterals` reads the same buffers.
2. Symbol codes are computed **once** per sequence, into reusable
   `Uint8List`s (literal-length, offset and match-length codes). Those arrays
   feed both `FseEncoder.stats` (which takes `List<int>`, so a `Uint8List`
   works) and `SequenceEncoder.encodeSequences`.
3. `encodeSequences` computes extra bits and values inline from the symbol
   arrays and the sequence buffers, using the existing `seq.*Base` and
   `seq.*Bits` tables. Remove `_SequenceToken`, `_OffsetEncoding`,
   `SequenceSymbols` and `ZstdMatch` once nothing uses them.
4. Keep the existing hot-path behavior: absolute offsets only, the same FSE
   state order, the same extra-bit order.

### 3.4 Out of scope for T1

- Changing match-finding decisions or block splitting (that would change
  output).
- Making `BitStreamWriter` or `BytesBuilder` usage allocation-free.

## 4. Part Z1: FSE-compressed Huffman weights

### 4.1 Current behavior

- `huffman_encoder.dart:247` `encodeWeightsHeader` writes only the direct
  representation: header byte `127 + count`, then 4-bit weights. Its maximum
  is 128 weights (header byte 255).
- `compressed_block_encoder.dart:171` returns `null` when `maxSym > 128`, so
  the block uses raw literals.

### 4.2 Required behavior (RFC 8878 section 4.2.1.2)

`encodeWeightsHeader(maxSym)` returns the Huffman tree description for
symbols `0..maxSym` (count = `maxSym`, the last weight is implicit):

1. If `count <= 128`, keep the direct representation exactly as it is today.
   This keeps output byte-identical for inputs that already work.
2. If `count > 128`, write the FSE-compressed representation:
   - Weights are values `0..12`. Build the table with the existing
     `FseEncoder.build(counts, 6, 12)` (accuracy log at most 6, as the decoder
     checks at `literals_decoder.dart:351`).
   - Write the FSE table header (`FseEncoder.encodeHeader`), then a backward
     bitstream encoding `weights[0..count-1]` with **two interleaved states
     sharing one table**. The decoder (`_decodeFseCompressedHuffmanWeights`)
     reads `state1` then `state2`, then decodes alternately starting with
     `state1`, so `weights[0]` comes from `state1`, `weights[1]` from
     `state2`, and so on. The encoder must produce exactly `count` weights
     when decoded, with the stream ending where the decoder stops.
   - Header byte = total size of FSE table header plus bitstream. It must be
     `< 128`. If it is `>= 128`, return `null` (the caller then falls back to
     raw literals, as today).
3. Degenerate weight distributions: if every weight in `weights[0..count-1]`
   is the same value, FSE cannot build a two-symbol table. Return `null` (raw
   literals). Measure how often this occurs before adding any special case.
4. Reuse `FseCompressionTable` (`sequence_encoder.dart:306`) for the state
   machine if its `begin`/`encode`/`finish` semantics match a two-state
   stream. If they do not, add the smallest helper needed next to
   `HuffmanEncoder`. Do not duplicate the table construction.

### 4.3 Caller change

`compressed_block_encoder.dart`: remove the `maxSym > 128` early return. A
`null` from `encodeWeightsHeader` means "Huffman not possible", the same as
the existing `encoded == null` path. `encodeWeightsHeader` return type becomes
`Uint8List?`; it has one caller.

### 4.4 Errors to avoid (from the ANALYSIS.md sketch)

- It uses `count <= 127` for the direct case. 128 weights are legal (header
  255). Changing this would alter output for `maxSym == 128`.
- It references an undefined `maxTableLog` and calls `FseEncoder.stats` with
  the wrong bound (weights max out at 12).
- It does not check the `< 128` limit on the compressed size.
- Its state parity logic is unverified against our decoder.

## 5. Part Z2: buffer small chunks in `StreamingZstdEncoder`

### 5.1 Current behavior

`addChunk` splits each chunk into `<= blockSize` pieces and emits each piece as
a block immediately (`streaming_zstd_encoder.dart:87`). `finish` always
writes an empty last raw block (`:101`).

### 5.2 Required behavior

Match `StreamingLz4Encoder.addChunk` (`lz4_encoder.dart:292`):

1. `addChunk` appends input to `_cur` after the history at `_hist`, tracking
   the buffered end in one new field (`_length`). Whenever
   `_length - _hist == blockSize`, encode that full block (not last) and
   rotate history as `_emitBlock` does now. Return the bytes produced, which
   may be empty.
2. `finish`:
   - If buffered bytes remain, encode them as the **last** block (last bit
     set, compressed or raw, whichever is smaller, as today).
   - If nothing remains (empty input, or input an exact multiple of
     `blockSize`), write the empty last raw block as today.
   - Then the optional checksum.
3. The XXH64 sink must still see every input byte exactly once, in order.
4. Buffer sizing is unchanged: history `<= blockSize` plus pending
   `<= blockSize` fits the existing `2 * blockSize` buffers, and the declared
   window (`_windowByteFor`) still covers every offset.
5. `_emitBlock` gains a `last` parameter; the block header writer already
   takes one.

### 5.3 Behavior change to document

Output is now delayed until `blockSize` bytes accumulate or the stream ends.
This matches LZ4 and DEFLATE streaming. There is no flush API today and this
spec does not add one. The CHANGELOG notes the change (section 9).

## 6. Testing strategy

All new tests go in the codec's single test file (`test/gzip_codec_test.dart`,
`test/zstd_codec_test.dart`), using the helpers in `test/test_utils.dart`.
Each new test must be checked by breaking the code deliberately, confirming
the test fails, restoring it, and confirming it passes.

### T1

1. **Output identity (verification step, not a committed test).** A script
   in the scratchpad compresses every fixture in `test/fixtures/data` plus the
   benchmark's synthetic inputs (random, zeros, period-7, Parquet-sized pages)
   with GZIP L1-L9, DEFLATE L1-L9, Zstd L1-L22 (block codec, and streaming at
   the default and a 16 KB block size), on the parent commit (via a git
   worktree) and on the change. Every output must be byte-identical. A
   committed golden-hash test is not wanted: Z1 and later encoder work change
   output on purpose.
2. Update `dynamic block with a deep Huffman tree stays decodable`
   (`gzip_codec_test.dart:1360`) to build packed tokens. It must keep passing,
   including the system `gzip` check.
3. Add `token buffer reuse across blocks`: compress input spanning several
   DEFLATE blocks and several Zstd blocks, where a later block has fewer
   tokens than an earlier one, and round-trip it. This catches stale entries
   from a reused buffer being read past `count`.
4. Existing round-trip, fragmented, level, CLI-compatibility and ratio-floor
   tests must pass unchanged.
5. **Throughput.** Run `benchmark/codec_benchmark.dart` for `gzip` and `zstd`
   before and after with `dart run` (JIT). Run each side twice and keep the
   better figure per row, since JIT numbers vary between runs. Record both
   tables in the commit message. First baseline from this tree: gzip L6
   bible.txt 20.9 MB/s, gzip L1 house.jpg 28.7 MB/s, zstd L3 bible.txt
   27.9 MB/s, zstd L3 page 8K 52.4 MB/s.

### Z1

1. `Huffman literals with bytes above 128 compress`: the skewed 64 KB input
   from section 1 shifted to 160..223 must compress to within 2% of the
   unshifted input, and round-trip.
2. `one high byte does not disable Huffman`: low-alphabet input plus a single
   byte 200 must stay within 2% of the input without it.
3. `full byte alphabet uses FSE weights`: a skewed distribution over all 256
   values round-trips, and the literals section carries a Huffman tree header
   byte `< 128` (parse the first compressed block's literals header).
4. `direct weights unchanged at maxSym 128`: compressed output for an input
   with `maxSym == 128` is byte-identical before and after the change
   (pin the expected length or hash).
5. Reference interop: frames from tests 1 and 3 decode with the system
   `zstd -d` when `zstd` is on `PATH` (skip otherwise, as
   `benchmark_test.dart:367` does).
6. The existing `no raw-block fallbacks` group (levels 1-22) and
   `meets compression-ratio floors on the corpus` must still pass. Tighten the
   corpus floors for binary fixtures if they improve.

### Z2

1. `small chunks produce the same blocks as one chunk`: 256 KB input fed as
   64-byte chunks produces output byte-identical to the same input fed as a
   single chunk.
2. `no trailing empty block for non-empty input`: the last block header of a
   non-empty, non-multiple-of-`blockSize` stream has the last bit set and a
   non-zero size.
3. `exact multiple of blockSize`: input of `2 * blockSize` round-trips and
   ends with the empty last block.
4. The existing streaming tests (`fragmented (1-byte) input`, checksum,
   `verified` mode, window descriptor, cross-chunk history) must pass
   unchanged.
5. Reference interop: a 64-byte-chunk stream decodes with `zstd -d` when
   available.

### Test runs

`dart analyze`, `dart test`, and the web test run
(`dart test test/web_runtime_codec_matrix_test.dart`, which compiles every
codec with dart2js at `-O1` and `-O4` and runs it under `node`). T1 changes
packed-integer arithmetic and Z1 adds bit arithmetic; both must stay exact on
dart2js.

## 7. Boundaries

- Always: keep the decoders unchanged; keep T1 output byte-identical; keep Z1
  output byte-identical for inputs that already used Huffman literals
  (`maxSym <= 128`).
- Ask first: any public API change (for example a `flush()` on
  `StreamCompressor`), raising the FSE accuracy log above 6, or any T1 change
  that alters output.
- Never: emit a weights header the in-repo decoder or reference `zstd`
  rejects; hide encode errors (the existing `strict` / `validate` /
  `onFallback` paths stay as they are).

## 8. Success criteria

1. All tests in section 6 pass on VM and web.
2. T1: output identity holds across the whole matrix in 6/T1/1; no
   `LiteralToken`, `MatchToken`, `LengthCode`, `DistanceCode`, `ZstdMatch`,
   `_SequenceToken` or `_OffsetEncoding` remain; JIT compress throughput is
   not lower on any benchmark row beyond run-to-run noise (about 5%). The
   ANALYSIS.md estimate of a 20-35% gain is not a target; report the
   measured change.
3. Z1 and Z2: the section 1 measurements become: shifted input within 2% of
   45,221 bytes; 64-byte-chunk stream equal in size to the single-chunk
   stream.
4. No change to any existing test expectation other than the packed-token
   update in 6/T1/2 and tightened ratio floors.

## 9. Release

The three fixes ship as **2.2.0**: `pubspec.yaml` version `2.2.0` and a
`## 2.2.0` CHANGELOG section, in the existing style, with one entry each:

- T1: faster GZIP, DEFLATE and Zstd compression from fewer allocations;
  output unchanged.
- Z1: Zstd Huffman-codes literals containing bytes above 128 (binary data,
  non-ASCII UTF-8), which previously fell back to raw literals.
- Z2: `ZstdStreamCodec` buffers input into full blocks; output for a stream
  of small chunks is now held until `blockSize` bytes accumulate or the
  stream ends, as `Lz4StreamCodec` and `GzipStreamCodec` already do.

## Appendix: verification of the other ANALYSIS.md findings

| Finding | Result | Notes |
|---------|--------|-------|
| Bug 1, Huffman `maxSym > 128` | Confirmed | Part Z1 |
| Bug 2, FSE normalization fails with 32 offset symbols | **Refuted** | `_optimalLog` and the table sizes keep `distinct <= size` (OF 32/32, LL 36/64, ML 53/64). Rounding up gives `sum >= size`; reducing every symbol to 1 gives `sum = distinct <= size`, so the loop always reaches `diff == 0`. 200,000 randomized trials over all three tables, half with every symbol present: 0 failures |
| Bug 3, one Zstd block per chunk | Confirmed | Part Z2 |
| Bug 4, CLI temp file on signal | Partly confirmed | No signal handler, so `$output.tmp-$pid` survives SIGINT/SIGTERM. The `_same` broken-symlink throw is not reachable: `_checkPaths` checks `existsSync` first, and `existsSync` is false for a broken symlink |
| Perf 1, per-token allocations, double `encodeLength` | Confirmed | Part T1 (ANALYSIS H3) |
| Perf 2, `GzipIncrementalDecoder` symbol-at-a-time | Confirmed | `_decodeOneSymbol` at `gzip_incremental_decoder.dart:234`. Candidate for a separate decode-speed spec, which fits the Parquet priority |
| Perf 3, byte loop on overlapping copy | Confirmed | `WindowBuffer.copyFromHistory:111`, `Lz4Decoder._decompressExact` |
| Perf 4, 3-byte `Uint8List` per Zstd block | Confirmed | `zstd_decoder.dart:475` |
| Perf 5, no `niceLength` in `MatchFinder` | Confirmed | Out of scope |
| Perf 6, gzip `ISIZE` hint from last member | Confirmed, minor | Capacity hint only. `DeflateDecoder` clamps it (1032:1 bound), so it is not a safety issue |
| `ZstdCompressor` pass-through wrapper | Confirmed | Low priority cleanup |
| Mutable `_hi` / `_lo` globals in `xxh64_web.dart` | Confirmed | `xxh64_web.dart:310` |
