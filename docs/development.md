# Development and embedding

Notes for contributors and embedders. End-user install and CLI usage live in the [root README](../README.md).

## Performance

Native builds use **multithreading**: the input is split on line boundaries and worker threads write part CSVs that are concatenated.

**Measured throughput** (PowerShell `Stopwatch` wall clock): `Prod216_4257_ew_6.dat` — 6 182 956 records in ~1.24 s → **~5.0 million records/second** (`zig build -Doptimize=ReleaseFast`). Absolute numbers vary with disk and CPU.

## Build commands

Requires [Zig](https://ziglang.org/) 0.16+.

```bash
zig build -Doptimize=ReleaseFast          # release CLI + libs
zig build                                 # debug CLI + libs
zig build test                            # unit tests
zig build wasm -Doptimize=ReleaseFast     # freestanding WASM (parse API only)
zig fmt --check .
```

CLI binary: `./zig-out/bin/parser` (or `parser.exe` on Windows).

### Remote URL, stdin, and directory input (CLI only)

The native CLI accepts a local file path, a **directory** of `.dat` files, an `http://` / `https://` URL, or `-` (stdin). Path kind is confirmed with a filesystem `stat` (heuristics: `.dat` → file; trailing `/` or no `.dat` extension → likely directory).

| Input | Pipeline |
|-------|----------|
| Single local file | Multi-threaded seek split when multiple CPUs are available; otherwise sequential stream |
| Directory of `.dat` | Lists top-level `*.dat` only; processes **one file at a time** with the same within-file multi-threading as a single file (option B). See [DDR-directory-parallelism.md](DDR-directory-parallelism.md) |
| Remote URL / stdin | Sequential streaming via `processFromReader` (no parallel seeks) |

WASM and the C ABI are unchanged (no network or directory fan-out).

Smoke tests:

```bash
# Remote URL — serve fixtures and point the CLI at localhost (Bun)
bun scripts/serve-testdata.ts
# other terminal
zig build -Doptimize=ReleaseFast
./zig-out/bin/parser http://127.0.0.1:8765/mini_snapshot.dat ./output/remote_test

# Stdin stream
./zig-out/bin/parser - ./output/stdin_test < src/testdata/mini_snapshot.dat

# Directory of snapshots (each .dat → companies + persons CSVs)
mkdir -p ./output/dir_in
cp src/testdata/mini_snapshot.dat ./output/dir_in/a.dat
cp src/testdata/mini_snapshot.dat ./output/dir_in/b.dat
./zig-out/bin/parser ./output/dir_in ./output/dir_out
```

## Library API

Parsing is separate from CLI I/O so the same logic can be embedded:

| Surface | Location | Role |
|---------|----------|------|
| Zig module | `src/parse.zig`, `src/snapshot.zig`, `src/stream.zig` | Pure format, full-buffer, and chunked streaming conversion |
| C ABI | `include/ch_fixedwidth.h`, `libch_fixedwidth` | `ch_parse_snapshot` (one-shot) + `ch_stream_*` (batched streaming) |
| WASM | `zig build wasm` → `ch_fixedwidth.wasm` | Same C-style exports, no filesystem I/O |
| TypeScript host | [`wasm-ts/`](../wasm-ts/) | Publish-ready package: `ChFixedWidthStream` + `ChFixedWidthParser`; Bun CLI under `wasm-ts/local/` |
| CLI | `src/main.zig` + `src/file_convert.zig` | Multithreaded local files; directory of `.dat` (sequential files, within-file MT); streaming HTTP(S) URL or stdin (`-`) |

### Large files (WASM / C)

Prefer the **streaming** API: feed input in chunks (e.g. 1 MiB) and pull CSV **batches** (default ~1000 rows or 256 KiB per kind). That keeps peak memory near O(chunk + batch) instead of O(file). One-shot `ch_parse_snapshot` / `ChFixedWidthParser.parse` still suit small fixtures and moderate documents.

```bash
zig build wasm -Doptimize=ReleaseFast
cd wasm-ts && bun install && bun test && bun run local ../src/testdata/mini_snapshot.dat ./out
```

See also [`wasm-ts/README.md`](../wasm-ts/README.md).

## Supported products

| Product | Header | Status |
|---------|--------|--------|
| 195 / 216 (snapshot) | `DDDDSNAP` | Implemented |
| 198 (update) | `DDDDUPDT` | Documented only — [Prod198_Update.md](Prod198_Update.md) |

## Format reference

- Snapshot field layouts: [Prod195_Snapshot.md](Prod195_Snapshot.md)
- Field positions are Unicode character offsets. Most rows are ASCII (fast path); multi-byte UTF-8 uses a character walk so boundaries match the historical reference parsers.

## Alternative implementations

Older Go, Python, and TypeScript parsers (and multi-language benchmarks) live under [`reference/`](../reference/) for comparison only. The Zig implementation is the maintained product path.
