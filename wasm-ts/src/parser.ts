import { getExports, instantiateWasm } from "./load.ts";
import {
  ChParseError,
  type ChFileType,
  type ChWasmExports,
  type DocumentInput,
  type LibraryInfo,
  type LoadOptions,
  type ParseResult,
  type SupportedFormat,
} from "./types.ts";

/**
 * wasm32 layout of ChParseResult:
 * 10× i32 counts (40) + 8× ChBuffer ptr+len (8×8 = 64) = 104.
 */
const PARSE_RESULT_SIZE = 104;

/**
 * wasm32 layout of ChSupportedFormat:
 * i32 file_type (0) + u32 product_code_count (4) + [4]u16 product_codes (8)
 * + ptr header (16) + ptr description (20) = 24.
 */
const SUPPORTED_FORMAT_SIZE = 24;
const CH_MAX_PRODUCT_CODES = 4;

/**
 * wasm32 layout of ChLibraryInfo:
 * ptr version (0) + ptr git_commit (4) + ptr formats (8) + usize format_count (12) = 16.
 */
const LIBRARY_INFO_SIZE = 16;
const OFF_FILE_TYPE = 0;
const OFF_TRAILER = 4;
const OFF_COMPANIES = 8;
const OFF_PERSONS = 12;
const OFF_DISQ = 16;
const OFF_EXEMPT = 20;
const OFF_VAR = 24;
const OFF_FORMS = 28;
const OFF_PRAC = 32;
const OFF_FREE = 36;
const OFF_COMPANIES_CSV = 40;
const OFF_PERSONS_CSV = 48;
const OFF_DISQ_CSV = 56;
const OFF_EXEMPT_CSV = 64;
const OFF_VAR_CSV = 72;
const OFF_FORMS_CSV = 80;
const OFF_PRAC_CSV = 88;
const OFF_FREE_CSV = 96;

function toBytes(input: DocumentInput): Uint8Array {
  if (typeof input === "string") {
    return new TextEncoder().encode(input);
  }
  if (input instanceof ArrayBuffer) {
    return new Uint8Array(input);
  }
  return input;
}

/** Read a NUL-terminated UTF-8 C string from WASM linear memory. */
function readCString(memory: WebAssembly.Memory, ptr: number): string {
  if (ptr === 0) return "";
  const bytes = new Uint8Array(memory.buffer, ptr);
  let end = 0;
  while (end < bytes.length && bytes[end] !== 0) {
    end++;
  }
  return new TextDecoder("utf-8", { fatal: false }).decode(bytes.subarray(0, end));
}

