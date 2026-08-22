# Adding a new bulk product (file format)

This guide is for contributors who want to add support for another Companies House (or similar) fixed-width bulk file type to **ch-fixedwidth**.

The library is multi-product: the first **8 bytes** of the file (header magic) select a body parser, which emits one or more **named** CSV outputs (`OutputKind`). Output kinds are **never overloaded** — if a product has a table that is not companies/persons/forms/…, add a new kind rather than reusing an existing name for different columns.

---

## 1. What you must know about the format

Before writing code, gather a complete specification. Incomplete specs are the usual cause of wrong field boundaries and trailer failures.

### 1.1 Identification

| Item | Why it matters |
|------|----------------|
| **8-byte header magic** | Exact ASCII string at the start of the first line (e.g. `DDDDSNAP`). Must be unique among supported products. |
| **Header layout after magic** | Current products share run number (4 chars) + production date (8 chars) for a 20-byte header. Document any divergence. |
| **Product number / name** | For docs, logs, `FileType.productCodes()` / `description()`, and `FileType.displayName()` (e.g. “Prod 199 — …”). Wire into `supported_formats` via `FileType.supportedFormat()`. |

### 1.2 Record model

| Item | Why it matters |
|------|----------------|
| **How body rows are classified** | Type byte position (e.g. officers type at byte 8; disqual type at byte 0), tag prefixes (e.g. liquidation `FM` / `NP`), or other rules. |
| **Per-record fixed widths** | Character offsets and lengths. **Positions are Unicode character offsets**, not always UTF-8 bytes — most rows are ASCII (fast path); multi-byte rows use a character walk. |
| **Variable / chevron fields** | Which fields are `<`-separated, empty consecutive chevrons, max field counts, truncation rules. |
| **Ordering / grouping** | Independent rows (officers) vs form groups that span many lines (liquidation). Grouping prevents naive multi-threaded split. |
| **Encoding** | Plain text; confirm any non-ASCII expectation. |

### 1.3 Trailer and validation

| Item | Why it matters |
|------|----------------|
| **Trailer shape** | e.g. `99999999` + 8-digit count, or `DISQUALS/count1/count2/…/total`. |
| **What the count means** | Companies+persons, per-type counts, raw data lines, form groups only, etc. The parser must validate the same quantity. |
| **Empty files / header-only** | Expected behaviour (error vs empty CSVs with headers only). |

### 1.4 Outputs

| Item | Why it matters |
|------|----------------|
| **Entity types → CSV files** | One entity type per file when schemas differ (reference rule). Map each to an `OutputKind` or introduce new kinds. |
| **Column names and order** | Exact CSV headers (stable for consumers). |
| **CLI filename stems** | Convention: `{stem}_data_<basename>.csv` via `OutputKind.fileStem()` (e.g. `companies_data`, `forms_data`). |

### 1.5 Fixtures

| Item | Why it matters |
|------|----------------|
| **Small complete file** | Real or synthetic `.dat` with header, representative body rows for every record type, valid trailer. Keep under git in `src/testdata/` (avoid multi-GB samples). |
| **Expected CSVs** | Golden files for each output kind (headers + rows). |
| **Optional large sample** | Local-only for perf; gitignored `*.dat` is fine. |

If the format is only partially documented, prefer documenting unknowns in `docs/ProdNNN_….md` and fail closed. Prod 197 is the exception: unknown tags warn and continue (see [stability.md](stability.md)).

---

## 2. Architecture (where work lands)

```text
.dat bytes
    │
    ▼
identifyFileType(magic)  ──► FileType  ──► requireImplemented()
    │
    ▼
stream.Stream   (single body parser: lines → OutputKind batches + trailer check)
    │
    ├─ document.parseDocument   (feed all + concat batches → ParseResult)
    ├─ file_convert sequential  (drain batches → CSV files; URL / stdin / single-thread)
    ├─ C / WASM ch_stream_*     (host drains batches)
    └─ file_convert parallel    (officers only: seek-split workers, own line loop)
```

| Layer | Path | Responsibility |
|-------|------|----------------|
| Pure format | `src/parse.zig` | Magic, `FileType` / `OutputKind`, classify lines, field extractors, CSV formatters, headers |
| Body parser | `src/stream.zig` | Carry buffer, per-kind batches, product line handlers, trailer check |
| One-shot | `src/document.zig` | Thin wrapper: full buffer via `Stream` → `ParseResult` |
| CLI I/O | `src/file_convert.zig` | Open outputs; sequential drains `Stream`; parallel officers path |
| C / WASM | `src/c_api.zig`, `include/ch_fixedwidth.h` | Stable ABI |
| TypeScript | `wasm-ts/src/*` | Layout offsets, kind names, `outputFileName` |
| Browser | `web/` | Optional UX; mostly follows wasm-ts kinds |
| Docs | `docs/`, `README.md`, `CHANGELOG.md` | Spec + status |

