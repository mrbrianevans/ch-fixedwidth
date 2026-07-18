/**
 * Companies House Product 195/216 snapshot parser (Bun / TypeScript).
 *
 * Streaming read via Bun.file().stream(); streaming write via file writers.
 * Field positions are string indices matching Python/Go character offsets for
 * this UTF-8 BMP dataset.
 *
 * Usage: bun run parser.ts <input.dat> <output_folder>
 */

const SNAPSHOT_HEADER = "DDDDSNAP";
const TRAILER_ID = "99999999";
const COMPANY_TYPE = "1";
const PERSON_TYPE = "2";

const COMPANIES_HEADER =
  "Company Number,Company Status,Number of Officers,Company Name\n";
const PERSONS_HEADER =
  "Company Number,App Date Origin,Appointment Type,Person number,Corporate indicator,Appointment Date,Resignation Date,Person Postcode,Partial Date of Birth,Full Date of Birth,Title,Forenames,Surname,Honours,Care_of,PO_box,Address line 1,Address line 2,Post_town,County,Country,Occupation,Nationality,Resident Country\n";

function slice(s: string, start: number, end: number): string {
  if (start < 0) start = 0;
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

function needsCsvQuote(s: string): boolean {
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c === 44 || c === 34 || c === 10 || c === 13) return true;
  }
  return false;
}

function csvField(s: string): string {
  if (!needsCsvQuote(s)) return s;
  return `"${s.replaceAll('"', '""')}"`;
}

function csvRow(fields: string[]): string {
  return fields.map(csvField).join(",") + "\n";
}

function parseCompany(row: string): string[] {
  const nameLength = parseIntField(slice(row, 36, 40));
  let name = slice(row, 40, 40 + nameLength - 1);
  if (name.endsWith(" ")) name = name.replace(/ +$/, "");
  return [
    slice(row, 0, 8),
    slice(row, 9, 10),
    String(parseIntField(slice(row, 32, 36))),
    name,
  ];
}

function parsePerson(row: string): string[] {
  const varLen = parseIntField(slice(row, 72, 76));
  const variable = slice(row, 76, 76 + varLen);
  const parts = variable.split("<");
  const fields: string[] = new Array(14).fill("");
  for (let i = 0; i < 14 && i < parts.length; i++) fields[i] = parts[i]!;

  return [
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
    ...fields,
  ];
}

/** Async line iterator over a binary stream (UTF-8). */
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

async function ensureDir(dir: string): Promise<void> {
  const { mkdir } = await import("node:fs/promises");
  await mkdir(dir, { recursive: true });
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

  await ensureDir(outputFolder);

  // Bun filesystem: open writers on output paths (creates/truncates files).
  const companiesWriter = Bun.file(companiesPath).writer();
  const personsWriter = Bun.file(personsPath).writer();
  companiesWriter.write(COMPANIES_HEADER);
  personsWriter.write(PERSONS_HEADER);

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
      await companiesWriter.end();
      await personsWriter.end();
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
      companiesWriter.write(csvRow(parseCompany(row)));
      companiesN++;
    } else if (recordType === PERSON_TYPE) {
      personsWriter.write(csvRow(parsePerson(row)));
      personsN++;
    }
    rowNum++;
  }

  console.log("ERROR: No trailer record found.");
  await companiesWriter.end();
  await personsWriter.end();
  return 1;
}

async function main() {
  if (Bun.argv.length < 4) {
    console.log("Usage: bun run parser.ts <input_file> <output_folder>");
    process.exit(1);
  }
  const inputPath = Bun.argv[2]!;
  const outputFolder = Bun.argv[3]!;
  const code = await parseSnapshot(inputPath, outputFolder);
  process.exit(code);
}

main();
