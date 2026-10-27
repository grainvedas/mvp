// FIX_LIST item 73 (Phase 3 close-out, 27 Oct 2026): the small things seen while checking the showcase page on staging.
// (1) The page's line above the name says "verified" only while the client is active; the badge's third line too.
// (2) When the host cannot read the status, the badge says "Status unavailable", not cached, never a wrong status.
// (3) A client's lines in the Audit log (status, gates, documents, renewals) name the client and open its page.
// (4) The unpublish reason box has a name for a screen reader.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { badgeSvg, BADGE_WORDS, type BadgeState } from '../src/lib/badge';
import type { ShowcaseData, ShowcaseOf } from '../src/lib/showcase';
import { clientAct, clientLabel } from '../src/pages/system/System';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';

vi.mock('../src/auth/AuthProvider', async (orig) => ({ ...(await orig<typeof import('../src/auth/AuthProvider')>()), useAuth: () => ({ ctx: null }) }));
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.resetModules(); });

const paused: ShowcaseData = {
  code: 'TCUP', name: 'Test Client UP', own_brand: false, expired: false,
  verification: { status: 'paused', ended_on: null },
  totals: { tonnes: 5.58, villages: 3, gi_pct: 4.8, lab_pass_pct: 100, states: 1, crops: 1 },
  states: [{ state: 'Uttar Pradesh', status: 'paused', ended_on: null, crops: [{ crop: 'Kalanamak Rice', gi_tag: 'GI 280', season: 'KH26', tonnes: 5.58, villages: 3, gi_pct: 4.8, lab_pass_pct: 100 }] }],
  recalls: [], partners: [],
};

describe('item 73 (1), (2): never "verified" when the client is not; never a wrong status', () => {
  const all: BadgeState[] = [{ status: 'active', name: 'T', code: 'TCUP' }, { status: 'paused', name: 'T', code: 'TCUP' },
    { status: 'ended', name: 'T', code: 'TCUP', ended_on: '2026-10-27' }, { status: 'none', code: 'TCUP' }, { status: 'unavailable', code: 'TCUP' },
    { status: 'paused', name: 'P', code: 'PRSDM', own_brand: true }];
  it('the badge: "verified" only while active, in both languages; the app and the host draw the same', async () => {
    // @ts-ignore -- a plain JavaScript module (Vercel runs it as it is)
    const host = await import('../api/badge.js');
    for (const b of all) for (const l of ['en', 'hi'] as const) {
      expect(host.badgeSvg(b, l)).toBe(badgeSvg(b, l));
      if (b.status !== 'active') {
        expect(badgeSvg(b, l).toLowerCase(), `${b.status} ${l}`).not.toContain('verified');
        expect(badgeSvg(b, l), `${b.status} ${l}`).not.toContain(BADGE_WORDS.hi.sub);
        expect(badgeSvg(b, l), `${b.status} ${l}`).not.toContain(BADGE_WORDS.hi.active);
      }
    }
    expect(badgeSvg(all[0])).toContain('Traceability verified under');   // the line, cut to the badge's width
    expect(badgeSvg(all[4])).toContain('Status unavailable'); expect(badgeSvg(all[4], 'hi')).toContain(BADGE_WORDS.hi.unavailable);
    expect(badgeSvg(all[5])).toContain('Operated by GrainVeda (own brand)');
  });
  it('the host: a status it cannot read is "Status unavailable", not cached; a status it reads is drawn and cached', async () => {
    const bundle = (u: string) => (u === 'https://app.test/' ? new Response('<script type="module" src="/assets/index-abc.js"></script>')
      : u === 'https://app.test/assets/index-abc.js' ? new Response('const u="https://abcdefghijklmnopqrst.supabase.co",k="sb_publishable_abcdefghij1234567890";') : null);
    // the database answers an error
    // @ts-ignore -- a plain JavaScript module
    let host = await import('../api/badge.js');
    let r = await host.answer(new Request('https://app.test/api/badge?c=TCUP'), vi.fn(async (u: string) => bundle(String(u)) ?? new Response('{}', { status: 503 })));
    let body = await r.text();
    expect(body).toContain('Status unavailable'); expect(body).not.toContain('No showcase page');
    expect(r.headers.get('cache-control')).toBe('no-store');
    // the database answers a status: drawn, cached 5 minutes
    r = await host.answer(new Request('https://app.test/api/badge?c=TCUP'), vi.fn(async (u: string) => bundle(String(u))
      ?? new Response(JSON.stringify({ status: 'none', code: 'TCUP' }), { status: 200 })));
    expect(await r.text()).toContain('No showcase page'); expect(r.headers.get('cache-control')).toBe('public, max-age=300');
    // no project found in the host's own app
    vi.resetModules();
    // @ts-ignore -- a plain JavaScript module
    host = await import('../api/badge.js');
    r = await host.answer(new Request('https://app.test/api/badge?c=TCUP&l=hi'), vi.fn(async () => new Response('<html></html>')));
    body = await r.text();
    expect(body).toContain(BADGE_WORDS.hi.unavailable); expect(r.headers.get('cache-control')).toBe('no-store');
  });
  it('the page: its line above the name says "verified" only while active', async () => {
    const show = async (d: ShowcaseData) => {
      const api = await import('../src/lib/api');
      vi.spyOn(api, 'rpc').mockResolvedValue(d as never);
      const { default: Showcase } = await import('../src/pages/public/Showcase');
      render(<MemoryRouter initialEntries={['/verified/TCUP']}><Routes><Route path="/verified/:code" element={<Showcase />} /></Routes></MemoryRouter>);
    };
    await show(paused);
    expect((await screen.findByTestId('sc-eyebrow')).textContent).toBe('Showcase · GrainVeda');
    expect(screen.getByTestId('showcase').textContent).not.toMatch(/verified by GrainVeda/i);
    cleanup();
    await show({ ...paused, verification: { status: 'ended', ended_on: '2026-10-27' }, states: [{ ...paused.states![0], status: 'ended', ended_on: '2026-10-27' }] });
    expect((await screen.findByTestId('sc-eyebrow')).textContent).toBe('Showcase · GrainVeda');
    cleanup();
    await show({ ...paused, verification: { status: 'active', ended_on: null }, states: [{ ...paused.states![0], status: 'active' }] });
    expect((await screen.findByTestId('sc-eyebrow')).textContent).toBe('Showcase · verified by GrainVeda');
  });
});

