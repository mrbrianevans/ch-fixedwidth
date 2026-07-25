/**
 * Main thread: pickers, progress, streaming writes.
 * Parsing runs in worker.ts.
 */
import wasmUrl from "../ch_fixedwidth.wasm";
import type { WorkerOutMessage } from "./types.ts";

const el = {
  capability: document.getElementById("capability") as HTMLElement,
  btnOpen: document.getElementById("btn-open") as HTMLButtonElement,
  btnOutdir: document.getElementById("btn-outdir") as HTMLButtonElement,
  btnConvert: document.getElementById("btn-convert") as HTMLButtonElement,
  btnCancel: document.getElementById("btn-cancel") as HTMLButtonElement,
  inputName: document.getElementById("input-name") as HTMLElement,
  outdirName: document.getElementById("outdir-name") as HTMLElement,
  dropZone: document.getElementById("drop-zone") as HTMLElement,
  fileInput: document.getElementById("file-input") as HTMLInputElement,
  progressBar: document.getElementById("progress-bar") as HTMLElement,
  status: document.getElementById("status") as HTMLElement,
  stats: document.getElementById("stats") as HTMLElement,
  statRead: document.getElementById("stat-read") as HTMLElement,
  statCompanies: document.getElementById("stat-companies") as HTMLElement,
  statPersons: document.getElementById("stat-persons") as HTMLElement,
  statElapsed: document.getElementById("stat-elapsed") as HTMLElement,
  statSpeed: document.getElementById("stat-speed") as HTMLElement,
};

const hasOpenPicker = typeof window.showOpenFilePicker === "function";
const hasDirPicker = typeof window.showDirectoryPicker === "function";
const canStreamToDisk = hasDirPicker;

let inputFile: File | null = null;
let outputDir: FileSystemDirectoryHandle | null = null;
let companiesChunks: Uint8Array[] = [];
let personsChunks: Uint8Array[] = [];
let companiesWritable: FileSystemWritableFileStream | null = null;
let personsWritable: FileSystemWritableFileStream | null = null;
let worker: Worker | null = null;
let converting = false;

/** Injected by production build; falls back for local tooling. */
declare const __WORKER_URL__: string | undefined;

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

function setProgress(bytesRead: number, totalBytes: number): void {
  const pct = totalBytes > 0 ? Math.min(100, (bytesRead / totalBytes) * 100) : 0;
  el.progressBar.style.width = `${pct.toFixed(2)}%`;
}

function updateConvertEnabled(): void {
  el.btnConvert.disabled = !(inputFile && !converting && (canStreamToDisk ? !!outputDir : true));
}

function setInputFile(file: File | null): void {
  inputFile = file;
  el.inputName.textContent = file ? `${file.name} (${formatBytes(file.size)})` : "No file selected";
  updateConvertEnabled();
}

function isAbortError(err: unknown): boolean {
  return err instanceof DOMException && err.name === "AbortError";
}

function resolveAssetUrl(url: string): string {
  if (/^(https?:|blob:|data:)/i.test(url)) return url;
  if (url.startsWith("/")) return new URL(url, self.location.origin).href;
  return new URL(url, self.location.href).href;
}

async function pickInputFile(): Promise<void> {
  if (hasOpenPicker) {
    try {
      const [handle] = await window.showOpenFilePicker!({
        multiple: false,
        types: [
          {
            description: "Companies House officers bulk data",
            accept: {
              "application/octet-stream": [".dat"],
              "text/plain": [".dat", ".txt"],
            },
          },
        ],
      });
      setInputFile(await handle.getFile());
      return;
    } catch (err) {
      if (isAbortError(err)) return;
    }
  }
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
    const cHandle = await outputDir.getFileHandle(`companies_data_${base}.csv`, { create: true });
    const pHandle = await outputDir.getFileHandle(`persons_data_${base}.csv`, { create: true });
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
  const src =
    typeof __WORKER_URL__ !== "undefined" ? __WORKER_URL__ : "./worker.js";
  return new Worker(src, { type: "module" });
}

async function startConvert(): Promise<void> {
  if (!inputFile || converting) return;
  if (canStreamToDisk && !outputDir) {
    setStatus("Choose an output folder first.", "error");
    return;
  }

  const base = basenameWithoutExt(inputFile.name);
  setConverting(true);
  el.stats.hidden = false;
  el.statRead.textContent = "0 B";
  el.statCompanies.textContent = "0";
  el.statPersons.textContent = "0";
  el.statElapsed.textContent = "—";
  el.statSpeed.textContent = "—";
  setProgress(0, inputFile.size);
  setStatus("Starting…");

  try {
    await openWritables(base);
  } catch (err) {
    setConverting(false);
    setStatus(`Could not create output files: ${String(err)}`, "error");
    return;
  }

  worker = createConverterWorker();
  let chain: Promise<void> = Promise.resolve();
  worker.onmessage = (ev: MessageEvent<WorkerOutMessage>) => {
    chain = chain
      .then(() => handleWorkerMessage(ev.data, base))
      .catch((err) => failConvert(String(err)));
  };
  worker.onerror = (ev) => {
    void failConvert(`Worker error: ${ev.message || "unknown"}`);
  };

  worker.postMessage({
    type: "convert",
    file: inputFile,
    wasmUrl: resolveAssetUrl(String(wasmUrl)),
  });
}

