/**
 * Production build into dist/:
 * - worker.js (fixed name, loaded by main)
 * - index.html + CSS + main JS + hashed WASM
 * - icons (PWA install), versioned service worker
 *
 * Bun's HTML bundler hashes favicons + the manifest linked from index.html.
 * Manifest icon entries stay at stable ./icons/*.png paths; we copy those here.
 */
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, relative } from "node:path";
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

const dist = join(root, "dist");
const iconsSrc = join(root, "icons");
const iconsDest = join(dist, "icons");
mkdirSync(iconsDest, { recursive: true });

// Stable paths referenced by manifest.webmanifest (not rewritten by Bun).
const pwaIconFiles = [
  "icon-192.png",
  "icon-512.png",
  "icon-maskable-192.png",
  "icon-maskable-512.png",
];
for (const f of pwaIconFiles) {
  const src = join(iconsSrc, f);
  if (!existsSync(src)) {
    console.error(`Missing ${f}. Run: bun run icons`);
    process.exit(1);
  }
  copyFileSync(src, join(iconsDest, f));
}

// Versioned service worker: cache name + precache list from dist contents.
function listFilesRecursive(dir: string, base = dir): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      out.push(...listFilesRecursive(full, base));
    } else {
      out.push(relative(base, full).replaceAll("\\", "/"));
    }
  }
  return out;
}

const distFiles = listFilesRecursive(dist)
  // Browser manages SW script updates; never precache sw.js.
  .filter((f) => f !== "sw.js")
  .sort();

const hash = createHash("sha256");
for (const f of distFiles) {
  hash.update(f);
  hash.update(readFileSync(join(dist, f)));
}
const cacheVersion = hash.digest("hex").slice(0, 12);
const cacheName = `ch-fw-${cacheVersion}`;

const precache = ["./", "./index.html", ...distFiles.map((f) => `./${f}`)];
const seen = new Set<string>();
const precacheUnique = precache.filter((u) => {
  if (seen.has(u)) return false;
  seen.add(u);
  return true;
});

const swTemplate = readFileSync(join(root, "sw.js"), "utf8");
if (!swTemplate.includes("__CACHE_NAME__") || !swTemplate.includes("__PRECACHE__")) {
  console.error("sw.js missing build placeholders __CACHE_NAME__ / __PRECACHE__");
  process.exit(1);
}
const swOut = swTemplate
  .replaceAll("__CACHE_NAME__", cacheName)
  .replaceAll("__PRECACHE__", JSON.stringify(precacheUnique, null, 2));
writeFileSync(join(dist, "sw.js"), swOut);

console.log("Built dist/:");
for (const out of [...worker.outputs, ...app.outputs]) {
  console.log(`  ${out.path} (${out.size} bytes)`);
}
console.log(`  icons/ (${pwaIconFiles.length} PWA icons)`);
console.log(`  sw.js (cache ${cacheName}, ${precacheUnique.length} precache URLs)`);
