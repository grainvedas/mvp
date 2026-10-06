// Local stand-in for Supabase Storage, for the one private bucket the app uses (`evidence`). Never deployed.
// It speaks the few routes supabase-js and the Edge Functions call, and — the point of having it — it asks Postgres
// whether the caller may write or read an object by doing that INSERT / SELECT on storage.objects AS THE CALLER through
// PostgREST. So the evidence_upload / evidence_read policies of migration 16 are the ones that decide here too, exactly
// as on Supabase; only the byte store (files under local-stack/run/storage) is different.
//
//   POST /object/<bucket>/<path>            upload (multipart from the browser, or a raw body)     user token
//   POST /object/sign/<bucket>/<path>       { expiresIn } → { signedURL }                         user token
//   GET  /object/sign/<bucket>/<path>?token=…   the file                                           the signature
//   GET  /object/<bucket>/<path>  and  /object/authenticated/<bucket>/<path>   the file            user or service token
import http from 'node:http';
import { createHmac, timingSafeEqual } from 'node:crypto';
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const port = Number(process.env.STORAGE_PORT ?? 54333);
const rest = `http://127.0.0.1:${process.env.PGRST_PORT ?? 54330}`;
const secret = process.env.STORAGE_JWT_SECRET ?? '';
const anon = process.env.SUPABASE_ANON_KEY ?? '';
const root = resolve(process.env.STORAGE_DIR ?? join(dirname(fileURLToPath(import.meta.url)), 'run', 'storage'));

const send = (res, status, body, headers = {}) => {
  const data = Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
  res.writeHead(status, { 'content-type': Buffer.isBuffer(body) ? 'application/octet-stream' : 'application/json', ...headers });
  res.end(data);
};
// Supabase Storage answers errors with HTTP 400 and the real status inside the body.
const fail = (res, statusCode, error, message) => send(res, 400, { statusCode: String(statusCode), error, message });

function claims(token) {
  try {
    const [h, b, s] = token.split('.');
    const want = createHmac('sha256', secret).update(`${h}.${b}`).digest();
    const got = Buffer.from(s, 'base64url');
    if (!secret || want.length !== got.length || !timingSafeEqual(want, got)) return null;
    const c = JSON.parse(Buffer.from(b, 'base64url').toString('utf8'));
    return c.exp && c.exp * 1000 < Date.now() ? null : c;
  } catch { return null; }
}
const sign = (key, exp) => createHmac('sha256', secret).update(`${key}|${exp}`).digest('base64url');

/** The file bytes and type from a multipart body (what supabase-js sends from a browser) or a raw body. */
function filePart(req, body) {
  const type = req.headers['content-type'] ?? 'application/octet-stream';
  const m = /^multipart\/form-data;\s*boundary=(?:"([^"]+)"|([^;]+))/i.exec(type);
  if (!m) return { bytes: body, type };
  const boundary = Buffer.from(`--${m[1] ?? m[2]}`);
  let at = body.indexOf(boundary);
  while (at !== -1) {
    const next = body.indexOf(boundary, at + boundary.length);
    if (next === -1) break;
    const part = body.subarray(at + boundary.length + 2, next - 2);            // skip CRLF after the boundary and before the next
    const split = part.indexOf('\r\n\r\n');
    const head = part.subarray(0, split).toString('utf8');
    if (/filename=/i.test(head)) {
      return { bytes: part.subarray(split + 4), type: (/content-type:\s*([^\r\n]+)/i.exec(head)?.[1] ?? 'application/octet-stream').trim() };
    }
    at = next;
  }
  return null;
}

