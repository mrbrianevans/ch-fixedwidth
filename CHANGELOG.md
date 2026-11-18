# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Remote `.dat` GET retries on 429, 5xx, and connection failures (connect / send / headers) with exponential backoff (5 attempts, 200 ms base, 10 s cap). Integer `Retry-After` is honoured, capped at 60 s. 4xx other than 429, and a failed body stream, are not retried.
- Daily CH bulk smoke workflow (08:00 UTC): latest prod192 / prod197 / prod198 plus one prod216 shard streamed from Companies Catalogue; `workflow_dispatch` can convert every 216 shard.

### Changed

- Multi-threaded officers conversion of a local file writes rows straight to the final CSVs in input order instead of writing per-worker part files and concatenating them afterwards (no `.zig_parts` directory). A reader thread cuts the input into ~1 MiB chunks that end before a record start; workers format chunks; the main thread writes them in order. Output is byte-identical. On real Prod 216 files (4 workers): `Prod216_4342_ew_7.dat` 1.70 s → 1.24 s and `Prod216_4342_ew_1.dat` 4.16 s → 2.11 s (median). Peak RSS stays bounded (about 17 MiB at 4 workers, 80 MiB at 32). Parse errors on this path now print `Error parsing input: … at byte offset N` instead of `Error in worker K: …`.
- Officers snapshot company and person rows format about 2× faster on one thread. Rows that are ASCII and need no CSV quoting (the vast majority) copy fixed-width fields directly and turn `<` separators into `,` in one vectorised pass; other rows use the existing path, with byte-identical output. On real Prod 216 files: `--workers 1` and stdin 4.8 s → 2.4 s (`Prod216_4342_ew_7.dat`, 1.49 GB) and 8.3 s → 3.4 s (`Prod216_4342_ew_1.dat`, 2.05 GB); default parallel 1.7 s → 1.0 s and 3.0 s → 1.8 s.
- Remote `.dat` downloads ask for `zstd, gzip, deflate` (plus identity) and decompress while streaming. Companies Catalogue serves zstd, which is about 5.5x fewer bytes than the uncompressed file: `Prod216_4342_ew_7.dat` (1.49 GB) now downloads and converts in about 30 s instead of over 2 minutes. A zstd frame whose window is larger than 8 MiB fails with a named decompression error.
- **Breaking:** CLI is `ch-fixedwidth [--workers N] -o DIR <input>`. `-o` is required (the current directory is not used as a default). Flags must precede the positional input. Optional `--workers N` sets officers seek-split thread count (default: `min(CPU count, 32)`; ignored for 192 / 197).
- Usage errors (no args, extra args, unknown flag, missing `-o`) exit **2**. `-h` / `-V` stay **0**. Conversion failures stay **1**. Ctrl-C exits **130**.

### Fixed

- `sliceChars` no longer reads past the end of a row that ends inside a multi-byte UTF-8 character (debug builds panicked; release builds read out of bounds).
- Officers snapshot / update records that Companies House published with a line break (CRLF or bare LF) inside their variable-length data no longer fail with `UnknownRecord` (e.g. `Prod216_4342_ew_3.dat`, `Prod216_4342_ew_7.dat`). A company or person line shorter than its declared length is joined with the following non-record line(s) until the declared length is reached. The embedded break becomes a single space, so each CSV row stays on one line. Both the streaming path and the parallel seek-split path re-join records; split points never start a worker inside a joined record.
- `UnknownRecord` errors now say where the bad line is: `line N` on the streaming path, `byte offset N` on the parallel path, plus the first 40 bytes of the line.
- Streaming input (remote URL, stdin, local `--workers 1`, and 192 / 197) no longer grows memory with the whole file. CSV batches were allocated on the process-long arena, so draining a batch never released it. The stream now uses a freeing heap allocator, feeds 1 MiB slices straight from the reader buffer, and drains after each slice. Peak RSS stays flat (about 26 MiB for a 200 MiB or 800 MiB officers snapshot over HTTP, down from 326 MiB at 200 MiB).
- Directory input gives each file its own scratch arena, freed before the next file starts. Read and write buffers no longer accumulate across files (6 × 48 MiB files: 586 MiB → 21 MiB at `--workers 1`).
- Native read and write buffers are now 1 MiB, down from 8 MiB. Seek-split officers conversion allocated one read and two write buffers per worker, so peak RSS scaled with core count (about 575 MiB at 32 workers). It is now about 100 MiB at 32 workers and 14 MiB at 4. Single-stream runs peak at about 12.5 MiB. Benchmarks showed no throughput loss.

## [0.2.0] — 2026-08-22

