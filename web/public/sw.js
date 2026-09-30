// GrainVeda service worker: lets the app OPEN with no network (PRD §9 offline field capture). Data is not cached here;
// the app keeps what forms need in IndexedDB and queues saves in its outbox. This file only serves the app shell:
//   - page loads: network first, fall back to the last copy of index.html
//   - /assets/* (hashed, never change): cache first
//   - everything else same-origin (icon, manifest): stale-while-revalidate
// Requests to Supabase (another origin) are never touched.
// One cache per build: main.tsx registers /sw.js?v=<build id>, so every deploy installs afresh and drops the old cache.
const CACHE = 'grainveda-shell-' + (new URL(self.location.href).searchParams.get('v') || 'dev');
const SHELL = ['/', '/index.html', '/manifest.webmanifest', '/icon.svg'];

// Precache the shell AND every built file (asset-manifest.json is written by `vite build`), so the signed-in part of
// the app, loaded lazily, also opens offline even if the operator never visited that screen online.
async function precache() {
  const c = await caches.open(CACHE);
  await c.addAll(SHELL);
  try {
    const m = await (await fetch('/asset-manifest.json', { cache: 'no-store' })).json();
    const files = new Set();
    for (const e of Object.values(m)) { files.add('/' + e.file); (e.css || []).forEach((f) => files.add('/' + f)); (e.assets || []).forEach((f) => files.add('/' + f)); }
    await c.addAll([...files]);
  } catch { /* dev server: no manifest, runtime caching still works */ }
}
self.addEventListener('install', (e) => { e.waitUntil(precache().then(() => self.skipWaiting())); });

self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  if (req.mode === 'navigate') {
    e.respondWith(fetch(req).then((res) => {
      const copy = res.clone();
      caches.open(CACHE).then((c) => c.put('/index.html', copy));
      return res;
    }).catch(() => caches.match('/index.html')));
    return;
  }
  if (url.pathname.startsWith('/assets/')) {
    e.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((res) => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
      return res;
    })));
    return;
  }
  e.respondWith(caches.match(req).then((hit) => {
    const net = fetch(req).then((res) => { if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); } return res; })
      .catch(() => hit);
    return hit || net;
  }));
});
