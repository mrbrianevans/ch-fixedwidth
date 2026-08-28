# Development and embedding

Notes for contributors and embedders. End-user install and CLI usage live in the [root README](../README.md).

## Product identity

Canonical name: **ch-fixedwidth**. Library / C / WASM symbol prefix: `ch_fixedwidth` / `ch_*`. TypeScript package: `@ch-fixedwidth/wasm-ts`.

## Performance

Native builds use **multithreading** for officers products: the input is split on line boundaries and worker threads write part CSVs that are concatenated. Products with multi-CSV or form-group state (192 / 197) always use the sequential stream path.

**Measured throughput** (PowerShell `Stopwatch` wall clock): `Prod216_4257_ew_6.dat` — 6 182 956 records in ~1.24 s → **~5.0 million records/second** (`zig build -Doptimize=ReleaseFast`). Absolute numbers vary with disk and CPU.

## Build commands

Requires [Zig](https://ziglang.org/) 0.16+.

```bash
zig build -Doptimize=ReleaseFast          # release CLI + libs
zig build                                 # debug CLI + libs
zig build test                            # unit tests
zig build wasm -Doptimize=ReleaseFast     # freestanding WASM
zig fmt --check .
```

CLI binary: `./zig-out/bin/ch-fixedwidth` (or `ch-fixedwidth.exe` on Windows).

Invocation: `ch-fixedwidth [-workers N] -o DIR <input>`. `-o` is required. Optional `-workers N` caps officers seek-split threads (default: CPU count, max 32). Stdin and remote URLs stay sequential.

### Remote URL, stdin, and directory input (CLI only)

The native CLI accepts a local file path, a **directory** of `.dat` files, an `http://` / `https://` URL, or `-` (stdin). Path kind is confirmed with a filesystem `stat` (heuristics: `.dat` → file; trailing `/` or no `.dat` extension → likely directory).

| Input | Pipeline |
|-------|----------|
| Single local file | Multi-threaded seek split for officers products (`-workers N` or CPU count); sequential for 192 / 197 |
| Directory of `.dat` | Lists top-level `*.dat` only; processes **one file at a time** with the same per-file strategy as a single file. See [DDR-directory-parallelism.md](DDR-directory-parallelism.md) |
| Remote URL / stdin | Sequential streaming via `processFromReader` (no parallel seeks) |

WASM and the C ABI are unchanged (no network or directory fan-out).

### Bulk verification (local)

Full Companies House extracts are gitignored (`Prod*.dat` / `Prod*.txt`). For a release gate, convert a local copy of each product and confirm trailer match plus zero unexpected warnings:

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/ch-fixedwidth -o ./output/bulk path/to/Prod216_….dat
./zig-out/bin/ch-fixedwidth -o ./output/bulk path/to/Prod198_….dat
./zig-out/bin/ch-fixedwidth -o ./output/bulk path/to/Prod192_….dat
./zig-out/bin/ch-fixedwidth -o ./output/bulk path/to/Prod197_….dat
```

Prod 198 trailing chevron fillers were proven empty on `Prod198_4271` (12 239 person rows). Re-run that check if the published person schema is questioned.

Smoke tests:

```bash
# Remote URL — serve fixtures and point the CLI at localhost (Bun)
bun scripts/serve-testdata.ts
# other terminal
zig build -Doptimize=ReleaseFast
./zig-out/bin/ch-fixedwidth -o ./output/remote_test http://127.0.0.1:8765/mini_snapshot.dat

# Stdin stream
./zig-out/bin/ch-fixedwidth -o ./output/stdin_test - < src/testdata/mini_snapshot.dat

# Directory of files (each .dat → product-specific CSVs)
mkdir -p ./output/dir_in
cp src/testdata/mini_snapshot.dat ./output/dir_in/a.dat
cp src/testdata/mini_snapshot.dat ./output/dir_in/b.dat
./zig-out/bin/ch-fixedwidth -o ./output/dir_out ./output/dir_in
```

## Library API

Parsing is separate from CLI I/O so the same logic can be embedded:

| Surface | Location | Role |
|---------|----------|------|
| Zig module | `src/parse.zig`, `src/document.zig`, `src/stream.zig` | Pure format, full-buffer, and chunked streaming conversion |
| C ABI | `include/ch_fixedwidth.h`, `libch_fixedwidth` | `ch_parse` (one-shot) + `ch_stream_*` (batched streaming by `CH_OUTPUT_*`) |
| WASM | `zig build wasm` → `ch_fixedwidth.wasm` | Same C-style exports, no filesystem I/O |
| TypeScript host | [`wasm-ts/`](../wasm-ts/) | `ChFixedWidthStream` + `ChFixedWidthParser`; Bun CLI under `wasm-ts/local/` |
| CLI | `src/main.zig` + `src/file_convert.zig` | Multithreaded local officers files; sequential multi-CSV products; directory / HTTP(S) / stdin |

### Output kinds (never overloaded)

Products emit a subset of `OutputKind` / `CH_OUTPUT_*`:

| Kind | Filename stem | Typical products |
|------|---------------|------------------|
| `companies` | `companies_data` | Officers 195/216/198 |
| `persons` | `persons_data` | Officers; disqual type 1 |
| `disqualifications` | `disqualifications_data` | Prod 192 type 2 |
| `exemptions` | `exemptions_data` | Prod 192 type 3 |
| `variations` | `variations_data` | Prod 192 type 4 |
| `forms` | `forms_data` | Prod 197 |
| `practitioners` | `practitioners_data` | Prod 197 |
| `free_text` | `free_text_data` | Prod 197 |

`FileType.outputKinds()` / `outputKindsForFileType()` list the stable set per product.

### Large files (WASM / C)

Prefer the **streaming** API: feed input in chunks (e.g. 1 MiB) and pull CSV **batches** (default ~1000 rows or 256 KiB per kind). That keeps peak memory near O(chunk + batch) instead of O(file). One-shot `ch_parse` / `ChFixedWidthParser.parse` still suit small fixtures and moderate documents.

```bash
zig build wasm -Doptimize=ReleaseFast
cd wasm-ts && bun install && bun test && bun run local ../src/testdata/mini_snapshot.dat ./out
```

See also [`wasm-ts/README.md`](../wasm-ts/README.md).

## Supported products

The parser reads the first 8 bytes of the header record and selects a body
parser from that magic (`parse.identifyFileType` → product-specific path).

| Product | Header | Status |
|---------|--------|--------|
| 195 / 216 (appointments snapshot) | `DDDDSNAP` | Implemented — companies + persons CSVs |
| 198 (appointments update) | `DDDDUPDT` | Implemented — companies + persons CSVs — [Prod198_Update.md](Prod198_Update.md) |
| 192 (disqualified persons) | `DISQUALS` | Implemented — persons, disqualifications, exemptions, variations CSVs — [Prod192_Disqualifications.md](Prod192_Disqualifications.md) |
| 197 (liquidation daily updates) | `LIQNFORM` | Implemented — forms + practitioners + free text CSVs — [Prod197_Liquidation.md](Prod197_Liquidation.md) |

Unknown magics return `UnsupportedFileType` / `CH_ERR_UNSUPPORTED_HEADER`. Known but not-yet-implemented magics (future) use `CH_ERR_NOT_IMPLEMENTED` via `FileType.isImplemented`.

## Adding a new product

To support another fixed-width bulk file type (new header magic, record layouts, and CSV outputs), follow the step-by-step guide:

**[adding-a-product.md](adding-a-product.md)** — required format knowledge, design choices (output kinds, sequential vs parallel), file-by-file checklist (parse → document → stream → CLI → C/WASM → TypeScript → docs), and testing expectations.

## Format reference

- Snapshot field layouts: [Prod195_Snapshot.md](Prod195_Snapshot.md)
- Update field layouts: [Prod198_Update.md](Prod198_Update.md)
- Disqualification field layouts: [Prod192_Disqualifications.md](Prod192_Disqualifications.md)
- Liquidation form-group layouts: [Prod197_Liquidation.md](Prod197_Liquidation.md)
- Field positions are Unicode character offsets. Most rows are ASCII (fast path); multi-byte UTF-8 uses a character walk so boundaries match the historical reference parsers.

## Alternative implementations

Older Go, Python, and TypeScript parsers (and multi-language benchmarks) live under [`reference/`](../reference/) for comparison only. The Zig implementation is the maintained product path.
