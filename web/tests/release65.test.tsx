// Migration 65 (Phase 2, release 2: Parts C and D). The rules are the database's (tests/60_client_states_status.sql);
// these hold the browser's side: the moves each status offers, the words of a notification, "Add [my state] to this
// client" on the shared record, the national documents "on file", the public page's "Verification paused" / "ended
// on …" and the page no longer live, the refusals in plain words, and every new word in Hindi.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { noticeText, statusMoves, type Notice } from '../src/lib/clients';
import { plainWords } from '../src/lib/plainErrors';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';

const tr = (d: Record<string, string>) => (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = d[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
const T = tr({ ...enPublic, ...en });
const H = tr({ ...enPublic, ...en, ...hi });
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

describe('D · the moves each status offers', () => {
  it('Active: suspend or end; Suspended: resume or end; Ended: return; before Active: end', () => {
    expect(statusMoves('active')).toEqual(['suspended', 'ended']);
    expect(statusMoves('suspended')).toEqual(['active', 'ended']);
    expect(statusMoves('ended')).toEqual(['diagnostic']);
    expect(statusMoves('prospect')).toEqual(['ended']);
    expect(statusMoves('diagnostic')).toEqual(['ended']);
  });
});

describe('C · the words of a notification', () => {
  const n = (kind: string, data: Notice['data']): Notice => ({ id: 'n', kind, client_id: 'c', state_id: null, created_at: '2026-10-21', read: false, data });
  it('"ABC Exim added in Uttarakhand by …", a national suspension, a renewal; the reason when there is one', () => {
    expect(noticeText(n('client_state_added', { client: 'ABC Exim Ltd', state: 'Uttarakhand', by: 'Uttarakhand State Manager' }), T))
      .toBe('ABC Exim Ltd added in Uttarakhand by Uttarakhand State Manager');
    expect(noticeText(n('client_suspended', { client: 'ABC Exim Ltd', national: true, by: 'Veda', reason: 'licence under review' }), T))
      .toBe('ABC Exim Ltd suspended in every state by Veda (licence under review)');
    expect(noticeText(n('client_renewal', { client: 'ABC Exim Ltd', kind: 'fssai', by: 'ABC Exim (login)' }), T))
      .toBe(`ABC Exim Ltd: a renewed ${en['cdoc.fssai']} uploaded by ABC Exim (login)`);
    expect(noticeText(n('client_ended', { client: 'ABC', state: 'Uttar Pradesh', by: 'Ram' }), H)).toContain('समाप्त');
  });
});

describe('C · the shared record: "Add [my state] to this client"; A4 · the national documents "on file"', () => {
  it('another state\'s State Manager: the shared identity and one action per state of his own', async () => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockResolvedValue({ shared_only: true, states: [], may: { add_state: true, add_states: [{ id: 'uk', name: 'Uttarakhand' }] },
      identity: { client_id: 'c1', legal_name: 'ABC Exim Ltd', trade_name: null, name: 'ABC Exim Ltd', pan_masked: 'ZZZCZ****Z', pan_pending: false,
        entity_type: 'company', office_city: 'Gorakhpur', office_state: 'Uttar Pradesh', status: 'active', code: 'AEL', own_brand: false } } as never);
    const { ClientPage } = await import('../src/pages/clients/Clients');
    render(<MemoryRouter initialEntries={['/clients/c1']}><Routes><Route path="/clients/:id" element={<ClientPage />} /></Routes></MemoryRouter>);
    const b = await screen.findByTestId('add-state');
    expect(b.textContent).toBe('Add Uttarakhand to this client');
    expect(b.dataset.state).toBe('Uttarakhand');
    expect(screen.queryByTestId('details-form')).toBeNull();
  });
  it('a national document without its file (another state) reads "on file", not a link', async () => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockImplementation(async (fn: string) => (fn === 'client_view' ? {
      shared_only: false, states: [], contact: {}, may: { edit: true, edit_states: ['uk'], national_docs: false, set_status: true },
      national: { reg_number: null, iec: null, rcmc: null, documents: [{ id: 'd1', kind: 'msa', file_name: null, path: null, sha256: 'a'.repeat(64), bytes: 1,
        signed_on: '2026-10-20', term_end: '2029-10-19', expires_on: null, amount: null, created_at: '2026-10-20' }] },
      identity: { client_id: 'c1', legal_name: 'ABC Exim Ltd', trade_name: null, name: 'ABC Exim Ltd', pan_masked: 'ZZZCZ****Z', pan_pending: false,
        entity_type: 'company', office_city: null, office_state: null, status: 'active', code: 'AEL', own_brand: false } } : []) as never);
    const { ClientPage } = await import('../src/pages/clients/Clients');
    render(<MemoryRouter initialEntries={['/clients/c1']}><Routes><Route path="/clients/:id" element={<ClientPage />} /></Routes></MemoryRouter>);
    expect((await screen.findByTestId('doc-on-file')).textContent).toBe(`${en['cdoc.msa']}: ${en['cl.on_file']}`);
  });
});