Hosts must not invent product logic: they consume `OutputKind` batches / `ParseResult` fields.

---

## 3. Design decisions before coding

### 3.1 Reuse an existing `OutputKind` vs add a new one

- **Reuse** only when the **same semantic entity and compatible columns** already exist (e.g. another officers-like persons table with the same or deliberately extended schema documented as such).
- **Add a new kind** when the table is a different entity or incompatible schema (e.g. forms ≠ companies). Never map “roughly similar” data into the wrong name.

New kinds are **additive minors** in 1.x: append a `CH_OUTPUT_*` id and fill the corresponding slot in the kind-indexed `counts` / `csv` tables (`CH_MAX_OUTPUT_KINDS` = 16). Do not renumber existing ids. Growing the cap, or changing CSV columns for an existing kind, is a **major**. See [stability.md](stability.md).

### 3.2 Sequential vs parallel CLI path

| Body shape | Path |
|------------|------|
| Independent lines; record type alone is enough (officers) | May use seek-split multi-threaded workers (`processParallel`) |
| Multi-line groups, multi-CSV, or order-sensitive state (192, 197) | **Sequential only** (`processFromReader` / `processSingle`); gate in `processOneLocalFile` |

Default for a new product: **sequential** unless you have proven independent line-parallel safety.

### 3.3 Known but not yet implemented

You can add a magic to `identifyFileType` and a `FileType` variant with `isImplemented() == false`. Callers then get `NotImplemented` / `CH_ERR_NOT_IMPLEMENTED` instead of “unsupported header”. Prefer this when the product is announced but the body parser is incomplete.

---

## 4. Implementation checklist

Work roughly top-down. Zig `switch` exhaustiveness will force most call sites to update when you add a `FileType` or `OutputKind` variant.

### Phase A — Spec and fixtures

1. Add `docs/ProdNNN_Name.md` (header, record layouts, trailer, CSV columns, status note).
2. Add `src/testdata/mini_<name>.dat` and `expected_*.csv` for each output kind.
3. Note CLI stems and product magic in the doc front matter.

### Phase B — `src/parse.zig` (format core)

1. Constant for the 8-byte magic.
2. `FileType` variant with stable `i32` value (append; do not renumber existing ABI values).
3. Wire `identifier`, `productCodes`, `description`, `displayName`, `isImplemented`, `outputKinds`, `csvHeader` (and any product-specific header helpers). Append to `FileType.all` and `supported_formats`.
4. `identifyFileType` / header parsing for the new magic.
5. Line classification (`classify…Line` or extend an existing classifier carefully).
6. Field extractors + `format…Row` writers; CSV header string constants.
7. Trailer parser if non-standard.
8. If new `OutputKind`s: extend the enum, `all`, `fileStem`, `displayName`, and every switch on `OutputKind` (document, stream, C, TS).

### Phase C — `src/stream.zig` (body parser — required)

1. Branch in `handleLine` (and `finish` trailer checks) for the product.
2. Per-kind buffers are `Stream.kinds[OutputKind.index()]` — when adding a new `OutputKind`, extend the enum/`all` array; no new named fields on `Stream`.
3. On `finish`, flush headers for `file_type.outputKinds()` and validate trailer counts.
4. Emit rows via `appendFormattedRow` (or the same kindBuf/flush pattern).

### Phase D — `src/document.zig` (one-shot)

Usually **no product-specific code**: `parseDocument` already feeds `Stream` and maps every `OutputKind` into `ParseResult`. Only touch this file if the public `ParseResult` shape changes (new kinds / ABI).

### Phase E — `src/file_convert.zig` (CLI)

1. Sequential path (`processFromReader`) already drains `Stream` batches into `{stem}_{base}.csv` via `OutputKind.fileStem()` — no per-product reader loop.
2. Gate parallel path: if the product is not officers-style independent lines, force `processSingle` in `processOneLocalFile` (same pattern as 192 / 197).
3. Log product name via `FileType.displayName()` (header probe in `processHeaderRow`).
4. If you add officers-style parallel support later, extend `processParallel` / workers (still a separate path from `Stream`).

### Phase F — C ABI and WASM

