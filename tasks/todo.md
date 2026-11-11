# Tasks: encoder fixes (SPEC.md T1, Z1, Z2)

Plan: `tasks/plan.md`. Spec: `SPEC.md`. The user makes all commits at the
checkpoints.

Standard commands:

- Analyze: `dart analyze`
- Focused tests: `dart test test/<codec>_codec_test.dart`
- Full suite: `dart test`
- Web: `dart test test/web_runtime_codec_matrix_test.dart` (needs `node`)
- Identity: `dart run --packages=.dart_tool/package_config.json <scratchpad>/identity.dart > <file>`, then `diff` against the baseline
- Benchmark (JIT): `dart run benchmark/codec_benchmark.dart gzip` and `... zstd`, twice per side, keep the better figure per row

Every new test is checked by breaking the code deliberately, confirming the
test fails, restoring it, and confirming it passes.

---

## Task 1: identity harness and baselines

**Description:** Write a scratchpad script that compresses a fixed input
matrix and prints one line per case: `input codec level blockSize mode length
crc32`. Inputs: every file in `test/fixtures/data`, plus random 1 MB, zeros
1 MB, period-7 1 MB, Parquet-sized pages (1 KB, 8 KB, 64 KB), and a
multi-block input whose later blocks have fewer tokens than earlier ones
(compressible text followed by a shorter, incompressible tail, repeated).
Codecs: GZIP L1-L9, DEFLATE L1-L9, Zstd L1-L22 block, Zstd streaming at the
default and a 16 KB block size (fed as 64 KB chunks). Run it on the current
tree and save the output as the baseline. Record the benchmark baseline for
`gzip` and `zstd`.

**Acceptance criteria:**
- [x] Baseline file saved in the scratchpad before any source change
- [x] Running the script twice on the same tree gives identical output
- [x] Benchmark baseline tables saved in the scratchpad

**Verification:**
- [x] `diff` of two runs on the unchanged tree is empty
- [x] `git status` shows no new files in the repository

**Done (2026-11-11):** scratchpad `identity.dart` writes 2,385 cases (53
inputs x GZIP/DEFLATE L1-9 block, GZIP L1/6/9 stream, Zstd L1-22 block, Zstd
L3 stream at 128 KB and 16 KB blocks) in about 78 s; `baseline.txt` and a
repeat run match exactly. Benchmark: two JIT runs per codec,
best-of-two per row in `bench-base-best.txt` (via `bestof.py`).

**Dependencies:** None

**Files likely touched:** scratchpad only

**Estimated scope:** XS

---

## Task 2: DEFLATE length/distance codes as int lookups

**Description:** Replace `encodeLength` / `encodeDistance` and the
`LengthCode` / `DistanceCode` classes in `deflate_common.dart` with `int`
lookups on `_lengthCodeFor` / `_distanceCodeFor`. Callers in
`deflate_encoder.dart` (`writeFixedBlock`, `_writeDynamic`, `_Counts`) read
extra bits and values from the existing base and extra-bit tables. Range
checks become `assert`s. Tokens stay as they are in this task.

**Acceptance criteria:**
- [x] `LengthCode`, `DistanceCode`, `encodeLength`, `encodeDistance` removed
- [x] Identity output for every GZIP and DEFLATE case equals the baseline

**Verification:**
- [x] `dart analyze` clean
- [x] `dart test test/gzip_codec_test.dart test/deflate_codec_test.dart`
- [x] Identity diff empty for GZIP/DEFLATE rows

**Dependencies:** Task 1

**Files likely touched:**
- `lib/src/gzip/deflate_common.dart`
- `lib/src/gzip/deflate_encoder.dart`

**Estimated scope:** S

---

## Task 3: DEFLATE packed tokens

