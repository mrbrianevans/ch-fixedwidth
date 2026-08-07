# `@ch-fixedwidth/wasm-ts`

TypeScript host for the freestanding Zig WASM multi-product parser (`ch_fixedwidth.wasm`).

Runtime-agnostic: uses only `WebAssembly` and optional `fetch`. No Node/Bun filesystem APIs in the library surface.

> **Not published to npm yet** (`private: true`). The package layout and `exports` are publish-ready; ship a matching `ch_fixedwidth.wasm` (release asset or build artifact) alongside it when you publish.

## Prerequisites

From the repository root (or use a release WASM binary):

```bash
zig build wasm -Doptimize=ReleaseFast
```

Produces `zig-out/ch_fixedwidth.wasm`.

## Products and output kinds

Header magic selects the product. Batches and one-shot results use **named** kinds (`companies`, `persons`, `disqualifications`, `exemptions`, `variations`, `forms`, `practitioners`, `free_text`) — never reusing companies/persons for unrelated tables.

Helpers: `outputFileName`, `outputKindsForFileType`, `parser.libraryInfo()`, `parser.supportedFormats()`, `ChFileType`, `ChOutputKind`.

`libraryInfo()` returns the embedded semver, build-time short git commit, and the formats catalogue (from WASM `ch_library_info`). `supportedFormats()` is the formats list alone.

## Usage

### Streaming (recommended for large files)

Peak memory stays roughly **O(chunk + batch)**, not O(file). Drain each batch
(e.g. write to disk) before feeding more if you want to bound host memory.

```ts
import { readFile } from "node:fs/promises";
import {
  ChFixedWidthStream,
  outputFileName,
} from "@ch-fixedwidth/wasm-ts";

const wasmBytes = await readFile("ch_fixedwidth.wasm");
const stream = await ChFixedWidthStream.create({
  wasmBytes,
  // optional: batchRows: 1000, batchBytes: 256 * 1024
});

try {
  for (const batch of stream.feed(chunk)) {
    // batch.kind: "companies" | "persons" | "forms" | …
    // batch.data: Uint8Array CSV fragment (header on first batch of each kind)
  }
  for (const batch of stream.finish()) {
    /* final batches + trailer check */
  }
  const stats = stream.stats(); // fileType + all kind counts + trailerCount
} finally {
  stream.destroy();
}
```

### One-shot (small / moderate files)

```ts
import { ChFixedWidthParser } from "@ch-fixedwidth/wasm-ts";

const parser = await ChFixedWidthParser.create({ wasmBytes });
const { version, gitCommit, formats } = parser.libraryInfo();
// version: "0.1.0", gitCommit: "5bc738d…", formats: [{ fileType, productCodes, headerIdentifier, description }, …]
const result = parser.parse(documentBytes);
// result.fileType, result.companiesCsv / formsCsv / …, counts
```

`parse()` holds the **entire** document and all CSV outputs in WASM linear memory. Prefer streaming for multi-hundred-MB / GB files.

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
| `ChFixedWidthStream` | Chunked input → batched CSV by kind |
| `ChFixedWidthParser` | One-shot in-memory parse |
| `ChParseError` / `ChErrorCode` | Typed ABI errors |
| `ChFileType` / `ChOutputKind` | Product and output enums |
| `outputFileName` / `outputKindsForFileType` | CLI-compatible naming |
| `compileWasm` / `instantiateWasm` / `getExports` | Low-level load helpers |

## Local Bun CLI (not published)

Monorepo helper: streaming read + per-kind batch write.

```bash
zig build wasm -Doptimize=ReleaseFast
cd wasm-ts && bun install && bun run local ../src/testdata/mini_snapshot.dat ./out
bun run local ../src/testdata/mini_liquidation.dat ./out_liq
```

Optional: `WASM_PATH=/path/to/ch_fixedwidth.wasm`.

## Tests

```bash
zig build wasm -Doptimize=ReleaseFast
cd wasm-ts && bun test
```

## Types and error codes

See `src/types.ts` and the C header `include/ch_fixedwidth.h`.
