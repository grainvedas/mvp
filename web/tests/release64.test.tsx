// Migration 64 (Phase 2, release 1: the client registry). The rules are the database's (tests/59_client_registry.sql);
// these hold the browser's side: the PAN checked early as the server will (format, 4th letter by type), the gates'
// counts and the next move, the record as another state's State Manager sees it (the shared identity only), the
// checklist, the refusals in plain words, and every new word in Hindi.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { gateCount, maskPan, nextMove, panProblem, regKind, type Gates, type StateRow } from '../src/lib/clients';
import { plainWords } from '../src/lib/plainErrors';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic } from '../src/lib/i18n.public';

const tr = (d: Record<string, string>) => (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = d[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
const T = tr({ ...enPublic, ...en });
const H = tr({ ...enPublic, ...en, ...hi });
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

const gates = (over: Partial<Record<string, boolean>> = {}, needed: Partial<Record<string, boolean>> = {}): Gates => {
  const it = (key: string) => ({ key, needed: needed[key] ?? true, done: over[key] ?? false });
  return { client_id: 'c', state_id: 's', status: 'prospect', legacy: false, gates: [
    { gate: 1, items: ['pan', 'legal_name', 'entity_type', 'client_code', 'contact', 'states_of_interest', 'crops_of_interest'].map(it) },
    { gate: 2, items: ['reg_office', 'reg_number', 'gstin', 'signatory', 'diagnostic_order', 'incorporation'].map(it) },
    { gate: 3, items: ['msa', 'consent_addendum', 'signatory_authority', 'billing', 'fssai', 'iec', 'rcmc', 'kyc', 'approval'].map(it) },
  ] };
};
const row = (over: Partial<StateRow> = {}): StateRow => ({ state_id: 's', state: 'Uttar Pradesh', status: 'prospect', legacy: false, gstin: null,
  gst_not_registered_reason: null, signatory: {}, billing: {}, address: {}, state_contact: {}, brand_on_pack: false, fssai: null, kyc_at: null,
  kyc_by: null, activation_requested_at: null, gates: null, documents: [], events: [], mine: true, ...over });
const all = (keys: string[]) => Object.fromEntries(keys.map((k) => [k, true]));

describe('A2 · the PAN, checked early as the server checks it', () => {
  it('format, and the 4th letter by entity type', () => {
    expect(panProblem('zzzcz0001z', 'company')).toBeNull();
    expect(panProblem('ZZZC0001Z', 'company')).toBe('format');
    expect(panProblem('ZZZPZ0001Z', 'company')).toBe('letter');
    expect(panProblem('ZZZFZ0001Z', 'llp')).toBeNull();
    expect(panProblem('ZZZAZ0001Z', 'cooperative')).toBeNull();
    expect(maskPan('ZZZCZ0001Z')).toBe('ZZZCZ****Z');
    expect([regKind('company'), regKind('llp'), regKind('society'), regKind('individual')]).toEqual(['cin', 'llpin', 'reg_no', null]);
  });
});

describe('B1–B3 · the gates', () => {
  it('"n of m done" counts only what the gate needs', () => {
    expect(gateCount(gates({ pan: true, legal_name: true, entity_type: true }), 1)).toEqual({ done: 3, of: 7 });
    expect(gateCount(gates({}, { fssai: false, iec: false, rcmc: false, approval: false }), 3)).toEqual({ done: 0, of: 5 });
  });
  it('the next move: Diagnostic after gates 1 and 2; KYC after the files; Active (or the request) after KYC', () => {
    const g12 = all(['pan', 'legal_name', 'entity_type', 'client_code', 'contact', 'states_of_interest', 'crops_of_interest',
      'reg_office', 'reg_number', 'gstin', 'signatory', 'diagnostic_order', 'incorporation']);
    expect(nextMove(gates(), row())).toEqual({ to: 'diagnostic', ready: false });
    expect(nextMove(gates(g12), row())).toEqual({ to: 'diagnostic', ready: true });
    const files = { ...g12, ...all(['msa', 'consent_addendum', 'signatory_authority', 'billing', 'fssai', 'iec', 'rcmc']) };
    expect(nextMove(gates(g12), row({ status: 'diagnostic' }))).toEqual({ to: 'kyc', ready: false });
    expect(nextMove(gates(files), row({ status: 'diagnostic' }))).toEqual({ to: 'kyc', ready: true });
    expect(nextMove(gates({ ...files, kyc: true }), row({ status: 'diagnostic', kyc_at: '2026-10-21' }))).toEqual({ to: 'active', ready: true });
    expect(nextMove(gates({ ...files, kyc: true }), row({ status: 'diagnostic', kyc_at: '2026-10-21', activation_requested_at: '2026-10-21' }))).toEqual({ to: null, ready: false });
  });
});

describe('A4 · what another state\'s State Manager sees; the checklist', () => {
  it('the shared identity only, and the plain note', async () => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockResolvedValue({ shared_only: true, states: [], may: { add_state: true },
      identity: { client_id: 'c1', legal_name: 'ABC Exim Ltd', trade_name: null, name: 'ABC Exim Ltd', pan_masked: 'ZZZCZ****Z', pan_pending: false,
        entity_type: 'company', office_city: 'Gorakhpur', office_state: 'Uttar Pradesh', status: 'active', code: 'AEL', own_brand: false } } as never);
    const { ClientPage } = await import('../src/pages/clients/Clients');
    render(<MemoryRouter initialEntries={['/clients/c1']}><Routes><Route path="/clients/:id" element={<ClientPage />} /></Routes></MemoryRouter>);
    expect((await screen.findByTestId('shared-identity')).textContent).toContain('ZZZCZ****Z');
    expect(screen.getByTestId('shared-only').textContent).toBe(en['cl.shared_only']);
    expect(screen.queryByTestId('details-form')).toBeNull();
    expect(screen.queryByTestId('gstin')).toBeNull();
  });
  it('the checklist lists only what is needed, done or not', async () => {
    const { Checklist } = await import('../src/pages/clients/Clients');
    render(<MemoryRouter><Checklist g={gates({ pan: true }, { fssai: false })} /></MemoryRouter>);
    const items = screen.getAllByTestId('gate-item');
    expect(items.find((i) => i.dataset.key === 'pan')?.dataset.done).toBe('yes');
    expect(items.some((i) => i.dataset.key === 'fssai')).toBe(false);
    expect(screen.getAllByTestId('gate')[0].dataset.of).toBe('7');
  });
});

describe('the refusals in plain words; every word in Hindi', () => {
  it('the database\'s words', () => {
    expect(plainWords('already registered with GrainVeda: add your state to this client instead', T)).toBe(en['err.client_registered']);
    expect(plainWords('PAN: its 4th letter is P but a company has C there: choose the right type or check the PAN', T)).toBe(en['err.client_pan']);
    expect(plainWords('GSTIN: it starts with 05, which is not Uttar Pradesh (09)', T)).toBe(en['err.client_gstin']);
    expect(plainWords('PAN: this number belongs to another business in the registry (the admin looks into it)', T)).toBe(en['err.client_number_taken']);
    expect(plainWords('a scope is prepared once the client is in Diagnostic in this state (it is prospect)', T)).toBe(en['err.scope_client_prospect']);
    expect(plainWords('the client is not Active in this state (it is diagnostic): the State Manager completes its registration first', H)).toBe(hi['err.scope_client_not_active']);
    expect(plainWords('an export scope needs the client\'s IEC on file (Clients)', T)).toBe(en['err.scope_client_iec']);
    expect(plainWords('Diagnostic needs gates 1 and 2: reg_office, gstin', T)).toBe(en['err.client_gates']);
    expect(plainWords('after the client is Active its legal name is changed by the admin', T)).toBe(en['err.client_after_active']);
  });
  it('Hindi for every new word', () => {
    const prefixes = ['cst.', 'etype.', 'ctype.', 'csrc.', 'idk.', 'cg.', 'cdoc.', 'cev.', 'cl.', 'ov.approvals', 'err.client', 'err.scope_client', 'states.gst_code', 'crops.apeda'];
    for (const k of Object.keys(en).filter((x) => prefixes.some((p) => x.startsWith(p)))) expect(hi[k], k).toBeTruthy();
    expect(hi['cl.own_brand_note']).toContain('GrainVeda');
  });
});
