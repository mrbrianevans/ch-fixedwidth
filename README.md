# ch-fixedwidth

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Converts [Companies House](https://www.gov.uk/government/organisations/companies-house) bulk fixed-width files into **named CSV outputs per product**.

Status: **0.2.x** (last breaking cut before a freezeable 1.0). See [issue #8](https://github.com/mrbrianevans/ch-fixedwidth/issues/8) and [docs/stability.md](docs/stability.md).

Browser converter: <https://mrbrianevans.github.io/ch-fixedwidth/>

## Supported products

Plain-text `.dat` files, identified by an 8-byte header magic.

| Header | Product | CLI outputs | Notes |
|--------|---------|-------------|-------|
| `DDDDSNAP` | Appointments snapshot (195 / 216) | `companies_data_*`, `persons_data_*` | [Prod195_Snapshot.md](docs/Prod195_Snapshot.md) |
| `DDDDUPDT` | Appointments update (198) | `companies_data_*`, `persons_data_*` | Person columns are **not** the snapshot schema. [Prod198_Update.md](docs/Prod198_Update.md) |
| `DISQUALS` | Disqualified persons (192) | `persons_data_*`, `disqualifications_data_*`, `exemptions_data_*`, `variations_data_*` | [Prod192_Disqualifications.md](docs/Prod192_Disqualifications.md) |
| `LIQNFORM` | Liquidation daily updates (197) | `forms_data_*`, `practitioners_data_*`, `free_text_data_*` | Tag-driven, not a full V4.6d sequence parser. [Prod197_Liquidation.md](docs/Prod197_Liquidation.md) |

Kinds are never overloaded: a liquidation form is not a company row.

## Install

Download a pre-built binary from [GitHub Releases](https://github.com/mrbrianevans/ch-fixedwidth/releases).

| Platform | Asset |
|----------|--------|
| Windows x86_64 | `ch-fixedwidth-windows-x86_64.exe` |
| Linux x86_64 | `ch-fixedwidth-linux-x86_64` |
| Linux ARM64 | `ch-fixedwidth-linux-aarch64` |
| macOS Intel | `ch-fixedwidth-macos-x86_64` |
| macOS Apple Silicon | `ch-fixedwidth-macos-aarch64` |

```bash
chmod +x ch-fixedwidth-linux-x86_64
```

Freestanding WASM is published as `ch_fixedwidth-wasm32-freestanding.wasm`. The TypeScript host (`@ch-fixedwidth/wasm-ts`) lives in this repository and is not on npm yet.

## Usage

```bash
ch-fixedwidth --help
ch-fixedwidth --version
ch-fixedwidth <input.dat|input_dir/|http(s)://.../file.dat|-> <output_folder>
```

| Argument | Description |
|----------|-------------|
| Input | A `.dat` file, a directory of `.dat` files, an `http://` / `https://` URL, or `-` (stdin) |
| `output_folder` | Directory for CSV output (created if missing) |

Examples:

```bash
ch-fixedwidth Prod216_4257_ew_6.dat ./output
ch-fixedwidth ./bulk/ ./output
ch-fixedwidth https://example.com/data/Prod216_4257_ew_6.dat ./output
ch-fixedwidth - ./output < Prod216_4257_ew_6.dat
```

Remote URLs and stdin are converted as a stream (the full file is not buffered to disk first). Directory input converts each top-level `.dat` one at a time.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Trailer counts matched. Prod 197 unknown tags are **warnings on stderr**; they do not fail the run. |
| 1 | Failure (unknown record type, field overflow, trailer mismatch, I/O, …) |

A failed run leaves whatever CSVs were already written.

## Honesty

- Unknown officers or disqualification record types, and extra data after a trailer, **fail** the run.
- Prod 197 unknown tags are logged (`unknown tag XX on form … company …`) and still counted toward the trailer. Exit 0 does not mean every tag was captured.
- Field overflow **fails**; cells are never silently truncated.
- Prod 198 person rows use the update column set (old/new identifiers). Trailing chevron fillers are omitted only while proven empty; a non-empty filler fails the parse.

## Building from source

Requires [Zig](https://ziglang.org/) 0.16+.

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/ch-fixedwidth <input> <output_folder>
```

```bash
zig build test
zig build wasm -Doptimize=ReleaseFast
```

Embedding (C ABI, streaming API, TypeScript host): [docs/development.md](docs/development.md).
Adding a product: [docs/adding-a-product.md](docs/adding-a-product.md).
Contributing: [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

[MIT](LICENSE)
