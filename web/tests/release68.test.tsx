// Migration 68 (Phase 3, release 2 of Veda's combined brief: Parts C and E4, with item 65). The rules and the figures
// are the database's (tests/63_client_views.sql); these hold the screens' side: the portfolio, one scope and across
// scopes show what the server sent (a price only when it sent one); the copy is offered only to those the server says
// may take the internal one; the export's sheets and CSV in the reader's language with the copy's footer; a client
// account says what it is where it is listed; the refusals in plain words; every new word in Hindi.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, waitFor, within, fireEvent } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic } from '../src/lib/i18n.public';
import { plainWords } from '../src/lib/plainErrors';
import { cvCsvRows, cvSheets, cvValue, cvColumn, type ClientExport, type Portfolio, type ScopeDetail, type Across } from '../src/lib/clientViews';
import { figureText } from '../src/pages/clients/Portfolio';
import { NAV, type NavWho } from '../src/shell/Layout';
import { NO_RIGHTS } from '../src/lib/types';

// the signed-in person: none here (GrainVeda's reader opening a client's portfolio from its page)
vi.mock('../src/auth/AuthProvider', async (orig) => ({ ...(await orig<typeof import('../src/auth/AuthProvider')>()), useAuth: () => ({ ctx: null }) }));

const tr = (d: Record<string, string>) => (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = d[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
const T = tr({ ...enPublic, ...en });
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

const fig = { procured_kg: 130, in_process_kg: 60, packed_packs: 20, packed_kg: 20, sold_kg: 5, shipped_kg: 5, released_packs: 5, scans: 3, copy_flags: 1,
  lab_open: 0, lab_waiting: 0, lab_failed: 0, recalls: 1, investigations: 0, waiting: 0 };
const portfolio = (mayInternal = false): Portfolio => ({
  client: { id: 'c1', name: 'Test Client UP', code: 'TCUP' }, may_internal: mayInternal,
  scopes: [{ ...fig, scope_id: 's1', state_id: 'up', state: 'Uttar Pradesh', crop_id: 'k', crop: 'Kalanamak Rice', season: 'KH26', place: 'Bansi', status: 'active',
    delivery_model: 'managed', label: 'Kalanamak Rice · KH26 · Bansi' }],
  groups: [{ ...fig, state_id: 'up', state: 'Uttar Pradesh', crop_id: 'k', crop: 'Kalanamak Rice', scopes: 1 }],
  total: { ...fig, scopes: 1 },
});

describe('C · the figures as the screen shows them', () => {
  it('kilograms with their unit, counts as numbers', () => {
    expect(figureText('procured_kg', 2347.2)).toBe('2,347.2 kg');
    expect(figureText('packed_packs', 20)).toBe('20');
    expect(figureText('scans', 0)).toBe('0');
  });
});

describe('C · the portfolio page', () => {
  it('shows the totals, by state and crop, and each scope with its link; a viewer is offered no internal copy', async () => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockResolvedValue(portfolio(false) as never);
    const { PortfolioPage } = await import('../src/pages/clients/Portfolio');
    render(<MemoryRouter initialEntries={['/portfolio/c1']}><Routes><Route path="/portfolio/:clientId" element={<PortfolioPage />} /></Routes></MemoryRouter>);
    await waitFor(() => expect(screen.getByTestId('cv-totals')).toBeTruthy());
    expect(screen.getByTestId('cv-totals').textContent).toContain('130 kg');
    expect(screen.getAllByTestId('cv-group')).toHaveLength(1);
    const sc = screen.getByTestId('cv-scope');
    expect(within(sc).getByRole('link').getAttribute('href')).toBe('/portfolio/scope/s1');
    expect(within(sc).getAllByTestId('fig-in_process_kg')[0].textContent).toBe('60 kg');
    expect(screen.queryByTestId('cv-copy')).toBeNull();                     // no internal copy offered
    expect(screen.getByTestId('cv-xlsx-portfolio')).toBeTruthy();
    expect(screen.getByText(en['cv.shareable_note'])).toBeTruthy();
  });
  it('the owner chooses the copy; the export asks the server for exactly that view and copy', async () => {
    const api = await import('../src/lib/api');
    const spy = vi.spyOn(api, 'rpc').mockImplementation(((fn: string) => fn === 'client_portfolio' ? Promise.resolve(portfolio(true)) : Promise.reject(new Error('stop here'))) as never);
    const { PortfolioPage } = await import('../src/pages/clients/Portfolio');
    render(<MemoryRouter initialEntries={['/portfolio/c1']}><Routes><Route path="/portfolio/:clientId" element={<PortfolioPage />} /></Routes></MemoryRouter>);
    await waitFor(() => expect(screen.getByTestId('cv-copy')).toBeTruthy());
    fireEvent.change(screen.getByTestId('cv-copy'), { target: { value: 'internal' } });
    expect(screen.getByText(en['cv.internal_note'])).toBeTruthy();
    fireEvent.click(screen.getByTestId('cv-csv-portfolio'));
    await waitFor(() => expect(spy).toHaveBeenCalledWith('export_client_view', { p_view: 'portfolio', p_client: 'c1', p_scope: null, p_copy: 'internal' }));
  });
});

const across = (internal: boolean): Across => ({
  client: { id: 'c1', name: 'Test Client UP', code: 'TCUP' }, may_internal: internal, internal,
  orders: [{ code: 'CM-1', scope_id: 's1', scope: 'Kalanamak Rice · KH26 · Bansi', on: '2026-10-21', buyer: 'Delhi Wholesale', market: 'domestic', destination_country: null,
    order_no: 'PO-1', qty_kg: 5, shipped_kg: 5, status: 'verified', ...(internal ? { price_per_kg: 120, currency: 'INR', total_value: 600 } : {}) }],
  buyers: [{ buyer: 'Delhi Wholesale', orders: 1, qty_kg: 5, shipped_kg: 5 }],
  scans_by_city: [{ city: 'New Delhi', region: 'DL', country: 'IN', scans: 2, last_at: '2026-10-21T10:00:00Z' }],
  copy_flags: [], recalls: [{ qr_code: 'GV-1', scope: 'Bansi', status: 'recalled', reason: 'wrong label', at: '2026-10-21T10:00:00Z' }], outputs: [],
});
describe('C · across scopes', () => {
  it('a viewer: the order without a price, and the note why', async () => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockImplementation(((fn: string) => Promise.resolve(fn === 'client_portfolio' ? portfolio(false) : across(false))) as never);
    const { PortfolioPage } = await import('../src/pages/clients/Portfolio');
    render(<MemoryRouter initialEntries={['/portfolio/c1?tab=across']}><Routes><Route path="/portfolio/:clientId" element={<PortfolioPage />} /></Routes></MemoryRouter>);
    await waitFor(() => expect(screen.getByTestId('cv-order')).toBeTruthy());
    expect(screen.queryByTestId('cv-price')).toBeNull();
    expect(screen.getByText(en['cv.no_prices'])).toBeTruthy();
    expect(screen.getByTestId('cv-recalls').textContent).toContain('wrong label');
  });
  it('the owner: its own price', async () => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockImplementation(((fn: string) => Promise.resolve(fn === 'client_portfolio' ? portfolio(true) : across(true))) as never);
    const { PortfolioPage } = await import('../src/pages/clients/Portfolio');
    render(<MemoryRouter initialEntries={['/portfolio/c1?tab=across']}><Routes><Route path="/portfolio/:clientId" element={<PortfolioPage />} /></Routes></MemoryRouter>);
    await waitFor(() => expect(screen.getByTestId('cv-price')).toBeTruthy());
    expect(screen.getByTestId('cv-price').textContent).toContain('120 INR/kg');
  });
});