async function db(method, path, token, body, prefer = 'return=representation') {
  const r = await fetch(`${rest}${path}`, {
    method,
    headers: { apikey: anon, authorization: `Bearer ${token}`, 'content-type': 'application/json', 'accept-profile': 'storage',
      'content-profile': 'storage', prefer },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, ok: r.ok, data: await r.json().catch(() => null) };
}
const filePath = (bucket, name) => {
  const p = resolve(root, bucket, name);
  if (!p.startsWith(resolve(root) + '/')) throw new Error('bad path');
  return p;
};
function sendFile(res, bucket, name) {
  const p = filePath(bucket, name);
  if (!existsSync(p)) return fail(res, 404, 'not_found', 'Object not found');
  const type = existsSync(`${p}.type`) ? readFileSync(`${p}.type`, 'utf8') : 'application/octet-stream';
  send(res, 200, readFileSync(p), { 'content-type': type, 'cache-control': 'no-store' });
}

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://local');
    const seg = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
    if (seg[0] !== 'object') return fail(res, 404, 'not_found', 'route not found');
    const token = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
    const who = token ? claims(token) : null;
    const chunks = []; for await (const c of req) chunks.push(c);
    const body = Buffer.concat(chunks);

    // GET a signed URL: the signature is the permission
    if (req.method === 'GET' && seg[1] === 'sign') {
      const [bucket, ...rest_] = seg.slice(2); const name = rest_.join('/');
      const exp = Number(url.searchParams.get('exp')), sig = url.searchParams.get('token') ?? '';
      if (!exp || exp < Date.now() || sig !== sign(`${bucket}/${name}`, exp)) return fail(res, 400, 'InvalidJWT', 'signature expired or wrong');
      return sendFile(res, bucket, name);
    }
    if (!who) return fail(res, 401, 'Unauthorized', 'missing or invalid token');

    // POST …/sign/…: a signed URL for an object the caller may read (evidence_read policy)
    if (req.method === 'POST' && seg[1] === 'sign') {
      const [bucket, ...rest_] = seg.slice(2); const name = rest_.join('/');
      const can = who.role === 'service_role' ? { ok: true, data: [1] }
        : await db('GET', `/objects?select=id&bucket_id=eq.${encodeURIComponent(bucket)}&name=eq.${encodeURIComponent(name)}`, token);
      if (!can.ok || !Array.isArray(can.data) || can.data.length === 0) return fail(res, 404, 'not_found', 'Object not found');
      const seconds = Number(JSON.parse(body.toString('utf8') || '{}').expiresIn ?? 60);
      const exp = Date.now() + seconds * 1000;
      const path = [bucket, ...name.split('/')].map(encodeURIComponent).join('/');
      return send(res, 200, { signedURL: `/object/sign/${path}?token=${sign(`${bucket}/${name}`, exp)}&exp=${exp}` });
    }

    const authed = seg[1] === 'authenticated' ? seg.slice(2) : seg.slice(1);
    const [bucket, ...rest_] = authed; const name = rest_.join('/');
    if (!bucket || !name) return fail(res, 400, 'invalid_request', 'bucket and path are required');

    if (req.method === 'GET') {
      const can = who.role === 'service_role' ? { ok: true, data: [1] }
        : await db('GET', `/objects?select=id&bucket_id=eq.${encodeURIComponent(bucket)}&name=eq.${encodeURIComponent(name)}`, token);
      if (!can.ok || !Array.isArray(can.data) || can.data.length === 0) return fail(res, 404, 'not_found', 'Object not found');
      return sendFile(res, bucket, name);
    }

    if (req.method === 'POST') {
      const part = filePart(req, body);
      if (!part) return fail(res, 400, 'invalid_request', 'no file in the request');
      // the INSERT as the caller is the permission check (evidence_upload policy); a second upload of the same name is a duplicate
      // return=minimal: as on Supabase Storage, a new (non-upsert) upload needs the INSERT policy only. A bucket whose
      // uploader may not read it back (hr-docs: only HR and the admin open a document) must still accept the upload.
      const ins = await db('POST', '/objects', token, { bucket_id: bucket, name, owner: who.sub ?? null }, 'return=minimal');
      if (ins.status === 409) return fail(res, 409, 'Duplicate', 'The resource already exists');
      if (!ins.ok) return fail(res, 403, 'Unauthorized', 'new row violates row-level security policy');
      const p = filePath(bucket, name);
      mkdirSync(dirname(p), { recursive: true });
      writeFileSync(p, part.bytes); writeFileSync(`${p}.type`, part.type);
      return send(res, 200, { Key: `${bucket}/${name}`, Id: ins.data?.[0]?.id ?? null });
    }
    return fail(res, 405, 'method_not_allowed', 'not supported by the local stand-in');
  } catch (e) { send(res, 500, { statusCode: '500', error: 'internal', message: String(e?.message ?? e) }); }
}).listen(port, '127.0.0.1', () => console.log(`storage stand-in on ${port}, files in ${root}`));
