import { getExports, instantiateWasm, requireStreamExports } from "./load.ts";
import {
  ChParseError,
  type ChWasmExports,
  type CsvBatch,
  type CsvBatchKind,
  type StreamOptions,
  type StreamStats,
} from "./types.ts";

/** wasm32 layout of ChStreamConfig */
const CONFIG_SIZE = 8;
/** wasm32 layout of ChCsvBatch */
const BATCH_SIZE = 16;
const STATS_I32_TRIPLE = 12;

function toBytes(input: Uint8Array | ArrayBuffer | string): Uint8Array {
  if (typeof input === "string") {
    return new TextEncoder().encode(input);
  }
  if (input instanceof ArrayBuffer) {
    return new Uint8Array(input);
  }
  return input;
}

function copyBytes(memory: WebAssembly.Memory, ptr: number, len: number): Uint8Array {
  if (ptr === 0 || len === 0) return new Uint8Array();
  const view = new Uint8Array(memory.buffer, ptr, len);
  const out = new Uint8Array(len);
  out.set(view);
  return out;
}

function makeBatch(kind: CsvBatchKind, data: Uint8Array, rowCount: number): CsvBatch {
  return {
    kind,
    data,
    rowCount,
    text: () => new TextDecoder("utf-8", { fatal: false }).decode(data),
  };
}

/**
 * Streaming host for large snapshots.
 *
 * Peak WASM memory is roughly O(input chunk + open CSV batches), not O(file).
 * Drain returned batches after every `feed` / `finish` (write them to disk or
 * a JS stream) so batches do not accumulate on the host either.
 *
 * Defaults inside WASM: flush every 1000 data rows or 256 KiB of CSV per kind.
 */
export class ChFixedWidthStream {
  readonly exports: ChWasmExports;
  private streamPtr: number;
  private destroyed = false;

  private constructor(exports: ChWasmExports, streamPtr: number) {
    this.exports = exports;
    this.streamPtr = streamPtr;
  }

  static async create(options: StreamOptions): Promise<ChFixedWidthStream> {
    const instance = await instantiateWasm(options);
    const exports = getExports(instance);
    requireStreamExports(exports);

    const { memory, ch_alloc, ch_free, ch_stream_create } = exports;
    const configPtr = ch_alloc(CONFIG_SIZE);
    if (configPtr === 0) {
      throw new ChParseError(5);
    }
    try {
      const view = new DataView(memory.buffer, configPtr, CONFIG_SIZE);
      view.setUint32(0, options.batchRows ?? 0, true);
      view.setUint32(4, options.batchBytes ?? 0, true);
      const streamPtr = ch_stream_create(configPtr);
      if (streamPtr === 0) {
        throw new ChParseError(5);
      }
      return new ChFixedWidthStream(exports, streamPtr);
    } finally {
      ch_free(configPtr, CONFIG_SIZE);
    }
  }

  /**
   * Feed the next input chunk. Returns any CSV batches that became ready.
   * Chunks need not end on line boundaries.
   */
  feed(chunk: Uint8Array | ArrayBuffer | string): CsvBatch[] {
    this.assertLive();
    const bytes = toBytes(chunk);
    const { memory, ch_alloc, ch_free, ch_stream_feed } = this.exports;
    requireStreamExports(this.exports);

    if (bytes.byteLength === 0) {
      const code = ch_stream_feed!(this.streamPtr, 0, 0);
      if (code !== 0) throw new ChParseError(code);
      return this.drainBatches();
    }

    const ptr = ch_alloc(bytes.byteLength);
    if (ptr === 0) throw new ChParseError(5);
    try {
      new Uint8Array(memory.buffer, ptr, bytes.byteLength).set(bytes);
      const code = ch_stream_feed!(this.streamPtr, ptr, bytes.byteLength);
      if (code !== 0) throw new ChParseError(code);
      return this.drainBatches();
    } finally {
      ch_free(ptr, bytes.byteLength);
    }
  }

  /**
   * Signal end of input, validate trailer, and return remaining batches
   * (including header-only sides if a kind had no rows).
   */
  finish(): CsvBatch[] {
    this.assertLive();
    requireStreamExports(this.exports);
    const code = this.exports.ch_stream_finish!(this.streamPtr);
    if (code !== 0) throw new ChParseError(code);
    return this.drainBatches();
  }

  /** Cumulative row counts (trailerCount is 0 until a trailer line is seen). */
  stats(): StreamStats {
    this.assertLive();
    requireStreamExports(this.exports);
    const { memory, ch_alloc, ch_free, ch_stream_stats } = this.exports;
    const ptr = ch_alloc(STATS_I32_TRIPLE);
    if (ptr === 0) throw new ChParseError(5);
    try {
      new Uint8Array(memory.buffer, ptr, STATS_I32_TRIPLE).fill(0);
      ch_stream_stats!(this.streamPtr, ptr, ptr + 4, ptr + 8);
      const view = new DataView(memory.buffer, ptr, STATS_I32_TRIPLE);
      return {
        companies: view.getInt32(0, true),
        persons: view.getInt32(4, true),
        trailerCount: view.getInt32(8, true),
      };
    } finally {
      ch_free(ptr, STATS_I32_TRIPLE);
    }
  }

  /** Release the native stream. Further use throws. */
  destroy(): void {
    if (this.destroyed) return;
    requireStreamExports(this.exports);
    this.exports.ch_stream_destroy!(this.streamPtr);
    this.streamPtr = 0;
    this.destroyed = true;
  }

  private assertLive(): void {
    if (this.destroyed || this.streamPtr === 0) {
      throw new Error("ChFixedWidthStream has been destroyed");
    }
  }

  private drainBatches(): CsvBatch[] {
    requireStreamExports(this.exports);
    const { memory, ch_alloc, ch_free, ch_stream_next_batch, ch_csv_batch_free } =
      this.exports;
    const out: CsvBatch[] = [];
    const batchPtr = ch_alloc(BATCH_SIZE);
    if (batchPtr === 0) throw new ChParseError(5);
    try {
      while (true) {
        new Uint8Array(memory.buffer, batchPtr, BATCH_SIZE).fill(0);
        const n = ch_stream_next_batch!(this.streamPtr, batchPtr);
        if (n === 0) break;
        if (n !== 1) throw new ChParseError(n);

        const view = new DataView(memory.buffer, batchPtr, BATCH_SIZE);
        const dataPtr = view.getUint32(0, true);
        const dataLen = view.getUint32(4, true);
        const rowCount = view.getInt32(8, true);
        const kindCode = view.getInt32(12, true);
        const kind: CsvBatchKind =
          kindCode === 1
            ? "persons"
            : kindCode === 2
              ? "disqualifications"
              : kindCode === 3
                ? "exemptions"
                : kindCode === 4
                  ? "variations"
                  : "companies";
        const data = copyBytes(memory, dataPtr, dataLen);
        out.push(makeBatch(kind, data, rowCount));
        ch_csv_batch_free!(batchPtr);
      }
    } finally {
      ch_free(batchPtr, BATCH_SIZE);
    }
    return out;
  }
}
