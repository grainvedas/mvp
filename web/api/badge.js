// Vercel Edge Function (migration 72, E3: Veda, 27 Oct 2026, "proceed"): the "Verified by GrainVeda" badge a client puts
// on its own site. GET /api/badge?c=<client code>[&l=hi] answers an SVG drawn from what app.showcase_badge says now, so it
// never looks active when the client is not ("Verification paused", "Verification ended on …", or "No showcase page"
// while none is published). Cached 5 minutes. When the status cannot be read: "Status unavailable", not cached (item 73). The drawing is src/lib/badge.ts's (web/tests/release72.test.tsx keeps the
// two the same).
// Which project: the host's settings if it has them; else the one the host's own app talks to, read once from the app's
// script (its public address and public key, both in the app already); only a Supabase project's address is taken.
export const config = { runtime: 'edge' };

const BADGE_WORDS = {
  en: { active: 'Verified by GrainVeda', paused: 'Verification paused', ended: 'Verification ended on {date}', none: 'No showcase page',
    own: 'Operated by GrainVeda (own brand)', sub: 'Traceability verified under GrainVeda’s protocol',
    unavailable: 'Status unavailable', plain: 'GrainVeda traceability' },
  hi: { active: 'GrainVeda द्वारा सत्यापित', paused: 'सत्यापन रुका हुआ है', ended: 'सत्यापन {date} को समाप्त हुआ', none: 'कोई शोकेस पेज नहीं',
    own: 'GrainVeda द्वारा संचालित (अपना ब्रांड)', sub: 'GrainVeda के प्रोटोकॉल के अंतर्गत सत्यापित ट्रेसबिलिटी',
    unavailable: 'स्थिति अभी उपलब्ध नहीं', plain: 'GrainVeda ट्रेसबिलिटी' },
};
const COLOURS = { active: ['#e8f4ec', '#1e4d35', '#1e7a4a'], paused: ['#fdf3dc', '#7a4b00', '#c98a00'], ended: ['#eef0ef', '#3d4441', '#7a807d'],
  none: ['#eef0ef', '#3d4441', '#7a807d'], unavailable: ['#eef0ef', '#3d4441', '#7a807d'] };
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const cut = (s, n) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);
const badgeDate = (s) => (s ? new Date(`${s.slice(0, 10)}T12:00:00+05:30`).toLocaleDateString('en-IN',
  { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'Asia/Kolkata' }) : '');

export function badgeSvg(b, lang = 'en') {
  const w = BADGE_WORDS[lang] ?? BADGE_WORDS.en;
  const st = ['active', 'paused', 'ended', 'unavailable'].includes(b.status) ? b.status : 'none';
  const [bg, ink, mark] = COLOURS[st];
  const head = st === 'ended' ? w.ended.replace('{date}', badgeDate(b.ended_on)) : w[st];
  const second = st === 'none' || st === 'unavailable' ? (b.code ?? '') : (b.name ?? '');
  /* item 73: "verified" only while active; own brand said whenever the client is known */
  const third = b.own_brand && st !== 'none' && st !== 'unavailable' ? w.own : st === 'active' ? w.sub : w.plain;
  const icon = st === 'active' ? '<path d="M17 32 l7 7 l13 -15" fill="none" stroke="#fff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>'
    : st === 'paused' ? '<rect x="20" y="22" width="6" height="20" rx="1" fill="#fff"/><rect x="31" y="22" width="6" height="20" rx="1" fill="#fff"/>'
    : '<rect x="18" y="29" width="22" height="6" rx="1" fill="#fff"/>';
  return `<svg xmlns="http://www.w3.org/2000/svg" width="240" height="64" viewBox="0 0 240 64" role="img" aria-label="${esc(head)}${second ? `: ${esc(second)}` : ''}">`
    + `<rect x="0.5" y="0.5" width="239" height="63" rx="10" fill="${bg}" stroke="${mark}"/>`
    + `<circle cx="29" cy="32" r="19" fill="${mark}"/>${icon}`
    + `<g font-family="'Noto Sans','Noto Sans Devanagari',Arial,sans-serif" fill="${ink}">`
    + `<text x="56" y="23" font-size="13" font-weight="700">${esc(cut(head, 30))}</text>`
    + `<text x="56" y="40" font-size="11">${esc(cut(second, 34))}</text>`
    + `<text x="56" y="54" font-size="8.5" opacity="0.85">${esc(cut(third, 46))}</text></g></svg>`;
}

const PROJECT = /^https:\/\/[a-z0-9-]{3,63}\.supabase\.co$/;
const KEY = /^[A-Za-z0-9._-]{20,400}$/;
const env = (k) => (typeof process !== 'undefined' && process.env ? process.env[k] : undefined) || undefined;
let found = null;
/** The project: the host's settings, else read from the host's own app (its first script). */
export async function project(origin, get = fetch) {
  const url = env('VITE_SUPABASE_URL') ?? env('NEXT_PUBLIC_SUPABASE_URL');
  const key = env('VITE_SUPABASE_ANON_KEY') ?? env('NEXT_PUBLIC_SUPABASE_ANON_KEY') ?? env('NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY');
  if (url && key) return { url, key };
  if (found) return found;
  const html = await get(`${origin}/`).then((r) => r.text()).catch(() => '');
  const src = (html.match(/src="(\/assets\/[^"]+\.js)"/) || [])[1];
  if (!src) return null;
  const js = await get(`${origin}${src}`).then((r) => r.text()).catch(() => '');
  const u = (js.match(/https:\/\/[a-z0-9-]{3,63}\.supabase\.co/) || [])[0];
  const k = (js.match(/sb_publishable_[A-Za-z0-9_-]{10,200}/) || js.match(/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/) || [])[0];
  if (!u || !k || !PROJECT.test(u) || !KEY.test(k)) return null;
  found = { url: u, key: k };
  return found;
}

const svg = (body, seconds) => new Response(body, { status: 200, headers: { 'content-type': 'image/svg+xml; charset=utf-8',
  'cache-control': seconds > 0 ? `public, max-age=${seconds}` : 'no-store', 'x-content-type-options': 'nosniff' } });

// Vercel calls (request, context); the tests call answer(request, their fetch)
export default async function handler(req) { return answer(req, fetch); }
export async function answer(req, get) {
  const u = new URL(req.url);
  const code = (u.searchParams.get('c') ?? '').trim().toUpperCase().slice(0, 20);
  const lang = u.searchParams.get('l') === 'hi' ? 'hi' : 'en';
  if (!/^[A-Z0-9-]{2,20}$/.test(code)) return svg(badgeSvg({ status: 'none', code: '' }, lang), 300);
  const p = await project(u.origin, get);
  if (!p) return svg(badgeSvg({ status: 'unavailable', code }, lang), 0);   /* item 73: never a wrong status */
  const r = await get(`${p.url}/rest/v1/rpc/showcase_badge`, { method: 'POST',
    headers: { apikey: p.key, authorization: `Bearer ${p.key}`, 'content-type': 'application/json', 'content-profile': 'app' },
    body: JSON.stringify({ p_code: code }) }).catch(() => null);
  const b = r && r.ok ? await r.json().catch(() => null) : null;
  return svg(badgeSvg(b && typeof b.status === 'string' ? { ...b, code } : { status: 'unavailable', code }, lang), b && typeof b.status === 'string' ? 300 : 0);
}
