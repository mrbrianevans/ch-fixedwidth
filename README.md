# Companies House fixed-width parser

High-performance Zig parser for Companies House bulk appointment data (products 195 / 216). Converts snapshot files from the proprietary fixed-width + chevron format into CSV.

Native builds use **multithreading**: the input is split on line boundaries and worker threads write part CSVs that are concatenated. On large snapshots this typically exceeds **~8 million records/second** on a multi-core machine (wall clock; host-dependent).

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

```bash
zig build-exe parser.zig -OReleaseFast -fstrip --name parser
./parser <input.dat> <output_folder>
```

| Argument | Description |
|----------|-------------|
| `input.dat` | Path to a single snapshot file |
| `output_folder` | Directory for CSV output (created if missing) |

Example:

```bash
./parser Prod216_4257_ew_6.dat ./output
```

Exit code `0` on success (trailer count matches rows written); non-zero on header/trailer mismatch or I/O errors.

## Alternative implementations

Older Go, Python, and TypeScript parsers (and multi-language benchmarks) live under [`reference/`](reference/) for comparison only. The Zig implementation is the maintained product path.
