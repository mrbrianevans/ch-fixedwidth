import { join } from "node:path";
import {
  ChParseError,
  type ChWasmExports,
  type LoadOptions,
  type ParseResult,
  type SnapshotInput,
} from "./types.ts";

/** Size of `ChParseResult` on wasm32 (two buffers + three i32s). */
const PARSE_RESULT_SIZE = 28;
/** Offset of `companies_csv` / `persons_csv` pointer+len pairs and counts. */
const OFF_COMPANIES_PTR = 0;
const OFF_COMPANIES_LEN = 4;
const OFF_PERSONS_PTR = 8;
const OFF_PERSONS_LEN = 12;
const OFF_COMPANIES = 16;
const OFF_PERSONS = 20;
const OFF_TRAILER = 24;

const DEFAULT_WASM = join(import.meta.dir, "..", "..", "zig-out", "ch_fixedwidth.wasm");

function toBytes(input: SnapshotInput): Uint8Array {
  if (typeof input === "string") {
    return new TextEncoder().encode(input);
  }
  if (input instanceof ArrayBuffer) {
    return new Uint8Array(input);
  }
  return input;
}

function readU32(view: DataView, offset: number): number {
  return view.getUint32(offset, true);
}

function readI32(view: DataView, offset: number): number {
  return view.getInt32(offset, true);
}

function copyUtf8(memory: WebAssembly.Memory, ptr: number, len: number): string {
  if (ptr === 0 || len === 0) return "";
  return new TextDecoder("utf-8", { fatal: false }).decode(
    new Uint8Array(memory.buffer, ptr, len),
  );
}

/**
 * Host-side wrapper around the freestanding `ch_fixedwidth` WASM module.
 * Parsing is entirely in linear memory — no filesystem I/O inside WASM.
 */
export class ChFixedWidthParser {
  readonly exports: ChWasmExports;
  private readonly instance: WebAssembly.Instance;

  private constructor(instance: WebAssembly.Instance) {
    this.instance = instance;
    this.exports = instance.exports as unknown as ChWasmExports;
    if (!this.exports.memory || typeof this.exports.ch_parse_snapshot !== "function") {
      throw new Error("Invalid ch_fixedwidth.wasm: missing expected exports");
    }
  }

  /** Compile and instantiate the WASM module. */
  static async create(options: LoadOptions = {}): Promise<ChFixedWidthParser> {
    let module = options.module;
    if (!module) {
      const path = options.wasmPath ?? DEFAULT_WASM;
      const bytes =
        typeof path === "string" || path instanceof URL
          ? await Bun.file(path).arrayBuffer()
          : path;
      module = await WebAssembly.compile(bytes);
    }
    // Freestanding: no imports required.
    const instance = await WebAssembly.instantiate(module, {});
    return new ChFixedWidthParser(instance);
  }

  /**
   * Parse a full Companies House snapshot document into two CSV strings.
   * Throws {@link ChParseError} on non-zero ABI status codes.
   */
  parse(input: SnapshotInput): ParseResult {
    const bytes = toBytes(input);
    if (bytes.byteLength === 0) {
      throw new ChParseError(1);
    }

    const { memory, ch_alloc, ch_free, ch_parse_snapshot, ch_parse_result_free } =
      this.exports;

    const inputPtr = ch_alloc(bytes.byteLength);
    if (inputPtr === 0) {
      throw new ChParseError(5);
    }

    const resultPtr = ch_alloc(PARSE_RESULT_SIZE);
    if (resultPtr === 0) {
      ch_free(inputPtr, bytes.byteLength);
      throw new ChParseError(5);
    }

    try {
      // Re-read memory.buffer after each alloc — growth may detach the old buffer.
      new Uint8Array(memory.buffer, inputPtr, bytes.byteLength).set(bytes);
      // Zero the result struct.
      new Uint8Array(memory.buffer, resultPtr, PARSE_RESULT_SIZE).fill(0);

      const code = ch_parse_snapshot(inputPtr, bytes.byteLength, resultPtr);
      if (code !== 0) {
        throw new ChParseError(code);
      }

      const view = new DataView(memory.buffer, resultPtr, PARSE_RESULT_SIZE);
      const companiesPtr = readU32(view, OFF_COMPANIES_PTR);
      const companiesLen = readU32(view, OFF_COMPANIES_LEN);
      const personsPtr = readU32(view, OFF_PERSONS_PTR);
      const personsLen = readU32(view, OFF_PERSONS_LEN);

      return {
        companiesCsv: copyUtf8(memory, companiesPtr, companiesLen),
        personsCsv: copyUtf8(memory, personsPtr, personsLen),
        companies: readI32(view, OFF_COMPANIES),
        persons: readI32(view, OFF_PERSONS),
        trailerCount: readI32(view, OFF_TRAILER),
      };
    } finally {
      // Free CSV buffers owned by the result, then host-owned allocations.
      ch_parse_result_free(resultPtr);
      ch_free(resultPtr, PARSE_RESULT_SIZE);
      ch_free(inputPtr, bytes.byteLength);
    }
  }
}

export type { ParseResult, SnapshotInput, LoadOptions, ChWasmExports };
export { ChParseError, ChErrorCode } from "./types.ts";
