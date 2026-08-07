/**
 * `@ch-fixedwidth/wasm-ts` — TypeScript host for the freestanding Zig WASM parser.
 *
 * Build the module from the repository root (or obtain a release `.wasm`):
 *   zig build wasm -Doptimize=ReleaseFast
 *
 * One-shot (small / moderate files):
 *   const parser = await ChFixedWidthParser.create({ wasmBytes });
 *   const result = parser.parse(documentBytes);
 *
 * Streaming (large files — preferred):
 *   const stream = await ChFixedWidthStream.create({ wasmBytes });
 *   for (const batch of stream.feed(chunk)) { ... write batch by kind ... }
 *   for (const batch of stream.finish()) { ... }
 *   stream.destroy();
 *
 * Products: officers snapshot/update, disqualifications, liquidation — each emits
 * named output kinds (never overloaded).
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
  ChFileType,
  ChOutputKind,
  csvBatchKindFromCode,
  outputFileStem,
  outputFileName,
  outputKindsForFileType,
  type ParseResult,
  type DocumentInput,
  type SnapshotInput,
  type LoadOptions,
  type StreamOptions,
  type StreamStats,
  type CsvBatch,
  type CsvBatchKind,
  type SupportedFormat,
  type LibraryInfo,
  type ChWasmExports,
} from "./types.ts";
