/** Messages between main thread and converter worker. */

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
      companies: number;
      persons: number;
      /** WASM linear memory size (bytes) for the active instance. */
      wasmMemoryBytes: number;
    }
  | {
      type: "batch";
      kind: "companies" | "persons";
      data: ArrayBuffer;
      rowCount: number;
    }
  | {
      type: "done";
      companies: number;
      persons: number;
      trailerCount: number;
      bytesRead: number;
      elapsedMs: number;
      wasmMemoryBytes: number;
    }
  | { type: "error"; message: string; code?: number }
  | { type: "cancelled" };
