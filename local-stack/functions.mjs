// Local runner for Supabase Edge Functions. Each function keeps its logic in supabase/functions/<name>/handler.ts
// (a plain `handle(request, env)`); on Supabase, index.ts wraps it with Deno.serve. Run with Node 22+:
//   node --experimental-strip-types local-stack/functions.mjs
import http from 'node:http';
import { existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'supabase', 'functions');
const port = Number(process.env.FUNCTIONS_PORT ?? 54332);
http.createServer(async (req, res) => {
  const name = (req.url ?? '/').split('?')[0].split('/').filter(Boolean)[0];
  const file = name && join(root, name, 'handler.ts');
  if (!file || !existsSync(file)) { res.writeHead(404, { 'content-type': 'application/json' }); return res.end('{"error":"no such function"}'); }
  const chunks = []; for await (const c of req) chunks.push(c);
  const request = new Request(`http://local${req.url}`, { method: req.method, headers: req.headers,
    body: ['GET', 'HEAD'].includes(req.method) ? undefined : Buffer.concat(chunks) });
  try {
    const { handle } = await import(pathToFileURL(file).href);
    const out = await handle(request, process.env);
    res.writeHead(out.status, Object.fromEntries(out.headers)); res.end(Buffer.from(await out.arrayBuffer()));
  } catch (e) { res.writeHead(500, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: String(e?.message ?? e) })); }
}).listen(port, '127.0.0.1', () => console.log(`functions on ${port}`));
