/**
 * CLI: parse a snapshot file via WASM and write CSV outputs.
 *
 *   bun run cli.ts <input.dat> [output_dir]
 *
 * Default output_dir is ./out
 */

import { mkdir } from "node:fs/promises";
import { basename, join } from "node:path";
import { ChFixedWidthParser, ChParseError } from "./src/index.ts";

const inputPath = process.argv[2];
const outputDir = process.argv[3] ?? "out";

if (!inputPath) {
  console.error("Usage: bun run cli.ts <input.dat> [output_dir]");
  process.exit(1);
}

const base = basename(inputPath).replace(/\.[^.]+$/, "");
const bytes = new Uint8Array(await Bun.file(inputPath).arrayBuffer());

const parser = await ChFixedWidthParser.create();
try {
  const result = parser.parse(bytes);
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
