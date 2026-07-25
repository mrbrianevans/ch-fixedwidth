/**
 * Main thread: pickers, batch queue, progress, streaming writes.
 * Parsing runs in worker.ts (one file at a time).
 */
import wasmUrl from "../ch_fixedwidth.wasm?url";
import type { WorkerOutMessage } from "./types.ts";

const el = {
  btnOpen: document.getElementById("btn-open") as HTMLButtonElement,
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
  progressBar: document.getElementById("progress-bar") as HTMLElement,
  batchProgressBar: document.getElementById("batch-progress-bar") as HTMLElement,
  status: document.getElementById("status") as HTMLElement,
  stats: document.getElementById("stats") as HTMLElement,
  statRead: document.getElementById("stat-read") as HTMLElement,
  statCompanies: document.getElementById("stat-companies") as HTMLElement,
  statPersons: document.getElementById("stat-persons") as HTMLElement,
  statElapsed: document.getElementById("stat-elapsed") as HTMLElement,
  statSpeed: document.getElementById("stat-speed") as HTMLElement,
  statMemory: document.getElementById("stat-memory") as HTMLElement,
};

type ItemStatus = "pending" | "converting" | "done" | "error" | "cancelled";

interface QueueItem {
  id: string;
  file: File;
  status: ItemStatus;
  error?: string;
  companies?: number;
  persons?: number;
  elapsedMs?: number;
}

const hasDirPicker = typeof window.showDirectoryPicker === "function";
/** Folder write API — required for multi-file batch (Chromium). */
const canStreamToDisk = hasDirPicker;
const allowMultiFile = canStreamToDisk;

let queue: QueueItem[] = [];
let outputDir: FileSystemDirectoryHandle | null = null;
let companiesChunks: Uint8Array[] = [];
let personsChunks: Uint8Array[] = [];
let companiesWritable: FileSystemWritableFileStream | null = null;
let personsWritable: FileSystemWritableFileStream | null = null;
let worker: Worker | null = null;
/** True while a batch run (possibly multi-file) is in progress. */
let converting = false;
/** Soft-cancel: finish stopping current file; do not start further pending items. */
let batchCancelled = false;
let currentItemId: string | null = null;
let currentFileBytesRead = 0;
let lastWasmMemoryBytes = 0;
let lastMemorySampleAt = 0;

/** Injected from wasm-ts/package.json at build time (vite define). */
declare const __PARSER_VERSION__: string | undefined;

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

function setStatus(text: string, kind: "" | "ok" | "error" = ""): void {
  el.status.textContent = text;
  el.status.className = kind ? `status ${kind}` : "status";
}

function setFileProgress(bytesRead: number, totalBytes: number): void {
  const pct = totalBytes > 0 ? Math.min(100, (bytesRead / totalBytes) * 100) : 0;
  el.progressBar.style.width = `${pct.toFixed(2)}%`;
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

function setBatchProgress(): void {
  const { total, done } = queueBytes();
  const pct = total > 0 ? Math.min(100, (done / total) * 100) : 0;
  el.batchProgressBar.style.width = `${pct.toFixed(2)}%`;
}

function countByStatus(status: ItemStatus): number {
  return queue.filter((i) => i.status === status).length;
}

function updateBatchSummary(): void {
  if (queue.length === 0) {
    el.batchSummary.hidden = true;
    el.batchSummary.textContent = "";
    return;
  }
  el.batchSummary.hidden = false;
  const n = queue.length;
  const done = countByStatus("done");
  const err = countByStatus("error");
  const pending = countByStatus("pending");
  const convertingN = countByStatus("converting");
  const cancelled = countByStatus("cancelled");
  const totalSize = queue.reduce((s, i) => s + i.file.size, 0);
  const parts = [
    `${n} file${n === 1 ? "" : "s"}`,
    formatBytes(totalSize),
    `${done} done`,
  ];
  if (convertingN) parts.push(`${convertingN} converting`);
  if (pending) parts.push(`${pending} waiting`);
  if (err) parts.push(`${err} failed`);
  if (cancelled) parts.push(`${cancelled} cancelled`);
  el.batchSummary.textContent = parts.join(" · ");
}

function statusLabel(status: ItemStatus): string {
  switch (status) {
    case "pending":
      return "Waiting";
    case "converting":
      return "Converting";
    case "done":
      return "Done";
    case "error":
      return "Failed";
    case "cancelled":
      return "Cancelled";
  }
}

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
    li.className = `queue-item queue-item--${item.status}`;
    li.dataset.id = item.id;

    const name = document.createElement("span");
    name.className = "queue-item-name";
    name.textContent = item.file.name;

    const meta = document.createElement("span");
    meta.className = "queue-item-meta";
    const bits = [formatBytes(item.file.size), statusLabel(item.status)];
    if (item.status === "done" && item.companies != null) {
      bits.push(
        `${formatNumber(item.companies)} co`,
        `${formatNumber(item.persons ?? 0)} pe`,
      );
    }
    if (item.status === "error" && item.error) bits.push(item.error);
    meta.textContent = bits.join(" · ");

    li.append(name, meta);
    el.queueList.append(li);
  }
  updateBatchSummary();
  updateConvertEnabled();
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
  setFileProgress(0, 1);
  setBatchProgress();
  renderQueue();
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
 * Open files via a synchronous &lt;input type="file"&gt; click.
 *
 * Avoid showOpenFilePicker here: some browsers expose a partial/broken
 * implementation, and after an async failure Firefox blocks the fallback
 * input.click() (lost user activation). The classic input works everywhere.
 */
