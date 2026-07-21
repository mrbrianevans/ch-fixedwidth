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

## Install (when published)

```bash
npm install @ch-fixedwidth/wasm-ts
# plus the WASM binary from GitHub Releases or your own build
```

Until publish, depend on the monorepo path or copy `wasm-ts/src`.

## Usage

```ts
import { readFile } from "node:fs/promises";
import { ChFixedWidthParser, ChParseError } from "@ch-fixedwidth/wasm-ts";

const wasmBytes = await readFile("ch_fixedwidth.wasm");
const parser = await ChFixedWidthParser.create({ wasmBytes });

const result = parser.parse(await readFile("snapshot.dat"));
// result.companiesCsv, result.personsCsv, result.companies, result.persons, result.trailerCount
```

### Load options

Provide **exactly one** of:

| Option | When to use |
|--------|-------------|
| `wasmBytes` | Local files, bundlers, Node/Bun (`readFile` / `Bun.file`) |
| `wasmUrl` | HTTP(S) or fetchable URL |
| `module` | Pre-compiled `WebAssembly.Module` |

### One-shot vs large files

`parse()` holds the **entire** snapshot and both CSV documents in WASM linear memory. Fine for small fixtures and moderate files; for multi-hundred-MB / GB snapshots use the native CLI or a streaming host when available.

### Public exports

| Export | Role |
|--------|------|
| `ChFixedWidthParser` | One-shot in-memory parse |
| `ChParseError` / `ChErrorCode` | Typed ABI errors |
| `compileWasm` / `instantiateWasm` / `getExports` | Low-level load helpers |
| Types: `ParseResult`, `SnapshotInput`, `LoadOptions`, `ChWasmExports` | |

## Local Bun CLI (not published)

Monorepo helper for manual runs and CI:

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
