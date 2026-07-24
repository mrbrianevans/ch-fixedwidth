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
bun run build    # → dist/
bun run dev      # build + serve dist on :3000
bun run start    # serve existing dist/
bun run smoke    # fixture check against wasm-ts
```

Uses the [`serve`](https://www.npmjs.com/package/serve) package for static hosting.

## GitHub Pages

Push to `master`, `production-ready`, or `site` (or run the **Deploy site to GitHub Pages** workflow manually). CI builds freestanding WASM, then `web/` into `web/dist`, and deploys with Actions.

Enable **Settings → Pages → Source: GitHub Actions** if not already set.
