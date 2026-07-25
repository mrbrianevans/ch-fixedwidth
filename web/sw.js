/**
 * Lean service worker for the static CH converter PWA.
 *
 * Build injects the cache name and precache URL list (see vite.config.ts).
 * Progressive enhancement: the app works fully without this file.
 *
 * Strategy:
 * - install: precache app shell + assets
 * - activate: drop old caches, claim clients
 * - navigate (HTML): network-first so deploys are not stuck on a stale shell
 * - other same-origin GET: cache-first, then network
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
      await Promise.all(
        PRECACHE.map(async (path) => {
          const url = abs(path);
          try {
            const res = await fetch(url, { cache: "reload" });
            if (res.ok) await cache.put(url, res);
          } catch {
            /* offline during install */
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
    /* quota / abort */
  }
}

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

  const isNavigate = request.mode === "navigate";
  const isHtml =
    request.headers.get("accept")?.includes("text/html") ||
    url.pathname.endsWith(".html") ||
    url.pathname.endsWith("/");

  if (isNavigate || isHtml) {
    // Network-first so a new deploy is not masked by an old shell.
    event.respondWith(
      (async () => {
        try {
          const network = await fetch(request);
          event.waitUntil(putInCache(request, network.clone()));
          return network;
        } catch {
          const shell = (await caches.match(request)) || (await matchShell());
          if (shell) return shell;
          throw new Error("offline and no cached shell");
        }
      })(),
    );
    return;
  }

  event.respondWith(
    (async () => {
      const cached = await caches.match(request);
      if (cached) return cached;

      const network = await fetch(request);
      event.waitUntil(putInCache(request, network.clone()));
      return network;
    })(),
  );
});
