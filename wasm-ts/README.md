# `@ch-fixedwidth/wasm-ts`

TypeScript / Bun host for the freestanding Zig WASM parser (`ch_fixedwidth.wasm`).

The WASM module exposes **in-memory parse only** (no filesystem). This package loads the artifact, copies snapshot bytes into linear memory, calls `ch_parse_snapshot`, and returns typed CSV strings.

## Prerequisites

From the repository root:

```bash
zig build wasm -Doptimize=ReleaseFast
```

Produces `zig-out/ch_fixedwidth.wasm` (default load path).

## Usage

```ts
import { ChFixedWidthParser } from "./src/index.ts";

const parser = await ChFixedWidthParser.create();
// optional: { wasmPath: "/path/to/ch_fixedwidth.wasm" }

const result = parser.parse(await Bun.file("snapshot.dat").bytes());
// result.companiesCsv, result.personsCsv, result.companies, result.persons, result.trailerCount
```

### CLI

```bash
bun run cli.ts <input.dat> [output_dir]
```

### Tests

```bash
bun test
```

## Types

| Type | Meaning |
|------|---------|
| `SnapshotInput` | `Uint8Array \| ArrayBuffer \| string` |
| `ParseResult` | CSV strings + row counts + trailer count |
| `ChParseError` | Thrown on non-zero ABI codes (`code` field) |

See `src/types.ts` and `include/ch_fixedwidth.h` for error codes.
