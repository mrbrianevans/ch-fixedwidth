/**
 * Smoke test against the repo mini fixture (run with `bun test` or `bun run test.ts`).
 */

import { expect, test } from "bun:test";
import { join } from "node:path";
import { ChErrorCode, ChFixedWidthParser, ChParseError } from "./src/index.ts";

const repoRoot = join(import.meta.dir, "..");
const fixturePath = join(repoRoot, "src", "testdata", "mini_snapshot.dat");
const expectedCompaniesPath = join(repoRoot, "src", "testdata", "expected_companies.csv");
const expectedPersonsPath = join(repoRoot, "src", "testdata", "expected_persons.csv");

test("parse mini snapshot via WASM", async () => {
  const parser = await ChFixedWidthParser.create();
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
  const parser = await ChFixedWidthParser.create();
  expect(() => parser.parse(new Uint8Array())).toThrow(ChParseError);
  try {
    parser.parse(new Uint8Array());
  } catch (e) {
    expect(e).toBeInstanceOf(ChParseError);
    expect((e as ChParseError).code).toBe(ChErrorCode.InvalidArg);
  }
});

test("rejects missing trailer", async () => {
  const parser = await ChFixedWidthParser.create();
  const bad = "DDDDSNAP425720260706\n029052131D                      00010013WGFA LIMITED<\n";
  try {
    parser.parse(bad);
    throw new Error("expected throw");
  } catch (e) {
    expect(e).toBeInstanceOf(ChParseError);
    expect((e as ChParseError).code).toBe(ChErrorCode.MissingTrailer);
  }
});