function pickInputFile(): void {
  el.fileInput.click();
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

async function openWritables(base: string): Promise<void> {
  companiesChunks = [];
  personsChunks = [];
  companiesWritable = null;
  personsWritable = null;

  if (outputDir) {
    const cHandle = await outputDir.getFileHandle(`companies_data_${base}.csv`, {
      create: true,
    });
    const pHandle = await outputDir.getFileHandle(`persons_data_${base}.csv`, {
      create: true,
    });
    companiesWritable = await cHandle.createWritable();
    personsWritable = await pHandle.createWritable();
  }
}

async function writeBatch(kind: "companies" | "persons", data: ArrayBuffer): Promise<void> {
  const bytes = new Uint8Array(data);
  if (kind === "companies") {
    if (companiesWritable) await companiesWritable.write(bytes);
    else companiesChunks.push(bytes);
  } else if (personsWritable) {
    await personsWritable.write(bytes);
  } else {
    personsChunks.push(bytes);
  }
}

async function closeWritables(): Promise<void> {
  if (companiesWritable) {
    await companiesWritable.close();
    companiesWritable = null;
  }
  if (personsWritable) {
    await personsWritable.close();
    personsWritable = null;
  }
}

async function abortWritables(): Promise<void> {
  try {
    if (companiesWritable) await companiesWritable.abort();
  } catch {
    /* ignore */
  }
  try {
    if (personsWritable) await personsWritable.abort();
  } catch {
    /* ignore */
  }
  companiesWritable = null;
  personsWritable = null;
  companiesChunks = [];
  personsChunks = [];
}

function triggerDownload(blob: Blob, name: string): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.rel = "noopener";
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30_000);
}

function downloadFallback(base: string): void {
  triggerDownload(
    new Blob(companiesChunks as BlobPart[], { type: "text/csv;charset=utf-8" }),
    `companies_data_${base}.csv`,
  );
  setTimeout(() => {
    triggerDownload(
      new Blob(personsChunks as BlobPart[], { type: "text/csv;charset=utf-8" }),
      `persons_data_${base}.csv`,
    );
  }, 250);
  companiesChunks = [];
  personsChunks = [];
}