const detail: ScopeDetail = {
  client: { id: 'c1', name: 'Test Client UP', code: 'TCUP' }, may_internal: false, internal: false,
  head: { scope_id: 's1', label: 'Kalanamak Rice · KH26 · Bansi', client: 'Test Client UP', crop: 'Kalanamak Rice', gi_tag: 'GI 280', season: 'KH26', geography: 'Bansi',
    state: 'Uttar Pradesh', status: 'active', delivery_model: 'hybrid', markets: ['domestic'], gi_user_no: null, chain: ['procurement', 'qc'] },
  figures: fig,
  pipeline: [{ stage: 'procurement', pos: 1, records: 2, pending: 1, verified: 1, kg_out: 130, kg_waiting: 0 }],
  lots: [{ lot: 'QR-1', qr_code: 'GV-1', sealed_at: '2026-10-21T10:00:00Z', batches: 'B0001', release: 'recalled', packs_live: 5 }],
  batches: [{ batch_code: 'B0001', packs: 20, kg: 20, packed_on: '2026-10-20', best_before: '2027-10-20', released: 5, held: 15, void: 0 }],
  qc: [{ code: 'QC-1', status: 'verified', tested_on: '2026-10-20', lab: 'Gorakhpur Grain Lab', report_no: 'GGL/63', report_date: '2026-10-20', domestic: 'pass', export: null, accepted: false, decided: false }],
  documents: [{ kind: 'lab_report', what: 'GGL/63', status: 'verified', record: 'QC-1', on_file: true, at: null }],
  reports: [],
  people: [{ stage: 'procurement', name: 'Lucky', client_staff: false }, { stage: 'qc', name: 'Practice Staff', client_staff: true }],
};
describe('C · one scope', () => {
  it('the pipeline, lots and batches, QC with its lab and report number, documents, the people by name and role', async () => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockResolvedValue(detail as never);
    const { ScopeView } = await import('../src/pages/clients/Portfolio');
    render(<MemoryRouter initialEntries={['/portfolio/scope/s1']}><Routes><Route path="/portfolio/scope/:scopeId" element={<ScopeView />} /></Routes></MemoryRouter>);
    await waitFor(() => expect(screen.getByTestId('cv-scope-view')).toBeTruthy());
    expect(screen.getByTestId('cv-pipeline').textContent).toContain('130 kg');
    expect(screen.getByTestId('cv-lots').textContent).toContain(en['cv.release.recalled']);
    expect(screen.getByTestId('cv-qc').textContent).toContain('Gorakhpur Grain Lab');
    expect(screen.getByTestId('cv-qc').textContent).toContain('report GGL/63');
    expect(screen.getByTestId('cv-people').textContent).toContain('Practice Staff · client staff');
    expect(screen.getByText(en['sd.hybrid'], { exact: false })).toBeTruthy();
  });
});

