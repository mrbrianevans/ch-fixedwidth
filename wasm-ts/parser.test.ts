/**
 * Package tests (Bun test runner). Library code stays Bun-free; tests load WASM
 * from the monorepo build output via wasmBytes.
 */

import { expect, test } from "bun:test";
import { join } from "node:path";
import {
  ChErrorCode,
  ChFileType,
  ChFixedWidthParser,
  ChFixedWidthStream,
  ChParseError,
  csvBatchKindFromCode,
  outputFileName,
} from "./src/index.ts";

const repoRoot = join(import.meta.dir, "..");
const wasmPath = process.env.WASM_PATH ?? join(repoRoot, "zig-out", "ch_fixedwidth.wasm");
const fixturePath = join(repoRoot, "src", "testdata", "mini_snapshot.dat");
const expectedCompaniesPath = join(repoRoot, "src", "testdata", "expected_companies.csv");
const expectedPersonsPath = join(repoRoot, "src", "testdata", "expected_persons.csv");
const liqPath = join(repoRoot, "src", "testdata", "mini_liquidation.dat");
const expectedLiqForms = join(repoRoot, "src", "testdata", "expected_liq_forms.csv");
const expectedLiqPrac = join(repoRoot, "src", "testdata", "expected_liq_practitioners.csv");
const expectedLiqFt = join(repoRoot, "src", "testdata", "expected_liq_free_text.csv");
const updatePath = join(repoRoot, "src", "testdata", "mini_update.dat");
const expectedUpdateCompanies = join(repoRoot, "src", "testdata", "expected_update_companies.csv");
const expectedUpdatePersons = join(repoRoot, "src", "testdata", "expected_update_persons.csv");
const disqualPath = join(repoRoot, "src", "testdata", "mini_disqual.dat");
const expectedDisqualPersons = join(repoRoot, "src", "testdata", "expected_disqual_persons.csv");
const expectedDisqualifications = join(repoRoot, "src", "testdata", "expected_disqualifications.csv");
const expectedExemptions = join(repoRoot, "src", "testdata", "expected_exemptions.csv");
const expectedVariations = join(repoRoot, "src", "testdata", "expected_variations.csv");

async function wasmBytes(): Promise<ArrayBuffer> {
  const wasmFile = Bun.file(wasmPath);
  if (!(await wasmFile.exists())) {
    throw new Error(
      `WASM not found at ${wasmPath}. Run: zig build wasm -Doptimize=ReleaseFast`,
    );
  }
  return wasmFile.arrayBuffer();
}

test("libraryInfo exposes version, git commit, and formats", async () => {
  const parser = await ChFixedWidthParser.create({ wasmBytes: await wasmBytes() });
  const info = parser.libraryInfo();

  expect(info.version.length).toBeGreaterThan(0);
  expect(info.version).toMatch(/^\d+\.\d+\.\d+/);
  expect(info.gitCommit.length).toBeGreaterThan(0);
  expect(info.gitCommit).not.toBe("");
  // Prefer a real short SHA; allow "unknown" when git was unavailable at build.
  expect(info.gitCommit === "unknown" || /^[0-9a-f]+$/i.test(info.gitCommit)).toBe(true);

  expect(info.formats).toHaveLength(4);
  expect(info.formats[0]).toEqual({
    fileType: ChFileType.OfficersSnapshot,
    productCodes: [195, 216],
    headerIdentifier: "DDDDSNAP",
    description: "officers snapshot",
  });
  expect(info.formats[1]).toEqual({
    fileType: ChFileType.OfficersUpdate,
    productCodes: [198],
    headerIdentifier: "DDDDUPDT",
    description: "officers update",
  });
  expect(info.formats[2]).toEqual({
    fileType: ChFileType.Disqualifications,
    productCodes: [192],
    headerIdentifier: "DISQUALS",
    description: "disqualifications",
  });
  expect(info.formats[3]).toEqual({
    fileType: ChFileType.Liquidation,
    productCodes: [197],
    headerIdentifier: "LIQNFORM",
    description: "liquidations",
  });

  expect(parser.supportedFormats()).toEqual(info.formats);
});

