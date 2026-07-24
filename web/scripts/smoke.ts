/** Stream mini_snapshot.dat through the WASM host and check expected CSVs. */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ChFixedWidthStream } from "@ch-fixedwidth/wasm-ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const repo = join(root, "..");
const wasmPath = join(root, "ch_fixedwidth.wasm");
const inputPath = join(repo, "src", "testdata", "mini_snapshot.dat");
const expectedCompanies = join(repo, "src", "testdata", "expected_companies.csv");
const expectedPersons = join(repo, "src", "testdata", "expected_persons.csv");

if (!existsSync(wasmPath)) {
  console.error("Missing ch_fixedwidth.wasm — run: bun run copy-wasm");
  process.exit(1);
}

const stream = await ChFixedWidthStream.create({
  wasmBytes: readFileSync(wasmPath),
  batchRows: 100,
  batchBytes: 64 * 1024,
});

const input = readFileSync(inputPath);
const companies: Uint8Array[] = [];
const persons: Uint8Array[] = [];

const CHUNK = 64;
for (let i = 0; i < input.byteLength; i += CHUNK) {
  const slice = input.subarray(i, Math.min(i + CHUNK, input.byteLength));
  for (const batch of stream.feed(slice)) {
    (batch.kind === "companies" ? companies : persons).push(batch.data);
  }
}
for (const batch of stream.finish()) {
  (batch.kind === "companies" ? companies : persons).push(batch.data);
}
const stats = stream.stats();
stream.destroy();

const norm = (s: string) => s.replace(/\r\n/g, "\n");
const companiesCsv = norm(Buffer.concat(companies).toString("utf8"));
const personsCsv = norm(Buffer.concat(persons).toString("utf8"));
const expC = norm(readFileSync(expectedCompanies, "utf8"));
const expP = norm(readFileSync(expectedPersons, "utf8"));

if (companiesCsv !== expC || personsCsv !== expP) {
  console.error("CSV mismatch against expected fixtures");
  process.exit(1);
}

console.log(
  `smoke ok: companies=${stats.companies} persons=${stats.persons} trailer=${stats.trailerCount}`,
);