const ex = (copy: 'shareable' | 'internal'): ClientExport => ({
  kind: 'client_view', view: 'across', copy, generated_at: '2026-10-26 10:00', generated_by: 'Prasaadam Owner', client: { name: 'Test Client UP', code: 'TCUP' },
  scope: null, units: {},
  tables: [{ key: 'orders', columns: ['code', 'on', 'buyer', 'market', 'qty_kg', 'status'], rows: [['CM-1', '2026-10-21', 'Delhi Wholesale', 'domestic', 5, 'verified']] },
           { key: 'recalls', columns: ['qr_code', 'status', 'at'], rows: [['GV-1', 'recalled', '2026-10-21T10:00:00Z']] }],
});
describe('E4 · the export in the reader\'s language', () => {
  it('values: a stage, a verdict, yes and no, the delivery model, a time in IST', () => {
    expect(cvValue('stage', 'qr_activation', T)).toBe(en['stage.qr_activation']);
    expect(cvValue('domestic', 'fail', T)).toBe('Fail');
    expect(cvValue('client_staff', true, T)).toBe(en['common.yes']);
    expect(cvValue('delivery_model', 'self_run', T)).toBe(en['sd.self_run']);
    expect(cvValue('at', '2026-10-21T10:00:00Z', T)).toBe('2026-10-21 15:30:00 IST');
    expect(cvColumn('procured_kg', T)).toBe('Procured');
    expect(cvColumn('farmer_code', T)).toBe('Farmer ID');
  });
  it('a heading sheet, one sheet per table; the shareable copy\'s footer', () => {
    const { sheets, names } = cvSheets(ex('shareable'), T);
    expect(names).toEqual([en['exp.sheet_heading'], 'Buyers and orders', 'Recalls']);
    expect(sheets).toHaveLength(3);
    const flat = JSON.stringify(sheets);
    expect(flat).toContain('Delhi Wholesale');
    expect(flat).toContain(en['cv.release.recalled']);                    // a value in the reader's words, not "recalled"
    expect(flat).toContain('No prices');                                   // the shareable footer
    expect(flat).not.toContain(en['exp.footer_internal']);
    expect(names.every((n) => n.length <= 31)).toBe(true);
  });
  it('the internal copy says who it is for and not to forward it; the CSV holds every table under its title', () => {
    const flat = JSON.stringify(cvSheets(ex('internal'), T).sheets);
    expect(flat).toContain(en['exp.footer_internal']);
    expect(flat).toContain('For Test Client UP and GrainVeda');
    const rows = cvCsvRows(ex('internal'), T);
    expect(rows.some((r) => r[0] === 'Buyers and orders')).toBe(true);
    expect(rows.some((r) => r[0] === 'Recalls')).toBe(true);
    expect(rows.some((r) => r[0] === en['exp.h.generated_by'] && r[1] === 'Prasaadam Owner')).toBe(true);
  });
});

