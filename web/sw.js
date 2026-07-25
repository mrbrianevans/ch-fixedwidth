/**
 * Lean service worker for the static CH converter PWA.
 *
 * Build injects the cache name and precache URL list (see scripts/build.ts).
 * Progressive enhancement: the app works fully without this file.
 *
 * Strategy (all assets are static, same-origin):
 * - install: precache the app shell + WASM + worker
 * - activate: drop old versioned caches, claim clients
 * - fetch: cache-first for same-origin GET; network fallback; cache successful responses
 * - navigate offline: fall back to cached index.html / scope root
 */
/* eslint-disable no-restricted-globals */

const CACHE_NAME = "__CACHE_NAME__";
/** Relative URLs (./…) injected at build time; resolved against the SW script URL. */
const PRECACHE = __PRECACHE__;

/** @param {string} path */
function abs(path) {
  return new URL(path, self.location.href).href;
}

self.addEventListener("install", (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE_NAME);
      // addAll fails the whole install if any URL 404s — add one-by-one so a
      // missing optional asset does not brick updates.
      await Promise.all(
        PRECACHE.map(async (path) => {
          const url = abs(path);
          try {
            const res = await fetch(url, { cache: "reload" });
            if (res.ok) await cache.put(url, res);
          } catch {
            // Offline during install of a new SW — leave for later fetches.
          }
        }),
      );
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)),
      );
      await self.clients.claim();
    })(),
  );
});

/**
 * @param {Request} request
 * @param {Response} response
 */
async function putInCache(request, response) {
  if (!response || !response.ok) return;
  if (response.type !== "basic" && response.type !== "cors") return;
  try {
    const cache = await caches.open(CACHE_NAME);
    await cache.put(request, response.clone());
  } catch {
    // Quota or abort — ignore.
  }
}

/** Offline shell for navigations (scope root and index.html). */
async function matchShell() {
  const candidates = [
    abs("./"),
    abs("./index.html"),
    self.registration.scope,
    new URL("index.html", self.registration.scope).href,
  ];
  for (const url of candidates) {
    const hit = await caches.match(url);
    if (hit) return hit;
  }
  return undefined;
}

self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  event.respondWith(
    (async () => {
      const cached = await caches.match(request);
      if (cached) return cached;

      try {
        const network = await fetch(request);
        event.waitUntil(putInCache(request, network.clone()));
        return network;
      } catch (err) {
        if (request.mode === "navigate") {
          const shell = await matchShell();
          if (shell) return shell;
        }
        throw err;
      }
    })(),
  );
});
