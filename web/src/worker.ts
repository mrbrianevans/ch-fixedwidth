/**
 * Dedicated worker: load WASM, stream File in large batches, post CSV fragments.
 */
import { ChFixedWidthStream, ChParseError } from "@ch-fixedwidth/wasm-ts";
import type { WorkerInMessage, WorkerOutMessage } from "./types.ts";

const DEFAULT_INPUT_BATCH = 8 * 1024 * 1024; // 8 MiB
let cancelled = false;

function post(msg: WorkerOutMessage, transfer?: Transferable[]): void {
  if (transfer?.length) self.postMessage(msg, transfer);
  else self.postMessage(msg);
}

function progressEvery(totalBytes: number): number {
  return Math.max(1, Math.min(32 * 1024 * 1024, Math.floor(totalBytes / 50) || 1));
}

function emitBatches(batches: { kind: "companies" | "persons"; data: Uint8Array; rowCount: number }[]): void {
  for (const batch of batches) {
    const ab = batch.data.buffer.slice(
      batch.data.byteOffset,
      batch.data.byteOffset + batch.data.byteLength,
    );
    post({ type: "batch", kind: batch.kind, data: ab, rowCount: batch.rowCount }, [ab]);
  }
}

async function convert(file: File, wasmUrl: string, inputBatchBytes: number): Promise<void> {
  cancelled = false;
  const started = performance.now();
  const totalBytes = file.size;
  let bytesRead = 0;
  let lastProgressAt = 0;
  const progressStep = progressEvery(totalBytes);

  const stream = await ChFixedWidthStream.create({
    wasmUrl,
    batchRows: 4000,
    batchBytes: 1024 * 1024,
  });

  try {
    const reader = file.stream().getReader();
    const pendingParts: Uint8Array[] = [];
    let pendingLen = 0;

    const flushPending = (): void => {
      if (pendingLen === 0) return;
      let chunk: Uint8Array;
      if (pendingParts.length === 1) {
        chunk = pendingParts[0]!;
      } else {
        chunk = new Uint8Array(pendingLen);
        let offset = 0;
        for (const part of pendingParts) {
          chunk.set(part, offset);
          offset += part.byteLength;
        }
      }
      pendingParts.length = 0;
      pendingLen = 0;
      emitBatches(stream.feed(chunk));
    };

    while (true) {
      if (cancelled) {
        await reader.cancel().catch(() => {});
        post({ type: "cancelled" });
        return;
      }

      const { done, value } = await reader.read();
      if (done) break;
      if (!value?.byteLength) continue;

      pendingParts.push(value);
      pendingLen += value.byteLength;
      bytesRead += value.byteLength;

      if (pendingLen >= inputBatchBytes) flushPending();

      if (bytesRead - lastProgressAt >= progressStep) {
        lastProgressAt = bytesRead;
        const stats = stream.stats();
        post({
          type: "progress",
          bytesRead,
          totalBytes,
          companies: stats.companies,
          persons: stats.persons,
        });
      }
    }

    flushPending();
    emitBatches(stream.finish());

    const stats = stream.stats();
    post({
      type: "progress",
      bytesRead,
      totalBytes,
      companies: stats.companies,
      persons: stats.persons,
    });
    post({
      type: "done",
      companies: stats.companies,
      persons: stats.persons,
      trailerCount: stats.trailerCount,
      bytesRead,
      elapsedMs: performance.now() - started,
    });
  } catch (err) {
    if (cancelled) {
      post({ type: "cancelled" });
      return;
    }
    if (err instanceof ChParseError) {
      post({ type: "error", message: err.message, code: err.code });
    } else {
      post({ type: "error", message: err instanceof Error ? err.message : String(err) });
    }
  } finally {
    stream.destroy();
  }
}

self.onmessage = (ev: MessageEvent<WorkerInMessage>) => {
  const msg = ev.data;
  if (msg.type === "cancel") {
    cancelled = true;
    return;
  }
  if (msg.type === "convert") {
    void convert(msg.file, msg.wasmUrl, msg.inputBatchBytes ?? DEFAULT_INPUT_BATCH);
  }
};
