/**
 * Companies House Product 195/216 snapshot parser (Bun / TypeScript).
 *
 * Streaming read via Bun.file().stream(); streaming write via file writers.
 * Field positions match parser.go / Python character offsets.
 * Bun APIs where available; otherwise Node built-ins (e.g. fs.mkdir).
 *
 * Usage: bun run parser.ts <input.dat> <output_folder>
 */

import { mkdir } from "node:fs/promises";

const SNAPSHOT_HEADER = "DDDDSNAP";
const TRAILER_ID = "99999999";
const COMPANY_TYPE = "1";
const PERSON_TYPE = "2";
/** Flush CSV line buffers after this many rows. */
const WRITE_BATCH = 16_384;

const COMPANIES_HEADER =
  "Company Number,Company Status,Number of Officers,Company Name\n";
const PERSONS_HEADER =
  "Company Number,App Date Origin,Appointment Type,Person number,Corporate indicator,Appointment Date,Resignation Date,Person Postcode,Partial Date of Birth,Full Date of Birth,Title,Forenames,Surname,Honours,Care_of,PO_box,Address line 1,Address line 2,Post_town,County,Country,Occupation,Nationality,Resident Country\n";

function slice(s: string, start: number, end: number): string {
  if (end > s.length) end = s.length;
  if (start >= end) return "";
  return s.slice(start, end);
}

function parseIntField(s: string): number {
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c >= 48 && c <= 57) n = n * 10 + (c - 48);
  }
  return n;
}

function csvField(s: string): string {
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c === 44 || c === 34 || c === 10 || c === 13) {
      return `"${s.replaceAll('"', '""')}"`;
    }
  }
  return s;
}

function appendField(parts: string[], s: string) {
  parts.push(csvField(s));
}

/** Build one company CSV line (including trailing newline). */
function companyCsvLine(row: string): string {
  const nameLength = parseIntField(slice(row, 36, 40));
  let name = slice(row, 40, 40 + nameLength - 1);
  if (name.endsWith(" ")) {
    let end = name.length;
    while (end > 0 && name.charCodeAt(end - 1) === 32) end--;
    name = name.slice(0, end);
  }
  const parts: string[] = [];
  appendField(parts, slice(row, 0, 8));
  parts.push(",");
  appendField(parts, slice(row, 9, 10));
  parts.push(",");
  parts.push(String(parseIntField(slice(row, 32, 36))));
  parts.push(",");
  appendField(parts, name);
  parts.push("\n");
  return parts.join("");
}

/** Build one person CSV line (including trailing newline). */
function personCsvLine(row: string): string {
  const varLen = parseIntField(slice(row, 72, 76));
  const variable = slice(row, 76, 76 + varLen);
  const vparts = variable.split("<");

  const parts: string[] = [];
  const fixed = [
    slice(row, 0, 8),
    slice(row, 9, 10),
    slice(row, 10, 12),
    slice(row, 12, 24),
    slice(row, 24, 25),
    slice(row, 32, 40),
    slice(row, 40, 48),
    slice(row, 48, 56),
    slice(row, 56, 64),
    slice(row, 64, 72),
  ];
  for (let i = 0; i < fixed.length; i++) {
    if (i > 0) parts.push(",");
    appendField(parts, fixed[i]!);
  }
  for (let i = 0; i < 14; i++) {
    parts.push(",");
    appendField(parts, i < vparts.length ? vparts[i]! : "");
  }
  parts.push("\n");
  return parts.join("");
}

async function* readLines(
  stream: ReadableStream<Uint8Array>,
): AsyncGenerator<string> {
  const reader = stream.getReader();
  const decoder = new TextDecoder("utf-8");
  let buffer = "";

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let nl: number;
      while ((nl = buffer.indexOf("\n")) >= 0) {
        let line = buffer.slice(0, nl);
        buffer = buffer.slice(nl + 1);
        if (line.endsWith("\r")) line = line.slice(0, -1);
        yield line;
      }
    }
    buffer += decoder.decode();
    if (buffer.length > 0) {
      if (buffer.endsWith("\r")) buffer = buffer.slice(0, -1);
      yield buffer;
    }
  } finally {
    reader.releaseLock();
  }
}

/** Batches lines as a string[] and flushes with a single join+write. */
class BatchWriter {
  private lines: string[] = [];
  constructor(
    private writer: ReturnType<ReturnType<typeof Bun.file>["writer"]>,
    private batchSize: number,
  ) {}

  writeLine(line: string) {
    this.lines.push(line);
    if (this.lines.length >= this.batchSize) this.flush();
  }

  flush() {
    if (this.lines.length === 0) return;
    this.writer.write(this.lines.join(""));
    this.lines = [];
  }

  async end() {
    this.flush();
    await this.writer.end();
  }
}

async function parseSnapshot(
  inputPath: string,
  outputFolder: string,
): Promise<number> {
  const baseName = inputPath.replace(/^.*[\\/]/, "").replace(/\.[^.]+$/, "");
  const companiesPath = `${outputFolder}/companies_data_${baseName}.csv`;
  const personsPath = `${outputFolder}/persons_data_${baseName}.csv`;

  console.log(`Saving companies data to ${companiesPath}`);
  console.log(`Saving persons data to ${personsPath}`);

  await mkdir(outputFolder, { recursive: true });

  const companies = new BatchWriter(
    Bun.file(companiesPath).writer(),
    WRITE_BATCH,
  );
  const persons = new BatchWriter(Bun.file(personsPath).writer(), WRITE_BATCH);
  companies.writeLine(COMPANIES_HEADER);
  persons.writeLine(PERSONS_HEADER);

  const input = Bun.file(inputPath);
  let companiesN = 0;
  let personsN = 0;
  let rowNum = 0;

  for await (const row of readLines(input.stream())) {
    if (rowNum === 0) {
      if (!row.startsWith(SNAPSHOT_HEADER)) {
        console.log(
          `Error: unsupported file type from header: '${row.slice(0, 8)}'`,
        );
        return 1;
      }
      console.log(
        `Processing snapshot file with run number ${row.slice(8, 12)} from date ${row.slice(12, 20)}`,
      );
      rowNum++;
      continue;
    }

    if (row.startsWith(TRAILER_ID)) {
      await companies.end();
      await persons.end();
      const expected = parseIntField(row.slice(8, 16));
      const got = companiesN + personsN;
      if (expected !== got) {
        console.log(`ERROR: Processed ${got} records out of ${expected}`);
        return 1;
      }
      console.log(
        `Processed ${got} records: ${companiesN} companies, ${personsN} persons.`,
      );
      return 0;
    }

    if (row.length <= 8) {
      rowNum++;
      continue;
    }

    const recordType = row[8];
    if (recordType === COMPANY_TYPE) {
      companies.writeLine(companyCsvLine(row));
      companiesN++;
    } else if (recordType === PERSON_TYPE) {
      persons.writeLine(personCsvLine(row));
      personsN++;
    }
    rowNum++;
  }

  console.log("ERROR: No trailer record found.");
  await companies.end();
  await persons.end();
  return 1;
}

async function main() {
  if (Bun.argv.length < 4) {
    console.log("Usage: bun run parser.ts <input_file> <output_folder>");
    process.exit(1);
  }
  const code = await parseSnapshot(Bun.argv[2]!, Bun.argv[3]!);
  process.exit(code);
}

main();