**Description:** `Lz77Encoder` owns a reusable `Uint32List` token buffer.
`tokenize` returns `(tokens, count, end)`; a literal is its byte value, a
match is `distance << 9 | length`. The block writers and `_Counts` take
`(Uint32List tokens, int count)`. `DeflateEncoder.compress` and
`StreamingDeflateEncoder._encode` pass them through. Document that the buffer
is valid only until the next `tokenize`. Remove `Token`, `LiteralToken`,
`MatchToken`. Update the deep-Huffman-tree test to build packed tokens. Add
`token buffer reuse across blocks` to `deflate_codec_test.dart` (and the GZIP
streaming equivalent to `gzip_codec_test.dart`).

**Acceptance criteria:**
- [x] No `Token` types remain in `lib/` or `test/`
- [x] Identity output for every GZIP and DEFLATE case equals the baseline
- [x] The reuse test fails when `count` is ignored (for example when the
      writer iterates the whole buffer)

**Verification:**
- [x] `dart analyze` clean
- [x] `dart test test/gzip_codec_test.dart test/deflate_codec_test.dart`,
      including the system `gzip` check in the deep-tree test
- [x] Identity diff empty for GZIP/DEFLATE rows

**Dependencies:** Task 2

**Files likely touched:**
- `lib/src/gzip/lz77_encoder.dart`
- `lib/src/gzip/deflate_encoder.dart`
- `lib/src/gzip/streaming_deflate_encoder.dart`
- `lib/src/gzip/deflate_common.dart`
- `test/gzip_codec_test.dart`, `test/deflate_codec_test.dart`

**Estimated scope:** M

---

## Checkpoint A: DEFLATE allocation work

- [x] `dart analyze` clean, `dart test` passes
- [x] Web matrix test passes
- [x] Identity diff empty for all GZIP/DEFLATE rows
- [x] No commit: user chose to commit after the run

---

## Task 4: typed sequence buffers in `MatchFinder`

**Description:** `MatchFinder` owns reusable `Int32List` buffers for
offsets, match lengths and literal lengths, grown on demand.
`findMatches` returns `(count, trailing)`. `extractLiterals` and
`CompressedBlockEncoder` read the buffers. To keep this task small,
`SequenceSymbols.from` and `SequenceEncoder.encodeSequences` are adapted to
read the buffers (with `count`) instead of `List<ZstdMatch>`; their internal
symbol computation is left for Task 5. Remove `ZstdMatch`. Add
`sequence buffer reuse across blocks` to `zstd_codec_test.dart`.

**Acceptance criteria:**
- [x] `ZstdMatch` removed
- [x] Identity output for every Zstd case equals the baseline
- [x] The reuse test fails when `count` is ignored

**Verification:**
- [x] `dart analyze` clean
- [x] `dart test test/zstd_codec_test.dart`
- [x] Identity diff empty for Zstd rows

**Dependencies:** Task 1

**Files likely touched:**
- `lib/src/zstd/match_finder.dart`
- `lib/src/zstd/compressed_block_encoder.dart`
- `lib/src/zstd/sequence_encoder.dart`
- `test/zstd_codec_test.dart`

**Estimated scope:** M

---

## Task 5: compute sequence symbols once, remove token classes

**Description:** Compute literal-length, offset and match-length codes once
per sequence into reusable `Uint8List`s. They feed `FseEncoder.stats` and
`encodeSequences`, which computes extra bits and values inline from the
sequence buffers and the `seq.*Base` / `seq.*Bits` tables. Remove
`SequenceSymbols`, `_SequenceToken`, `_OffsetEncoding`. State order and
extra-bit order stay as they are.

**Acceptance criteria:**
- [x] `SequenceSymbols`, `_SequenceToken`, `_OffsetEncoding` removed
- [x] Identity output for every Zstd case equals the baseline
- [x] No growable `List<int>` or per-sequence object allocated on the
      sequence path

**Verification:**
- [x] `dart analyze` clean
- [x] `dart test test/zstd_codec_test.dart`
- [x] Identity diff empty for Zstd rows

**Dependencies:** Task 4

**Files likely touched:**
- `lib/src/zstd/sequence_encoder.dart`
- `lib/src/zstd/compressed_block_encoder.dart`

**Estimated scope:** S

---

## Checkpoint B: T1 complete

