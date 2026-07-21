/**
 * Local Bun CLI — not part of the published package API.
 *
 * Uses the **streaming** WASM API so large snapshots never need to sit fully
 * in linear memory. Input is read in chunks; CSV batches are written as they
 * arrive.
 *
 *   bun run local/cli.ts <input.dat> [output_dir]
 *
 * Optional env:
 *   WASM_PATH   path to ch_fixedwidth.wasm (default: ../../zig-out/...)
 *   CHUNK_SIZE  input chunk size in bytes (default: 1048576)
 */

import { createWriteStream } from "node:fs";
import { mkdir } from "node:fs/promises";
import { basename, join } from "node:path";
import {
  ChFixedWidthStream,
  ChParseError,
  type CsvBatch,
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

const companiesPath = join(outputDir, `companies_data_${base}.csv`);
const personsPath = join(outputDir, `persons_data_${base}.csv`);

const companiesOut = createWriteStream(companiesPath);
const personsOut = createWriteStream(personsPath);

function writeBatch(batch: CsvBatch): Promise<void> {
  const stream = batch.kind === "companies" ? companiesOut : personsOut;
  return new Promise((resolve, reject) => {
    stream.write(batch.data, (err) => (err ? reject(err) : resolve()));
  });
}

async function closeWriters(): Promise<void> {
  await Promise.all(
    [companiesOut, personsOut].map(
      (s) =>
        new Promise<void>((resolve, reject) =>
          s.end((err) => (err ? reject(err) : resolve())),
        ),
    ),
  );
}

const stream = await ChFixedWidthStream.create({ wasmBytes });
try {
  const file = Bun.file(inputPath);
  // Prefer streaming read when available; fall back to chunked arrayBuffer for small files.
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

  console.log(
    `Processed ${stats.trailerCount} records: ${stats.companies} companies, ${stats.persons} persons (streaming).`,
  );
  console.log(`Wrote ${companiesPath}`);
  console.log(`Wrote ${personsPath}`);
} catch (err) {
  stream.destroy();
  companiesOut.destroy();
  personsOut.destroy();
  if (err instanceof ChParseError) {
    console.error(`Parse failed (${err.code}): ${err.message}`);
    process.exit(1);
  }
  throw err;
} finally {
  stream.destroy();
}
