/**
 * Production build into dist/:
 * - worker.js (fixed name, loaded by main)
 * - index.html + CSS + main JS + hashed WASM
 */
import { copyFileSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
process.chdir(root);

const wasmSrc = join(root, "ch_fixedwidth.wasm");
if (!existsSync(wasmSrc)) {
  const candidates = [
    join(root, "..", "zig-out", "ch_fixedwidth.wasm"),
    join(root, "..", "zig-out", "bin", "ch_fixedwidth.wasm"),
  ];
  const found = candidates.find((p) => existsSync(p));
  if (!found) {
    console.error("ch_fixedwidth.wasm not found. Run: zig build wasm -Doptimize=ReleaseFast");
    process.exit(1);
  }
  copyFileSync(found, wasmSrc);
}

rmSync(join(root, "dist"), { recursive: true, force: true });
mkdirSync(join(root, "dist"), { recursive: true });

const worker = await Bun.build({
  entrypoints: ["./src/worker.ts"],
  outdir: "./dist",
  target: "browser",
  minify: true,
  naming: "worker.[ext]",
});
if (!worker.success) {
  console.error(worker.logs);
  process.exit(1);
}

const app = await Bun.build({
  entrypoints: ["./index.html"],
  outdir: "./dist",
  target: "browser",
  minify: true,
  define: {
    __WORKER_URL__: JSON.stringify("./worker.js"),
  },
});
if (!app.success) {
  console.error(app.logs);
  process.exit(1);
}

console.log("Built dist/:");
for (const out of [...worker.outputs, ...app.outputs]) {
  console.log(`  ${out.path} (${out.size} bytes)`);
}