describe('item 65 · what a client account is, where it shows', () => {
  it('People → Client logins: client staff say so; a suspended account says so', async () => {
    const { AccessBadges } = await import('../src/pages/people/shared');
    render(<AccessBadges systemRole="operational" assignments={[]} elsewhere={0} unassigned={false}
      clientAccount={{ kind: 'operator', status: 'suspended', client_name: 'Test Client UP' }} />);
    expect(screen.getByTestId('client-staff-badge').textContent).toBe('Client staff: Test Client UP');
    expect(screen.getByTestId('client-account-status').textContent).toBe(en['ca.status.suspended']);
  });
  it('an owner\'s client view reads "Client owner", not "read-only"', async () => {
    const { AccessBadges } = await import('../src/pages/people/shared');
    render(<AccessBadges systemRole="operational" elsewhere={0} unassigned={false} clientAccount={{ kind: 'owner', status: 'active', client_name: 'Test Client UP' }}
      assignments={[{ id: 'a', lens: 'client', op_role: 'client_viewer', label: 'Test Client UP', stages: [], active: true } as never]} />);
    expect(screen.getByTestId('access-badges').textContent).toContain('Client owner: Test Client UP');
    expect(screen.getByTestId('access-badges').textContent).not.toContain('read-only');
  });
  it('the menu offers the Portfolio to a client\'s owner and viewers only', () => {
    const who = (clientReader: boolean): NavWho => ({ role: 'client_view', can: NO_RIGHTS, farmerSlot: false, joiner: false, employee: false, clientReader });
    const item = NAV.find((n) => n.to === '/portfolio')!;
    expect(item.show(who(true))).toBe(true);
    expect(item.show(who(false))).toBe(false);
  });
  it('a sign-in that opens nothing tells a client account whom to ask (not only HR)', () => {
    expect(en['signin.no_role']).toContain('account owner');
    expect(hi['signin.no_role']).toContain('ओनर');
  });
});

describe('the database\'s words, in plain words; Hindi for every new word', () => {
  it('the refusals', () => {
    expect(plainWords('not allowed to read this client\'s portfolio', T)).toBe(en['err.cv_not_allowed']);
    expect(plainWords('not allowed to export this scope', T)).toBe(en['err.cv_not_allowed']);
    expect(plainWords('the internal copy is for the people of this client, its owner and the viewers it allowed: take the shareable copy', T)).toBe(en['err.cv_internal']);
    expect(plainWords('the internal copy is for the people of this scope, the client\'s owner and the viewers it allowed: take the shareable copy', T)).toBe(en['err.internal_copy']);
  });
  it('Hindi for every new word', () => {
    const keys = Object.keys(en).filter((x) => x.startsWith('cv.') || x.startsWith('err.cv_') || x.startsWith('audit.export') || x === 'nav.portfolio');
    expect(keys.length).toBeGreaterThan(170);
    for (const k of keys) expect(hi[k], k).toBeTruthy();
  });
  it('no word of before was replaced by this release but the one named (FIX_LIST 63)', () => {
    expect(en['sp.title']).toBe('Same person, next stage');
    expect(en['exp.footer_internal_for']).toBe('For {client} and GrainVeda\'s people on this scope only. Made on {at} IST.');
    expect(en['oprole.client_viewer']).toBe('Client login (read-only)');
  });
});
