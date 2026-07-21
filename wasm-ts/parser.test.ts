/**
 * Package tests (Bun test runner). Library code stays Bun-free; tests load WASM
 * from the monorepo build output via wasmBytes.
 */

import { expect, test } from "bun:test";
import { join } from "node:path";
import { ChErrorCode, ChFixedWidthParser, ChParseError } from "./src/index.ts";

const repoRoot = join(import.meta.dir, "..");
const wasmPath = process.env.WASM_PATH ?? join(repoRoot, "zig-out", "ch_fixedwidth.wasm");
const fixturePath = join(repoRoot, "src", "testdata", "mini_snapshot.dat");
const expectedCompaniesPath = join(repoRoot, "src", "testdata", "expected_companies.csv");
const expectedPersonsPath = join(repoRoot, "src", "testdata", "expected_persons.csv");

async function loadParser(): Promise<ChFixedWidthParser> {
  const wasmFile = Bun.file(wasmPath);
  if (!(await wasmFile.exists())) {
    throw new Error(
      `WASM not found at ${wasmPath}. Run: zig build wasm -Doptimize=ReleaseFast`,
    );
  }
  return ChFixedWidthParser.create({ wasmBytes: await wasmFile.arrayBuffer() });
}

test("parse mini snapshot via WASM", async () => {
  const parser = await loadParser();
  const input = await Bun.file(fixturePath).text();
  const result = parser.parse(input);

  expect(result.companies).toBe(2);
  expect(result.persons).toBe(3);
  expect(result.trailerCount).toBe(5);

  const expC = await Bun.file(expectedCompaniesPath).text();
  const expP = await Bun.file(expectedPersonsPath).text();
  expect(result.companiesCsv).toBe(expC);
  expect(result.personsCsv).toBe(expP);
});

test("rejects empty input", async () => {
  const parser = await loadParser();
  expect(() => parser.parse(new Uint8Array())).toThrow(ChParseError);
  try {
    parser.parse(new Uint8Array());
  } catch (e) {
    expect(e).toBeInstanceOf(ChParseError);
    expect((e as ChParseError).code).toBe(ChErrorCode.InvalidArg);
  }
});

test("rejects missing trailer", async () => {
  const parser = await loadParser();
  const bad =
    "DDDDSNAP425720260706\n029052131D                      00010013WGFA LIMITED<\n";
  try {
    parser.parse(bad);
    throw new Error("expected throw");
  } catch (e) {
    expect(e).toBeInstanceOf(ChParseError);
    expect((e as ChParseError).code).toBe(ChErrorCode.MissingTrailer);
  }
});

test("create requires load options", async () => {
  await expect(ChFixedWidthParser.create({} as never)).rejects.toThrow(/LoadOptions/);
});