describe('item 73 (3), (4)', () => {
  it('a client\'s lines in the Audit log name the client and open its page', () => {
    for (const a of ['client_status', 'client_created', 'client_state_added', 'client_kyc', 'client_document', 'client_renewal_accepted',
      'client_activation_approved', 'showcase_published', 'client_accounts_closed']) expect(clientAct(a), a).toBe(true);
    for (const a of ['client_account_owner', 'client_login_created', 'client_order_created', 'client_acceptance', 'report_read']) expect(clientAct(a), a).toBe(false);
    const line = { target: 'c1', target_name: null, detail: { state_id: 's1', to: 'suspended' } };
    expect(clientLabel(line, { c1: 'TCUP' }, 'a client')).toBe('TCUP');
    expect(clientLabel(line, {}, 'a client')).toBe('a client');
    expect(clientLabel({ ...line, detail: { code: 'PRSDM' } }, { c1: 'TCUP' }, 'a client')).toBe('PRSDM');
  });
  it('the unpublish reason box has a name', async () => {
    const api = await import('../src/lib/api');
    const of: ShowcaseOf = { client_id: 'c1', code: 'TCUP', status: 'published', published_at: '2026-10-27T09:24:00Z', published_by: 'Owner', unpublished_at: null,
      unpublished_by: null, unpublish_reason: null, may_publish: false, may_unpublish: true, live_until: null, preview: { ...paused, verification: { status: 'active', ended_on: null } } };
    vi.spyOn(api, 'rpc').mockResolvedValue(of as never);
    const { ShowcaseCard } = await import('../src/pages/clients/ShowcaseCard');
    render(<MemoryRouter><ShowcaseCard clientId="c1" /></MemoryRouter>);
    fireEvent.click(await screen.findByTestId('sh-unpublish'));
    const why = screen.getByTestId('sh-why');
    expect(why.getAttribute('aria-label')).toBeTruthy();
    expect(why.getAttribute('aria-label')).toBe(why.closest('label')!.textContent!.trim());   // the label's own words
  });
  it('every new word in English and Hindi', () => {
    expect(hi['audit.a_client']).toBeTruthy(); expect(en['audit.a_client']).toBe('a client');
    expect(enPublic['sc.eyebrow_plain']).toBe('Showcase · GrainVeda'); expect(hiPublic['sc.eyebrow_plain']).toBeTruthy();
    for (const k of ['unavailable', 'plain']) { expect(BADGE_WORDS.en[k], k).toBeTruthy(); expect(BADGE_WORDS.hi[k], k).toBeTruthy(); }
  });
});
