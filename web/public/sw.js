// GrainVeda service worker: lets the app OPEN with no network (PRD §9 offline field capture). Data is not cached here;
// the app keeps what forms need in IndexedDB and queues saves in its outbox. This file only serves the app shell:
//   - page loads: network first, fall back to the last copy of index.html
//   - /assets/* (hashed, never change): cache first
//   - everything else same-origin (icon, manifest): stale-while-revalidate
// Requests to Supabase (another origin) are never touched.
// One cache per build: main.tsx registers /sw.js?v=<build id>, so every deploy installs afresh and drops the old cache.
const CACHE = 'grainveda-shell-' + (new URL(self.location.href).searchParams.get('v') || 'dev');
const SHELL = ['/manifest.webmanifest', '/icon.svg'];

// Precache the shell AND every built file (asset-manifest.json is written by `vite build`), so the signed-in part of
// the app, loaded lazily, also opens offline even if the operator never visited that screen online.
// Static hosts redirect /index.html to / (Cloudflare) and a redirected response may not be used to answer a page
// load. So the shell is fetched from / and stored as a plain copy under both names.
async function plainCopy(res) {
  return new Response(await res.blob(), { status: res.status, statusText: res.statusText, headers: res.headers });
}
async function precache() {
  const c = await caches.open(CACHE);
  const shell = await fetch('/', { cache: 'no-store' });
  if (!shell.ok) throw new Error('app shell not available');
  const copy = await plainCopy(shell);
  await c.put('/index.html', copy.clone());
  await c.put('/', copy);
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
      // keep the newest shell for the next start with no network; only a real page, never an error or a redirect chain
      if (res.ok && (res.headers.get('content-type') ?? '').includes('text/html')) {
        const copy = res.clone();
        e.waitUntil(plainCopy(copy).then((plain) => caches.open(CACHE).then((c) => c.put('/index.html', plain))).catch(() => undefined));
      }
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
