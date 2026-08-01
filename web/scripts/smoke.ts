/** Stream mini fixtures through the WASM host and check expected CSVs. */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ChFixedWidthStream, type CsvBatchKind } from "@ch-fixedwidth/wasm-ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const repo = join(root, "..");
const wasmPath = join(root, "ch_fixedwidth.wasm");
const inputPath = join(repo, "src", "testdata", "mini_snapshot.dat");
const expectedCompanies = join(repo, "src", "testdata", "expected_companies.csv");
const expectedPersons = join(repo, "src", "testdata", "expected_persons.csv");
const liqPath = join(repo, "src", "testdata", "mini_liquidation.dat");
const expectedForms = join(repo, "src", "testdata", "expected_liq_forms.csv");
const expectedPrac = join(repo, "src", "testdata", "expected_liq_practitioners.csv");
const expectedFt = join(repo, "src", "testdata", "expected_liq_free_text.csv");

if (!existsSync(wasmPath)) {
  console.error("Missing ch_fixedwidth.wasm — run: bun run copy-wasm");
  process.exit(1);
}

const wasmBytes = readFileSync(wasmPath);
const norm = (s: string) => s.replace(/\r\n/g, "\n");

async function collect(path: string): Promise<Map<CsvBatchKind, Uint8Array[]>> {
  const stream = await ChFixedWidthStream.create({
    wasmBytes,
    batchRows: 100,
    batchBytes: 64 * 1024,
  });
  const input = readFileSync(path);
  const byKind = new Map<CsvBatchKind, Uint8Array[]>();
  const push = (kind: CsvBatchKind, data: Uint8Array) => {
    let list = byKind.get(kind);
    if (!list) {
      list = [];
      byKind.set(kind, list);
    }
    list.push(data);
  };
  const CHUNK = 64;
  for (let i = 0; i < input.byteLength; i += CHUNK) {
    const slice = input.subarray(i, Math.min(i + CHUNK, input.byteLength));
    for (const batch of stream.feed(slice)) push(batch.kind, batch.data);
  }
  for (const batch of stream.finish()) push(batch.kind, batch.data);
  stream.destroy();
  return byKind;
}

function joinUtf8(parts: Uint8Array[] | undefined): string {
  if (!parts?.length) return "";
  return norm(Buffer.concat(parts).toString("utf8"));
}

const snap = await collect(inputPath);
const companiesCsv = joinUtf8(snap.get("companies"));
const personsCsv = joinUtf8(snap.get("persons"));
const expC = norm(readFileSync(expectedCompanies, "utf8"));
const expP = norm(readFileSync(expectedPersons, "utf8"));
if (companiesCsv !== expC || personsCsv !== expP) {
  console.error("Snapshot CSV mismatch against expected fixtures");
  process.exit(1);
}

const liq = await collect(liqPath);
const formsCsv = joinUtf8(liq.get("forms"));
const pracCsv = joinUtf8(liq.get("practitioners"));
const ftCsv = joinUtf8(liq.get("free_text"));
if (
  formsCsv !== norm(readFileSync(expectedForms, "utf8")) ||
  pracCsv !== norm(readFileSync(expectedPrac, "utf8")) ||
  ftCsv !== norm(readFileSync(expectedFt, "utf8"))
) {
  console.error("Liquidation CSV mismatch against expected fixtures");
  process.exit(1);
}
if (liq.has("companies") && joinUtf8(liq.get("companies")).length > 0) {
  console.error("Liquidation must not emit companies batches");
  process.exit(1);
}

console.log("smoke ok: snapshot + liquidation multi-product kinds");
