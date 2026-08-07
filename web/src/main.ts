/**
 * Main thread: pickers, batch queue, progress, streaming writes.
 * Parsing runs in worker.ts (one file at a time).
 */
import {
  ChFixedWidthParser,
  outputFileName,
  type CsvBatchKind,
  type StreamStats,
} from "@ch-fixedwidth/wasm-ts";
import wasmUrl from "../ch_fixedwidth.wasm?url";
import type { WorkerOutMessage } from "./types.ts";

const el = {
  btnOpen: document.getElementById("btn-open") as HTMLElement,
  btnOutdir: document.getElementById("btn-outdir") as HTMLButtonElement,
  btnConvert: document.getElementById("btn-convert") as HTMLButtonElement,
  btnRetry: document.getElementById("btn-retry") as HTMLButtonElement,
  btnCancel: document.getElementById("btn-cancel") as HTMLButtonElement,
  inputName: document.getElementById("input-name") as HTMLElement,
  outdirName: document.getElementById("outdir-name") as HTMLElement,
  outputHeading: document.getElementById("output-heading") as HTMLElement,
  outputFolderUi: document.getElementById("output-folder-ui") as HTMLElement,
  outputDownloadNote: document.getElementById("output-download-note") as HTMLElement,
  dropZone: document.getElementById("drop-zone") as HTMLElement,
  dropZoneTitle: document.querySelector(".drop-zone-title") as HTMLElement,
  dropZoneHint: document.querySelector(".drop-zone-hint") as HTMLElement,
  fileInput: document.getElementById("file-input") as HTMLInputElement,
  queueList: document.getElementById("queue-list") as HTMLElement,
  batchSummary: document.getElementById("batch-summary") as HTMLElement,
  status: document.getElementById("status") as HTMLElement,
  resultsPanel: document.getElementById("results-panel") as HTMLElement,
  resultsList: document.getElementById("results-list") as HTMLElement,
  resultsProgressFill: document.getElementById("results-progress-fill") as HTMLElement,
  resultsMemory: document.getElementById("results-memory") as HTMLElement,
  downloadPanel: document.getElementById("download-panel") as HTMLElement,
  downloadList: document.getElementById("download-list") as HTMLElement,
};

type ItemStatus = "pending" | "converting" | "done" | "error" | "cancelled";

interface QueueItem {
  id: string;
  file: File;
  status: ItemStatus;
  error?: string;
  /** Row counts by output kind (from stream stats). */
  stats?: StreamStats;
  /** Frozen parse elapsed (set at end of read / on done). */
  elapsedMs?: number;
  bytesRead?: number;
  /** performance.now() when this file began converting */
  startedAt?: number;
  /**
   * True once input is fully read (100%) and remaining work is draining
   * CSV batches to disk. Elapsed and rec/s freeze at this point.
   */
  writing?: boolean;
}

const hasDirPicker = typeof window.showDirectoryPicker === "function";
/** Folder write API — required for multi-file batch (Chromium). */
const canStreamToDisk = hasDirPicker;
const allowMultiFile = canStreamToDisk;

let queue: QueueItem[] = [];
let outputDir: FileSystemDirectoryHandle | null = null;
/** Open writers keyed by output kind (lazy; product-dependent). */
let kindWritables = new Map<CsvBatchKind, FileSystemWritableFileStream>();
/** In-memory CSV chunks when not writing to a directory handle. */
let kindChunks = new Map<CsvBatchKind, Uint8Array[]>();
/**
 * Ready downloads for non-Chromium (object URLs). User clicks to save —
 * never auto-trigger multiple dialogs.
 */
interface ReadyDownload {
  name: string;
  url: string;
  size: number;
}
let readyDownloads: ReadyDownload[] = [];
let worker: Worker | null = null;
/** True while a batch run (possibly multi-file) is in progress. */
let converting = false;
/** Soft-cancel: finish stopping current file; do not start further pending items. */
let batchCancelled = false;
let currentItemId: string | null = null;
let currentFileBytesRead = 0;
let lastWasmMemoryBytes = 0;
let lastMemorySampleAt = 0;
/** Live elapsed / rec-s tick while a file is converting (not writing). */
let liveStatsTimer: number | null = null;
/** Wall-clock for the whole batch (Convert click → last write finished). */
let batchWallTimer: number | null = null;
/** performance.now() when the user started the current batch. */
let batchStartedAt: number | null = null;
/** Frozen total once the batch ends (last write complete or cancelled). */
let batchTotalMs: number | null = null;
/** Show results once a batch has been started (or has outcomes). */
let resultsVisible = false;

