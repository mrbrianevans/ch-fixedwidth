/** Error codes from `include/ch_fixedwidth.h` / the Zig C ABI. */
export const ChErrorCode = {
  Ok: 0,
  InvalidArg: 1,
  UnsupportedHeader: 2,
  MissingTrailer: 3,
  TrailerMismatch: 4,
  OutOfMemory: 5,
  Internal: 6,
} as const;

export type ChErrorCode = (typeof ChErrorCode)[keyof typeof ChErrorCode];

const ERROR_MESSAGES: Record<number, string> = {
  [ChErrorCode.InvalidArg]: "Invalid argument (null or empty input)",
  [ChErrorCode.UnsupportedHeader]: "Unsupported or missing DDDDSNAP header",
  [ChErrorCode.MissingTrailer]: "Missing trailer record",
  [ChErrorCode.TrailerMismatch]: "Trailer record count does not match rows parsed",
  [ChErrorCode.OutOfMemory]: "Out of memory in WASM allocator",
  [ChErrorCode.Internal]: "Internal parser error",
};

export class ChParseError extends Error {
  readonly code: ChErrorCode;

  constructor(code: number) {
    const message = ERROR_MESSAGES[code] ?? `Unknown parser error (${code})`;
    super(message);
    this.name = "ChParseError";
    this.code = code as ChErrorCode;
  }
}

/** Snapshot bytes accepted by the one-shot parser (plain-text fixed-width file). */
export type SnapshotInput = Uint8Array | ArrayBuffer | string;

/**
 * Successful in-memory parse result.
 * CSV strings include the header row and trailing newlines on data rows.
 */
export interface ParseResult {
  /** Full companies CSV document (header + rows). */
  companiesCsv: string;
  /** Full persons CSV document (header + rows). */
  personsCsv: string;
  /** Number of company data rows written. */
  companies: number;
  /** Number of person data rows written. */
  persons: number;
  /** Trailer record count from the input (must equal companies + persons). */
  trailerCount: number;
}

/** Low-level WASM export table (wasm32 pointers are i32). */
export interface ChWasmExports {
  memory: WebAssembly.Memory;
  ch_alloc(size: number): number;
  ch_free(ptr: number, size: number): void;
  ch_parse_snapshot(inputPtr: number, inputLen: number, outPtr: number): number;
  ch_parse_result_free(resultPtr: number): void;
  ch_buffer_free(bufPtr: number): void;
}

/**
 * How to load the freestanding `ch_fixedwidth.wasm` module.
 * Provide exactly one of `module`, `wasmBytes`, or `wasmUrl`.
 *
 * For Node/Bun local files, read the file yourself and pass `wasmBytes`
 * (this package does not depend on a filesystem API).
 */
export interface LoadOptions {
  /** Pre-compiled module (skips fetch/compile of bytes). */
  module?: WebAssembly.Module;
  /** Raw WASM binary. Preferred for local filesystem loads. */
  wasmBytes?: BufferSource;
  /**
   * URL that `fetch` can load (http(s), or a `file:` URL where the runtime allows it).
   * Not for bare filesystem paths in Node — use `wasmBytes` instead.
   */
  wasmUrl?: string | URL;
}
