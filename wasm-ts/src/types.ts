/** Error codes from `include/ch_fixedwidth.h` / the Zig C ABI. */
export const ChErrorCode = {
  Ok: 0,
  InvalidArg: 1,
  UnsupportedHeader: 2,
  MissingTrailer: 3,
  TrailerMismatch: 4,
  OutOfMemory: 5,
  Internal: 6,
  StreamState: 7,
  /** Known product magic (e.g. DDDDUPDT / DISQUALS) without a body parser yet. */
  NotImplemented: 8,
} as const;

export type ChErrorCode = (typeof ChErrorCode)[keyof typeof ChErrorCode];

const ERROR_MESSAGES: Record<number, string> = {
  [ChErrorCode.Ok]: "OK",
  [ChErrorCode.InvalidArg]: "Invalid argument (null or empty input)",
  [ChErrorCode.UnsupportedHeader]:
    "Unsupported or missing file header (expected a known 8-byte product magic)",
  [ChErrorCode.MissingTrailer]: "Missing trailer record",
  [ChErrorCode.TrailerMismatch]: "Trailer record count does not match rows parsed",
  [ChErrorCode.OutOfMemory]: "Out of memory in WASM allocator",
  [ChErrorCode.Internal]: "Internal parser error",
  [ChErrorCode.StreamState]: "Invalid stream state (already finished or data after trailer)",
  [ChErrorCode.NotImplemented]:
    "Recognised product header, but this file type is not implemented yet",
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

/** CSV batch kind from the streaming API. */
export type CsvBatchKind = "companies" | "persons";

/** One batched CSV chunk from the streaming parser (owned by the host). */
export interface CsvBatch {
  kind: CsvBatchKind;
  /** UTF-8 CSV bytes (may include the header row on the first batch of each kind). */
  data: Uint8Array;
  /** Number of data rows in this batch (header not counted). */
  rowCount: number;
  /** Decode `data` as UTF-8 text. */
  text(): string;
}

export interface StreamStats {
  companies: number;
  persons: number;
  trailerCount: number;
}

export interface StreamOptions extends LoadOptions {
  /**
   * Flush a kind after this many data rows (default 1000 inside WASM when omitted).
   * Pass 0 to use the WASM default.
   */
  batchRows?: number;
  /**
   * Flush a kind after this many buffered CSV bytes (default 256 KiB inside WASM).
   * Pass 0 to use the WASM default.
   */
  batchBytes?: number;
}

/** Low-level WASM export table (wasm32 pointers are i32). */
export interface ChWasmExports {
  memory: WebAssembly.Memory;
  ch_alloc(size: number): number;
  ch_free(ptr: number, size: number): void;
  ch_parse_snapshot(inputPtr: number, inputLen: number, outPtr: number): number;
  ch_parse_result_free(resultPtr: number): void;
  ch_buffer_free(bufPtr: number): void;
  // Streaming (optional on older modules — host checks before use)
  ch_stream_create?(configPtr: number): number;
  ch_stream_destroy?(streamPtr: number): void;
  ch_stream_feed?(streamPtr: number, dataPtr: number, len: number): number;
  ch_stream_finish?(streamPtr: number): number;
  ch_stream_next_batch?(streamPtr: number, outPtr: number): number;
  ch_csv_batch_free?(batchPtr: number): void;
  ch_stream_stats?(
    streamPtr: number,
    companiesPtr: number,
    personsPtr: number,
    trailerPtr: number,
  ): void;
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
