# Fixed width parser for companies house data

Companies House publish bulk data products in a custom file format which is broadly fixed width + variable width chevron separated values.

Files have a custom header and trailer format with metadata.

Files are encoded as plain text - no binary.

Most data products are split into multiple files to allow parallel processing.

## Parser rules

A parser for this format should convert the data into a common, interoperable format like CSV, which can be read by tools like DuckDB.

A parser implementation MUST correctly convert an input file to valid output data file(s). All input data must be represented in the output - no data rows can be lost (this does not include metadata such as number of lines in a file). 

The output can be compressed (zstd/gzip), if by doing so the processing is sped up by reduce disk usage on output.

Assuming perfect correctness is achieved, a parser should aim to be high performance and efficient to achieve fast conversion times.

The input to a parser implementation is a file path pointing to a single data file on disk, and a file path to an output directory where output files are to be written.

The parser must read the input data file, and incrementally parse (in a streaming fashion) all records and write them to the appropriate output file(s).
At no point should the parser load the entire data set into memory. It MUST allow for larger than memory processing.
A single input file may result in multiple output files - the general rule for this is one entity type per output file, eg officers in one file, companies in another. But variants of an entity type, eg corporate officer and natural officer can be in the same file provided most of the fields are the same.

A parser may make full use of available resources on the machine its running on - including all CPU cores.

## Instructions to LLMs building a Go parser

Use the python parser (process_company_appointments_data.py) as the reference implementation. 
Use the .env file to get paths for testing files, and output to ./output.
Use DuckDB to verify the output, eg `select * from 'output\persons_data_Prod216_4257_ew_6.csv' using sample 10;` or `select count(*) from 'output\persons_data_Prod216_4257_ni.csv';`. You can run duckdb from the command line to query the files like this: `duckdb -json -c "select * from 'output\persons_data_Prod216_4257_ew_6.csv' using sample 10;"` and it will return json output to stdout.

Compare the output of your Go parser to the reference implementation for specific rows and ensure all values match. 

Run the python one like this:
```
uv run python .\process_company_appointments_data.py "...\Prod216_4257_ew_6.dat" ./output
```
And the Go one like this:
```
go run parser.go ...\Prod216_4257_ni.dat output
```
You can wrap those commands in `Measure-Command` in Powershell to time how long they take - do not trust self-reported measurements from the parser.

Before starting your implementation, ensure you are not on the master branch of the git repo. You must be on a feature branch.
After each change, efficiency enhancement, performance improvement or code refactor, if the output is correct, commit the change to Git with a message explaining the change. The subject should be short, the body more explainatory. Include the time to convert the files in the commit body.

For test runs, I suggest running on a small file initially to check the output is correct without wasting time. Once you're more confident, run it on a larger file.

## Implementations

| Parser | File | How to run | Lines of code\* |
|--------|------|------------|----------------:|
| Zig (native) | `parser.zig` | `zig build-exe parser.zig -OReleaseFast -femit-bin=parser_zig` then rename/run `.\parser_zig.exe <input.dat> <output_folder>` | ~780 |
| Zig (WASI) + Bun | `parser.wasm` + `run_wasm.ts` | Build wasm (see below), then `bun run run_wasm.ts <input.dat> <output_folder>` | 79† |
| Go (fast) | `parser.go` | `go build -o parser.exe parser.go` then `.\parser.exe <input.dat> <output_folder>` | 436 |
| Go (simple) | `simple_parser.go` | `go build -o simple_parser.exe simple_parser.go` then `.\simple_parser.exe …` | 290 |
| Python | `process_company_appointments_data.py` | `uv run python .\process_company_appointments_data.py <input.dat> <output_folder>` | 177 |
| Bun / TypeScript | `parser.ts` | `bun run parser.ts <input.dat> <output_folder>` | 243 |

† Host loader only; parse logic lives in the Zig WASI binary (`parser.wasm`).

Build WASI module:

```bash
zig build-exe parser.zig -OReleaseFast -fstrip --name parser -target wasm32-wasi \
  --initial-memory=33554432 --max-memory=536870912
```

\*Physical source lines in the file (including blanks and comments), counted on the benchmark date.

## Performance benchmark

Timed with PowerShell `Measure-Command` / `Stopwatch` (wall clock; not self-reported). Native parsers measured as release/fast binaries. Correctness checked with DuckDB full-table `EXCEPT`: **0 differing rows** for companies and persons (Zig vs Bun/TypeScript reference on the large file; other parsers previously matched Go).

**Test inputs**:

| Label | File | Data records (companies + persons) |
|-------|------|-----------------------------------:|
| Small | `Prod216_4257_ni.dat` (~158 MB) | 857 317 |
| Large | `Prod216_4257_ew_6.dat` (~1.17 GB) | 6 182 956 |

### Wall-clock time

| Parser | Small (s) | Large (s) |
|--------|----------:|----------:|
| Zig native (parallel) | — | ~0.74 |
| Zig WASI via Bun | — | ~3.40‡ |
| Go (fast) | 0.56 | 3.46 |
| Go (simple) | 1.76 | 13.28 |
| Python | 3.34 | 23.90 |
| Bun / TypeScript | 3.53 | ~28.8† |

† Re-timed on the same host as the Zig work (~28.8 s); earlier table had ~24 s.  
‡ Average of 3 PowerShell `Stopwatch` runs; single-threaded WASI (no worker threads). DuckDB full-table `EXCEPT` vs Bun/TS: **0** differing rows.

### Throughput (records / second)

Records = trailer count (companies + persons). Higher is better.

| Parser | Small (rec/s) | Large (rec/s) |
|--------|-------------:|-------------:|
| Zig native (parallel) | — | ~8 400 000 |
| Zig WASI via Bun | — | ~1 820 000 |
| Go (fast) | ~1 530 000 | ~1 790 000 |
| Go (simple) | ~487 000 | ~466 000 |
| Python | ~257 000 | ~259 000 |
| Bun / TypeScript | ~243 000 | ~215 000 |

On the large file, the parallel Zig native parser is about **4–5×** Go (fast) and about **30–40×** pure Bun/TS. The Zig **WASI** module under Bun is roughly **on par with Go (fast)** and about **8×** faster than the pure TypeScript parser, despite single-threaded execution and WASI syscall overhead.

*Benchmark host/OS: local Windows machine (22 logical CPUs); absolute numbers will vary with disk and CPU. Relative ordering is the useful takeaway.*

## Further work

Ideas to extend this in future:
 - compress output with zstd set to very low level (1) to reduce disk usage on write
 - try rust as another systems language comparison
 - avoid intermediate part files (shared ordered writers / memory ring)

 