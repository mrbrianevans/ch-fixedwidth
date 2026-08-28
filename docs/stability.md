# Stability (0.2 toward 1.x)

This is the freeze table for the public surfaces of **ch-fixedwidth**.
`v1.0.0` will lock it; `0.2.0` is the last breaking 0.x cut.

Decisions: [issue #8](https://github.com/mrbrianevans/ch-fixedwidth/issues/8).

## What is frozen in 1.x

| Surface | Frozen |
|---------|--------|
| CLI binary name | `ch-fixedwidth` |
| Invocation | `ch-fixedwidth [-workers N] -o DIR <input>` plus `--help` / `--version` |
| Input kinds | file, directory of `*.dat`, `http(s)://`, `-` (stdin) |
| Output | directory given with `-o` (created if missing; no cwd default) |
| Filenames | `{stem}_data_{basename}.csv` (stdin basename `stdin`) |
| CSV headers | exact strings per **product** (198 persons ≠ 195/216 persons) |
| Success | exit 0 and trailer counts match |
| Failure | exit 1 (code 1 remains the generic failure) |
| C / WASM integers | `CH_FILE_*`, `CH_OUTPUT_*`, `CH_ERR_*` — append-only |
| C / WASM structs | kind-indexed `ChParseResult` / `ChStreamStats` (`CH_MAX_OUTPUT_KINDS` = 16) |
| TypeScript host | `@ch-fixedwidth/wasm-ts` layout and named aliases for kinds 0–7 |

New bulk products in 1.x are **minors**: append a `CH_OUTPUT_*` / `CH_FILE_*` id and fill an unused slot. Hosts that do not know the id ignore the slot.

## What is a major after 1.0

- Renaming the binary or the `-o DIR` CLI form
- Renaming or reordering CSV columns for an existing product/kind
- Renumbering `CH_FILE_*` / `CH_OUTPUT_*` / `CH_ERR_*`
- Growing `CH_MAX_OUTPUT_KINDS` or changing `ChParseResult` / `ChStreamStats` field order
- Overloading an output kind (e.g. putting liquidation rows in `companies`)

## Not frozen

- Browser converter UX (it consumes wasm-ts)
- npm publish of `@ch-fixedwidth/wasm-ts` (package stays private until a later publish against this ABI)
- Zig module internals (`ParseResult` arrays, `Stream` fields)
- `--help` wording (flags and the `-o DIR` form stay)

## Honesty rules

| Event | Behaviour |
|-------|-----------|
| Officers unknown type byte, extra bytes after trailer, unknown records on non-197 products | Fail (exit 1 / `CH_ERR_UNKNOWN_RECORD` or `CH_ERR_STREAM_STATE`) |
| Prod 197 unknown tag | Warn (tag + form number + company number). Continue. Count toward trailer. Exit 0 if trailer matches. |
| Field overflow (all products) | Fail (`CH_ERR_FIELD_OVERFLOW` / `CH_ERR_RECORD_LIMIT`) — no truncated cells |
| Prod 198 trailing chevron fillers | Omitted while proven empty; non-empty filler fails the parse |
| Prod 197 per-form V4.6d sequence | Not validated. This is not a complete sequence parser. |

CLI warnings go to stderr. C/WASM/TS expose `warning_count` and `last_warning` on the result/stats. Exit 0 does not mean every 197 tag was captured.

## CLI defaults on failure

- A failed run leaves whatever CSVs were already written.
- Directory input processes every `.dat`; any hard failure makes the process exit 1. 197 warnings on one file do not skip the rest.

## Adding a product

See [adding-a-product.md](adding-a-product.md). New kinds must fit in `CH_MAX_OUTPUT_KINDS`. Exceeding that cap is a major.
