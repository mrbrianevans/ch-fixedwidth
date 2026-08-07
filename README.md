# ch-fixedwidth

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

High-performance multi-product parser for [Companies House](https://www.gov.uk/government/organisations/companies-house) bulk fixed-width data. Converts proprietary fixed-width + chevron files into **named CSV outputs per product**.

Supported products: appointments **195** / **216** / **198**, disqualified persons **192**, and liquidation daily updates **197**. Designed for speed — native builds can exceed **5 million records per second** on modern laptops.

## Source format

Plain-text `.dat` files identified by an 8-byte header magic. The parser dispatches on that magic; each product emits its own CSV set (kinds are never overloaded across products).

| Header | Product | Docs | CLI outputs |
|--------|---------|------|-------------|
| `DDDDSNAP` | Appointments snapshot (195 / 216) | [Prod195_Snapshot.md](docs/Prod195_Snapshot.md) | `companies_data_*`, `persons_data_*` |
| `DDDDUPDT` | Appointments update (198) | [Prod198_Update.md](docs/Prod198_Update.md) | `companies_data_*`, `persons_data_*` |
| `DISQUALS` | Disqualified persons (192) | [Prod192_Disqualifications.md](docs/Prod192_Disqualifications.md) | `persons_data_*`, `disqualifications_data_*`, `exemptions_data_*`, `variations_data_*` |
| `LIQNFORM` | Liquidation daily updates (197) | [Prod197_Liquidation.md](docs/Prod197_Liquidation.md) | `forms_data_*`, `practitioners_data_*`, `free_text_data_*` |

Company and officer (person) records use a fixed-width layout with variable-length name and address fields separated by chevrons (`<`). Update person rows include old/new appointment types, person numbers, postcodes, change/update dates, and the full named variable-field set. Disqualification files use record types 1–4 (person, disqualification, exemption, variation) and a multi-count trailer. Liquidation files group form tags into form / practitioner / free-text CSVs.

## Available data

**Officers snapshot / update (195 / 216 / 198)**

- **Companies** — company number, status, officer count, and company name.
- **Officers (snapshot)** — appointment type, dates, person number, name parts, DOB, address, occupation, nationality, residence.
- **Officers (update)** — old/new appointment fields, correction indicators, change/update dates, and the full named variable-field set.

**Disqualified persons (192)**

- **Persons**, **disqualifications**, **exemptions**, **variations** — separate CSVs; trailer validates per-type and total counts.

**Liquidation daily updates (197)**

- **Forms** (one row per form group), **practitioners** (`NP`), **free text** (`FT`); trailer validates total data-record count.

## Install

Download a pre-built binary for your platform from the [GitHub Releases](https://github.com/mrbrianevans/ch-fixedwidth/releases) page.

Assets are named like:

| Platform | Asset |
|----------|--------|
| Windows x86_64 | `parser-windows-x86_64.exe` |
| Linux x86_64 | `parser-linux-x86_64` |
| Linux ARM64 | `parser-linux-aarch64` |
| macOS Intel | `parser-macos-x86_64` |
| macOS Apple Silicon | `parser-macos-aarch64` |

Make the binary executable on Unix-like systems:

```bash
chmod +x parser-linux-x86_64
```

## Run

```bash
./parser <input.dat|input_dir/|http(s)://.../file.dat|-> <output_folder>
```

| Argument | Description |
|----------|-------------|
| Input | Path to a single `.dat`, a **directory** of `.dat` files, an `http://` / `https://` URL of a hosted `.dat`, or `-` to read from **stdin** |
| `output_folder` | Directory for CSV output (created if missing) |

**Local path detection:** a path ending in `.dat` is treated as a file; a path ending in `/` (or with no `.dat` extension) is more likely a directory. The filesystem is always checked to confirm file vs directory before processing.

Examples:

```bash
./parser Prod216_4257_ew_6.dat ./output
./parser ./bulk/ ./output
./parser https://example.com/data/Prod216_4257_ew_6.dat ./output
./parser - ./output < Prod216_4257_ew_6.dat
```

Remote URLs and stdin are converted in a **streaming pipeline** (bytes are parsed as they arrive; the full file is not buffered to disk first). Output CSV names and contents match a local-file run with the same basename (stdin uses basename `stdin`).

For a **directory** input, every top-level `.dat` file is converted (non-recursive), **one file at a time**. Officers products use within-file multi-threading on multi-core systems; multi-CSV products (192 / 197) run sequentially per file. Design rationale: [docs/DDR-directory-parallelism.md](docs/DDR-directory-parallelism.md).

Exit code `0` on success (trailer record count matches for every file); non-zero on header/trailer mismatch, HTTP errors, missing `.dat` files in a directory, or I/O errors.

## Output

Each input file produces the CSV set for its product (see table above). Filenames are `{kind}_data_<basename>.csv`.

Examples for basename `Prod216_4257_ew_6`:

- Officers: `companies_data_Prod216_4257_ew_6.csv`, `persons_data_Prod216_4257_ew_6.csv`
- Liquidation: `forms_data_…`, `practitioners_data_…`, `free_text_data_…`

Column headers differ by product; see the format docs under [docs/](docs/).

---

## Building from source

Requires [Zig](https://ziglang.org/) 0.16+.

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/parser <input.dat|input_dir/|http(s)://.../file.dat|-> <output_folder>
```

### Development

```bash
zig build                   # debug CLI + libs
zig build test              # unit tests
zig fmt --check .
```

### WASM

```bash
zig build wasm -Doptimize=ReleaseFast
```

Produces `zig-out/ch_fixedwidth.wasm` (also published on releases as `ch_fixedwidth-wasm32-freestanding.wasm`).

For embedding (C ABI, streaming API, TypeScript host), see [docs/development.md](docs/development.md). To add support for another bulk product, see [docs/adding-a-product.md](docs/adding-a-product.md).

### Browser converter

See [web/README.md](web/README.md). The static site converts the same multi-product set in-browser via WASM.
