/**
 * `@ch-fixedwidth/wasm-ts` — TypeScript host for the freestanding Zig WASM parser.
 *
 * Build the module from the repository root (or obtain a release `.wasm`):
 *   zig build wasm -Doptimize=ReleaseFast
 *
 * One-shot (small / moderate files):
 *   const parser = await ChFixedWidthParser.create({ wasmBytes });
 *   const result = parser.parse(snapshotBytes);
 *
 * Streaming (large files — preferred):
 *   const stream = await ChFixedWidthStream.create({ wasmBytes });
 *   for (const batch of stream.feed(chunk)) { ... write batch.data ... }
 *   for (const batch of stream.finish()) { ... }
 *   stream.destroy();
 *
 * This package is runtime-agnostic (WebAssembly + fetch). Bun/Node local runners
 * live under `local/` and are not part of the published export surface.
 */

export { ChFixedWidthParser } from "./parser.ts";
export { ChFixedWidthStream } from "./stream.ts";
export { compileWasm, instantiateWasm, getExports, requireStreamExports } from "./load.ts";
export {
  ChParseError,
  ChErrorCode,
  type ParseResult,
  type SnapshotInput,
  type LoadOptions,
  type StreamOptions,
  type StreamStats,
  type CsvBatch,
  type CsvBatchKind,
  type ChWasmExports,
} from "./types.ts";
