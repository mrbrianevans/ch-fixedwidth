/** Copy freestanding WASM from the Zig build output into this package. */
import { copyFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const dest = join(root, "ch_fixedwidth.wasm");
const candidates = [
  join(root, "..", "zig-out", "ch_fixedwidth.wasm"),
  join(root, "..", "zig-out", "bin", "ch_fixedwidth.wasm"),
];

const src = candidates.find((p) => existsSync(p));
if (!src) {
  console.error(
    "ch_fixedwidth.wasm not found. From the repo root run:\n  zig build wasm -Doptimize=ReleaseFast",
  );
  process.exit(1);
}

copyFileSync(src, dest);
console.log(`WASM ready: ${dest}`);