function setConverting(on: boolean): void {
  converting = on;
  el.btnOpen.disabled = on;
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
 * Memory estimate that works the same on localhost and GitHub Pages
 * (no custom headers / cross-origin isolation).
 *
 * - Main-thread JS heap via `performance.memory` when the browser exposes it
 * - WASM linear memory from the worker (always, when converting)
 * - Approximate total = JS heap + WASM (heap is main-thread only; worker JS
 *   is not included)
 */
function formatMemorySample(wasmBytes: number): string {
  const perf = performance as PerformanceWithMemory;
  const jsHeap =
    perf.memory && typeof perf.memory.usedJSHeapSize === "number"
      ? perf.memory.usedJSHeapSize
      : null;
  const wasmPart = wasmBytes > 0 ? `WASM ${formatBytes(wasmBytes)}` : null;

  if (jsHeap != null && wasmPart) {
    return `~${formatBytes(jsHeap + wasmBytes)} est. · JS heap ${formatBytes(jsHeap)} · ${wasmPart}`;
  }
  if (jsHeap != null) return `JS heap ${formatBytes(jsHeap)}`;
  if (wasmPart) return wasmPart;
  return "n/a";
}

function scheduleMemoryUpdate(wasmBytes: number): void {
  lastWasmMemoryBytes = wasmBytes;
  const now = performance.now();
  if (now - lastMemorySampleAt < 500 && el.statMemory.textContent !== "—") return;
  lastMemorySampleAt = now;
  el.statMemory.textContent = formatMemorySample(wasmBytes);
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
    currentFileBytesRead = 0;
    renderQueue();

    const base = basenameWithoutExt(item.file.name);
    const fileIndex = queue.indexOf(item) + 1;
    el.stats.hidden = false;
    el.statRead.textContent = "0 B";
    el.statCompanies.textContent = "0";
    el.statPersons.textContent = "0";
    el.statElapsed.textContent = "—";
    el.statSpeed.textContent = "—";
    el.statMemory.textContent = "…";
    setFileProgress(0, item.file.size);
    setBatchProgress();
    setStatus(
      queue.length > 1
        ? `File ${fileIndex} of ${queue.length}: ${item.file.name} — starting…`
        : "Starting…",
    );

    try {
      await openWritables(base);
    } catch (err) {
      item.status = "error";
      item.error = `Could not create outputs: ${String(err)}`;
      currentItemId = null;
      renderQueue();
      setStatus(`${item.file.name}: ${item.error}`, "error");
      continue;
    }

    const outcome = await runWorkerForItem(item, base);
    currentItemId = null;
    if (outcome === "cancelled" || batchCancelled) break;
  }

  if (batchCancelled) {
    for (const q of queue) {
      if (q.status === "pending" || q.status === "converting") q.status = "cancelled";
    }
    renderQueue();
    finishBatchRun("Batch cancelled.");
    return;
  }

  const failed = countByStatus("error");
  const done = countByStatus("done");
  if (failed > 0) {
    setStatus(
      `Batch finished — ${done} succeeded, ${failed} failed. You can retry failed files.`,
      "error",
    );
    finishBatchRun();
  } else if (done === 1) {
    const only = queue.find((i) => i.status === "done");
    setStatus(
      `Done — ${formatNumber(only?.companies ?? 0)} companies, ${formatNumber(only?.persons ?? 0)} persons.`,
      "ok",
    );
    finishBatchRun();
  } else {
    setStatus(`Batch complete — ${done} file${done === 1 ? "" : "s"} converted.`, "ok");
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
      setFileProgress(msg.bytesRead, msg.totalBytes);
      setBatchProgress();
      el.statRead.textContent = `${formatBytes(msg.bytesRead)} / ${formatBytes(msg.totalBytes)}`;
      el.statCompanies.textContent = formatNumber(msg.companies);
      el.statPersons.textContent = formatNumber(msg.persons);
      const pct =
        msg.totalBytes > 0 ? ((msg.bytesRead / msg.totalBytes) * 100).toFixed(1) : "0";
      const fileIndex = queue.indexOf(item) + 1;
      setStatus(
        queue.length > 1
          ? `File ${fileIndex} of ${queue.length}: ${item.file.name} — ${pct}%`
          : `Converting… ${pct}%`,
      );
      scheduleMemoryUpdate(msg.wasmMemoryBytes);
      return null;
    }
    case "batch": {
      try {
        await writeBatch(msg.kind, msg.data);
        return null;
      } catch (err) {
        worker?.postMessage({ type: "cancel" });
        await markItemError(item, `Write failed: ${String(err)}`);
        return "error";
      }
    }
    case "done": {
      try {
        await closeWritables();
        if (!canStreamToDisk || !outputDir) downloadFallback(base);
        item.status = "done";
        item.companies = msg.companies;
        item.persons = msg.persons;
        item.elapsedMs = msg.elapsedMs;
        currentFileBytesRead = msg.bytesRead;
        const records = msg.companies + msg.persons;
        const secs = msg.elapsedMs / 1000;
        const recPerSec = secs > 0 ? records / secs : 0;
        el.statElapsed.textContent = `${secs.toFixed(2)} s`;
        el.statSpeed.textContent =
          recPerSec >= 1_000_000
            ? `${(recPerSec / 1_000_000).toFixed(2)} M rec/s`
            : `${formatNumber(Math.round(recPerSec))} rec/s`;
        el.statCompanies.textContent = formatNumber(msg.companies);
        el.statPersons.textContent = formatNumber(msg.persons);
        el.statRead.textContent = formatBytes(msg.bytesRead);
        setFileProgress(msg.bytesRead, msg.bytesRead);
        setBatchProgress();
        scheduleMemoryUpdate(msg.wasmMemoryBytes);
        renderQueue();
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
      }
      renderQueue();
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
  }
  renderQueue();
  setStatus(`${item.file.name}: ${message}`, "error");
}

