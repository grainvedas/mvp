// Vercel Edge Function (migration 56, D5: Veda, 16 Oct 2026, "proceed with 56"): a scan of a pack's or a lot's QR is
// counted with where the host saw it: the city, the region and the country, and a point rounded to about 10 km
// (app.record_scan_at rounds it again). Vercel puts these in the request's x-vercel-ip-* headers; nothing about the
// person is kept (no address, no device). The page falls back to app.record_scan (no place) when this answers anything
// but JSON: on the local stack, on a host that has no such function (Cloudflare needs its own; docs/FIX_LIST.md item 51).
// POST { code }  →  { counted, copy_warning }
export const config = { runtime: 'edge' };

const head = (req, name) => {
  const v = req.headers.get(name);
  if (!v) return null;
  try { return decodeURIComponent(v).slice(0, 80); } catch { return v.slice(0, 80); }
};
const num = (v) => (v == null || v === '' || Number.isNaN(Number(v)) ? null : Number(v));
const answer = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });

export default async function handler(req) {
  if (req.method !== 'POST') return answer(405, { counted: false });
  const url = process.env.VITE_SUPABASE_URL, anon = process.env.VITE_SUPABASE_ANON_KEY;
  if (!url || !anon) return answer(500, { counted: false, problem: 'not configured' });
  const body = await req.json().catch(() => null);
  const code = body && typeof body.code === 'string' ? body.code.trim() : '';
  if (!code || code.length > 80) return answer(400, { counted: false });
  const r = await fetch(`${url}/rest/v1/rpc/record_scan_at`, {
    method: 'POST',
    headers: { apikey: anon, authorization: `Bearer ${anon}`, 'content-type': 'application/json', 'content-profile': 'app' },
    body: JSON.stringify({ p_code: code, p_city: head(req, 'x-vercel-ip-city'), p_region: head(req, 'x-vercel-ip-country-region'),
      p_country: head(req, 'x-vercel-ip-country'), p_lat: num(req.headers.get('x-vercel-ip-latitude')), p_lng: num(req.headers.get('x-vercel-ip-longitude')) }),
  });
  const out = await r.json().catch(() => null);
  return answer(r.ok && out ? 200 : 502, out && r.ok ? out : { counted: false });
}