describe('D · the public page: paused, ended, no longer live', () => {
  it('"Verification paused"; "Verification ended on …" with the day it stays live until; the page no longer live', async () => {
    const { VerificationNotice, ExpiredView } = await import('../src/pages/public/PublicVerify');
    const { rerender } = render(<VerificationNotice v={{ status: 'paused' }} />);
    expect(screen.getByTestId('pv-verification').dataset.status).toBe('paused');
    expect(screen.getByTestId('pv-verification').textContent).toContain(enPublic['pv.verification_paused']);
    rerender(<VerificationNotice v={{ status: 'ended', ended_on: '2026-10-21', live_until: '2028-10-21' }} />);
    expect(screen.getByTestId('pv-verification').textContent).toMatch(/Verification ended on .*2026/);
    expect(screen.getByTestId('pv-verification').textContent).toMatch(/until .*2028/);
    rerender(<VerificationNotice v={null} />);
    expect(screen.queryByTestId('pv-verification')).toBeNull();
    render(<ExpiredView p={{ expired: true, verification: { status: 'ended', ended_on: '2023-01-01', live_until: '2025-01-01' }, crop: { name: 'Kalanamak rice' } }} />);
    expect(screen.getByTestId('pv-expired').textContent).toContain('no longer live');
  });
});

describe('the refusals in plain words; every word in Hindi', () => {
  it('the database\'s words', () => {
    expect(plainWords('this client is suspended in this state: no new procurement (work in progress may finish to Packing)', T)).toBe(en['err.client_suspended_entry']);
    expect(plainWords('this client is suspended in this state: no sale, shipment or release until it is resumed', T)).toBe(en['err.client_suspended_release']);
    expect(plainWords('this client\'s contract has ended in this state: its records are read only', H)).toBe(hi['err.client_ended']);
    expect(plainWords('the admin suspended this client here: the admin moves it back', T)).toBe(en['err.client_status_admin']);
    expect(plainWords('status: a client active cannot be returned', T)).toBe(en['err.client_status_move']);
    expect(plainWords('a state is added to a client by that state\'s State Manager', T)).toBe(en['err.client_add_state_who']);
    expect(plainWords('this client is already in this state', T)).toBe(en['err.client_state_exists']);
    expect(plainWords('the national documents are kept by the State Manager of the client\'s home state (here they are on file)', T)).toBe(en['err.client_national_docs']);
    expect(plainWords('this client is suspended in this state', T)).toBe(en['err.client_not_open']);
    expect(plainWords('status: a reason of 10 characters or more', T)).toBe(en['err.client_reason']);
  });
  it('Hindi for every new word', () => {
    const prefixes = ['cl.add_state', 'cl.move_', 'cl.all_states', 'cl.reason_10', 'cl.suspended_note', 'cl.ended_note', 'exp.', 'rn.', 'note.', 'cev.', 'err.client', 'wizard.state_client'];
    for (const k of Object.keys(en).filter((x) => prefixes.some((p) => x.startsWith(p)))) expect(hi[k], k).toBeTruthy();
    for (const k of ['pv.verification_paused', 'pv.verification_paused_note', 'pv.verification_ended', 'pv.verification_ended_note', 'pv.expired'])
      expect(hiPublic[k], k).toBeTruthy();
  });
});
