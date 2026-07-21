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
