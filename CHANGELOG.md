# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Remote `.dat` GET retries on 429, 5xx, and connection failures (connect / send / headers) with exponential backoff (5 attempts, 200 ms base, 10 s cap). Integer `Retry-After` is honoured, capped at 60 s. 4xx other than 429, and a failed body stream, are not retried.
- Daily CH bulk smoke workflow (08:00 UTC): latest prod192 / prod197 / prod198 plus one prod216 shard streamed from Companies Catalogue; `workflow_dispatch` can convert every 216 shard.

### Changed

- **Breaking:** CLI is `ch-fixedwidth [--workers N] -o DIR <input>`. `-o` is required (the current directory is not used as a default). Flags must precede the positional input. Optional `--workers N` sets officers seek-split thread count (default: `min(CPU count, 32)`; ignored for 192 / 197).
- Usage errors (no args, extra args, unknown flag, missing `-o`) exit **2**. `-h` / `-V` stay **0**. Conversion failures stay **1**. Ctrl-C exits **130**.

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