test("parse mini snapshot via WASM (one-shot)", async () => {
  const parser = await ChFixedWidthParser.create({ wasmBytes: await wasmBytes() });
  const input = await Bun.file(fixturePath).text();
  const result = parser.parse(input);

  expect(result.fileType).toBe(ChFileType.OfficersSnapshot);
  expect(result.companies).toBe(2);
  expect(result.persons).toBe(3);
  expect(result.trailerCount).toBe(5);
  expect(result.forms).toBe(0);

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
        else if (batch.kind === "persons") persons += batch.text();
      }
    }
    for (const batch of stream.finish()) {
      if (batch.kind === "companies") companies += batch.text();
      else if (batch.kind === "persons") persons += batch.text();
    }

    const stats = stream.stats();
    expect(stats.fileType).toBe(ChFileType.OfficersSnapshot);
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

test("parse mini liquidation uses forms/practitioners/free_text kinds", async () => {
  const parser = await ChFixedWidthParser.create({ wasmBytes: await wasmBytes() });
  const input = await Bun.file(liqPath).text();
  const result = parser.parse(input);

  expect(result.fileType).toBe(ChFileType.Liquidation);
  expect(result.forms).toBe(8);
  expect(result.practitioners).toBe(7);
  expect(result.freeText).toBe(3);
  expect(result.companies).toBe(0);
  expect(result.trailerCount).toBe(61);

  expect(result.formsCsv).toBe(await Bun.file(expectedLiqForms).text());
  expect(result.practitionersCsv).toBe(await Bun.file(expectedLiqPrac).text());
  expect(result.freeTextCsv).toBe(await Bun.file(expectedLiqFt).text());
});

test("parse mini update (prod 198) uses update person columns", async () => {
  const parser = await ChFixedWidthParser.create({ wasmBytes: await wasmBytes() });
  const input = await Bun.file(updatePath).text();
  const result = parser.parse(input);

  expect(result.fileType).toBe(ChFileType.OfficersUpdate);
  expect(result.companies).toBe(4);
  expect(result.persons).toBe(9);
  expect(result.trailerCount).toBe(13);
  expect(result.warningCount).toBe(0);
  expect(result.companiesCsv).toBe(await Bun.file(expectedUpdateCompanies).text());
  expect(result.personsCsv).toBe(await Bun.file(expectedUpdatePersons).text());
  expect(result.personsCsv.startsWith("Company Number,App Date Origin,Res Date Origin,")).toBe(true);
});

test("parse mini disqualifications (prod 192) emits four kinds", async () => {
  const parser = await ChFixedWidthParser.create({ wasmBytes: await wasmBytes() });
  const input = await Bun.file(disqualPath).text();
  const result = parser.parse(input);

  expect(result.fileType).toBe(ChFileType.Disqualifications);
  expect(result.persons).toBe(3);
  expect(result.disqualifications).toBe(3);
  expect(result.exemptions).toBe(2);
  expect(result.variations).toBe(1);
  expect(result.trailerCount).toBe(9);
  expect(result.personsCsv).toBe(await Bun.file(expectedDisqualPersons).text());
  expect(result.disqualificationsCsv).toBe(await Bun.file(expectedDisqualifications).text());
  expect(result.exemptionsCsv).toBe(await Bun.file(expectedExemptions).text());
  expect(result.variationsCsv).toBe(await Bun.file(expectedVariations).text());
});

test("outputFileName stems match CLI conventions", () => {
  expect(outputFileName("forms", "x")).toBe("forms_data_x.csv");
  expect(outputFileName("free_text", "x")).toBe("free_text_data_x.csv");
  expect(outputFileName("companies", "mini")).toBe("companies_data_mini.csv");
});

test("csvBatchKindFromCode maps known codes and rejects unknown", () => {
  expect(csvBatchKindFromCode(0)).toBe("companies");
  expect(csvBatchKindFromCode(5)).toBe("forms");
  expect(csvBatchKindFromCode(7)).toBe("free_text");
  expect(() => csvBatchKindFromCode(99)).toThrow(/Unknown CSV batch kind code/);
  expect(() => csvBatchKindFromCode(-1)).toThrow(/Unknown CSV batch kind code/);
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
