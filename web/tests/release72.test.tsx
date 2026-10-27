// Migration 72 (Phase 3, release 5 of Veda's combined brief of 19 Oct 2026: Part E3, Part F, A4; item 71). The rules are
// the database's (tests/67_showcase_lifetime.sql); these hold the browser's and the host's side: the badge drawn the same
// by the app and by the host's /api/badge, never "Verified" when the client is not, its snippet linking to the page; the
// host's function finding its project and asking app.showcase_badge; the showcase page (figures, recalls, partners, the
// status banners, after its lifetime, none); "Verify any pack"; the owner's card (approve after a confirmation,
// unpublish with a reason, the snippet once published); the verify page of an output past its lifetime; the notice
// before the accounts close; item 71 (the Audit log's references; an order pack's files stored at its first opening).
import { afterEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { badgeSnippet, badgeSvg, BADGE_WORDS, type BadgeState } from '../src/lib/badge';
import { figure, verifyPath, type ShowcaseData, type ShowcaseOf } from '../src/lib/showcase';
import { noticeText } from '../src/lib/clients';
import { clientAct, refOf } from '../src/pages/system/System';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';

vi.mock('../src/auth/AuthProvider', async (orig) => ({ ...(await orig<typeof import('../src/auth/AuthProvider')>()), useAuth: () => ({ ctx: null }) }));
const root = join(__dirname, '../..');
const tr = (d: Record<string, string>) => (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = d[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
const T = tr({ ...enPublic, ...en });
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

const data: ShowcaseData = {
  code: 'PRSDM', name: 'GrainVeda (Prasaadam trade scope)', own_brand: true, expired: false,
  verification: { status: 'active', ended_on: null },
  totals: { tonnes: 1.25, villages: 3, gi_pct: 62.5, lab_pass_pct: 100, states: 2, crops: 1 },
  states: [{ state: 'Assam', status: 'paused', ended_on: null, crops: [{ crop: 'Kalanamak rice', gi_tag: 'GI 280', season: 'KH26', tonnes: 0.25, villages: 1, gi_pct: null, lab_pass_pct: 100 }] },
    { state: 'Uttar Pradesh', status: 'active', ended_on: null, crops: [{ crop: 'Kalanamak rice', gi_tag: 'GI 280', season: 'KH26', tonnes: 1, villages: 2, gi_pct: 62.5, lab_pass_pct: 100 }] }],
  recalls: [{ qr_code: 'GV-7FA853226C45', crop: 'Kalanamak rice', season: 'KH26', at: '2026-10-27T05:00:00Z', reason: 'practice recall: moisture complaint' }],
  partners: ['Named Partner FPO'],
};

describe('E3 · the badge', () => {
  const states: BadgeState[] = [
    { status: 'active', name: 'Test Client UP', code: 'TCUP' }, { status: 'paused', name: 'Test Client UP', code: 'TCUP' },
    { status: 'ended', name: 'Test Client UP', code: 'TCUP', ended_on: '2026-10-27' }, { status: 'none', code: 'TCUP' },
    { status: 'active', name: 'GrainVeda (Prasaadam trade scope)', code: 'PRSDM', own_brand: true }, { status: 'active', name: '<script>x</script> & "co"', code: 'X1' }];
  it('the app and the host draw the same badge, in both languages', async () => {
    // @ts-ignore -- a plain JavaScript module (Vercel runs it as it is)
    const host = await import('../api/badge.js');
    for (const b of states) for (const l of ['en', 'hi'] as const) expect(host.badgeSvg(b, l)).toBe(badgeSvg(b, l));
  });
  it('never "Verified" when the client is not; the date of the end; own brand said; names escaped', () => {
    expect(badgeSvg({ status: 'active', name: 'A' })).toContain('Verified by GrainVeda');
    for (const s of ['paused', 'ended', 'none'] as const) expect(badgeSvg({ status: s, name: 'A', ended_on: '2026-10-27' })).not.toContain('Verified by');
    expect(badgeSvg({ status: 'paused', name: 'A' })).toContain('Verification paused');
    expect(badgeSvg({ status: 'ended', name: 'A', ended_on: '2026-10-27' })).toContain('Verification ended on 27 Oct 2026');
    expect(badgeSvg({ status: 'none', code: 'TCUP' })).toContain('No showcase page');
    expect(badgeSvg({ status: 'active', name: 'P', own_brand: true })).toContain('Operated by GrainVeda (own brand)');
    expect(badgeSvg({ status: 'none', code: 'P', own_brand: true })).not.toContain('own brand');
    const x = badgeSvg(states[5]);
    expect(x).not.toContain('<script>'); expect(x).toContain('&lt;script&gt;');
    expect(badgeSvg({ status: 'paused', name: 'A' }, 'hi')).toContain(BADGE_WORDS.hi.paused);
    expect(BADGE_WORDS.en.paused).toBe(enPublic['pv.verification_paused']);
    expect(BADGE_WORDS.en.active).toBe(enPublic['sc.st.active']);
    expect(BADGE_WORDS.hi.active).toBe(hiPublic['sc.st.active']);
  });
  it('the snippet: the badge, linking to the page', () => {
    const s = badgeSnippet('https://app.test', 'TCUP', 'Test Client UP');
    expect(s).toBe('<a href="https://app.test/verified/TCUP" target="_blank" rel="noopener"><img src="https://app.test/api/badge?c=TCUP" alt="Verified by GrainVeda: Test Client UP" width="240" height="64"></a>');
    expect(badgeSnippet('https://app.test', 'TCUP', 'T', 'hi')).toContain('/api/badge?c=TCUP&l=hi');
  });
  it('the host\'s function: its project from the host\'s own app; the badge from app.showcase_badge; anything else, none', async () => {
    // @ts-ignore -- a plain JavaScript module
    const host = await import('../api/badge.js');
    const calls: string[] = [];
    const get = vi.fn(async (u: string, init?: RequestInit) => {
      calls.push(String(u));
      if (String(u) === 'https://app.test/') return new Response('<script type="module" src="/assets/index-abc.js"></script>');
      if (String(u) === 'https://app.test/assets/index-abc.js') return new Response('const u="https://abcdefghijklmnopqrst.supabase.co",k="sb_publishable_abcdefghij1234567890";');
      if (String(u).endsWith('/rest/v1/rpc/showcase_badge')) {
        expect(JSON.parse(String(init?.body))).toEqual({ p_code: 'TCUP' });
        expect((init?.headers as Record<string, string>)['content-profile']).toBe('app');
        return new Response(JSON.stringify({ status: 'paused', name: 'Test Client UP', code: 'TCUP', own_brand: false }), { status: 200 });
      }
      return new Response('', { status: 404 });
    });
    const r = await host.answer(new Request('https://app.test/api/badge?c=tcup'), get);
    expect(r.headers.get('content-type')).toContain('image/svg+xml');
    expect(r.headers.get('cache-control')).toBe('public, max-age=300');
    const body = await r.text();
    expect(body).toContain('Verification paused'); expect(body).toContain('Test Client UP');
    expect(calls).toContain('https://abcdefghijklmnopqrst.supabase.co/rest/v1/rpc/showcase_badge');
    const bad = await host.answer(new Request('https://app.test/api/badge?c=%3Cscript%3E'), get);
    expect(await bad.text()).toContain('No showcase page');
    const s = readFileSync(join(root, 'web/api/badge.js'), 'utf8');
    expect(s).not.toMatch(/SERVICE_ROLE/); expect(s).toContain("export const config = { runtime: 'edge' }");
  });
});

describe('E3 · the showcase page', () => {
  const page = async (d: ShowcaseData | null) => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockResolvedValue(d as never);
    const { default: Showcase } = await import('../src/pages/public/Showcase');
    render(<MemoryRouter initialEntries={['/verified/PRSDM']}><Routes><Route path="/verified/:code" element={<Showcase />} />
      <Route path="/verify/:code" element={<p data-testid="went">went</p>} /></Routes></MemoryRouter>);
  };
  it('the name, own brand, the figures, each state with its status, the recall, the named partner', async () => {
    await page(data);
    expect((await screen.findByTestId('sc-name')).textContent).toBe('GrainVeda (Prasaadam trade scope)');
    expect(screen.getByTestId('sc-own-brand').textContent).toBe('Operated by GrainVeda (own brand)');
    expect(screen.getByTestId('sc-banner').getAttribute('data-status')).toBe('active');
    expect(screen.getByTestId('sc-tonnes').textContent).toBe('1.25 t');
    expect(screen.getByTestId('sc-gi').textContent).toBe('62.5 %');
    const assam = screen.getAllByTestId('sc-state').find((x) => x.getAttribute('data-state') === 'Assam')!;
    expect(assam.textContent).toContain('Verification paused');
    expect(screen.getByTestId('sc-recall').textContent).toContain('GV-7FA853226C45');
    expect(screen.getByTestId('sc-recall').textContent).toContain('practice recall: moisture complaint');
    expect(screen.getByTestId('sc-partners').textContent).toContain('Named Partner FPO');
    expect(screen.getByTestId('sc-footer').textContent).toContain('It is not a quality, residue or Geographical Indication certificate.');
    fireEvent.change(screen.getByTestId('sc-code'), { target: { value: ' tcup-knm-kh26-b0001-0011 ' } });
    fireEvent.click(screen.getByTestId('sc-go'));
    expect(await screen.findByTestId('went')).toBeTruthy();
  });
  it('paused and ended say so, never "Verified"; after its lifetime only that; none published: nothing', async () => {
    await page({ ...data, verification: { status: 'paused', ended_on: null } });
    expect((await screen.findByTestId('sc-banner')).textContent).toContain('Verification paused');
    cleanup();
    await page({ ...data, verification: { status: 'ended', ended_on: '2026-10-27' } });
    expect((await screen.findByTestId('sc-banner')).textContent).toContain('Verification ended on 27 Oct 2026');
    cleanup();
    await page({ code: 'PRSDM', name: 'GrainVeda (Prasaadam trade scope)', own_brand: true, expired: true, verification: { status: 'ended', ended_on: '2024-01-10' } });
    expect((await screen.findByTestId('sc-expired')).textContent).toContain('Verification ended on 10 Jan 2024');
    expect(screen.queryByTestId('sc-totals')).toBeNull(); expect(screen.queryByTestId('sc-verify')).toBeNull();
    cleanup();
    await page(null);
    expect((await screen.findByTestId('sc-none')).textContent).toContain('PRSDM');
  });
  it('figures and the verify box\'s address', () => {
    expect(figure('tonnes', 0)).toBe('0 t'); expect(figure('pct', null)).toBe('—'); expect(figure('villages', 1234)).toBe('1,234');
    expect(verifyPath('GV-7fa853226c45')).toBe('/verify/GV-7FA853226C45'); expect(verifyPath('x')).toBeNull(); expect(verifyPath('<a>')).toBeNull();
  });
});

describe('E3 · the owner\'s card', () => {
  const of = (o: Partial<ShowcaseOf>): ShowcaseOf => ({ client_id: 'c1', code: 'TCUP', status: 'never', published_at: null, published_by: null, unpublished_at: null,
    unpublished_by: null, unpublish_reason: null, may_publish: true, may_unpublish: false, live_until: null, preview: { ...data, name: 'Test Client UP', own_brand: false }, ...o });
  it('approve after a confirmation; then the badge and the snippet; unpublish with a reason', async () => {
    const api = await import('../src/lib/api');
    let cur = of({});
    const spy = vi.spyOn(api, 'rpc').mockImplementation(async (fn: string, args?: unknown) => {
      if (fn === 'showcase_publish') cur = of({ status: 'published', published_at: '2026-10-27T05:00:00Z', published_by: 'Owner', may_publish: false, may_unpublish: true });
      if (fn === 'showcase_unpublish') { expect((args as { p_reason: string }).p_reason).toBe('taken down for now'); cur = of({ status: 'unpublished', may_unpublish: false }); }
      return cur as never;
    });
    const { ShowcaseCard } = await import('../src/pages/clients/ShowcaseCard');
    render(<MemoryRouter><ShowcaseCard clientId="c1" /></MemoryRouter>);
    expect((await screen.findByTestId('sh-status')).textContent).toBe(en['scw.never']);
    expect(screen.queryByTestId('sh-badge')).toBeNull();
    fireEvent.click(screen.getByTestId('sh-publish'));
    expect(screen.getByTestId('sh-publish-confirm').textContent).toContain('Anyone with the address');
    fireEvent.click(screen.getByTestId('sh-publish-go'));
    await waitFor(() => expect(spy).toHaveBeenCalledWith('showcase_publish', { p_client: 'c1' }));
    expect((await screen.findByTestId('sh-snippet') as HTMLTextAreaElement).value).toContain('/verified/TCUP');
    expect(screen.getByTestId('sh-badge-img').getAttribute('src')).toMatch(/^data:image\/svg\+xml/);
    fireEvent.click(screen.getByTestId('sh-unpublish'));
    expect((screen.getByTestId('sh-unpublish-go') as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(screen.getByTestId('sh-why'), { target: { value: 'taken down for now' } });
    fireEvent.click(screen.getByTestId('sh-unpublish-go'));
    await waitFor(() => expect(spy).toHaveBeenCalledWith('showcase_unpublish', { p_client: 'c1', p_reason: 'taken down for now' }));
  });
  it('a reader who may do nothing: its state and the preview only', async () => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockResolvedValue(of({ may_publish: false, live_until: '2028-10-27' }) as never);
    const { ShowcaseCard } = await import('../src/pages/clients/ShowcaseCard');
    render(<MemoryRouter><ShowcaseCard clientId="c1" /></MemoryRouter>);
    expect(await screen.findByTestId('sh-preview')).toBeTruthy();
    expect(screen.queryByTestId('sh-publish')).toBeNull(); expect(screen.queryByTestId('sh-unpublish')).toBeNull();
    expect(screen.getByTestId('sh-live-until').textContent).toContain('27 Oct 2028');
  });
});

describe('F, A4 and item 71', () => {
  it('an output\'s verify page after its lifetime: only that verification ended', async () => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockResolvedValue({ ref: 'GV-EP-000004', kind: 'evidence_pack', version: 2, status: 'valid', expired: true, files: [],
      verification: { status: 'ended', ended_on: '2024-01-10' } } as never);
    const { DocumentVerify } = await import('../src/pages/public/DocumentVerify');
    render(<MemoryRouter initialEntries={['/d/GV-EP-000004']}><Routes><Route path="/d/:ref" element={<DocumentVerify />} /></Routes></MemoryRouter>);
    expect((await screen.findByTestId('dv-expired')).textContent).toContain('Verification ended on 10 Jan 2024');
    expect(screen.queryByTestId('dv-status')).toBeNull();
  });
  it('the notice before the accounts close names the day', () => {
    expect(noticeText({ id: '1', kind: 'client_accounts_closing', client_id: 'c', state_id: null, created_at: '', read: false,
      data: { client: 'Test Client UP', on: '2028-10-27' } }, T)).toBe('Test Client UP: its accounts close on 27 Oct 2028, when the time its pages stay live after the contract ended has passed. Take any exports before then.');
  });
  it('item 71: the Audit log names a report\'s or a pack\'s reference; a client\'s showcase lines', () => {
    expect(refOf({ action: 'evidence_pack_issued', detail: { ref: 'GV-EP-000001' } })).toBe('GV-EP-000001');
    expect(refOf({ action: 'report_downloaded', detail: { ref: 'GV-SR-000002' } })).toBe('GV-SR-000002');
    expect(refOf({ action: 'buyer_link_created', detail: { ref: 'GV-EP-000001' } })).toBeNull();
    expect(refOf({ action: 'report_read', detail: { ref: 'javascript:x' } })).toBeNull();
    expect(clientAct('showcase_published')).toBe(true); expect(clientAct('client_accounts_closed')).toBe(true); expect(clientAct('report_read')).toBe(false);
    expect(en['ov.reports_title']).toBe('Reports and evidence packs issued');
  });
  it('item 71: an order pack\'s files are stored the first time its manager opens it; a shipment\'s wait for the click', async () => {
    const packs = await import('../src/lib/evidencePacks');
    const mk = vi.spyOn(packs, 'makePackFiles').mockResolvedValue(undefined);
    const api = await import('../src/lib/api');
    const head = { id: 'p1', ref: 'GV-EP-000002', kind: 'evidence_pack', status: 'valid', version: 1, subject_kind: 'order', subject_code: 'ORD-TCUP-0001',
      issued_at: '2026-10-27T04:24:50Z', issued_by: 'Lucky', auto: true, internal_ok: true, may_store: true, files: {} };
    vi.spyOn(api, 'rpc').mockResolvedValue({ packs: [head, { ...head, id: 'p2', ref: 'GV-EP-000003', subject_kind: 'shipment' }], may_issue: false } as never);
    const { EvidencePacks } = await import('../src/pages/records/EvidencePacks');
    render(<MemoryRouter><EvidencePacks kind="scope" id="s1" /></MemoryRouter>);
    await waitFor(() => expect(mk).toHaveBeenCalledTimes(1));
    expect((mk.mock.calls[0][0] as { id: string }).id).toBe('p1');
  });
  it('every new word in English and Hindi', () => {
    for (const k of Object.keys(en).filter((x) => x.startsWith('scw.') || x === 'note.client_accounts_closing' || x.startsWith('audit.showcase') || x === 'audit.client_accounts_closed'))
      expect(hi[k], k).toBeTruthy();
    for (const k of Object.keys(enPublic).filter((x) => x.startsWith('sc.') || x === 'dv.expired')) expect(hiPublic[k], k).toBeTruthy();
  });
});
