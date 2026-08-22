# Agent instructions

Check the `agents/` directory for markdown instructions for this repository.

## Product identity

Canonical product name: **ch-fixedwidth**.

| Surface | Naming |
|---------|--------|
| Repository / package scope | `ch-fixedwidth` |
| Zig / C library | `ch_fixedwidth` (snake_case) |
| Native CLI binary | `ch-fixedwidth` (release assets `ch-fixedwidth-*`) |
| TypeScript host | `@ch-fixedwidth/wasm-ts` |
| Browser app | sentence case title (“Companies House bulk converter”); brand **ch-fixedwidth** in kicker/footer |

## Styling

Website styling should always obey `agents/design.md` (ch-fixedwidth converter design system).
When creating or changing UI in `web/`, ensure visual language matches that specification: surface hierarchy, no-line sectioning, Newsreader + Work Sans, sharp primary actions, British English copy, and **converter** (not archive) language.

## Git commits

After each discrete change (or logical unit of work), commit promptly rather than batching unrelated work.

- **Subject:** concise, imperative; focus on why/what landed (not a file list).
- **Body:** summarise the change in complete sentences.

Do not commit secrets, `.env`, or credentials. Do not push unless asked.
