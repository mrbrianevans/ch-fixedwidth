# Browser converter

Convert Companies House bulk appointment snapshots (products 195 / 216) to CSV in the browser.

- Zig WASM via local `@ch-fixedwidth/wasm-ts`
- Streams input (`File.stream`, 8 MiB batches) in a Worker
- Chromium: write both CSVs to a chosen folder
- Other browsers: in-memory download fallback

## Setup

```bash
# repo root — once, or after Zig changes
zig build wasm -Doptimize=ReleaseFast

cd web
bun install
```

## Build & serve

```bash
bun run build    # → dist/ (includes PWA manifest + service worker)
bun run dev      # build + serve dist on :3000
bun run start    # serve existing dist/
bun run smoke    # fixture check against wasm-ts
bun run icons    # regenerate PNG icons from SVG (needs ffmpeg on PATH)
```

Uses the [`serve`](https://www.npmjs.com/package/serve) package for static hosting.

## Progressive Web App

The site is a static PWA (no backend). Installable offline after first visit.

| Piece | Role |
| --- | --- |
| `manifest.webmanifest` | Name, `standalone` display, theme, 192/512 (+ maskable) icons |
| `sw.js` | Lean versioned service worker; build injects cache name + precache list |
| `icons/` | Chevron SVG source + PNG sizes (favicon, Apple touch, maskable) |

Progressive enhancement: conversion works without the service worker or manifest. The SW only caches same-origin static assets (HTML/CSS/JS/WASM/worker/icons). Cache names are content-hashed at build time so deploys update reliably.

Icon pipeline: edit `icons/icon.svg` / `icons/icon-maskable.svg`, then `bun run icons` (resvg → 1024 master, ffmpeg → sizes).

## GitHub Pages

Push to `master`, `production-ready`, or `site` (or run the **Deploy site to GitHub Pages** workflow manually). CI builds freestanding WASM, then `web/` into `web/dist`, and deploys with Actions.

Enable **Settings → Pages → Source: GitHub Actions** if not already set.
