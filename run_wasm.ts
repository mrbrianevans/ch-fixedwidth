/**
 * Run the Zig wasm32-wasi parser (parser.wasm) under Bun via node:wasi.
 *
 * Usage:
 *   bun run run_wasm.ts <input.dat> <output_folder> [path/to/parser.wasm]
 *
 * Build the module (from repo root):
 *   zig build-exe parser.zig -OReleaseFast -fstrip --name parser -target wasm32-wasi \
 *     --initial-memory=33554432 --max-memory=536870912
 *
 * Same CLI contract as the native parsers: input path + output folder →
 * companies_data_*.csv and persons_data_*.csv.
 */

import { WASI } from "node:wasi";
import { mkdir } from "node:fs/promises";
import path from "node:path";

const wasmPath = process.argv[4] ?? path.join(import.meta.dir, "parser.wasm");
const inputPath = process.argv[2];
const outputFolder = process.argv[3];

if (!inputPath || !outputFolder) {
  console.error("Usage: bun run run_wasm.ts <input_file> <output_folder> [parser.wasm]");
  process.exit(1);
}

const absInput = path.resolve(inputPath);
const absOutput = path.resolve(outputFolder);
const absWasm = path.resolve(wasmPath);

await mkdir(absOutput, { recursive: true });

// Preopen the drive root (Windows) or filesystem root so WASI can resolve absolute paths.
// Also map "." to cwd for relative paths.
const cwd = process.cwd();
const rootPreopen =
  process.platform === "win32"
    ? path.parse(cwd).root.replace(/\\/g, "/") // e.g. "C:/"
    : "/";

// Guest paths: pass host absolute paths; preopens make them visible.
// On Windows, Zig/WASI often sees paths with forward slashes.
const guestInput = absInput.replace(/\\/g, "/");
const guestOutput = absOutput.replace(/\\/g, "/");

const wasi = new WASI({
  version: "preview1",
  args: ["parser", guestInput, guestOutput],
  env: {},
  preopens: {
    // Map guest "/" to host root so absolute paths work under WASI.
    "/": rootPreopen,
    // Relative paths under cwd.
    ".": cwd,
  },
});

const wasmModule = await WebAssembly.compile(await Bun.file(absWasm).arrayBuffer());
const instance = await WebAssembly.instantiate(wasmModule, wasi.getImports(wasmModule));

// node:wasi start() runs _start and does not return a normal JS value; exit
// is delivered via exception or process exit depending on runtime.
try {
  const code = wasi.start(instance);
  // Some runtimes return the exit code; others exit the process.
  if (typeof code === "number" && code !== 0) {
    process.exit(code);
  }
} catch (err: unknown) {
  // Bun may throw on non-zero WASI proc_exit
  const msg = err instanceof Error ? err.message : String(err);
  if (/exit|proc_exit|WASI/i.test(msg)) {
    const m = msg.match(/\b(\d+)\b/);
    const code = m ? Number(m[1]) : 1;
    if (code !== 0) {
      console.error(msg);
      process.exit(code);
    }
  } else {
    throw err;
  }
}
