#!/usr/bin/env node
// Serves web/dist the way the production host does, for the production-build tests (playwright.prod.config.ts) and
// for rehearsing the acceptance run. It is NOT the production server; it copies the three behaviours of a static host
// (Cloudflare static assets, Netlify) that a plain file server does not have and that have broken apps at go-live:
//   1. the headers in dist/_headers are sent, so the Content-Security-Policy is really enforced by the browser
//   2. any path that is not a file answers with the app (single-page application fallback)
//   3. /index.html redirects to / (the service worker must cope with that, see public/sw.js)
// Text files are gzipped, so transfer sizes measured against it are comparable with a real host (which does at least that).
import http from 'node:http';
import { gzipSync } from 'node:zlib';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'dist');
const port = Number(process.env.PORT ?? 4173);
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon' };

/** dist/_headers → [{ pattern, headers }] (the subset of the format the app uses: a path, optionally ending in *). */
export function parseHeaders(text) {
  const rules = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim() || line.trim().startsWith('#')) continue;
    if (!/^\s/.test(line)) rules.push({ pattern: line.trim(), headers: {} });
    else if (rules.length) { const i = line.indexOf(':'); rules.at(-1).headers[line.slice(0, i).trim()] = line.slice(i + 1).trim(); }
  }
  return rules;
}
const matches = (pattern, path) => (pattern.endsWith('*') ? path.startsWith(pattern.slice(0, -1)) : path === pattern);

const rules = existsSync(join(root, '_headers')) ? parseHeaders(readFileSync(join(root, '_headers'), 'utf8')) : [];
const gz = new Map();

http.createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (path === '/index.html') { res.writeHead(307, { location: '/' }); return res.end(); }
  let file = resolve(root, '.' + path);
  const isFile = file.startsWith(root) && existsSync(file) && statSync(file).isFile() && !path.startsWith('/_headers');
  if (!isFile) {
    if (extname(path)) { res.writeHead(404, { 'content-type': 'text/plain' }); return res.end('not found'); }
    file = join(root, 'index.html');                                              // the app answers for every route
  }
  const headers = { 'content-type': TYPES[extname(file)] ?? 'application/octet-stream' };
  for (const r of rules) if (matches(r.pattern, path)) Object.assign(headers, r.headers);
  let body = readFileSync(file);
  if (/text|javascript|json|svg/.test(headers['content-type']) && /\bgzip\b/.test(req.headers['accept-encoding'] ?? '')) {
    if (!gz.has(file)) gz.set(file, gzipSync(body));
    body = gz.get(file); headers['content-encoding'] = 'gzip'; headers.vary = 'accept-encoding';
  }
  res.writeHead(200, headers); res.end(body);
}).listen(port, '127.0.0.1', () => console.log(`dist served like the production host on http://127.0.0.1:${port} (${rules.length} header rules)`));
