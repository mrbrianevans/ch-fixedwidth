/**
 * Package tests (Bun test runner). Library code stays Bun-free; tests load WASM
 * from the monorepo build output via wasmBytes.
 */

import { expect, test } from "bun:test";
import { join } from "node:path";
import {
  ChErrorCode,
  ChFixedWidthParser,
  ChFixedWidthStream,
  ChParseError,
} from "./src/index.ts";

const repoRoot = join(import.meta.dir, "..");
const wasmPath = process.env.WASM_PATH ?? join(repoRoot, "zig-out", "ch_fixedwidth.wasm");
const fixturePath = join(repoRoot, "src", "testdata", "mini_snapshot.dat");
const expectedCompaniesPath = join(repoRoot, "src", "testdata", "expected_companies.csv");
const expectedPersonsPath = join(repoRoot, "src", "testdata", "expected_persons.csv");

async function wasmBytes(): Promise<ArrayBuffer> {
  const wasmFile = Bun.file(wasmPath);
  if (!(await wasmFile.exists())) {
    throw new Error(
      `WASM not found at ${wasmPath}. Run: zig build wasm -Doptimize=ReleaseFast`,
    );
  }
  return wasmFile.arrayBuffer();
}

test("parse mini snapshot via WASM (one-shot)", async () => {
  const parser = await ChFixedWidthParser.create({ wasmBytes: await wasmBytes() });
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

test("stream mini snapshot with tiny chunks matches expected CSV", async () => {
  const stream = await ChFixedWidthStream.create({
    wasmBytes: await wasmBytes(),
    batchRows: 2,
    batchBytes: 64,
  });
  try {
    const input = new Uint8Array(await Bun.file(fixturePath).arrayBuffer());
    let companies = "";
    let persons = "";

    for (let i = 0; i < input.byteLength; i += 3) {
      const chunk = input.subarray(i, Math.min(i + 3, input.byteLength));
      for (const batch of stream.feed(chunk)) {
        if (batch.kind === "companies") companies += batch.text();
        else persons += batch.text();
      }
    }
    for (const batch of stream.finish()) {
      if (batch.kind === "companies") companies += batch.text();
      else persons += batch.text();
    }

    const stats = stream.stats();
    expect(stats.companies).toBe(2);
    expect(stats.persons).toBe(3);
    expect(stats.trailerCount).toBe(5);

    const expC = await Bun.file(expectedCompaniesPath).text();
    const expP = await Bun.file(expectedPersonsPath).text();
    expect(companies).toBe(expC);
    expect(persons).toBe(expP);
  } finally {
    stream.destroy();
  }
});

test("rejects empty input (one-shot)", async () => {
  const parser = await ChFixedWidthParser.create({ wasmBytes: await wasmBytes() });
  expect(() => parser.parse(new Uint8Array())).toThrow(ChParseError);
  try {
    parser.parse(new Uint8Array());
  } catch (e) {
    expect(e).toBeInstanceOf(ChParseError);
    expect((e as ChParseError).code).toBe(ChErrorCode.InvalidArg);
  }
});

test("rejects missing trailer (one-shot)", async () => {
  const parser = await ChFixedWidthParser.create({ wasmBytes: await wasmBytes() });
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
