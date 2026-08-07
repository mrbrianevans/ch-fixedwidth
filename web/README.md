# ch-fixedwidth browser converter

Convert Companies House fixed-width bulk data (products 195 / 216 / 198 / 192 / 197, `.dat`) to tabular CSV in the browser.

- Zig WASM via local `@ch-fixedwidth/wasm-ts`
- Streams input (`File.stream`, 8 MiB batches) in a Worker
- Named CSV outputs per product (`companies_data_*`, `forms_data_*`, …) — never overloaded kinds
- Chromium: write CSVs to a chosen folder; multi-file batch queue (one file at a time, retry failed)
- Other browsers: single file; CSVs as in-memory download links (click to save)
- Memory estimate during conversion (JS heap when available + WASM linear memory)
- **Vite** for dev (HMR) and production builds — plain HTML / CSS / TypeScript (no UI framework)
- Visual language: [agents/design.md](../agents/design.md) (converter system)

## Setup

```bash
# repo root — once, or after Zig changes
zig build wasm -Doptimize=ReleaseFast

cd web
bun install
```

## Develop & build

```bash
bun run dev      # Vite dev server (default :3000), hot reload
bun run build    # → dist/ (hashed assets + PWA service worker)
bun run preview  # serve production build
bun run start    # preview on :3000
bun run smoke    # fixture check against wasm-ts
bun run icons    # regenerate PNG icons from SVG (needs ffmpeg on PATH)
```

WASM is resolved from `ch_fixedwidth.wasm` (copied/refreshed from `zig-out` when that build is newer). After Zig export changes, run `zig build wasm -Doptimize=ReleaseFast` from the repo root (or `bun run copy-wasm`).

The local `@ch-fixedwidth/wasm-ts` package is **not** pre-bundled in dev (`optimizeDeps.exclude`), so API changes like `libraryInfo()` show up without a stale Vite dep cache. If the formats list or footer still looks old, stop the dev server, delete `web/node_modules/.vite`, and restart.

## Progressive Web App

The site is a static PWA (no backend). Installable offline after first visit.

| Piece | Role |
| --- | --- |
| `public/manifest.webmanifest` | Name, `standalone` display, theme, 192/512 (+ maskable) icons |
| `sw.js` (generated at build) | Lean versioned service worker; Vite plugin injects cache name + precache list |
| `public/icons/` | Chevron SVG source + PNG sizes (favicon, Apple touch, maskable) |

Progressive enhancement: conversion works without the service worker or manifest. The SW only caches same-origin static assets. Cache names are content-hashed at build time so deploys update reliably.

Icon pipeline: edit `public/icons/icon.svg` / `icon-maskable.svg`, then `bun run icons`.

## GitHub Pages

Push to `master`, `production-ready`, or `site` (or run the **Deploy site to GitHub Pages** workflow manually). CI builds freestanding WASM, then `web/` into `web/dist`, and deploys with Actions.

Enable **Settings → Pages → Source: GitHub Actions** if not already set.

Vite uses `base: './'` so assets resolve on project pages (`/repo/`).
