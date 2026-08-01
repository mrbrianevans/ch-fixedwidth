# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Native CLI accepts HTTP(S) URLs as the input argument and streams the response body through the same conversion pipeline as a local file (same CSV basenames and contents)
- Native CLI accepts `-` as the input argument to stream a snapshot from stdin (`companies_data_stdin.csv` / `persons_data_stdin.csv`)

## [0.0.1] — 2026-07-21

Initial production-oriented release of the Zig Companies House fixed-width parser.

### Added

- MIT license
- Zig library modules: pure `parse`, full-buffer `snapshot`, chunked `stream`, multithreaded CLI `file_convert`
- C ABI (`include/ch_fixedwidth.h`):
  - One-shot `ch_parse_snapshot`
  - Streaming `ch_stream_create` / `feed` / `finish` / `next_batch` (batched CSV output)
- Freestanding WASM build (`zig build wasm`) exporting the same C surface
- TypeScript host package `@ch-fixedwidth/wasm-ts` (private / not published yet):
  - `ChFixedWidthParser` (one-shot)
  - `ChFixedWidthStream` (chunked input, batched CSV)
  - Runtime-agnostic load via `wasmBytes` / `wasmUrl` / `module`
  - Local Bun CLI under `wasm-ts/local/` for monorepo runs and CI
- CI: Zig format/build/test on Linux, Windows, macOS; wasm-ts unit tests + local CLI smoke
- Release workflow: multi-arch native CLI binaries + freestanding WASM artifact
- Format documentation for products 195/216 (snapshot) and 198 (update — **not implemented yet**)
- Small embedded fixtures and unit tests for parse, snapshot, C ABI, and streaming

### Notes

- Supported input: snapshot products **195 / 216** (`DDDSNAP` header) only
- Prefer the native CLI or the streaming C/WASM API for multi-hundred-MB and larger files
- Product **198** (`DDDDUPDT`) remains a documented future format

[0.0.1]: https://github.com/mrbrianevans/ch-fixedwidth/releases/tag/v0.0.1
