# Contributing

Thank you for considering a change to **ch-fixedwidth**.

## Development

Build, test, and embedding notes: [docs/development.md](docs/development.md).

Adding another Companies House bulk product: [docs/adding-a-product.md](docs/adding-a-product.md).

Public ABI and 1.x freeze rules: [docs/stability.md](docs/stability.md).

## Practical bar

- `zig fmt --check .`
- `zig build test`
- `zig build wasm -Doptimize=ReleaseSafe` then `cd wasm-ts && bun test` if you touch C/WASM/TS
- Do not commit bulk `Prod*.dat` / `Prod*.txt` dumps (they are gitignored)
- User-facing web copy is British English; follow `agents/design.md` for `web/` UI
