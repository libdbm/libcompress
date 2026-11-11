# Implementation Plan: encoder fixes (SPEC.md T1, Z1, Z2)

## Overview

Three independent encoder fixes from `SPEC.md`:

- **T1** removes per-token heap allocations from the DEFLATE and Zstd
  encoders. Pure refactor: compressed output must stay byte-identical.
- **Z1** adds FSE-compressed Huffman weights so Zstd literals with byte
  values above 128 are Huffman-coded.
- **Z2** buffers small chunks in `StreamingZstdEncoder` so each block holds up
  to `blockSize` bytes.

Tasks are in `tasks/todo.md`. Commits are made by the user at each
checkpoint; nothing is committed by the agent.

## Dependency graph

```
Task 1: identity harness + baselines
   │
   ├── T1 DEFLATE path
   │     Task 2: int length/distance lookups
   │        └── Task 3: packed Uint32List tokens
   │
   ├── T1 Zstd path (independent of DEFLATE)
   │     Task 4: typed sequence buffers in MatchFinder
   │        └── Task 5: symbols computed once, token classes removed
   │
   ├── Z1 (after Task 5: both touch compressed_block_encoder.dart)
   │     Task 6: FSE weights encoder + caller + interop tests
   │        └── Task 7: edge cases, maxSym 128 identity, ratio floors
   │
   └── Z2 (after Task 5: streaming_zstd_encoder calls the block encoder)
         Task 8: buffered StreamingZstdEncoder + CHANGELOG
```

The identity harness (Task 1) must capture baseline output **before** any
code change, because T1 is verified against it and Z1/Z2 change Zstd output
on purpose.

## Architecture decisions

- **Order T1, Z1, Z2.** T1 is verified by byte identity against the
  untouched parent. Doing it first means the baseline only has to be captured
  once and is not disturbed by intended Zstd output changes.
- **DEFLATE before Zstd inside T1.** The DEFLATE path is smaller (three
  source files plus one test) and settles the reusable-buffer pattern
  (owner-held typed buffer, `count` returned, contents valid until the next
  call) before the larger Zstd change.
- **Split each T1 path in two.** Task 2 and Task 4 each leave the old types
  in place at one end of the pipeline, so every task leaves the tree green
  and identity-checkable. A single "convert everything" task would touch 6+
  files with no intermediate check.
- **Z1 is one vertical slice plus a hardening task**, not "encoder then
  caller": the weights encoder cannot be tested end to end until the
  `maxSym > 128` guard is removed, and the in-repo decoder entry point
  (`_decodeFseCompressedHuffmanWeights`) is private, so tests go through the
  codec.
- **Reuse `FseCompressionTable`** for the two weight states. Its
  `begin`/`encode`/`finish` are per-state and carry no stream state, so two
  states can share one table. This is the main Z1 risk; Task 6 checks it with
  both decoders before anything else.
- **Identity check is a scratchpad script, not a committed test.** A golden
  hash test would have to be rewritten by Z1 and by any later encoder work.
- **Tests live in the existing per-codec files**: `deflate_codec_test.dart`,
  `gzip_codec_test.dart`, `zstd_codec_test.dart`.

## Task list

### Phase 0: baselines
- [x] Task 1: identity harness and baselines

### Phase 1: T1 DEFLATE
- [x] Task 2: DEFLATE length/distance codes as int lookups
- [x] Task 3: DEFLATE packed tokens

### Checkpoint A: DEFLATE allocation work
- [x] Identity holds for GZIP/DEFLATE, full test suite and web matrix pass
- [x] User reviews and commits

### Phase 2: T1 Zstd
- [x] Task 4: typed sequence buffers in `MatchFinder`
- [x] Task 5: compute sequence symbols once, remove token classes

### Checkpoint B: T1 complete
- [x] Identity holds for the whole matrix, JIT benchmark recorded
- [x] User reviews and commits

### Phase 3: Z1
- [x] Task 6: FSE-compressed Huffman weights
- [x] Task 7: Z1 edge cases and ratio floors

### Checkpoint C: Z1 complete
- [x] Interop with `zstd -d`, web matrix passes
- [x] User reviews and commits

### Phase 4: Z2
- [x] Task 8: buffer small chunks in `StreamingZstdEncoder`

### Checkpoint D: complete
- [x] Every SPEC.md success criterion met
- [ ] User reviews and commits

## Risks and mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Z1 two-state order or final-state order wrong: decoder reads the wrong number of weights | High (corrupt frames) | Task 6 starts with a round trip through both the in-repo decoder and `zstd -d` over many random weight sets before wiring into the block encoder; `validate: true` in tests |
| Reused token buffer read past `count` (stale entries from a larger earlier block) | High (silent wrong output) | Identity matrix includes multi-block inputs with shrinking token counts; dedicated reuse test in Tasks 3 and 4 |
| Packed integers lose precision or sign on dart2js | Medium | Packing stays below `2^25`; web matrix test run at each checkpoint |
| T1 is slower, not faster (for example typed-list bounds checks in tight loops) | Medium | JIT benchmark (two runs per side) before and after at Checkpoint B; if a row regresses beyond noise, report it and stop for a decision |
| Z2 latency change surprises streaming users | Low | CHANGELOG entry; behavior matches LZ4 and DEFLATE streaming |
| FSE weights header over 127 bytes on real data | Low (falls back to raw, as today) | Task 7 measures how often it happens on the corpus |

## Decisions (answered 2026-11-11)

1. **Release 2.2.0.** `pubspec.yaml` goes to `2.2.0` with a `## 2.2.0`
   CHANGELOG section. T1, Z1 and Z2 each get an entry (SPEC.md section 9),
   written in the task that makes the change.
2. **Web test run** is `test/web_runtime_codec_matrix_test.dart`; SPEC.md
   updated to match.
3. **Benchmarks use JIT** (`dart run benchmark/codec_benchmark.dart <filter>`).
   Each side runs twice and the better figure per row is kept.
