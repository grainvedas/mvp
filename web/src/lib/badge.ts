// Migration 72 (E3): the "Verified by GrainVeda" badge a client puts on its own site, linking to its showcase page. The
// host draws it at /api/badge?c=<code> (web/api/badge.js, the same drawing: tests/release72.test.tsx keeps the two
// the same) from what app.showcase_badge says, so it never looks active when the client is not: "Verification paused",
// "Verification ended on …", or "No showcase page" while none is published. An own-brand client's badge says so.
// Pure: no fetch.
export interface BadgeState { status: 'active' | 'paused' | 'ended' | 'none'; name?: string | null; code?: string | null; ended_on?: string | null; own_brand?: boolean | null }
export type BadgeLang = 'en' | 'hi';

export const BADGE_WORDS: Record<BadgeLang, Record<string, string>> = {
  en: { active: 'Verified by GrainVeda', paused: 'Verification paused', ended: 'Verification ended on {date}', none: 'No showcase page',
    own: 'Operated by GrainVeda (own brand)', sub: 'Traceability verified under GrainVeda’s protocol' },
  hi: { active: 'GrainVeda द्वारा सत्यापित', paused: 'सत्यापन रुका हुआ है', ended: 'सत्यापन {date} को समाप्त हुआ', none: 'कोई शोकेस पेज नहीं',
    own: 'GrainVeda द्वारा संचालित (अपना ब्रांड)', sub: 'GrainVeda के प्रोटोकॉल के अंतर्गत सत्यापित ट्रेसबिलिटी' },
};
const COLOURS = { active: ['#e8f4ec', '#1e4d35', '#1e7a4a'], paused: ['#fdf3dc', '#7a4b00', '#c98a00'], ended: ['#eef0ef', '#3d4441', '#7a807d'],
  none: ['#eef0ef', '#3d4441', '#7a807d'] } as const;

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
const cut = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);
/** Pure: a date as the page writes it (27 Oct 2026, India's time). */
export const badgeDate = (s?: string | null) => (s ? new Date(`${s.slice(0, 10)}T12:00:00+05:30`).toLocaleDateString('en-IN',
  { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'Asia/Kolkata' }) : '');

/** Pure: the badge as SVG text, 240 × 64. */
export function badgeSvg(b: BadgeState, lang: BadgeLang = 'en'): string {
  const w = BADGE_WORDS[lang] ?? BADGE_WORDS.en;
  const st = (['active', 'paused', 'ended'] as const).includes(b.status as 'active') ? b.status : 'none';
  const [bg, ink, mark] = COLOURS[st];
  const head = st === 'ended' ? w.ended.replace('{date}', badgeDate(b.ended_on)) : w[st];
  const second = st === 'none' ? (b.code ?? '') : (b.name ?? '');
  const third = b.own_brand && st !== 'none' ? w.own : w.sub;
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

/** Pure: the snippet a client copies onto its own site: the badge, linking to its showcase page. */
export function badgeSnippet(origin: string, code: string, name: string, lang: BadgeLang = 'en'): string {
  const c = encodeURIComponent(code);
  return `<a href="${origin}/verified/${c}" target="_blank" rel="noopener"><img src="${origin}/api/badge?c=${c}${lang === 'hi' ? '&l=hi' : ''}" `
    + `alt="${esc(`${BADGE_WORDS[lang].active}: ${name}`)}" width="240" height="64"></a>`;
}
