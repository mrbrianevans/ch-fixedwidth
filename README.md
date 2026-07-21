# Companies House fixed-width parser

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

High-performance Zig parser for Companies House bulk appointment data (products 195 / 216). Converts snapshot files from the proprietary fixed-width + chevron format into CSV.

**Version:** 0.0.1

Native builds use **multithreading**: the input is split on line boundaries and worker threads write part CSVs that are concatenated.

**Measured throughput** (PowerShell `Stopwatch` wall clock, not self-reported): `Prod216_4257_ew_6.dat` — 6 182 956 records in ~1.24 s → **~5.0 million records/second** (`zig build -Doptimize=ReleaseFast`, post-refactor CLI). Absolute numbers vary with disk and CPU.

## File format (overview)

Plain-text snapshot files with:

| Record | Identifier / type | Role |
|--------|-------------------|------|
| Header | `DDDDSNAP` | Run number and production date |
| Company | type `1` at column 9 | Fixed fields + variable-length company name |
| Person  | type `2` at column 9 | Fixed fields + chevron-separated (`<`) variable fields |
| Trailer | `99999999` | Record count (excludes header/trailer) |

Field positions are Unicode character offsets. Most rows are ASCII (fast path); multi-byte UTF-8 uses a character walk so boundaries match the historical reference parsers.

Full field layouts: [docs/Prod195_Snapshot.md](docs/Prod195_Snapshot.md).

## Output format

One input file produces two CSVs in the output directory:

- `companies_data_<basename>.csv`
- `persons_data_<basename>.csv`

Company columns: Company Number, Company Status, Number of Officers, Company Name.

Person columns: Company Number, App Date Origin, Appointment Type, Person number, Corporate indicator, Appointment Date, Resignation Date, Person Postcode, Partial Date of Birth, Full Date of Birth, Title, Forenames, Surname, Honours, Care_of, PO_box, Address line 1, Address line 2, Post_town, County, Country, Occupation, Nationality, Resident Country.

## Build and run

Requires [Zig](https://ziglang.org/) 0.16+.

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/parser <input.dat> <output_folder>
```

| Argument | Description |
|----------|-------------|
| `input.dat` | Path to a single snapshot file |
| `output_folder` | Directory for CSV output (created if missing) |

Example:

```bash
./zig-out/bin/parser Prod216_4257_ew_6.dat ./output
```

Exit code `0` on success (trailer count matches rows written); non-zero on header/trailer mismatch or I/O errors.

```bash
zig build test              # unit tests
zig build wasm -Doptimize=ReleaseFast   # freestanding WASM (parse API only)
```

## Library API

Parsing is separate from CLI I/O so the same logic can be embedded:

| Surface | Location | Role |
|---------|----------|------|
| Zig module | `src/parse.zig`, `src/snapshot.zig` | Pure format + in-memory conversion |
| C ABI | `include/ch_fixedwidth.h`, `libch_fixedwidth` | `ch_parse_snapshot` for native FFI |
| WASM | `zig build wasm` → `ch_fixedwidth.wasm` | Same C-style exports, no filesystem I/O |
| TypeScript host | [`wasm-ts/`](wasm-ts/) | Bun/TS wrapper with typed `ParseResult` over the WASM module |
| CLI | `src/main.zig` + `src/file_convert.zig` | Multithreaded file conversion |

```bash
zig build wasm -Doptimize=ReleaseFast
cd wasm-ts && bun test && bun run cli.ts ../src/testdata/mini_snapshot.dat ./out
```

## Development

```bash
zig build                   # debug CLI + libs
zig build test
zig fmt --check .
```

## Alternative implementations

Older Go, Python, and TypeScript parsers (and multi-language benchmarks) live under [`reference/`](reference/) for comparison only. The Zig implementation is the maintained product path.
