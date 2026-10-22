// Migration 67 (Phase 3, release 1 of Veda's combined brief: Part A, with Phase 2's B4). The rules are the database's
// (tests/62_client_accounts.sql); these hold the screens' side: who the app treats as a read-only client login (an owner
// and a viewer) and who works stages (the client's own staff); the accounts card shows what the server says the reader
// may make; a viewer made by the Client Manager is offered one state's scopes only; "Recorded by client staff"; the
// refusals in plain words; every new word in Hindi.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { plainWords } from '../src/lib/plainErrors';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic } from '../src/lib/i18n.public';
import { isClientLogin, isClientOperator, isClientOwner } from '../src/lib/rights';
import { reachLabel, type ClientAccounts } from '../src/lib/clientAccounts';
import { roleWord } from '../src/shell/Layout';
import type { MyContext } from '../src/lib/types';

const tr = (d: Record<string, string>) => (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = d[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
const T = tr({ ...enPublic, ...en });
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

const ctx = (kind: 'owner' | 'viewer' | 'operator' | null, external = true, client = 'c1') =>
  ({ user: { id: 'u', role: kind === 'operator' ? 'operator' : 'client_view', external, display_name: 'x', email: null, phone: null, client_id: client, client_name: 'C',
             state_ids: [], client_account: kind ? { kind, client_id: client, client_name: 'C', reach: 'client', internal_copies: false, status: 'active' } : null },
     slots: [], scopes: [] } as unknown as MyContext);

describe('A1 · who the app treats as what', () => {
  it('an owner and a viewer read only (no stage pages); the client\'s own staff work their stages', () => {
    expect(isClientLogin(ctx('viewer'))).toBe(true);
    expect(isClientLogin(ctx('owner'))).toBe(true);
    expect(isClientLogin(ctx('operator'))).toBe(false);
    expect(isClientOperator(ctx('operator'))).toBe(true);
    expect(isClientLogin(ctx(null))).toBe(true);                  // a client login of a server before migration 67: read-only, as before
    expect(isClientLogin(ctx(null, false))).toBe(false);          // GrainVeda's people
  });
  it('the owner, of its own client only', () => {
    expect(isClientOwner(ctx('owner'), 'c1')).toBe(true);
    expect(isClientOwner(ctx('owner'), 'c2')).toBe(false);
    expect(isClientOwner(ctx('viewer'), 'c1')).toBe(false);
  });
  it('the word beside the name says which account it is', () => {
    expect(roleWord({ role: 'client_view', external: true, client_account: { kind: 'owner' } }, T)).toBe('Client owner');
    expect(roleWord({ role: 'operator', external: true, client_account: { kind: 'operator' } }, T)).toBe('Client staff');
  });
});

const info = (o: Partial<ClientAccounts['may']> = {}): ClientAccounts => ({
  accounts: [
    { id: 'o1', name: 'Prasaadam Owner', email: 'o@x.test', kind: 'owner', status: 'active', reach: 'client', state_id: null, state: null, scopes: [], internal_copies: false,
      made_as: 'admin', created_at: '2026-10-22T00:00:00Z', status_reason: null, has_login: true, stages: null, may: { manage: true, internal: false, promote: false } },
    { id: 'v1', name: 'Bansi Desk', email: 'b@x.test', kind: 'viewer', status: 'suspended', reach: 'scopes', state_id: null, state: null, scopes: [{ id: 's2', label: 'Kalanamak · KH26 · Bansi' }],
      internal_copies: true, made_as: 'owner', created_at: '2026-10-22T00:00:00Z', status_reason: 'desk closed', has_login: true, stages: null, may: { manage: true, internal: true, promote: false } },
  ],
  may: { owner: false, viewer: true, viewer_whole_client: false, operator: true, internal: false, ...o },
  states: [{ id: 'up', name: 'Uttar Pradesh', status: 'active' }, { id: 'as', name: 'Assam', status: 'active' }],
  scopes: [{ id: 's1', state_id: 'up', status: 'active', delivery_model: 'hybrid', label: 'Kalanamak · KH26 · Siddharthnagar' },
           { id: 's2', state_id: 'up', status: 'active', delivery_model: 'managed', label: 'Kalanamak · KH26 · Bansi' },
           { id: 's3', state_id: 'as', status: 'draft', delivery_model: 'managed', label: 'Joha · KH26 · Nagaon' }],
});

describe('A1/B · the accounts card', () => {
  it('lists the accounts with what each sees; offers what the server says the reader may make', async () => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockResolvedValue(info() as never);
    const { ClientAccountsCard } = await import('../src/pages/clients/ClientAccounts');
    render(<MemoryRouter><ClientAccountsCard client="c1" /></MemoryRouter>);
    await waitFor(() => expect(screen.getAllByTestId('ca-row')).toHaveLength(2));
    const rows = screen.getAllByTestId('ca-row');
    expect(within(rows[1]).getByTestId('ca-reach').textContent).toBe('Chosen scopes: Kalanamak · KH26 · Bansi');
    expect(within(rows[1]).getByTestId('ca-resume')).toBeTruthy();                       // suspended: resume, not suspend
    expect((screen.getByTestId('ca-kind') as HTMLSelectElement).options.length).toBe(2);   // the Client Manager: a viewer, client staff
    expect([...(screen.getByTestId('ca-reach-pick') as HTMLSelectElement).options].map((o) => o.value)).toEqual(['state', 'scopes']);   // never the whole client
  });
  it('the owner may offer the whole client and internal copies', async () => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockResolvedValue(info({ viewer_whole_client: true, internal: true, operator: false }) as never);
    const { ClientAccountsCard } = await import('../src/pages/clients/ClientAccounts');
    render(<MemoryRouter><ClientAccountsCard client="c1" /></MemoryRouter>);
    await waitFor(() => expect(screen.getByTestId('ca-reach-pick')).toBeTruthy());
    expect([...(screen.getByTestId('ca-reach-pick') as HTMLSelectElement).options].map((o) => o.value)).toEqual(['client', 'state', 'scopes']);
    expect(screen.getByTestId('ca-internal-new')).toBeTruthy();
    expect(screen.queryByTestId('ca-kind')).toBeNull();                                    // the owner makes viewers only
  });
  it('what a viewer sees, in words', () => {
    expect(reachLabel({ kind: 'viewer', reach: 'state', state: 'Assam', scopes: [] }, T)).toBe('Every scope in Assam');
    expect(reachLabel({ kind: 'owner', reach: 'client', state: null, scopes: [] }, T)).toBe('Every scope of the client');
  });
});