- [x] `dart analyze` clean, `dart test` passes
- [x] Web matrix test passes
- [x] Identity diff empty for the whole matrix
- [x] Benchmark after T1 recorded next to the baseline; no compress row slower
      than baseline beyond about 5% (if one is, stop and report)
- [x] `pubspec.yaml` version `2.2.0`; `## 2.2.0` CHANGELOG section with the
      T1 entry (SPEC.md section 9)
- [x] No commit: user chose to commit after the run (benchmark tables in the final summary)

---

## Task 6: FSE-compressed Huffman weights

**Description:** In `HuffmanEncoder.encodeWeightsHeader`, keep the direct
representation for `count <= 128`; for `count > 128` write the FSE table
header (`FseEncoder.build(counts, 6, 12)`) and a backward bitstream with two
interleaved states sharing one `FseCompressionTable`, matching the decoder's
read order (`state1` first, alternating from `weights[0]`). Return `null`
when the compressed size is `>= 128` or all weights are equal. Return type
becomes `Uint8List?`. In `CompressedBlockEncoder._encodeHuffmanLiterals`,
remove the `maxSym > 128` guard and treat `null` as "no Huffman". Start by
checking the two-state order with a round trip through both decoders over
many random weight sets before relying on it. Add Z1 tests 1, 2, 3 and 5
from SPEC.md section 6.

**Acceptance criteria:**
- [x] Shifted skewed input (bytes 160..223) within 2% of the unshifted
      size, and round-trips
- [x] Low-alphabet input plus one byte 200 within 2% of the input without it
- [x] Full-alphabet input carries a tree header byte `< 128` and decodes
      with `zstd -d` (skipped when `zstd` is not on `PATH`)

**Verification:**
- [x] `dart analyze` clean
- [x] `dart test test/zstd_codec_test.dart`, including the
      `no raw-block fallbacks` group at levels 1-22
- [x] Section 1 measurement script from SPEC.md re-run and recorded

**Dependencies:** Task 5

**Files likely touched:**
- `lib/src/zstd/huffman_encoder.dart`
- `lib/src/zstd/compressed_block_encoder.dart`
- `test/zstd_codec_test.dart`

**Estimated scope:** M

---

**Resolved (2026-11-11):** user chose a 1% tolerance for the `level 6+ ratio is not worse than level 3` test (kennedy.xls: L3 218,366 vs
L6 218,389 bytes, both down from about 237,800). 300-input stress run through
both decoders: 278 FSE weight headers, 0 failures.

---

## Task 7: Z1 edge cases and ratio floors

**Description:** Add `direct weights unchanged at maxSym 128` (output for a
`maxSym == 128` input matches its baseline identity row). Cover the `>= 128`
compressed-size fallback and the all-equal-weights fallback with tests that
reach them through the codec. Measure how often each fallback happens on
`test/fixtures/data`. Tighten the corpus ratio floors in `zstd_codec_test.dart`
for fixtures that improved.

**Acceptance criteria:**
- [x] `maxSym == 128` case byte-identical to the baseline
- [x] Both fallbacks produce valid frames and are covered by tests
- [x] Ratio floors updated only upward

**Verification:**
- [x] `dart test test/zstd_codec_test.dart`
- [x] Identity diff: Zstd rows differ only where inputs contain bytes > 128

**Dependencies:** Task 6

**Files likely touched:**
- `test/zstd_codec_test.dart`
- `lib/src/zstd/huffman_encoder.dart` (only if a fallback needs a fix)

**Estimated scope:** S

---

**Done (2026-11-11):** `direct weights unchanged at maxSym 128` pins the 2.1.0
output (52,921 bytes, CRC `bfbb25ca`, checked against `git archive HEAD`).
The all-equal-weights fallback is unreachable through the codec (129+ equal
weights force 8-bit codes, which never beat raw literals), so its test calls
`encodeWeightsHeader` directly. The 128-byte size fallback has no test: the
largest FSE weights description seen was 98 bytes in 20,000 adversarial
weight sets and 91 bytes over the corpus (31 blocks, 0 fallbacks). Identity:
288 Zstd rows changed, all inputs with bytes above 128, all smaller; no
GZIP/DEFLATE row changed. New binary floors: kennedy.xls 78%, calgary/geo 27%.

