/** Messages between main thread and converter worker. */

import type { CsvBatchKind, StreamStats } from "@ch-fixedwidth/wasm-ts";

export type { CsvBatchKind, StreamStats };

export type WorkerInMessage =
  | {
      type: "convert";
      file: File;
      wasmUrl: string;
      inputBatchBytes?: number;
    }
  | { type: "cancel" };

export type WorkerOutMessage =
  | {
      type: "progress";
      bytesRead: number;
      totalBytes: number;
      stats: StreamStats;
      /** WASM linear memory size (bytes) for the active instance. */
      wasmMemoryBytes: number;
    }
  | {
      type: "batch";
      kind: CsvBatchKind;
      data: ArrayBuffer;
      rowCount: number;
    }
  | {
      type: "done";
      stats: StreamStats;
      bytesRead: number;
      elapsedMs: number;
      wasmMemoryBytes: number;
    }
  | { type: "error"; message: string; code?: number }
  | { type: "cancelled" };
