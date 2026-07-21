/**
 * TypeScript host for the freestanding Companies House fixed-width WASM parser.
 *
 * Build the module from the repo root first:
 *   zig build wasm -Doptimize=ReleaseFast
 *
 * Then:
 *   import { ChFixedWidthParser } from "./src/index.ts";
 *   const parser = await ChFixedWidthParser.create();
 *   const result = parser.parse(snapshotBytes);
 */

export {
  ChFixedWidthParser,
  ChParseError,
  ChErrorCode,
  type ParseResult,
  type SnapshotInput,
  type LoadOptions,
  type ChWasmExports,
} from "./parser.ts";