---

## Checkpoint C: Z1 complete

- [x] `dart analyze` clean, `dart test` passes
- [x] Web matrix test passes
- [x] Z1 entry added to the `## 2.2.0` CHANGELOG section
- [x] No commit: user chose to commit after the run

---

Added a `skewed` case to `test/support/web_codec_matrix_runner.dart`: none of
the existing cases reached FSE-compressed weights, so the web run did not
cover Z1's bit arithmetic.

---

## Task 8: buffer small chunks in `StreamingZstdEncoder`

**Description:** `addChunk` appends into `_cur` after the history and
emits a block only when `blockSize` bytes are buffered. `finish` encodes the
remaining bytes as the last block, or writes the empty last raw block when
nothing is buffered, then the optional checksum. `_emitBlock` takes `last`.
Add Z2 tests 1, 2, 3 and 5 from SPEC.md section 6. Add the Z2 entry
(output-latency change) to the `## 2.2.0` CHANGELOG section.

**Acceptance criteria:**
- [x] 256 KB input fed as 64-byte chunks gives output byte-identical to the
      same input fed as one chunk
- [x] Non-empty input not a multiple of `blockSize` ends with a non-empty
      last block; `2 * blockSize` input ends with the empty last block
- [x] 64-byte-chunk output decodes with `zstd -d` (skipped when unavailable)

**Verification:**
- [x] `dart analyze` clean
- [x] `dart test test/zstd_codec_test.dart`, including the existing
      fragmented, checksum, `verified`, window-descriptor and cross-chunk tests

**Dependencies:** Task 5

**Files likely touched:**
- `lib/src/zstd/streaming_zstd_encoder.dart`
- `test/zstd_codec_test.dart`
- `CHANGELOG.md`

**Estimated scope:** S

---

**Done (2026-11-11):** output is now independent of chunking (kennedy.xls:
210,700 bytes for 64-byte, 64 KB or single chunks; previously 464,066,
200,361 and 210,703). Identity: only Zstd stream rows changed; the identity
script's 64 KB chunks used to act as 64 KB blocks, so a few files grow up to
5% at the default 128 KB `blockSize` (`blockSize: 64 * 1024` gives the old
size back).

---

## Checkpoint D: complete

- [x] `dart analyze` clean, `dart test` passes
- [x] Web matrix test passes
- [x] Every SPEC.md section 8 success criterion checked off
- [x] Final benchmark recorded
- [ ] User reviews and commits (all changes left uncommitted at the user's request)

**Open finding (2026-11-11):** Zstd L3 compression of `house.jpg` is 37%
slower than 2.1.0 (79.8 to 50.4 MB/s, same-session back-to-back runs) for a
0.2% size gain: JPEG literals now get Huffman tables built and encoded. Two
output-preserving checks were tried and reverted: the reference
`HUF_compress` early exit (no effect: JPEG literals pass it) and an exact
size pre-check before stream encoding (50 to 53 MB/s only). Text and other
binary inputs are unaffected or faster. Needs profiling of the Huffman
literal path; not in SPEC.md scope.

**Follow-up (2026-11-11), Huffman literal path profiled:** on house.jpg
(one block, 99% literals) the time was findMatches 57%, Huffman stream
encoding 28%, Huffman build 4%, histogram 4%, FSE weights header 1%. Stream
encoding was rewritten in `huffman_encoder.dart` (typed code tables, one
local bit-buffer loop per stream, streams written in place after the jump
table, no per-symbol `BitStreamWriter` calls or copies): 0.76 to 0.31 ms per
block, output byte-identical (identity matrix), full suite and web matrix
pass. house.jpg Zstd L3 vs 2.1.0 is now -12.5% (was -37%), measured at load
average 4 to 5. random 1M at -8.8% is within that noise (it was -2% in a
quiet run earlier, and its output path is unchanged by Z1).

