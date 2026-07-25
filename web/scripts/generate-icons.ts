/**
 * Generate PWA / favicon PNGs from SVG sources.
 *
 * Pipeline:
 *   1. @resvg/resvg-js rasterizes SVG → 1024×1024 master PNGs
 *      (ffmpeg cannot decode SVG without librsvg)
 *   2. ffmpeg scales masters to the sizes listed below
 *
 * Requires: bun, ffmpeg on PATH, @resvg/resvg-js (devDependency).
 *
 * Usage: bun run icons
 */
import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { Resvg } from "@resvg/resvg-js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const iconsDir = join(root, "icons");
mkdirSync(iconsDir, { recursive: true });

const MASTER = 1024;

/** Any-purpose / favicon sizes from icon.svg */
const ANY_SIZES = [16, 32, 180, 192, 512] as const;
/** Maskable sizes from icon-maskable.svg */
const MASKABLE_SIZES = [192, 512] as const;

function rasterizeSvg(svgPath: string, outPng: string, size: number): void {
  const svg = readFileSync(svgPath);
  const resvg = new Resvg(svg, {
    fitTo: { mode: "width", value: size },
    background: "rgba(0,0,0,0)",
  });
  const png = resvg.render().asPng();
  writeFileSync(outPng, png);
  console.log(`  resvg  ${outPng} (${png.length} bytes)`);
}

function ffmpegScale(src: string, dest: string, size: number): void {
  const r = spawnSync(
    "ffmpeg",
    [
      "-y",
      "-i",
      src,
      "-vf",
      `scale=${size}:${size}:flags=lanczos`,
      "-frames:v",
      "1",
      dest,
    ],
    { encoding: "utf8" },
  );
  if (r.status !== 0) {
    console.error(r.stderr || r.stdout);
    throw new Error(`ffmpeg failed for ${dest} (is ffmpeg on PATH?)`);
  }
  console.log(`  ffmpeg ${dest}`);
}

function requireFfmpeg(): void {
  const r = spawnSync("ffmpeg", ["-version"], { encoding: "utf8" });
  if (r.status !== 0) {
    throw new Error("ffmpeg not found on PATH. Install ffmpeg to generate icon PNGs.");
  }
}

console.log("Generating icons…");
requireFfmpeg();

const anyMaster = join(iconsDir, "_master-any.png");
const maskMaster = join(iconsDir, "_master-maskable.png");

rasterizeSvg(join(iconsDir, "icon.svg"), anyMaster, MASTER);
rasterizeSvg(join(iconsDir, "icon-maskable.svg"), maskMaster, MASTER);

for (const size of ANY_SIZES) {
  const name = size === 180 ? "apple-touch-icon.png" : `icon-${size}.png`;
  ffmpegScale(anyMaster, join(iconsDir, name), size);
}

for (const size of MASKABLE_SIZES) {
  ffmpegScale(maskMaster, join(iconsDir, `icon-maskable-${size}.png`), size);
}

// Keep masters out of the published tree — rebuild anytime with `bun run icons`.
for (const tmp of [anyMaster, maskMaster]) {
  try {
    unlinkSync(tmp);
  } catch {
    /* ignore */
  }
}

console.log("Done.");
