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