describe('A2 · the database\'s words, in plain words; Hindi for every new word', () => {
  it('the refusals', () => {
    expect(plainWords('a record made by the client\'s own staff is verified by GrainVeda', T)).toBe(en['err.ca_staff_verify']);
    expect(plainWords('this client is not active in this state: an owner\'s acts are paused', T)).toBe(en['err.ca_paused']);
    expect(plainWords('a viewer made by the Client Manager sees one state\'s scopes: choose the state, or scopes of one state', T)).toBe(en['err.ca_cm_state']);
    expect(plainWords('client account: say first what it is (owner, viewer or operator) and what it sees', T)).toBe(en['err.ca_say_first']);
    expect(plainWords('the client\'s own staff hold stages only on a Hybrid or Self-run scope', T)).toBe(en['err.ca_operator_scope']);
    expect(plainWords('delivery model: the client\'s own staff still hold stages here: end their stages first', T)).toBe(en['err.sd_staff']);
    expect(plainWords('a client owner is made by the admin', T)).toBe(en['err.ca_owner_admin']);
  });
  it('Hindi for every new word', () => {
    const prefixes = ['ca.', 'sd.', 'acc.', 'record.client_staff', 'err.ca_', 'err.sd_', 'err.gi_', 'err.acc_', 'rep.dm.', 'audit.client_account', 'audit.scope_'];
    const keys = Object.keys(en).filter((x) => prefixes.some((p) => x.startsWith(p)));
    expect(keys.length).toBeGreaterThan(80);
    for (const k of keys) expect(hi[k], k).toBeTruthy();
  });
  it('no word of before was replaced by this release (FIX_LIST 63)', () => {
    expect(en['sp.title']).toBe('Same person, next stage');
    expect(en['people.new_client_login']).toBe('New client login');
  });
});