function readSupportedFormats(
  memory: WebAssembly.Memory,
  tablePtr: number,
  count: number,
): SupportedFormat[] {
  if (tablePtr === 0 || count === 0) return [];
  const formats: SupportedFormat[] = [];
  for (let i = 0; i < count; i++) {
    const base = tablePtr + i * SUPPORTED_FORMAT_SIZE;
    const view = new DataView(memory.buffer, base, SUPPORTED_FORMAT_SIZE);
    const fileType = view.getInt32(0, true) as ChFileType;
    const codeCount = Math.min(view.getUint32(4, true), CH_MAX_PRODUCT_CODES);
    const productCodes: number[] = [];
    for (let c = 0; c < codeCount; c++) {
      productCodes.push(view.getUint16(8 + c * 2, true));
    }
    formats.push({
      fileType,
      productCodes,
      headerIdentifier: readCString(memory, view.getUint32(16, true)),
      description: readCString(memory, view.getUint32(20, true)),
    });
  }
  return formats;
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

function readCsv(
  memory: WebAssembly.Memory,
  view: DataView,
  bufOff: number,
): string {
  return copyUtf8(memory, readU32(view, bufOff), readU32(view, bufOff + 4));
}

/**
 * Host-side wrapper around the freestanding `ch_fixedwidth` WASM module.
 *
 * One-shot parse: entire input and all CSV outputs live in WASM linear memory.
 * Prefer the streaming API for multi-hundred-MB files.
 */
export class ChFixedWidthParser {
  readonly exports: ChWasmExports;
  private readonly instance: WebAssembly.Instance;

  private constructor(instance: WebAssembly.Instance) {
    this.instance = instance;
    this.exports = getExports(instance);
  }

  /**
   * Compile and instantiate the WASM module.
   * Pass `wasmBytes`, `wasmUrl`, or a prebuilt `module` (see {@link LoadOptions}).
   */
  static async create(options: LoadOptions): Promise<ChFixedWidthParser> {
    const instance = await instantiateWasm(options);
    return new ChFixedWidthParser(instance);
  }

  /**
   * Library identity embedded in the WASM module: semver, build-time git
   * commit, and supported file formats. Strings/table are copied out of
   * static WASM storage.
   */
  libraryInfo(): LibraryInfo {
    const { memory, ch_library_info } = this.exports;
    if (typeof ch_library_info !== "function") {
      throw new Error(
        "Invalid ch_fixedwidth.wasm: missing ch_library_info. Rebuild with zig build wasm.",
      );
    }

    const infoPtr = ch_library_info();
    if (infoPtr === 0) {
      throw new Error("ch_library_info returned null");
    }

    const view = new DataView(memory.buffer, infoPtr, LIBRARY_INFO_SIZE);
    const versionPtr = view.getUint32(0, true);
    const commitPtr = view.getUint32(4, true);
    const formatsPtr = view.getUint32(8, true);
    const formatCount = view.getUint32(12, true);

    return {
      version: readCString(memory, versionPtr),
      gitCommit: readCString(memory, commitPtr),
      formats: readSupportedFormats(memory, formatsPtr, formatCount),
    };
  }

  /**
   * List of bulk file formats this module can parse (product codes, header
   * magic, short description). Prefer {@link libraryInfo} when you also need
   * version/commit metadata.
   */
  supportedFormats(): SupportedFormat[] {
    return this.libraryInfo().formats;
  }

  /**
   * Parse a full Companies House fixed-width document into named CSV strings.
   * Throws {@link ChParseError} on non-zero ABI status codes.
   */
  parse(input: DocumentInput): ParseResult {
    const bytes = toBytes(input);
    if (bytes.byteLength === 0) {
      throw new ChParseError(1);
    }

    const { memory, ch_alloc, ch_free, ch_parse, ch_parse_result_free } =
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
      new Uint8Array(memory.buffer, inputPtr, bytes.byteLength).set(bytes);
      new Uint8Array(memory.buffer, resultPtr, PARSE_RESULT_SIZE).fill(0);

      const code = ch_parse(inputPtr, bytes.byteLength, resultPtr);
      if (code !== 0) {
        throw new ChParseError(code);
      }

      const view = new DataView(memory.buffer, resultPtr, PARSE_RESULT_SIZE);
      return {
        fileType: readI32(view, OFF_FILE_TYPE) as ChFileType,
        trailerCount: readI32(view, OFF_TRAILER),
        companies: readI32(view, OFF_COMPANIES),
        persons: readI32(view, OFF_PERSONS),
        disqualifications: readI32(view, OFF_DISQ),
        exemptions: readI32(view, OFF_EXEMPT),
        variations: readI32(view, OFF_VAR),
        forms: readI32(view, OFF_FORMS),
        practitioners: readI32(view, OFF_PRAC),
        freeText: readI32(view, OFF_FREE),
        companiesCsv: readCsv(memory, view, OFF_COMPANIES_CSV),
        personsCsv: readCsv(memory, view, OFF_PERSONS_CSV),
        disqualificationsCsv: readCsv(memory, view, OFF_DISQ_CSV),
        exemptionsCsv: readCsv(memory, view, OFF_EXEMPT_CSV),
        variationsCsv: readCsv(memory, view, OFF_VAR_CSV),
        formsCsv: readCsv(memory, view, OFF_FORMS_CSV),
        practitionersCsv: readCsv(memory, view, OFF_PRAC_CSV),
        freeTextCsv: readCsv(memory, view, OFF_FREE_CSV),
      };
    } finally {
      ch_parse_result_free(resultPtr);
      ch_free(resultPtr, PARSE_RESULT_SIZE);
      ch_free(inputPtr, bytes.byteLength);
    }
  }
}
