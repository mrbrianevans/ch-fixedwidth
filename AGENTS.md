# Agent instructions

Check the `agents/` directory for markdown instructions for this repository.

## Styling

Website styling should always obey `agents/design.md` (The Digital Archive design system).
When creating or changing UI in `web/`, ensure visual language matches that specification: surface hierarchy, no-line sectioning, Newsreader + Work Sans, sharp primary actions, and British English copy.

## Git commits

After each discrete change (or logical unit of work), commit promptly rather than batching unrelated work.

- **Subject:** concise, imperative; focus on why/what landed (not a file list).
- **Body:** first summarise the change in complete sentences; then include the **user’s prompt** that requested the work (quoted or clearly labelled), so the commit records intent.

Example shape:

```
Add agents design system docs

Introduce The Digital Archive design system under agents/ and wire
AGENTS.md so UI work follows it.

Prompt: add an agents design.md file to the repo based on the current
convention for file path, using this design system: …
```

Do not commit secrets, `.env`, or credentials. Do not push unless asked.
