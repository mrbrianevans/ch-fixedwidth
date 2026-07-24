/**
 * Junction/symlink @ch-fixedwidth/wasm-ts to the sibling package.
 * Bun file: installs can fail on Windows with large trees.
 */
import { existsSync, lstatSync, mkdirSync, rmSync, symlinkSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const target = join(webRoot, "..", "wasm-ts");
const scopeDir = join(webRoot, "node_modules", "@ch-fixedwidth");
const linkPath = join(scopeDir, "wasm-ts");

if (!existsSync(target)) {
  console.error(`Local package missing: ${target}`);
  process.exit(1);
}

mkdirSync(scopeDir, { recursive: true });

if (existsSync(linkPath)) {
  try {
    rmSync(linkPath, { recursive: true, force: true });
  } catch {
    /* recreate below */
  }
}

try {
  const type = process.platform === "win32" ? "junction" : "dir";
  symlinkSync(target, linkPath, type);
  console.log(`Linked @ch-fixedwidth/wasm-ts -> ${target}`);
} catch (err) {
  if (existsSync(join(linkPath, "package.json"))) {
    console.log("@ch-fixedwidth/wasm-ts already present");
    process.exit(0);
  }
  console.error("Failed to link local wasm-ts:", err);
  process.exit(1);
}
