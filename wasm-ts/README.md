# `@ch-fixedwidth/wasm-ts`

TypeScript host for the freestanding Zig WASM parser (`ch_fixedwidth.wasm`).

Runtime-agnostic: uses only `WebAssembly` and optional `fetch`. No Node/Bun filesystem APIs in the library surface.

> **Not published to npm yet** (`private: true`). The package layout and `exports` are publish-ready; ship a matching `ch_fixedwidth.wasm` (release asset or build artifact) alongside it when you publish.

## Prerequisites

From the repository root (or use a release WASM binary):

```bash
zig build wasm -Doptimize=ReleaseFast
```

Produces `zig-out/ch_fixedwidth.wasm`.

## Usage

### Streaming (recommended for large files)

Peak memory stays roughly **O(chunk + batch)**, not O(file). Drain each batch
(e.g. write to disk) before feeding more if you want to bound host memory.

```ts
import { readFile } from "node:fs/promises";
import { ChFixedWidthStream } from "@ch-fixedwidth/wasm-ts";

const wasmBytes = await readFile("ch_fixedwidth.wasm");
const stream = await ChFixedWidthStream.create({
  wasmBytes,
  // optional: batchRows: 1000, batchBytes: 256 * 1024
});

try {
  // feed any chunk size — need not end on a newline
  for (const batch of stream.feed(chunk)) {
    if (batch.kind === "companies") {
      // batch.data: Uint8Array CSV fragment (header on first companies batch)
    } else {
      // persons
    }
  }
  for (const batch of stream.finish()) {
    /* final batches + trailer check */
  }
  const { companies, persons, trailerCount } = stream.stats();
} finally {
  stream.destroy();
}
```

### One-shot (small / moderate files)

```ts
import { ChFixedWidthParser } from "@ch-fixedwidth/wasm-ts";

const parser = await ChFixedWidthParser.create({ wasmBytes });
const result = parser.parse(snapshotBytes);
// result.companiesCsv, result.personsCsv, ...
```

`parse()` holds the **entire** snapshot and both CSV documents in WASM linear memory. Prefer streaming for multi-hundred-MB / GB snapshots.

### Load options

Provide **exactly one** of:

| Option | When to use |
|--------|-------------|
| `wasmBytes` | Local files, bundlers, Node/Bun (`readFile` / `Bun.file`) |
| `wasmUrl` | HTTP(S) or fetchable URL |
| `module` | Pre-compiled `WebAssembly.Module` |

### Public exports

| Export | Role |
|--------|------|
| `ChFixedWidthStream` | Chunked input → batched CSV (large files) |
| `ChFixedWidthParser` | One-shot in-memory parse |
| `ChParseError` / `ChErrorCode` | Typed ABI errors |
| `compileWasm` / `instantiateWasm` / `getExports` | Low-level load helpers |
| Types: `CsvBatch`, `ParseResult`, `LoadOptions`, `StreamOptions`, … | |

## Local Bun CLI (not published)

Monorepo helper: streaming read + batch write.

```bash
zig build wasm -Doptimize=ReleaseFast
cd wasm-ts && bun install && bun run local ../src/testdata/mini_snapshot.dat ./out
```

Optional: `WASM_PATH=/path/to/ch_fixedwidth.wasm`.

## Tests

```bash
zig build wasm -Doptimize=ReleaseFast
cd wasm-ts && bun test
```

## Types and error codes

See `src/types.ts` and the C header `include/ch_fixedwidth.h`.