function finishBatchRun(statusMessage?: string): void {
  setConverting(false);
  batchCancelled = false;
  currentItemId = null;
  if (statusMessage) setStatus(statusMessage, "error");
  setBatchProgress();
  renderQueue();
  scheduleMemoryUpdate(lastWasmMemoryBytes);
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
      }
    }
  }

  if (!queue.some((i) => i.status === "pending")) {
    setStatus("No files waiting to convert.", "error");
    return;
  }

  batchCancelled = false;
  setConverting(true);
  el.stats.hidden = false;
  renderQueue();
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
    zone.classList.add("active");
  });
  zone.addEventListener("dragover", (e) => {
    prevent(e);
    zone.classList.add("active");
  });
  zone.addEventListener("dragleave", (e) => {
    prevent(e);
    zone.classList.remove("active");
  });
  zone.addEventListener("drop", (e) => {
    prevent(e);
    zone.classList.remove("active");
    if (converting) return;
    const list = e.dataTransfer?.files;
    if (!list?.length) return;
    setInputFiles(Array.from(list));
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

function registerServiceWorker(): void {
  if (!("serviceWorker" in navigator)) return;
  const swUrl = new URL("./sw.js", self.location.href);
  window.addEventListener("load", () => {
    void navigator.serviceWorker.register(swUrl, { scope: "./" }).catch(() => {
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
      "This browser will download results into memory. Prefer Chrome or Edge for large files and multi-file batches.";
  }
}

function initInputStepCopy(): void {
  if (allowMultiFile) {
    el.dropZoneTitle.textContent = "Drop .dat files";
    el.dropZoneHint.textContent =
      "One or more officers bulk files (batch requires an output folder)";
    el.dropZone.setAttribute("aria-label", "Drop .dat files here");
    el.btnOpen.textContent = "Open files…";
    el.fileInput.multiple = true;
    const heading = document.getElementById("input-heading");
    if (heading) heading.textContent = "Input files";
  } else {
    el.dropZoneTitle.textContent = "Drop .dat file";
    el.dropZoneHint.textContent = "Single file only — use Chrome or Edge for batches";
    el.dropZone.setAttribute("aria-label", "Drop .dat file here");
    el.btnOpen.textContent = "Open file…";
    el.fileInput.multiple = false;
  }
}

function initSiteFooter(): void {
  const yearEl = document.getElementById("copyright-year");
  if (yearEl) yearEl.textContent = String(new Date().getFullYear());

  const verEl = document.getElementById("parser-version");
  if (verEl) {
    const v =
      typeof __PARSER_VERSION__ !== "undefined" && __PARSER_VERSION_
        ? __PARSER_VERSION__
        : "dev";
    verEl.textContent = v.startsWith("v") ? v : `v${v}`;
  }
}

function init(): void {
  initOutputStep();
  initInputStepCopy();
  initSiteFooter();

  el.btnOpen.addEventListener("click", () => {
    if (!converting) pickInputFile();
  });
  el.btnOutdir.addEventListener("click", () => void pickOutputDir());
  el.btnConvert.addEventListener("click", () => void startBatch(false));
  el.btnRetry.addEventListener("click", () => void startBatch(true));
  el.btnCancel.addEventListener("click", () => cancelConvert());
  el.fileInput.addEventListener("change", () => {
    const files = el.fileInput.files ? Array.from(el.fileInput.files) : [];
    if (files.length) setInputFiles(files);
    el.fileInput.value = "";
  });
  bindDropZone();
  updateConvertEnabled();
  registerServiceWorker();

  el.statMemory.title =
    "Estimate: main-thread JS heap (when available) plus WASM linear memory from the converter worker. Same on localhost and GitHub Pages.";
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
    getFile(): Promise<File>;
    createWritable(): Promise<FileSystemWritableFileStream>;
  }

  interface FileSystemWritableFileStream extends WritableStream {
    write(data: BufferSource | Blob | string): Promise<void>;
    close(): Promise<void>;
    abort(): Promise<void>;
  }
}

export {};
