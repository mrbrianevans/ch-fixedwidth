/**
 * Local Bun CLI — not part of the published package API.
 *
 * Uses the **streaming** WASM API so large files never need to sit fully
 * in linear memory. Input is read in chunks; CSV batches are written to the
 * product-specific filename for each OutputKind.
 *
 *   bun run local/cli.ts <input.dat> [output_dir]
 *
 * Optional env:
 *   WASM_PATH   path to ch_fixedwidth.wasm (default: ../../zig-out/...)
 *   CHUNK_SIZE  input chunk size in bytes (default: 1048576)
 */

import { createWriteStream, type WriteStream } from "node:fs";
import { mkdir } from "node:fs/promises";
import { basename, join } from "node:path";
import {
  ChFixedWidthStream,
  ChParseError,
  outputFileName,
  type CsvBatch,
  type CsvBatchKind,
  type StreamStats,
} from "../src/index.ts";

const repoRoot = join(import.meta.dir, "..", "..");
const defaultWasm = join(repoRoot, "zig-out", "ch_fixedwidth.wasm");

const inputPath = process.argv[2];
const outputDir = process.argv[3] ?? "out";
const wasmPath = process.env.WASM_PATH ?? defaultWasm;
const chunkSize = Number(process.env.CHUNK_SIZE ?? 1_048_576);

if (!inputPath) {
  console.error("Usage: bun run local/cli.ts <input.dat> [output_dir]");
  console.error("Optional: WASM_PATH=... CHUNK_SIZE=1048576");
  process.exit(1);
}

const wasmFile = Bun.file(wasmPath);
if (!(await wasmFile.exists())) {
  console.error(`WASM module not found: ${wasmPath}`);
  console.error("Build it from the repo root: zig build wasm -Doptimize=ReleaseFast");
  process.exit(1);
}

const wasmBytes = await wasmFile.arrayBuffer();
const base = basename(inputPath).replace(/\.[^.]+$/, "");
await mkdir(outputDir, { recursive: true });

const writers = new Map<CsvBatchKind, WriteStream>();

function getWriter(kind: CsvBatchKind): WriteStream {
  let w = writers.get(kind);
  if (!w) {
    const path = join(outputDir, outputFileName(kind, base));
    w = createWriteStream(path);
    writers.set(kind, w);
    console.log(`Writing ${path}`);
  }
  return w;
}

function writeBatch(batch: CsvBatch): Promise<void> {
  const stream = getWriter(batch.kind);
  return new Promise((resolve, reject) => {
    stream.write(batch.data, (err) => (err ? reject(err) : resolve()));
  });
}

async function closeWriters(): Promise<void> {
  await Promise.all(
    [...writers.values()].map(
      (s) =>
        new Promise<void>((resolve, reject) =>
          s.end((err) => (err ? reject(err) : resolve())),
        ),
    ),
  );
}

function formatStats(stats: StreamStats): string {
  const parts: string[] = [];
  if (stats.companies) parts.push(`${stats.companies} companies`);
  if (stats.persons) parts.push(`${stats.persons} persons`);
  if (stats.disqualifications) parts.push(`${stats.disqualifications} disqualifications`);
  if (stats.exemptions) parts.push(`${stats.exemptions} exemptions`);
  if (stats.variations) parts.push(`${stats.variations} variations`);
  if (stats.forms) parts.push(`${stats.forms} forms`);
  if (stats.practitioners) parts.push(`${stats.practitioners} practitioners`);
  if (stats.freeText) parts.push(`${stats.freeText} free text`);
  const detail = parts.length ? parts.join(", ") : "no data rows";
  return `Processed ${stats.trailerCount} trailer records: ${detail} (streaming).`;
}

const stream = await ChFixedWidthStream.create({ wasmBytes });
try {
  const file = Bun.file(inputPath);
  if (typeof file.stream === "function") {
    const reader = file.stream().getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value && value.byteLength > 0) {
        for (const batch of stream.feed(value)) {
          await writeBatch(batch);
        }
      }
    }
  } else {
    const all = new Uint8Array(await file.arrayBuffer());
    for (let off = 0; off < all.byteLength; off += chunkSize) {
      const slice = all.subarray(off, Math.min(off + chunkSize, all.byteLength));
      for (const batch of stream.feed(slice)) {
        await writeBatch(batch);
      }
    }
  }

  for (const batch of stream.finish()) {
    await writeBatch(batch);
  }

  const stats = stream.stats();
  await closeWriters();
  console.log(formatStats(stats));
} catch (err) {
  stream.destroy();
  for (const w of writers.values()) w.destroy();
  if (err instanceof ChParseError) {
    console.error(`Parse failed (${err.code}): ${err.message}`);
    process.exit(1);
  }
  throw err;
} finally {
  stream.destroy();
}
