/**
 * `@ch-fixedwidth/wasm-ts` — TypeScript host for the freestanding Zig WASM parser.
 *
 * Build the module from the repository root (or obtain a release `.wasm`):
 *   zig build wasm -Doptimize=ReleaseFast
 *
 * Then load it without filesystem coupling:
 *   const wasmBytes = await readFile("ch_fixedwidth.wasm");
 *   const parser = await ChFixedWidthParser.create({ wasmBytes });
 *   const result = parser.parse(snapshotBytes);
 *
 * This package is runtime-agnostic (WebAssembly + fetch). Bun/Node local runners
 * live under `local/` and are not part of the published export surface.
 */

export { ChFixedWidthParser } from "./parser.ts";
export { compileWasm, instantiateWasm, getExports } from "./load.ts";
export {
  ChParseError,
  ChErrorCode,
  type ParseResult,
  type SnapshotInput,
  type LoadOptions,
  type ChWasmExports,
} from "./types.ts";