1. `include/ch_fixedwidth.h`: append `CH_FILE_*` / `CH_OUTPUT_*` (do not renumber). Fill `counts[kind]` / `csv[kind]`; unused slots stay zero/empty.
2. `src/c_api.zig`: keep `extern struct` layouts in sync. **wasm32 layout sizes must match** what TypeScript reads. Compile-time assert `OutputKind.all.len <= CH_MAX_OUTPUT_KINDS`.
3. Rebuild: `zig build test` and `zig build wasm -Doptimize=ReleaseFast`.

### Phase G — TypeScript host (`wasm-ts/`)

1. `ChFileType` / `ChOutputKind` and `csvBatchKindFromCode`.
2. `outputFileStem` / `outputKindsForFileType`; `ChFixedWidthParser.libraryInfo()` / `supportedFormats()` read the WASM catalogue.
3. `ParseResult` / `StreamStats` named aliases and `csvBatchKindFromCode`; kind-indexed `counts[]` already has spare slots up to `CH_MAX_OUTPUT_KINDS`.
4. Local CLI already writes by batch kind; confirm new kinds get correct filenames.
5. Tests against the mini fixture (one-shot and tiny-chunk stream).

### Phase H — Browser (`web/`) — if users convert this product in-browser

1. Usually no product switch is required if batches carry kinds (writers are kind-keyed).
2. Update marketing copy (index, README, manifest) only if the product should be advertised.
3. Optional smoke fixture in `web/scripts/smoke.ts`.

### Phase I — Docs and release notes

1. Root `README.md` product table + Available data / Output sections.
2. `docs/development.md` supported-products table.
3. `CHANGELOG.md` under the next version (note ABI breaks if new kinds/fields).
4. Cross-link the format doc from the README.

---

## 5. Testing requirements

Minimum bar for merging a new product:

| Test | Purpose |
|------|---------|
| `identifyFileType` / `parseHeader` | Magic and header metadata |
| `document.parseDocument` vs golden CSVs | Correct columns and row counts |
| Stream with tiny chunks (1–3 bytes) | Carry buffer and batching |
| Trailer mismatch / missing trailer | Error codes |
| C ABI one-shot or stream smoke | Layout and free paths |
| CLI on mini fixture (optional local) | Filenames and exit code 0 |
| wasm-ts unit test | Host layout stays aligned |

Commands:

```bash
zig build test
zig build wasm -Doptimize=ReleaseFast
cd wasm-ts && bun test
# optional
./zig-out/bin/ch-fixedwidth src/testdata/mini_<name>.dat ./output/manual
```

Correctness beats performance. Optimise only after golden fixtures match.

---

## 6. Conventions and pitfalls

1. **Magic length is fixed at 8** (`header_identifier_len`). Do not invent shorter/longer identifiers without a project-wide change.
2. **Stable integer IDs**: existing `FileType` / `OutputKind` numeric values are part of the public ABI. Only append new values.
3. **Empty kinds**: unused `ParseResult` CSVs should be empty owned slices (or empty strings in TS), counts zero — not omitted fields with garbage.
4. **CSV rows**: include trailing `\n`; respect `max_csv_row_bytes`.
5. **Do not load whole multi-GB files** in WASM one-shot paths in examples; streaming is the supported large-file API.
6. **Reference parsers** under `reference/` are historical officers comparisons; new products belong only in the Zig path unless you deliberately extend references for benchmarking.
7. **British English** in user-facing web copy; format docs may mirror Companies House terminology.

---

## 7. Minimal “happy path” outline (pseudocode)

```text
// parse.zig
FileType.my_product = N
identifier → "MYMAGIC1"
outputKinds → &.{ .foo, .bar }   // existing or new OutputKinds
identifyFileType("MYMAGIC1") → .my_product

// document.zig / stream.zig / file_convert.zig
switch (file_type) {
    …
    .my_product => parseMyProduct(...),
}

// On each body line: classify → format row → append to the correct OutputKind buffer
// On trailer: compare counts → error.TrailerMismatch or success
// CLI: write foo_data_<base>.csv, bar_data_<base>.csv
```

---

## 8. Related reading

- [development.md](development.md) — build, embed, current product table  
- [Prod195_Snapshot.md](Prod195_Snapshot.md), [Prod198_Update.md](Prod198_Update.md), [Prod192_Disqualifications.md](Prod192_Disqualifications.md), [Prod197_Liquidation.md](Prod197_Liquidation.md) — worked examples  
- [DDR-directory-parallelism.md](DDR-directory-parallelism.md) — why directory conversion is sequential-per-file  
- C header: [`include/ch_fixedwidth.h`](../include/ch_fixedwidth.h)  
- Root [README.md](../README.md) — end-user product matrix  

When in doubt: match the structure of the closest existing product (officers for independent company/person lines; disqual for multi-type single-line records; liquidation for multi-line form groups).