function basenameWithoutExt(name: string): string {
  const i = name.lastIndexOf(".");
  return i > 0 ? name.slice(0, i) : name;
}

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KiB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MiB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GiB`;
}

function formatNumber(n: number): string {
  return n.toLocaleString();
}

function formatElapsed(ms: number): string {
  const secs = ms / 1000;
  if (secs < 10) return `${secs.toFixed(1)} s`;
  if (secs < 60) return `${secs.toFixed(1)} s`;
  const m = Math.floor(secs / 60);
  const s = secs - m * 60;
  return `${m}m ${s.toFixed(0)}s`;
}

function formatRecPerSec(records: number, elapsedMs: number): string {
  if (elapsedMs <= 0 || records <= 0) return "—";
  const recPerSec = records / (elapsedMs / 1000);
  if (recPerSec >= 1_000_000) return `${(recPerSec / 1_000_000).toFixed(2)} M rec/s`;
  if (recPerSec >= 1000) return `${(recPerSec / 1000).toFixed(1)} k rec/s`;
  return `${formatNumber(Math.round(recPerSec))} rec/s`;
}

function totalDataRows(stats?: StreamStats): number {
  if (!stats) return 0;
  return (
    stats.companies +
    stats.persons +
    stats.disqualifications +
    stats.exemptions +
    stats.variations +
    stats.forms +
    stats.practitioners +
    stats.freeText
  );
}

/** Non-zero row counts for status / results lines (full words, not abbreviations). */
function formatStatsCounts(stats?: StreamStats): string {
  if (!stats) return "0 rows";
  const parts: string[] = [];
  if (stats.companies) parts.push(`${formatNumber(stats.companies)} companies`);
  if (stats.persons) parts.push(`${formatNumber(stats.persons)} persons`);
  if (stats.disqualifications) {
    parts.push(`${formatNumber(stats.disqualifications)} disqualifications`);
  }
  if (stats.exemptions) parts.push(`${formatNumber(stats.exemptions)} exemptions`);
  if (stats.variations) parts.push(`${formatNumber(stats.variations)} variations`);
  if (stats.forms) parts.push(`${formatNumber(stats.forms)} forms`);
  if (stats.practitioners) {
    parts.push(`${formatNumber(stats.practitioners)} practitioners`);
  }
  if (stats.freeText) parts.push(`${formatNumber(stats.freeText)} free text`);
  if (parts.length === 0) return "0 rows";
  return parts.join(", ");
}

function setStatus(text: string, kind: "" | "ok" | "error" = ""): void {
  el.status.textContent = text;
  el.status.className = kind ? `status ${kind}` : "status";
}

function queueBytes(): { total: number; done: number } {
  let total = 0;
  let done = 0;
  for (const item of queue) {
    total += item.file.size;
    if (item.status === "done") done += item.file.size;
    else if (item.status === "converting") done += currentFileBytesRead;
  }
  return { total, done };
}

function updateVerticalProgress(): void {
  const { total, done } = queueBytes();
  const pct = total > 0 ? Math.min(100, (done / total) * 100) : 0;
  el.resultsProgressFill.style.height = `${pct.toFixed(2)}%`;
}

function countByStatus(status: ItemStatus): number {
  return queue.filter((i) => i.status === status).length;
}

/** Step 1 summary: file count and total size only. */
function updateBatchSummary(): void {
  if (queue.length === 0) {
    el.batchSummary.hidden = true;
    el.batchSummary.textContent = "";
    return;
  }
  el.batchSummary.hidden = false;
  const n = queue.length;
  const totalSize = queue.reduce((s, i) => s + i.file.size, 0);
  el.batchSummary.textContent = `${n} file${n === 1 ? "" : "s"} · ${formatBytes(totalSize)}`;
}

function itemElapsedMs(item: QueueItem): number {
  // Prefer frozen parse time (writing phase or completed).
  if (item.elapsedMs != null) return item.elapsedMs;
  if (item.status === "converting" && !item.writing && item.startedAt != null) {
    return performance.now() - item.startedAt;
  }
  return 0;
}

/**
 * Input fully read — remaining work is writing CSV. Freeze parse elapsed/rec/s
 * and stop the live ticker so the drain phase does not drag the figures down.
 */
function enterWritingPhase(item: QueueItem): void {
  if (item.writing || item.status !== "converting") return;
  item.writing = true;
  if (item.elapsedMs == null && item.startedAt != null) {
    item.elapsedMs = performance.now() - item.startedAt;
  }
  stopLiveStatsTimer();
  const fileIndex = queue.indexOf(item) + 1;
  setStatus(
    queue.length > 1
      ? `File ${fileIndex} of ${queue.length}: ${item.file.name} — writing CSV…`
      : "Writing CSV…",
  );
}

function resultMetaLine(item: QueueItem): string {
  const size = formatBytes(item.file.size);
  const records = totalDataRows(item.stats);
  const counts = formatStatsCounts(item.stats);
  const elapsed = itemElapsedMs(item);

  switch (item.status) {
    case "pending":
      return `${size} · Waiting`;
    case "converting": {
      if (item.writing) {
        return [
          size,
          "Writing",
          formatElapsed(elapsed),
          counts,
          formatRecPerSec(records, elapsed),
        ].join(" · ");
      }
      const bits = [
        size,
        "Converting",
        formatElapsed(elapsed),
        counts,
        formatRecPerSec(records, elapsed),
      ];
      if (item.bytesRead != null && item.file.size > 0) {
        const pct = Math.min(100, (item.bytesRead / item.file.size) * 100);
        bits.splice(2, 0, `${pct.toFixed(0)}%`);
      }
      return bits.join(" · ");
    }
    case "done": {
      const bits = [
        size,
        `Done in ${formatElapsed(elapsed)}`,
        counts,
        formatRecPerSec(records, elapsed),
      ];
      return bits.join(" · ");
    }
    case "error": {
      const bits = [size, "Failed"];
      if (item.error) bits.push(item.error);
      return bits.join(" · ");
    }
    case "cancelled":
      return `${size} · Cancelled`;
  }
}

/** Step 1: names and sizes only — no conversion status. */
function renderQueue(): void {
  el.queueList.replaceChildren();
  if (queue.length === 0) {
    el.queueList.hidden = true;
    updateBatchSummary();
    updateConvertEnabled();
    return;
  }
  el.queueList.hidden = false;
  for (const item of queue) {
    const li = document.createElement("li");
    li.className = "queue-item";
    li.dataset.id = item.id;

    const name = document.createElement("span");
    name.className = "queue-item-name";
    name.textContent = item.file.name;

    const meta = document.createElement("span");
    meta.className = "queue-item-meta";
    meta.textContent = formatBytes(item.file.size);

    li.append(name, meta);
    el.queueList.append(li);
  }
  updateBatchSummary();
  updateConvertEnabled();
}

function showResultsPanel(show: boolean): void {
  resultsVisible = show;
  el.resultsPanel.hidden = !show;
}

/** Step 3: per-file conversion results with live progress. */
function renderResults(): void {
  if (!resultsVisible && !converting && !queue.some((i) => i.status !== "pending")) {
    el.resultsList.replaceChildren();
    el.resultsPanel.hidden = true;
    updateVerticalProgress();
    return;
  }

  showResultsPanel(true);
  el.resultsList.replaceChildren();

  for (const item of queue) {
    const li = document.createElement("li");
    const phaseClass =
      item.status === "converting" && item.writing
        ? "result-item--writing"
        : `result-item--${item.status}`;
    li.className = `result-item ${phaseClass}`;
    li.dataset.id = item.id;

    const name = document.createElement("span");
    name.className = "result-item-name";
    name.textContent = item.file.name;

    const meta = document.createElement("span");
    meta.className = "result-item-meta";
    meta.textContent = resultMetaLine(item);

    li.append(name, meta);

    if (item.status === "converting") {
      const wrap = document.createElement("div");
      wrap.className = "result-item-progress";
      const bar = document.createElement("div");
      bar.className = "result-item-progress-bar";
      const total = item.file.size;
      const read = item.bytesRead ?? currentFileBytesRead;
      const pct = total > 0 ? Math.min(100, (read / total) * 100) : 0;
      bar.style.width = `${pct.toFixed(2)}%`;
      wrap.append(bar);
      li.append(wrap);
    }

    el.resultsList.append(li);
  }

  updateVerticalProgress();
}

function updateConvertEnabled(): void {
  const hasPending = queue.some((i) => i.status === "pending");
  const hasFailed = queue.some((i) => i.status === "error");
  const folderOk = canStreamToDisk ? !!outputDir : true;
  el.btnConvert.disabled = !(hasPending && !converting && folderOk);
  el.btnRetry.hidden = !hasFailed;
  el.btnRetry.disabled = !(hasFailed && !converting && folderOk);
}

function setInputFiles(files: File[]): void {
  if (converting) return;
  const list = allowMultiFile ? files : files.slice(0, 1);
  if (!allowMultiFile && files.length > 1) {
    setStatus(
      "This browser only supports one file at a time. Use Chrome or Edge for batch conversion.",
      "error",
    );
  }
  queue = list.map((file, i) => ({
    id: `${file.name}-${file.size}-${file.lastModified}-${i}-${Math.random().toString(36).slice(2, 8)}`,
    file,
    status: "pending" as const,
  }));
  if (queue.length === 0) {
    el.inputName.textContent = "No file selected";
  } else if (queue.length === 1) {
    const f = queue[0]!.file;
    el.inputName.textContent = `${f.name} (${formatBytes(f.size)})`;
  } else {
    const total = queue.reduce((s, i) => s + i.file.size, 0);
    el.inputName.textContent = `${queue.length} files (${formatBytes(total)})`;
  }
  currentFileBytesRead = 0;
  batchStartedAt = null;
  batchTotalMs = null;
  stopBatchWallTimer();
  clearReadyDownloads();
  showResultsPanel(false);
  el.resultsMemory.hidden = true;
  el.resultsMemory.textContent = "";
  updateVerticalProgress();
  renderQueue();
  renderResults();
}

function isAbortError(err: unknown): boolean {
  return err instanceof DOMException && err.name === "AbortError";
}

function resolveAssetUrl(url: string): string {
  if (/^(https?:|blob:|data:)/i.test(url)) return url;
  if (url.startsWith("/")) return new URL(url, self.location.origin).href;
  return new URL(url, self.location.href).href;
}

/**
 * Open the native file dialog.
 * Prefer label[for=file-input] (no JS). This is a fallback for the drop zone
 * keyboard/click path. The input must not be display:none / [hidden].
 */
function pickInputFile(): void {
  // Reset so choosing the same file again still fires `change`.
  el.fileInput.value = "";
  el.fileInput.click();
}

/** Collect File objects from a drop (files list and/or items). */
function filesFromDataTransfer(dt: DataTransfer | null): File[] {
  if (!dt) return [];
  if (dt.files && dt.files.length > 0) return Array.from(dt.files);
  const out: File[] = [];
  if (dt.items) {
    for (const item of Array.from(dt.items)) {
      if (item.kind === "file") {
        const f = item.getAsFile();
        if (f) out.push(f);
      }
    }
  }
  return out;
}

async function pickOutputDir(): Promise<void> {
  if (!hasDirPicker) return;
  try {
    outputDir = await window.showDirectoryPicker!({ mode: "readwrite" });
    el.outdirName.textContent = outputDir.name;
    updateConvertEnabled();
  } catch (err) {
    if (isAbortError(err)) return;
    setStatus(`Could not open folder: ${String(err)}`, "error");
  }
}

function resetWritables(): void {
  kindWritables = new Map();
  kindChunks = new Map();
}

async function ensureWritable(kind: CsvBatchKind, base: string): Promise<void> {
  if (kindWritables.has(kind)) return;
  if (!outputDir) {
    if (!kindChunks.has(kind)) kindChunks.set(kind, []);
    return;
  }
  const handle = await outputDir.getFileHandle(outputFileName(kind, base), {
    create: true,
  });
  kindWritables.set(kind, await handle.createWritable());
}

async function writeBatch(kind: CsvBatchKind, data: ArrayBuffer, base: string): Promise<void> {
  const bytes = new Uint8Array(data);
  await ensureWritable(kind, base);
  const writable = kindWritables.get(kind);
  if (writable) {
    await writable.write(bytes);
    return;
  }
  let chunks = kindChunks.get(kind);
  if (!chunks) {
    chunks = [];
    kindChunks.set(kind, chunks);
  }
  chunks.push(bytes);
}

async function closeWritables(): Promise<void> {
  for (const w of kindWritables.values()) {
    await w.close();
  }
  kindWritables = new Map();
}

async function abortWritables(): Promise<void> {
  for (const w of kindWritables.values()) {
    try {
      await w.abort();
    } catch {
      /* ignore */
    }
  }
  resetWritables();
}

/** Revoke object URLs and clear the download list UI. */
function clearReadyDownloads(): void {
  for (const d of readyDownloads) {
    URL.revokeObjectURL(d.url);
  }
  readyDownloads = [];
  renderDownloadLinks();
}

/**
 * Build in-memory CSV blobs for browsers without a directory picker.
 * Exposes clickable download links (createObjectURL) instead of firing
 * automatic save dialogs for every output file at once.
 */
function materialiseDownloadLinks(base: string): void {
  clearReadyDownloads();
  const next: ReadyDownload[] = [];
  for (const [kind, chunks] of kindChunks.entries()) {
    const blob = new Blob(chunks as BlobPart[], { type: "text/csv;charset=utf-8" });
    next.push({
      name: outputFileName(kind, base),
      url: URL.createObjectURL(blob),
      size: blob.size,
    });
  }
  kindChunks = new Map();
  readyDownloads = next;
  renderDownloadLinks();
}

function renderDownloadLinks(): void {
  if (!el.downloadPanel || !el.downloadList) return;
  el.downloadList.replaceChildren();
  if (readyDownloads.length === 0) {
    el.downloadPanel.hidden = true;
    return;
  }
  el.downloadPanel.hidden = false;
  for (const d of readyDownloads) {
    const li = document.createElement("li");
    li.className = "download-item";

    const a = document.createElement("a");
    a.className = "download-link";
    a.href = d.url;
    a.download = d.name;
    a.rel = "noopener";
    a.textContent = d.name;

    const meta = document.createElement("span");
    meta.className = "download-meta meta";
    meta.textContent = formatBytes(d.size);

    li.append(a, meta);
    el.downloadList.append(li);
  }
}

function setConverting(on: boolean): void {
  converting = on;
  // btnOpen is a <label>; use inert/aria rather than disabled where needed.
  el.btnOpen.setAttribute("aria-disabled", on ? "true" : "false");
  if (on) el.btnOpen.classList.add("is-disabled");
  else el.btnOpen.classList.remove("is-disabled");
  el.fileInput.disabled = on;
  el.btnOutdir.disabled = on || !canStreamToDisk;
  el.btnCancel.disabled = !on;
  el.dropZone.style.pointerEvents = on ? "none" : "";
  updateConvertEnabled();
}

function createConverterWorker(): Worker {
  return new Worker(new URL("./worker.ts", import.meta.url), { type: "module" });
}

function teardownWorker(): void {
  if (worker) {
    worker.terminate();
    worker = null;
  }
}

function startLiveStatsTimer(): void {
  stopLiveStatsTimer();
  liveStatsTimer = window.setInterval(() => {
    if (!currentItemId) return;
    const item = queue.find((i) => i.id === currentItemId);
    // Freeze once writing — elapsed/rec-s must not keep climbing during disk drain.
    if (!item || item.status !== "converting" || item.writing) return;
    renderResults();
  }, 100);
}

function stopLiveStatsTimer(): void {
  if (liveStatsTimer != null) {
    window.clearInterval(liveStatsTimer);
    liveStatsTimer = null;
  }
}

function batchElapsedMs(): number {
  if (batchTotalMs != null) return batchTotalMs;
  if (batchStartedAt != null) return performance.now() - batchStartedAt;
  return 0;
}

function startBatchWallTimer(): void {
  stopBatchWallTimer();
  batchWallTimer = window.setInterval(() => {
    if (batchStartedAt == null || batchTotalMs != null) return;
    updateResultsFooter();
  }, 100);
}

function stopBatchWallTimer(): void {
  if (batchWallTimer != null) {
    window.clearInterval(batchWallTimer);
    batchWallTimer = null;
  }
}

/** Freeze wall-clock at end of batch (after last write / cancel cleanup). */
function freezeBatchTotal(): void {
  if (batchStartedAt != null && batchTotalMs == null) {
    batchTotalMs = performance.now() - batchStartedAt;
  }
  stopBatchWallTimer();
  updateResultsFooter();
}

/** Chrome `performance.memory` (non-standard; works without COOP/COEP). */
interface PerformanceMemory {
  usedJSHeapSize: number;
  totalJSHeapSize: number;
  jsHeapSizeLimit: number;
}

interface PerformanceWithMemory extends Performance {
  memory?: PerformanceMemory;
}

/**
 * Single combined memory figure (JS heap + WASM linear memory when both known).
 * Same on localhost and GitHub Pages — no COOP/COEP required.
 */
function formatMemorySample(wasmBytes: number): string {
  const perf = performance as PerformanceWithMemory;
  const jsHeap =
    perf.memory && typeof perf.memory.usedJSHeapSize === "number"
      ? perf.memory.usedJSHeapSize
      : 0;
  const total = jsHeap + (wasmBytes > 0 ? wasmBytes : 0);
  if (total <= 0) return "n/a";
  return formatBytes(total);
}

/**
 * Footer under results: batch wall-clock + memory.
 * Total time runs from Convert click until the last CSV write finishes.
 */
function updateResultsFooter(wasmBytes?: number): void {
  if (wasmBytes != null && wasmBytes > 0) lastWasmMemoryBytes = wasmBytes;
  const sample = formatMemorySample(lastWasmMemoryBytes);
  const parts: string[] = [];
  if (batchStartedAt != null || batchTotalMs != null) {
    parts.push(`Total time · ${formatElapsed(batchElapsedMs())}`);
  }
  if (sample !== "n/a" || lastWasmMemoryBytes > 0 || el.resultsMemory.textContent) {
    parts.push(`Memory · ${sample}`);
  }
  if (parts.length === 0) {
    el.resultsMemory.hidden = true;
    el.resultsMemory.textContent = "";
    return;
  }
  el.resultsMemory.hidden = false;
  el.resultsMemory.textContent = parts.join(" · ");
  el.resultsMemory.title =
    "Total time: from Convert until the last output byte is written. " +
    "Memory: estimated RAM (JS heap when available + WASM linear memory).";
}

function scheduleMemoryUpdate(wasmBytes: number): void {
  lastWasmMemoryBytes = wasmBytes;
  const now = performance.now();
  // Throttle memory sampling; wall-clock is refreshed by batchWallTimer.
  if (now - lastMemorySampleAt < 500 && el.resultsMemory.textContent) {
    // Still refresh total time if the batch is live.
    if (batchStartedAt != null && batchTotalMs == null) updateResultsFooter();
    return;
  }
  lastMemorySampleAt = now;
  updateResultsFooter(wasmBytes);
}

function nextPendingItem(): QueueItem | undefined {
  return queue.find((i) => i.status === "pending");
}

type ItemOutcome = "done" | "error" | "cancelled";

async function runBatchLoop(): Promise<void> {
  while (!batchCancelled) {
    const item = nextPendingItem();
    if (!item) break;

    currentItemId = item.id;
    item.status = "converting";
    item.error = undefined;
    item.stats = undefined;
    item.bytesRead = 0;
    item.elapsedMs = undefined;
    item.writing = false;
    item.startedAt = performance.now();
    currentFileBytesRead = 0;
    startLiveStatsTimer();
    renderResults();

    const base = basenameWithoutExt(item.file.name);
    const fileIndex = queue.indexOf(item) + 1;
    setStatus(
      queue.length > 1
        ? `File ${fileIndex} of ${queue.length}: ${item.file.name} — starting…`
        : "Starting…",
    );

    resetWritables();
    const outcome = await runWorkerForItem(item, base);
    stopLiveStatsTimer();
    currentItemId = null;
    if (outcome === "cancelled" || batchCancelled) break;
  }

  stopLiveStatsTimer();

  if (batchCancelled) {
    for (const q of queue) {
      if (q.status === "pending" || q.status === "converting") q.status = "cancelled";
    }
    renderResults();
    finishBatchRun("Batch cancelled.");
    return;
  }

  const failed = countByStatus("error");
  const done = countByStatus("done");
  const downloadHint =
    readyDownloads.length > 0
      ? ` Click the link${readyDownloads.length === 1 ? "" : "s"} below to download.`
      : "";
  if (failed > 0) {
    setStatus(
      `Batch finished — ${done} succeeded, ${failed} failed. You can retry failed files.${downloadHint}`,
      "error",
    );
    finishBatchRun();
  } else if (done === 1) {
    const only = queue.find((i) => i.status === "done");
    setStatus(`Done — ${formatStatsCounts(only?.stats)}.${downloadHint}`, "ok");
    finishBatchRun();
  } else {
    setStatus(
      `Batch complete — ${done} file${done === 1 ? "" : "s"} converted.${downloadHint}`,
      "ok",
    );
    finishBatchRun();
  }
}

function runWorkerForItem(item: QueueItem, base: string): Promise<ItemOutcome> {
  return new Promise((resolve) => {
    teardownWorker();
    worker = createConverterWorker();
    let chain: Promise<void> = Promise.resolve();
    let settled = false;

    const settle = (outcome: ItemOutcome): void => {
      if (settled) return;
      settled = true;
      teardownWorker();
      resolve(outcome);
    };

    worker.onmessage = (ev: MessageEvent<WorkerOutMessage>) => {
      chain = chain
        .then(async () => {
          if (settled) return;
          const outcome = await handleWorkerMessage(ev.data, item, base);
          if (outcome) settle(outcome);
        })
        .catch(async (err) => {
          if (settled) return;
          await markItemError(item, String(err));
          settle("error");
        });
    };

    worker.onerror = (ev) => {
      chain = chain.then(async () => {
        if (settled) return;
        await markItemError(item, `Worker error: ${ev.message || "unknown"}`);
        settle("error");
      });
    };

    worker.postMessage({
      type: "convert",
      file: item.file,
      wasmUrl: resolveAssetUrl(String(wasmUrl)),
    });
  });
}

/**
 * @returns terminal outcome when this file is finished; null if more messages expected
 */
async function handleWorkerMessage(
  msg: WorkerOutMessage,
  item: QueueItem,
  base: string,
): Promise<ItemOutcome | null> {
  switch (msg.type) {
    case "progress": {
      currentFileBytesRead = msg.bytesRead;
      item.bytesRead = msg.bytesRead;
      item.stats = msg.stats;
      const readComplete = msg.totalBytes > 0 && msg.bytesRead >= msg.totalBytes;
      if (readComplete) {
        enterWritingPhase(item);
      } else if (!item.writing) {
        const pct = ((msg.bytesRead / msg.totalBytes) * 100).toFixed(1);
        const fileIndex = queue.indexOf(item) + 1;
        setStatus(
          queue.length > 1
            ? `File ${fileIndex} of ${queue.length}: ${item.file.name} — ${pct}%`
            : `Converting… ${pct}%`,
        );
      }
      scheduleMemoryUpdate(msg.wasmMemoryBytes);
      renderResults();
      return null;
    }
    case "batch": {
      try {
        // After the input is fully read, batches still arrive while CSV is flushed.
        if (
          !item.writing &&
          item.bytesRead != null &&
          item.file.size > 0 &&
          item.bytesRead >= item.file.size
        ) {
          enterWritingPhase(item);
          renderResults();
        }
        await writeBatch(msg.kind, msg.data, base);
        return null;
      } catch (err) {
        worker?.postMessage({ type: "cancel" });
        await markItemError(item, `Write failed: ${String(err)}`);
        return "error";
      }
    }
    case "done": {
      try {
        // Ensure writing status is visible while closing output streams.
        if (!item.writing) enterWritingPhase(item);
        renderResults();
        await closeWritables();
        if (!canStreamToDisk || !outputDir) materialiseDownloadLinks(base);
        item.status = "done";
        item.writing = false;
        item.stats = msg.stats;
        item.elapsedMs = msg.elapsedMs;
        item.bytesRead = msg.bytesRead;
        item.startedAt = undefined;
        currentFileBytesRead = msg.bytesRead;
        scheduleMemoryUpdate(msg.wasmMemoryBytes);
        renderResults();
        return "done";
      } catch (err) {
        await markItemError(item, `Failed to close outputs: ${String(err)}`);
        return "error";
      }
    }
    case "cancelled": {
      await abortWritables();
      if (item.status === "converting") {
        item.status = batchCancelled ? "cancelled" : "error";
        if (!batchCancelled) item.error = "Cancelled";
        item.startedAt = undefined;
        item.writing = false;
      }
      renderResults();
      return "cancelled";
    }
    case "error": {
      await markItemError(
        item,
        msg.code != null ? `${msg.message} (code ${msg.code})` : msg.message,
      );
      return "error";
    }
  }
}

async function markItemError(item: QueueItem, message: string): Promise<void> {
  await abortWritables();
  if (item.status === "converting" || item.status === "pending") {
    item.status = "error";
    item.error = message;
    item.startedAt = undefined;
    item.writing = false;
  }
  renderResults();
  setStatus(`${item.file.name}: ${message}`, "error");
}

function finishBatchRun(statusMessage?: string): void {
  setConverting(false);
  batchCancelled = false;
  currentItemId = null;
  stopLiveStatsTimer();
  // Last write (or cancel) has finished — freeze wall-clock for the batch.
  freezeBatchTotal();
  if (statusMessage) setStatus(statusMessage, "error");
  renderResults();
  updateResultsFooter(lastWasmMemoryBytes);
}

async function startBatch(retryFailedOnly: boolean): Promise<void> {
  if (converting) return;
  if (canStreamToDisk && !outputDir) {
    setStatus("Choose an output folder first.", "error");
    return;
  }

  if (retryFailedOnly) {
    for (const item of queue) {
      if (item.status === "error" || item.status === "cancelled") {
        item.status = "pending";
        item.error = undefined;
        item.stats = undefined;
        item.elapsedMs = undefined;
        item.bytesRead = undefined;
        item.startedAt = undefined;
        item.writing = false;
      }
    }
  }

  if (!queue.some((i) => i.status === "pending")) {
    setStatus("No files waiting to convert.", "error");
    return;
  }

  batchCancelled = false;
  batchStartedAt = performance.now();
  batchTotalMs = null;
  clearReadyDownloads();
  setConverting(true);
  showResultsPanel(true);
  startBatchWallTimer();
  updateResultsFooter();
  renderResults();
  await runBatchLoop();
}

function cancelConvert(): void {
  if (!converting) return;
  batchCancelled = true;
  setStatus("Cancelling…");
  if (worker) {
    worker.postMessage({ type: "cancel" });
  } else {
    for (const q of queue) {
      if (q.status === "pending" || q.status === "converting") q.status = "cancelled";
    }
    finishBatchRun("Batch cancelled.");
  }
}

function bindDropZone(): void {
  const zone = el.dropZone;
  const prevent = (e: DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
  };
  zone.addEventListener("dragenter", (e) => {
    prevent(e);
    if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
    zone.classList.add("active");
  });
  zone.addEventListener("dragover", (e) => {
    prevent(e);
    if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
    zone.classList.add("active");
  });
  zone.addEventListener("dragleave", (e) => {
    prevent(e);
    if (e.relatedTarget instanceof Node && zone.contains(e.relatedTarget)) return;
    zone.classList.remove("active");
  });
  zone.addEventListener("drop", (e) => {
    prevent(e);
    zone.classList.remove("active");
    if (converting) return;
    const files = filesFromDataTransfer(e.dataTransfer);
    if (!files.length) {
      setStatus("No files found in that drop. Try Open file… instead.", "error");
      return;
    }
    setInputFiles(files);
  });
  zone.addEventListener("click", () => {
    if (!converting) pickInputFile();
  });
  zone.addEventListener("keydown", (e) => {
    if ((e.key === "Enter" || e.key === " ") && !converting) {
      e.preventDefault();
      pickInputFile();
    }
  });
}

/**
 * Register SW only in production builds. Dev would fight HMR with cache-first.
 * Also force an update check so deploys replace old cached app shells.
 */
function registerServiceWorker(): void {
  if (!("serviceWorker" in navigator)) return;
  if (import.meta.env.DEV) {
    void navigator.serviceWorker.getRegistrations().then((regs) => {
      for (const reg of regs) void reg.unregister();
    });
    void caches.keys().then((keys) => {
      for (const k of keys) void caches.delete(k);
    });
    return;
  }
  const swUrl = new URL("./sw.js", self.location.href);
  window.addEventListener("load", () => {
    void navigator.serviceWorker
      .register(swUrl, { scope: "./", updateViaCache: "none" })
      .then((reg) => {
        void reg.update();
      })
      .catch(() => {
        /* optional enhancement */
      });
  });
}

function initOutputStep(): void {
  if (canStreamToDisk) {
    el.outputHeading.textContent = "Output folder";
    el.outputFolderUi.hidden = false;
    el.outputDownloadNote.hidden = true;
    el.btnOutdir.disabled = false;
    el.outdirName.textContent = "Not chosen";
  } else {
    // No directory picker — replace folder controls with the download warning.
    el.outputHeading.textContent = "Output";
    el.outputFolderUi.hidden = true;
    el.outputDownloadNote.hidden = false;
    el.btnOutdir.disabled = true;
    el.outputDownloadNote.textContent =
      "This browser can convert one file at a time. Results stay in memory; download links appear when conversion finishes. Prefer Chrome or Edge for large files and multi-file batches (output folder).";
  }
}

function initInputStepCopy(): void {
  if (allowMultiFile) {
    el.dropZoneTitle.textContent = "Drop .dat files";
    el.dropZoneHint.textContent =
      "Companies House bulk .dat files (batch requires an output folder)";
    el.dropZone.setAttribute("aria-label", "Drop .dat files here or press to browse");
    el.btnOpen.textContent = "Open files…";
    el.fileInput.multiple = true;
    const heading = document.getElementById("input-heading");
    if (heading) heading.textContent = "Input files";
  } else {
    el.dropZoneTitle.textContent = "Drop .dat file";
    el.dropZoneHint.textContent = "Single file only — use Chrome or Edge for batches";
    el.dropZone.setAttribute("aria-label", "Drop .dat file here or press to browse");
    el.btnOpen.textContent = "Open file…";
    el.fileInput.multiple = false;
  }
}

function initSiteFooter(): void {
  const yearEl = document.getElementById("copyright-year");
  if (yearEl) yearEl.textContent = String(new Date().getFullYear());

  const verEl = document.getElementById("parser-version");
  if (!verEl) return;

  // Placeholder until WASM libraryInfo resolves (semver + build-time short SHA).
  verEl.textContent = "…";
  void loadParserVersionInto(verEl);
}

/**
 * Read version + git commit from the freestanding WASM module so the footer
 * matches the exact binary that will parse files (not package.json alone).
 */
async function loadParserVersionInto(verEl: HTMLElement): Promise<void> {
  try {
    const parser = await ChFixedWidthParser.create({ wasmUrl });
    const info = parser.libraryInfo();
    const ver = info.version.startsWith("v") ? info.version : `v${info.version}`;
    const commit = info.gitCommit && info.gitCommit !== "unknown" ? info.gitCommit : null;
    verEl.textContent = commit ? `${ver} · ${commit}` : ver;
    verEl.title = commit
      ? `ch_fixedwidth ${ver} (git ${commit})`
      : `ch_fixedwidth ${ver}`;
  } catch (err) {
    console.warn("Could not load parser version from WASM:", err);
    verEl.textContent = "dev";
    verEl.removeAttribute("title");
  }
}

function init(): void {
  if (!el.fileInput || !el.btnOpen || !el.dropZone) {
    console.error("Converter UI failed to initialise: missing file controls");
    return;
  }
  if (!el.resultsPanel || !el.resultsList || !el.resultsProgressFill) {
    console.error("Converter UI failed to initialise: missing results controls");
    return;
  }

  initOutputStep();
  initInputStepCopy();
  initSiteFooter();

  // Open uses <label for="file-input"> — no click handler needed on the label.
  // Prevent double-open if a browser also synthesizes a click we handle elsewhere.
  el.btnOpen.addEventListener("click", (e) => {
    if (converting) {
      e.preventDefault();
      return;
    }
  });
  el.btnOutdir.addEventListener("click", () => void pickOutputDir());
  el.btnConvert.addEventListener("click", () => void startBatch(false));
  el.btnRetry.addEventListener("click", () => void startBatch(true));
  el.btnCancel.addEventListener("click", () => cancelConvert());
  el.fileInput.addEventListener("change", () => {
    const files = el.fileInput.files ? Array.from(el.fileInput.files) : [];
    if (files.length) setInputFiles(files);
  });
  bindDropZone();
  updateConvertEnabled();
  registerServiceWorker();
}

init();

declare global {
  interface Window {
    showDirectoryPicker?: (options?: {
      mode?: "read" | "readwrite";
    }) => Promise<FileSystemDirectoryHandle>;
  }

  interface FileSystemDirectoryHandle {
    getFileHandle(
      name: string,
      options?: { create?: boolean },
    ): Promise<FileSystemFileHandle>;
  }

  interface FileSystemFileHandle {
    createWritable(): Promise<FileSystemWritableFileStream>;
  }

  interface FileSystemWritableFileStream extends WritableStream {
    write(data: BufferSource | Blob | string): Promise<void>;
    close(): Promise<void>;
    abort(): Promise<void>;
  }
}
