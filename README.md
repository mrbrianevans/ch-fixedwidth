# Companies House fixed-width parser

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

High-performance parser for [Companies House](https://www.gov.uk/government/organisations/companies-house) bulk appointment data (products **195** / **216**). Converts proprietary fixed-width + chevron snapshot files into CSV.

It is designed for speed and can exceed **5 million records per second** on modern laptops.

## Source format

Plain-text snapshot files (`DDDDSNAP` header) containing company and officer (person) records in a fixed-width layout, with variable-length name and address fields separated by chevrons (`<`).

Full field layouts: [docs/Prod195_Snapshot.md](docs/Prod195_Snapshot.md).

## Available data

Each input file yields company rows and officer (person) rows.

**Companies** — company number, status, officer count, and company name.

**Officers** — company number; appointment type, dates, and origin; person number and corporate indicator; name parts (title, forenames, surname, honours); dates of birth; address fields; occupation, nationality, and country of residence.

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
| Input | Path to a single snapshot `.dat`, a **directory** of `.dat` files, an `http://` / `https://` URL of a hosted `.dat`, or `-` to read from **stdin** |
| `output_folder` | Directory for CSV output (created if missing) |

**Local path detection:** a path ending in `.dat` is treated as a file; a path ending in `/` (or with no `.dat` extension) is more likely a directory. The filesystem is always checked to confirm file vs directory before processing.

Examples:

```bash
./parser Prod216_4257_ew_6.dat ./output
./parser ./snapshots/ ./output
./parser https://example.com/data/Prod216_4257_ew_6.dat ./output
./parser - ./output < Prod216_4257_ew_6.dat
```

Remote URLs and stdin are converted in a **streaming pipeline** (bytes are parsed as they arrive; the full file is not buffered to disk first). Output CSV names and contents match a local-file run with the same basename (stdin uses basename `stdin`).

For a **directory** input, every top-level `.dat` file is converted (non-recursive). On multi-core systems, files are processed concurrently; single-threaded builds process one file at a time. Each input file still produces its own company and person CSVs in the shared output folder.

Exit code `0` on success (trailer record count matches rows written for every file); non-zero on header/trailer mismatch, HTTP errors, missing `.dat` files in a directory, or I/O errors.

## Output

Each input file produces two CSVs in the output directory:

- `companies_data_<basename>.csv`
- `persons_data_<basename>.csv`

So five `.dat` files in a directory yield ten CSV files (one company and one person file per input).

**Companies header:**

```
Company Number,Company Status,Number of Officers,Company Name
```

**Persons header:**

```
Company Number,App Date Origin,Appointment Type,Person number,Corporate indicator,Appointment Date,Resignation Date,Person Postcode,Partial Date of Birth,Full Date of Birth,Title,Forenames,Surname,Honours,Care_of,PO_box,Address line 1,Address line 2,Post_town,County,Country,Occupation,Nationality,Resident Country
```

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

For embedding (C ABI, streaming API, TypeScript host), see [docs/development.md](docs/development.md). Format notes for update product 198 (not yet implemented) are under [docs/](docs/).