async function handleWorkerMessage(msg: WorkerOutMessage, base: string): Promise<void> {
  switch (msg.type) {
    case "progress": {
      setProgress(msg.bytesRead, msg.totalBytes);
      el.statRead.textContent = `${formatBytes(msg.bytesRead)} / ${formatBytes(msg.totalBytes)}`;
      el.statCompanies.textContent = formatNumber(msg.companies);
      el.statPersons.textContent = formatNumber(msg.persons);
      const pct =
        msg.totalBytes > 0 ? ((msg.bytesRead / msg.totalBytes) * 100).toFixed(1) : "0";
      setStatus(`Converting… ${pct}%`);
      break;
    }
    case "batch": {
      try {
        await writeBatch(msg.kind, msg.data);
      } catch (err) {
        await failConvert(`Write failed: ${String(err)}`);
      }
      break;
    }
    case "done": {
      try {
        await closeWritables();
        if (!canStreamToDisk || !outputDir) downloadFallback(base);
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
        setProgress(msg.bytesRead, msg.bytesRead);
        setStatus(
          `Done — ${formatNumber(msg.companies)} companies, ${formatNumber(msg.persons)} persons.`,
          "ok",
        );
      } catch (err) {
        setStatus(`Failed to close outputs: ${String(err)}`, "error");
      } finally {
        teardownWorker();
        setConverting(false);
      }
      break;
    }
    case "cancelled": {
      await abortWritables();
      setStatus("Cancelled.", "error");
      teardownWorker();
      setConverting(false);
      break;
    }
    case "error": {
      await failConvert(msg.code != null ? `${msg.message} (code ${msg.code})` : msg.message);
      break;
    }
  }
}

async function failConvert(message: string): Promise<void> {
  await abortWritables();
  setStatus(message, "error");
  teardownWorker();
  setConverting(false);
}

function teardownWorker(): void {
  if (worker) {
    worker.terminate();
    worker = null;
  }
}

function cancelConvert(): void {
  if (!converting || !worker) return;
  worker.postMessage({ type: "cancel" });
  setStatus("Cancelling…");
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
    const file = e.dataTransfer?.files?.[0];
    if (file) setInputFile(file);
  });
  zone.addEventListener("click", () => {
    if (!converting) void pickInputFile();
  });
  zone.addEventListener("keydown", (e) => {
    if ((e.key === "Enter" || e.key === " ") && !converting) {
      e.preventDefault();
      void pickInputFile();
    }
  });
}

/**
 * Progressive enhancement: register the service worker only when supported.
 * Failures are silent — the converter works fully without offline caching.
 */
function registerServiceWorker(): void {
  if (!("serviceWorker" in navigator)) return;
  // Relative to the page so GitHub project pages (/repo/) stay in scope.
  const swUrl = new URL("./sw.js", self.location.href);
  window.addEventListener("load", () => {
    void navigator.serviceWorker.register(swUrl, { scope: "./" }).catch(() => {
      /* optional enhancement */
    });
  });
}

function init(): void {
  el.capability.hidden = false;
  if (canStreamToDisk) {
    el.capability.className = "banner ok";
    el.capability.textContent =
      "Direct-to-folder writing is available in this browser (Chrome or Edge recommended).";
  } else {
    el.capability.className = "banner warn";
    el.capability.textContent =
      "This browser will download results into memory. Prefer Chrome or Edge for large files.";
  }

  el.btnOutdir.disabled = !canStreamToDisk;
  el.outdirName.textContent = canStreamToDisk ? "Not chosen" : "Browser downloads";

  el.btnOpen.addEventListener("click", () => void pickInputFile());
  el.btnOutdir.addEventListener("click", () => void pickOutputDir());
  el.btnConvert.addEventListener("click", () => void startConvert());
  el.btnCancel.addEventListener("click", () => cancelConvert());
  el.fileInput.addEventListener("change", () => {
    setInputFile(el.fileInput.files?.[0] ?? null);
    el.fileInput.value = "";
  });
  bindDropZone();
  updateConvertEnabled();
  registerServiceWorker();
}

init();

declare global {
  interface Window {
    showOpenFilePicker?: (options?: {
      multiple?: boolean;
      types?: Array<{ description?: string; accept: Record<string, string[]> }>;
    }) => Promise<FileSystemFileHandle[]>;
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

  declare module "*.wasm" {
    const url: string;
    export default url;
  }
}

export {};
