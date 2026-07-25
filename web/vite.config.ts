/**
 * Vite config for the plain HTML/CSS/TS/WASM converter (no UI framework).
 *
 * - Dev: HMR + module workers + WASM URL imports
 * - Build: hashed assets, public/ static PWA files, generated service worker
 */
import { createHash } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import type { Plugin } from "vite";
import { defineConfig } from "vite";

const root = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(root, "..");
const outDir = join(root, "dist");

function readParserVersion(): string {
  const pkgPath = join(repoRoot, "wasm-ts", "package.json");
  if (!existsSync(pkgPath)) return "dev";
  try {
    const pkg = JSON.parse(readFileSync(pkgPath, "utf8")) as { version?: string };
    return pkg.version?.trim() || "dev";
  } catch {
    return "dev";
  }
}

/** Ensure freestanding WASM is at web/ch_fixedwidth.wasm for `?url` imports. */
function ensureWasm(): void {
  const dest = join(root, "ch_fixedwidth.wasm");
  if (existsSync(dest)) return;
  const candidates = [
    join(repoRoot, "zig-out", "ch_fixedwidth.wasm"),
    join(repoRoot, "zig-out", "bin", "ch_fixedwidth.wasm"),
  ];
  const src = candidates.find((p) => existsSync(p));
  if (!src) {
    throw new Error(
      "ch_fixedwidth.wasm not found. From the repo root run:\n  zig build wasm -Doptimize=ReleaseFast",
    );
  }
  copyFileSync(src, dest);
  console.log(`[ch-fixedwidth] WASM ready: ${dest}`);
}

function listFilesRecursive(dir: string, base = dir): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...listFilesRecursive(full, base));
    else out.push(relative(base, full).replaceAll("\\", "/"));
  }
  return out;
}

/** After Vite writes dist/, emit a versioned lean service worker. */
function generateServiceWorker(distPath: string): void {
  const swTemplatePath = join(root, "sw.js");
  if (!existsSync(swTemplatePath)) {
    console.warn("[ch-fixedwidth] sw.js template missing; skipping SW generation");
    return;
  }

  const distFiles = listFilesRecursive(distPath)
    // Never precache the SW itself or source maps.
    .filter((f) => f !== "sw.js" && !f.endsWith(".map"))
    .sort();

  const hash = createHash("sha256");
  for (const f of distFiles) {
    hash.update(f);
    hash.update(readFileSync(join(distPath, f)));
  }
  const cacheName = `ch-fw-${hash.digest("hex").slice(0, 12)}`;

  const precache = ["./", "./index.html", ...distFiles.map((f) => `./${f}`)];
  const seen = new Set<string>();
  const precacheUnique = precache.filter((u) => {
    if (seen.has(u)) return false;
    seen.add(u);
    return true;
  });

  const template = readFileSync(swTemplatePath, "utf8");
  if (!template.includes("__CACHE_NAME__") || !template.includes("__PRECACHE__")) {
    throw new Error("sw.js missing __CACHE_NAME__ / __PRECACHE__ placeholders");
  }

  const swOut = template
    .replaceAll("__CACHE_NAME__", cacheName)
    .replaceAll("__PRECACHE__", JSON.stringify(precacheUnique, null, 2));
  writeFileSync(join(distPath, "sw.js"), swOut);
  console.log(
    `[ch-fixedwidth] sw.js (cache ${cacheName}, ${precacheUnique.length} precache URLs)`,
  );
}

function chFixedwidthPlugin(): Plugin {
  return {
    name: "ch-fixedwidth",
    buildStart() {
      ensureWasm();
    },
    configureServer() {
      try {
        ensureWasm();
      } catch (err) {
        console.warn(String(err));
      }
    },
    closeBundle() {
      if (!existsSync(outDir)) return;
      // Ensure PWA icons referenced by the manifest exist (public/ copies them;
      // verify after emptyOutDir builds).
      const iconsDest = join(outDir, "icons");
      mkdirSync(iconsDest, { recursive: true });
      const required = [
        "icon-192.png",
        "icon-512.png",
        "icon-maskable-192.png",
        "icon-maskable-512.png",
      ];
      for (const f of required) {
        if (!existsSync(join(iconsDest, f))) {
          const src = join(root, "public", "icons", f);
          if (existsSync(src)) copyFileSync(src, join(iconsDest, f));
        }
      }
      generateServiceWorker(outDir);
      console.log(`[ch-fixedwidth] parser version: ${readParserVersion()}`);
    },
  };
}

export default defineConfig({
  root,
  base: "./",
  publicDir: "public",
  plugins: [chFixedwidthPlugin()],
  // Always a quoted string so dev + build both replace every identifier use.
  // Avoid `typeof __PARSER_VERSION__` in app code (esbuild define footgun).
  define: {
    __PARSER_VERSION__: JSON.stringify(readParserVersion() || "dev"),
  },
  worker: {
    format: "es",
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "es2022",
    sourcemap: true,
    assetsInlineLimit: 0,
  },
  server: {
    port: 3000,
    strictPort: false,
  },
  preview: {
    port: 3000,
  },
  // Local monorepo package is TypeScript source — let Vite pre-bundle it.
  optimizeDeps: {
    include: ["@ch-fixedwidth/wasm-ts"],
  },
});
