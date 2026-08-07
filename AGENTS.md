# Agent instructions

Check the `agents/` directory for markdown instructions for this repository.

## Product identity

Canonical product name: **ch-fixedwidth**.

| Surface | Naming |
|---------|--------|
| Repository / package scope | `ch-fixedwidth` |
| Zig / C library | `ch_fixedwidth` (snake_case) |
| Native CLI binary | `parser` (release assets `parser-*`) |
| TypeScript host | `@ch-fixedwidth/wasm-ts` |
| Browser app | sentence case title (“Companies House bulk converter”); brand **ch-fixedwidth** in kicker/footer |

## Styling

Website styling should always obey `agents/design.md` (ch-fixedwidth converter design system).
When creating or changing UI in `web/`, ensure visual language matches that specification: surface hierarchy, no-line sectioning, Newsreader + Work Sans, sharp primary actions, British English copy, and **converter** (not archive) language.

## Git commits

After each discrete change (or logical unit of work), commit promptly rather than batching unrelated work.

- **Subject:** concise, imperative; focus on why/what landed (not a file list).
- **Body:** first summarise the change in complete sentences; then include the **user’s prompt** that requested the work (quoted or clearly labelled), so the commit records intent.

Example shape:

```
Add agents design system docs

Introduce the converter design system under agents/ and wire
AGENTS.md so UI work follows it.

Prompt: add an agents design.md file to the repo based on the current
convention for file path, using this design system: …
```

Do not commit secrets, `.env`, or credentials. Do not push unless asked.
