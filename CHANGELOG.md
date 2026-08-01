# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- CSV formatters never write past the destination buffer (`error.RowTooLarge` / `CH_ERR_ROW_TOO_LARGE`)
- Prod 197 form groups fail hard when practitioner or free-text caps are exceeded (`error.RecordLimitExceeded` / `CH_ERR_RECORD_LIMIT`) instead of dropping rows
- TypeScript `csvBatchKindFromCode` throws on unknown kind codes (no silent fallback to companies)

### Removed

- Legacy snapshot-only helpers `requireSnapshotHeader` / `startsWithSnapshotHeader` (use `identifyFileType` / `parseHeader`)

### Added

- Integration test: parallel officers path and sequential stream path byte-compare on the mini snapshot fixture
- `.gitignore` entry for local `Prod*.txt` bulk dumps

## [0.1.0] — 2026-08-01

Multi-product release of **ch-fixedwidth**. Breaking C/WASM/TypeScript API cleanup so output kinds are never overloaded across products.

### Added

- Header-based product dispatch: the first 8-byte header identifier selects the body parser
- **Product 198** (`DDDDUPDT`) officers update parser
- **Product 192** (`DISQUALS`) disqualified persons parser (four named CSVs)
- **Product 197** (`LIQNFORM`) liquidation daily-update parser (`forms` / `practitioners` / `free_text`)
- Shared `OutputKind` / `CH_OUTPUT_*` model across Zig, C ABI, WASM, and TypeScript
- `FileType.outputKinds()` and TS `outputKindsForFileType` / `outputFileName` helpers
- Stream stats report all kind counts plus `file_type` (`ch_stream_stats` → `ChStreamStats`)
- Browser converter multi-product writes and converter-oriented design language

### Changed

- **Breaking:** `ch_parse_snapshot` renamed to `ch_parse`
- **Breaking:** `ChParseResult` layout: counts first, dedicated buffers for forms / practitioners / free_text (no mapping free text into disqualifications)
- **Breaking:** `ch_stream_stats` takes a single `ChStreamStats *` instead of three int pointers
- **Breaking:** Liquidation batches use kinds 5–7 (`forms`, `practitioners`, `free_text`) instead of reusing companies/persons/disqualifications
- Zig `snapshot` module → `document` (`parseDocument`); CLI `processLocalFile`
- Design system reframed as converter language (not “Digital Archive”)
- Docs and README describe full multi-product CLI/WASM/web behaviour

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
