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
  /** Known product magic without a body parser yet. */
  NotImplemented: 8,
  /** Formatted CSV row exceeds the internal row buffer. */
  RowTooLarge: 9,
  /** Prod 197 form group exceeded max practitioners or free-text lines. */
  RecordLimit: 10,
} as const;

export type ChErrorCode = (typeof ChErrorCode)[keyof typeof ChErrorCode];

/** Product id after header magic is known (`CH_FILE_*`). */
export const ChFileType = {
  Unknown: -1,
  OfficersSnapshot: 0,
  OfficersUpdate: 1,
  Disqualifications: 2,
  Liquidation: 3,
} as const;

export type ChFileType = (typeof ChFileType)[keyof typeof ChFileType];

/** CSV output channel (`CH_OUTPUT_*` / `OutputKind`). */
export const ChOutputKind = {
  Companies: 0,
  Persons: 1,
  Disqualifications: 2,
  Exemptions: 3,
  Variations: 4,
  Forms: 5,
  Practitioners: 6,
  FreeText: 7,
} as const;

export type ChOutputKindCode = (typeof ChOutputKind)[keyof typeof ChOutputKind];

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
  [ChErrorCode.RowTooLarge]: "CSV row exceeds maximum formatted size",
  [ChErrorCode.RecordLimit]:
    "Form group exceeded maximum practitioners or free-text lines",
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

/** Fixed-width document bytes accepted by the one-shot parser. */
export type DocumentInput = Uint8Array | ArrayBuffer | string;

/** @deprecated Use {@link DocumentInput}. */
export type SnapshotInput = DocumentInput;

/**
 * Successful in-memory parse result.
 * CSV strings include the header row. Unused product outputs are empty strings / 0.
 */
export interface ParseResult {
  fileType: ChFileType;
  trailerCount: number;
  companiesCsv: string;
  personsCsv: string;
  disqualificationsCsv: string;
  exemptionsCsv: string;
  variationsCsv: string;
  formsCsv: string;
  practitionersCsv: string;
  freeTextCsv: string;
  companies: number;
  persons: number;
  disqualifications: number;
  exemptions: number;
  variations: number;
  forms: number;
  practitioners: number;
  freeText: number;
}

/** Named CSV batch kind from the streaming API. */
export type CsvBatchKind =
  | "companies"
  | "persons"
  | "disqualifications"
  | "exemptions"
  | "variations"
  | "forms"
  | "practitioners"
  | "free_text";

const BATCH_KIND_BY_CODE: Record<number, CsvBatchKind> = {
  [ChOutputKind.Companies]: "companies",
  [ChOutputKind.Persons]: "persons",
  [ChOutputKind.Disqualifications]: "disqualifications",
  [ChOutputKind.Exemptions]: "exemptions",
  [ChOutputKind.Variations]: "variations",
  [ChOutputKind.Forms]: "forms",
  [ChOutputKind.Practitioners]: "practitioners",
  [ChOutputKind.FreeText]: "free_text",
};

export function csvBatchKindFromCode(code: number): CsvBatchKind {
  const kind = BATCH_KIND_BY_CODE[code];
  if (kind === undefined) {
    throw new Error(`Unknown CSV batch kind code: ${code}`);
  }
  return kind;
}

/** Filename stem before `_<basename>.csv`. */
export function outputFileStem(kind: CsvBatchKind): string {
  switch (kind) {
    case "companies":
      return "companies_data";
    case "persons":
      return "persons_data";
    case "disqualifications":
      return "disqualifications_data";
    case "exemptions":
      return "exemptions_data";
    case "variations":
      return "variations_data";
    case "forms":
      return "forms_data";
    case "practitioners":
      return "practitioners_data";
    case "free_text":
      return "free_text_data";
  }
}

export function outputFileName(kind: CsvBatchKind, baseName: string): string {
  return `${outputFileStem(kind)}_${baseName}.csv`;
}

/** Output kinds emitted by each product (stable writer order). */
export function outputKindsForFileType(fileType: ChFileType): CsvBatchKind[] {
  switch (fileType) {
    case ChFileType.OfficersSnapshot:
    case ChFileType.OfficersUpdate:
      return ["companies", "persons"];
    case ChFileType.Disqualifications:
      return ["persons", "disqualifications", "exemptions", "variations"];
    case ChFileType.Liquidation:
      return ["forms", "practitioners", "free_text"];
    default:
      return [];
  }
}

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
  fileType: ChFileType;
  trailerCount: number;
  companies: number;
  persons: number;
  disqualifications: number;
  exemptions: number;
  variations: number;
  forms: number;
  practitioners: number;
  freeText: number;
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
  ch_parse(inputPtr: number, inputLen: number, outPtr: number): number;
  ch_parse_result_free(resultPtr: number): void;
  ch_buffer_free(bufPtr: number): void;
  ch_stream_create?(configPtr: number): number;
  ch_stream_destroy?(streamPtr: number): void;
  ch_stream_feed?(streamPtr: number, dataPtr: number, len: number): number;
  ch_stream_finish?(streamPtr: number): number;
  ch_stream_next_batch?(streamPtr: number, outPtr: number): number;
  ch_csv_batch_free?(batchPtr: number): void;
  ch_stream_stats?(streamPtr: number, outPtr: number): void;
}

/**
 * How to load the freestanding `ch_fixedwidth.wasm` module.
 * Provide exactly one of `module`, `wasmBytes`, or `wasmUrl`.
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