Last breaking 0.x cut on the path to a freezeable 1.0 ([issue #8](https://github.com/mrbrianevans/ch-fixedwidth/issues/8)).

### Added

- CLI `--help` / `-h` and `--version` / `-V` from `libraryInfo()` (semver + git SHA)
- Kind-indexed `ChParseResult` / `ChStreamStats` (`CH_MAX_OUTPUT_KINDS` = 16) so a later product can add a CSV kind without growing the struct
- `warning_count` and `last_warning` on parse results and stream stats; CLI prints each warning to stderr
- Fail-closed unknown officers/disqualification type bytes and extra data after a trailer
- Prod 197 unknown tags: warn (tag + form + company) and continue; field overflow fails
- UTF-8 character-offset goldens; wasm-ts tests for products 192 and 198
- `docs/stability.md`, `CONTRIBUTING.md`

### Changed

- **Breaking:** CLI binary and release assets renamed `parser` → `ch-fixedwidth`
- **Breaking:** C/WASM/TS one-shot result and stream stats are kind-indexed arrays, not eight named fields
- Prod 198 person schema is documented as distinct from snapshot 195/216; non-empty trailing chevron fillers fail the parse
- Adding a product in 1.x is an additive minor (append a kind id); renumbering kinds or changing existing CSV columns is a major

### Notes

- `@ch-fixedwidth/wasm-ts` remains private; publish later against this ABI
- Prod 197 is tag-driven, not a complete V4.6d sequence parser
- Exit 0 on 197 still allows unknown-tag warnings

## [0.1.0] — 2026-08-01

Multi-product release of **ch-fixedwidth**. Breaking C/WASM/TypeScript API cleanup so output kinds are never overloaded across products.

### Added

- `libraryInfo()` / `ch_library_info`: semver, build-time short git SHA, and supported-format catalogue (product codes, header magic, short description) across Zig, C ABI, WASM, and TypeScript; web footer reads version + commit from WASM
- `supportedFormats()` / `ch_supported_formats` catalogue: product code(s), header identifier, and short description for each implemented format (Zig, C ABI, WASM/TypeScript)
- Header-based product dispatch: the first 8-byte header identifier selects the body parser
- **Product 198** (`DDDDUPDT`) officers update parser
- **Product 192** (`DISQUALS`) disqualified persons parser (four named CSVs)
- **Product 197** (`LIQNFORM`) liquidation daily-update parser (`forms` / `practitioners` / `free_text`)
- Shared `OutputKind` / `CH_OUTPUT_*` model across Zig, C ABI, WASM, and TypeScript
- `FileType.outputKinds()` and TS `outputKindsForFileType` / `outputFileName` helpers
- Stream stats report all kind counts plus `file_type` (`ch_stream_stats` → `ChStreamStats`)
- Browser converter multi-product writes and converter-oriented design language
- Integration test: parallel officers path and sequential stream path byte-compare on the mini snapshot fixture
- `.gitignore` entry for local `Prod*.txt` bulk dumps
- C/TS error codes `CH_ERR_ROW_TOO_LARGE` (9) and `CH_ERR_RECORD_LIMIT` (10)

### Changed

- **Breaking:** `ch_parse_snapshot` renamed to `ch_parse`
- **Breaking:** `ChParseResult` layout: counts first, dedicated buffers for forms / practitioners / free_text (no mapping free text into disqualifications)
- **Breaking:** `ch_stream_stats` takes a single `ChStreamStats *` instead of three int pointers
- **Breaking:** Liquidation batches use kinds 5–7 (`forms`, `practitioners`, `free_text`) instead of reusing companies/persons/disqualifications
- Zig `snapshot` module → `document` (`parseDocument`); CLI `processLocalFile`
- Design system reframed as converter language (not “Digital Archive”)
- Docs and README describe full multi-product CLI/WASM/web behaviour

### Fixed

- CSV formatters never write past the destination buffer (`error.RowTooLarge` / `CH_ERR_ROW_TOO_LARGE`)
- Prod 197 form groups fail hard when practitioner or free-text caps are exceeded (`error.RecordLimitExceeded` / `CH_ERR_RECORD_LIMIT`) instead of dropping rows
- TypeScript `csvBatchKindFromCode` throws on unknown kind codes (no silent fallback to companies)

### Removed

- Legacy snapshot-only helpers `requireSnapshotHeader` / `startsWithSnapshotHeader` (use `identifyFileType` / `parseHeader`)

### Notes

- Package versions: `0.1.0` (`@ch-fixedwidth/wasm-ts`, web)
- Prefer native CLI or streaming C/WASM API for multi-hundred-MB and larger files
- `FileType.isImplemented` remains for future recognised-but-unsupported magics

## [0.0.2] — 2026-08-01

### Added

- Native CLI accepts HTTP(S) URLs as the input argument and streams the response body through the same conversion pipeline as a local file (same CSV basenames and contents)
- Native CLI accepts `-` as the input argument to stream a snapshot from stdin (`companies_data_stdin.csv` / `persons_data_stdin.csv`)
- Native CLI accepts a **directory** of `.dat` files: each snapshot yields its own company and person CSVs; files are processed one at a time with within-file multi-threading (see [docs/DDR-directory-parallelism.md](docs/DDR-directory-parallelism.md))

## [0.0.1] — 2026-07-21

Initial production-oriented release of the Zig Companies House fixed-width parser.

### Added

- MIT license
- Zig library modules: pure `parse`, full-buffer `snapshot`, chunked `stream`, multithreaded CLI `file_convert`
- C ABI (`include/ch_fixedwidth.h`):
  - One-shot `ch_parse_snapshot`
  - Streaming `ch_stream_create` / `feed` / `finish` / `next_batch` (batched CSV output)
- Freestanding WASM build (`zig build wasm`) exporting the same C surface
- TypeScript host package `@ch-fixedwidth/wasm-ts` (private / not published yet)
- CI: Zig format/build/test on Linux, Windows, macOS; wasm-ts unit tests + local CLI smoke
- Release workflow: multi-arch native CLI binaries + freestanding WASM artifact
- Format documentation for products 195/216 (snapshot) and 198 (update — not implemented in 0.0.1)
- Small embedded fixtures and unit tests for parse, snapshot, C ABI, and streaming

### Notes

- Supported input in 0.0.1: snapshot products **195 / 216** (`DDDDSNAP` header) only

[0.1.0]: https://github.com/mrbrianevans/ch-fixedwidth/releases/tag/v0.1.0
[0.0.2]: https://github.com/mrbrianevans/ch-fixedwidth/releases/tag/v0.0.2
[0.0.1]: https://github.com/mrbrianevans/ch-fixedwidth/releases/tag/v0.0.1
