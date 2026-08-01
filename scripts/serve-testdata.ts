/**
 * Minimal static file server for CLI remote-URL smoke tests.
 *
 * Serves `src/testdata/` (and optionally other roots) so the Zig CLI can
 * stream-download fixtures from http://127.0.0.1:PORT/...
 *
 * Usage:
 *   bun scripts/serve-testdata.ts
 *   bun scripts/serve-testdata.ts --port 9000
 *   bun scripts/serve-testdata.ts --root src/testdata --port 8765
 *
 * Default: root = src/testdata, port = 8765
 */

import { join, resolve, relative, sep } from "node:path";
import { existsSync, statSync } from "node:fs";

const args = process.argv.slice(2);

function flagValue(name: string, fallback: string): string {
  const idx = args.indexOf(name);
  if (idx >= 0 && args[idx + 1]) return args[idx + 1]!;
  return fallback;
}

const port = Number.parseInt(flagValue("--port", "8765"), 10);
const rootDir = resolve(flagValue("--root", "src/testdata"));

if (!existsSync(rootDir) || !statSync(rootDir).isDirectory()) {
  console.error(`Root directory not found or not a directory: ${rootDir}`);
  process.exit(1);
}

function safeJoin(root: string, urlPath: string): string | null {
  // Strip query/hash; decode percent-encoding.
  const raw = urlPath.split("?")[0]!.split("#")[0]!;
  let decoded: string;
  try {
    decoded = decodeURIComponent(raw);
  } catch {
    return null;
  }
  // Prevent path traversal.
  const normalized = decoded.replace(/\\/g, "/").replace(/^\/+/, "");
  if (normalized.includes("..")) return null;
  const full = resolve(join(root, normalized));
  const rel = relative(root, full);
  if (rel.startsWith("..") || rel.startsWith(sep) || rel.includes(`..${sep}`)) {
    return null;
  }
  return full;
}

const server = Bun.serve({
  port,
  hostname: "127.0.0.1",
  fetch(req) {
    const url = new URL(req.url);
    if (req.method !== "GET" && req.method !== "HEAD") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    if (url.pathname === "/" || url.pathname === "") {
      return new Response(
        `ch-fixedwidth test file server\nroot: ${rootDir}\nexample: /mini_snapshot.dat\n`,
        { headers: { "content-type": "text/plain; charset=utf-8" } },
      );
    }

    const filePath = safeJoin(rootDir, url.pathname);
    if (!filePath || !existsSync(filePath) || !statSync(filePath).isFile()) {
      return new Response("Not Found\n", { status: 404 });
    }

    const file = Bun.file(filePath);
    // Identity encoding so the CLI can stream without decompression.
    return new Response(file, {
      headers: {
        "content-type": "application/octet-stream",
        "cache-control": "no-store",
      },
    });
  },
});

console.log(`Serving ${rootDir}`);
console.log(`http://127.0.0.1:${server.port}/mini_snapshot.dat`);
console.log("Ctrl+C to stop");
