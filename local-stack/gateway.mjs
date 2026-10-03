// One URL like a Supabase project: /rest/v1 -> PostgREST, /auth/v1 -> Auth, /functions/v1/<name> -> local function runner,
// /storage/v1 -> the Storage stand-in.
import http from 'node:http';
const port = Number(process.env.GATEWAY_PORT ?? 54321);
const routes = [
  ['/rest/v1', Number(process.env.PGRST_PORT ?? 54330)],
  ['/auth/v1', Number(process.env.AUTH_PORT ?? 54331)],
  ['/functions/v1', Number(process.env.FUNCTIONS_PORT ?? 54332)],
  ['/storage/v1', Number(process.env.STORAGE_PORT ?? 54333)],
];
http.createServer((req, res) => {
  const hit = routes.find(([p]) => req.url === p || req.url.startsWith(p + '/') || req.url.startsWith(p + '?'));
  const cors = { 'access-control-allow-origin': req.headers.origin ?? '*', 'access-control-allow-credentials': 'true',
    'access-control-allow-headers': req.headers['access-control-request-headers'] ?? '*',
    'access-control-allow-methods': 'GET,POST,PATCH,PUT,DELETE,OPTIONS', 'access-control-expose-headers': 'content-range,content-profile' };
  if (req.method === 'OPTIONS') { res.writeHead(204, cors); return res.end(); }
  if (!hit) { res.writeHead(404, cors); return res.end('{"message":"no route"}'); }
  const path = req.url.slice(hit[0].length) || '/';
  const up = http.request({ host: '127.0.0.1', port: hit[1], path, method: req.method, headers: { ...req.headers, host: `127.0.0.1:${hit[1]}` } }, (u) => {
    const h = { ...u.headers }; delete h['access-control-allow-origin'];
    res.writeHead(u.statusCode, { ...h, ...cors }); u.pipe(res);
  });
  up.on('error', (e) => { res.writeHead(502, cors); res.end(JSON.stringify({ message: `upstream ${hit[0]}: ${e.message}` })); });
  req.pipe(up);
}).listen(port, '127.0.0.1', () => console.log(`gateway on http://127.0.0.1:${port}`));
