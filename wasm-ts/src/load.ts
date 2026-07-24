import type { ChWasmExports, LoadOptions } from "./types.ts";

/**
 * Compile `ch_fixedwidth.wasm` from the given load options.
 * Does not instantiate; freestanding module needs no imports.
 */
export async function compileWasm(options: LoadOptions): Promise<WebAssembly.Module> {
  if (options.module) {
    return options.module;
  }
  if (options.wasmBytes && options.wasmUrl) {
    throw new Error("LoadOptions: provide only one of wasmBytes or wasmUrl");
  }
  if (options.wasmBytes) {
    return WebAssembly.compile(options.wasmBytes);
  }
  if (options.wasmUrl) {
    const res = await fetch(options.wasmUrl);
    if (!res.ok) {
      throw new Error(`Failed to fetch WASM (${res.status} ${res.statusText})`);
    }
    return WebAssembly.compile(await res.arrayBuffer());
  }
  throw new Error(
    "LoadOptions: provide module, wasmBytes, or wasmUrl to load ch_fixedwidth.wasm",
  );
}

/** Instantiate a freestanding ch_fixedwidth module (no imports). */
export async function instantiateWasm(
  options: LoadOptions,
): Promise<WebAssembly.Instance> {
  const module = await compileWasm(options);
  return WebAssembly.instantiate(module, {});
}

/** Validate and cast instance exports to the C ABI table. */
export function getExports(instance: WebAssembly.Instance): ChWasmExports {
  const exports = instance.exports as unknown as ChWasmExports;
  if (!exports.memory || typeof exports.ch_parse_snapshot !== "function") {
    throw new Error("Invalid ch_fixedwidth.wasm: missing expected exports");
  }
  if (typeof exports.ch_alloc !== "function" || typeof exports.ch_free !== "function") {
    throw new Error("Invalid ch_fixedwidth.wasm: missing ch_alloc/ch_free");
  }
  if (typeof exports.ch_parse_result_free !== "function") {
    throw new Error("Invalid ch_fixedwidth.wasm: missing ch_parse_result_free");
  }
  return exports;
}

/** Require streaming exports (throws if the module is too old). */
export function requireStreamExports(exports: ChWasmExports): asserts exports is ChWasmExports & {
  ch_stream_create: (configPtr: number) => number;
  ch_stream_destroy: (streamPtr: number) => void;
  ch_stream_feed: (streamPtr: number, dataPtr: number, len: number) => number;
  ch_stream_finish: (streamPtr: number) => number;
  ch_stream_next_batch: (streamPtr: number, outPtr: number) => number;
  ch_csv_batch_free: (batchPtr: number) => void;
  ch_stream_stats: (
    streamPtr: number,
    companiesPtr: number,
    personsPtr: number,
    trailerPtr: number,
  ) => void;
} {
  const needed = [
    "ch_stream_create",
    "ch_stream_destroy",
    "ch_stream_feed",
    "ch_stream_finish",
    "ch_stream_next_batch",
    "ch_csv_batch_free",
    "ch_stream_stats",
  ] as const;
  for (const name of needed) {
    if (typeof exports[name] !== "function") {
      throw new Error(
        `Invalid ch_fixedwidth.wasm: missing streaming export ${name}. Rebuild with zig build wasm.`,
      );
    }
  }
}
