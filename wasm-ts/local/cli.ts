/**
 * Local Bun CLI — not part of the published package API.
 *
 * Builds on the public `src/` exports and loads WASM from the monorepo
 * `zig-out` (or `WASM_PATH`). Used for manual runs and CI smoke tests.
 *
 *   bun run local/cli.ts <input.dat> [output_dir]
 */

import { mkdir } from "node:fs/promises";
import { basename, join } from "node:path";
import { ChFixedWidthParser, ChParseError } from "../src/index.ts";

const repoRoot = join(import.meta.dir, "..", "..");
const defaultWasm = join(repoRoot, "zig-out", "ch_fixedwidth.wasm");

const inputPath = process.argv[2];
const outputDir = process.argv[3] ?? "out";
const wasmPath = process.env.WASM_PATH ?? defaultWasm;

if (!inputPath) {
  console.error("Usage: bun run local/cli.ts <input.dat> [output_dir]");
  console.error("Optional: WASM_PATH=/path/to/ch_fixedwidth.wasm");
  process.exit(1);
}

const wasmFile = Bun.file(wasmPath);
if (!(await wasmFile.exists())) {
  console.error(`WASM module not found: ${wasmPath}`);
  console.error("Build it from the repo root: zig build wasm -Doptimize=ReleaseFast");
  process.exit(1);
}

const wasmBytes = await wasmFile.arrayBuffer();
const inputBytes = new Uint8Array(await Bun.file(inputPath).arrayBuffer());
const base = basename(inputPath).replace(/\.[^.]+$/, "");

const parser = await ChFixedWidthParser.create({ wasmBytes });
try {
  const result = parser.parse(inputBytes);
  await mkdir(outputDir, { recursive: true });
  const companiesPath = join(outputDir, `companies_data_${base}.csv`);
  const personsPath = join(outputDir, `persons_data_${base}.csv`);
  await Bun.write(companiesPath, result.companiesCsv);
  await Bun.write(personsPath, result.personsCsv);
  console.log(
    `Processed ${result.trailerCount} records: ${result.companies} companies, ${result.persons} persons.`,
  );
  console.log(`Wrote ${companiesPath}`);
  console.log(`Wrote ${personsPath}`);
} catch (err) {
  if (err instanceof ChParseError) {
    console.error(`Parse failed (${err.code}): ${err.message}`);
    process.exit(1);
  }
  throw err;
}
