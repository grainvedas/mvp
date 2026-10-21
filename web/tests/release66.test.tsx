// Migration 66 (Phase 2, release 3: Parts E, F and G). The rules are the database's (tests/61_sourcing_partners_hooks.sql);
// these hold the screens' side: the public page's "Operated by GrainVeda (own brand)", "Sourced through …" (only what the
// server sends: the partners that agreed) and "not farm-verified"; the procurement form's "Procured through" field and
// its picker (pre-filled with the scope's one partner); the season warning in the brief's words; the refusals in plain
// words; every new word in Hindi.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { JourneyView } from '../src/pages/public/PublicVerify';
import type { Journey, JourneyStep } from '../src/pages/public/journey';
import { plainWords } from '../src/lib/plainErrors';
import { SUPPORTED } from '../src/engine/widgets';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';
import defs from './fixtures/stage_definitions.json';

const tr = (d: Record<string, string>) => (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = d[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
const T = tr({ ...enPublic, ...en });
const H = tr({ ...enPublic, ...en, ...hi });
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

const step = (o: Partial<JourneyStep>): JourneyStep => ({ stage: 'procurement', code: 'X', qty_in_kg: 0, qty_out_kg: 0, verified_at: null, created_at: '2026-11-12T05:00:00Z', ...o });
const journey = (o: Partial<Journey> = {}): Journey => ({
  qr_code: 'GV-ABCDEF123456', sealed_at: '2026-12-02T05:00:00Z', ledger_hash: 'a'.repeat(64), batch_codes: [], season: 'KH26', geography: 'Bansi',
  crop: { name: 'Kalanamak rice', gi_tag: '280', origin: 'Siddharthnagar' }, client: { name: 'ITC Agri (test)', type: 'exporter' }, gi_status: 'gi',
  farmer_count: 1, verdict: { domestic: 'pass', export: 'pass', overridden: false }, journey: [step({ code: 'P1' }), step({ code: 'R1', stage: 'qr_activation' })],
  independent: false, ...o });

describe('F, E3, G2 · the public page', () => {
  it('"Operated by GrainVeda (own brand)" only for an own-brand client', () => {
    const { rerender } = render(<MemoryRouter><JourneyView j={journey({ client: { name: 'Prasaadam', type: 'grainveda', own_brand: true } })} /></MemoryRouter>);
    expect(screen.getByTestId('pv-own-brand').textContent).toBe('Operated by GrainVeda (own brand)');
    rerender(<MemoryRouter><JourneyView j={journey()} /></MemoryRouter>);
    expect(screen.queryByTestId('pv-own-brand')).toBeNull();
  });
  it('"Sourced through …" for the partners the server sends (those that agreed), none otherwise', () => {
    const { rerender } = render(<MemoryRouter><JourneyView j={journey({ sourced_through: ['AB Farmers Producer Co'] })} /></MemoryRouter>);
    expect(screen.getByTestId('pv-sourced').textContent).toBe('Sourced through AB Farmers Producer Co');
    rerender(<MemoryRouter><JourneyView j={journey({ sourced_through: [] })} /></MemoryRouter>);
    expect(screen.queryByTestId('pv-sourced')).toBeNull();
  });
  it('a lot not farm-verified says so; a farm-verified one (every lot today) says nothing', () => {
    const { rerender } = render(<MemoryRouter><JourneyView j={journey({ farm_verified: false, gi_status: 'non_gi' })} /></MemoryRouter>);
    expect(screen.getByTestId('pv-not-farm-verified').textContent).toBe('Received from supplier, not farm-verified by GrainVeda');
    expect(screen.queryByTestId('pv-gi')).toBeNull();
    rerender(<MemoryRouter><JourneyView j={journey({ farm_verified: true })} /></MemoryRouter>);
    expect(screen.queryByTestId('pv-not-farm-verified')).toBeNull();
  });
});

describe('E3 · "Procured through" on the procurement form', () => {
  it('the field, after "Where", of a type this build renders', () => {
    const proc = (defs as { stage_type: string; form_schema: { key: string; type: string }[] }[]).find((d) => d.stage_type === 'procurement')!;
    const keys = proc.form_schema.map((f) => f.key);
    expect(keys.indexOf('procured_through')).toBe(keys.indexOf('collection_point_id') + 1);
    expect(SUPPORTED.has(proc.form_schema.find((f) => f.key === 'procured_through')!.type)).toBe(true);
    expect(en['field.procured_through']).toBe('Procured through');
  });
  it('pre-filled with the scope\'s one partner', async () => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockResolvedValue([{ entity_id: 'e1', name: 'AB Farmers Producer Co', named_publicly: false }] as never);
    const { Widget } = await import('../src/engine/widgets');
    const onChange = vi.fn();
    render(<Widget id="w" field={{ key: 'procured_through', type: 'partner', label: 'Procured through', required: false } as never} value=""
      onChange={onChange} qualityParams={[]} clientId="c" scopeId={`scope-${Date.now()}`} />);
    await waitFor(() => expect(onChange).toHaveBeenCalledWith('e1'));
  });
});

describe('E4 · the season across clients, in the brief\'s words; the refusals; Hindi', () => {
  it('the warning names the total and the limit only', () => {
    expect(plainWords('above the expected yield: 1200 of 1000 kg this season (1.00 acres of GI land)', T))
      .toBe('This farmer has sold 1200 kg through GrainVeda this season; his GI land (1.00 acres) plausibly gives about 1000 kg.');
  });
  it('the database\'s words', () => {
    expect(plainWords('this farmer is not registered with this scope\'s client (his consent to that client): register him for it first', T)).toBe(en['err.farmer_other_client']);
    expect(plainWords('procured through: one of this scope\'s sourcing partners', H)).toBe(hi['err.procured_through']);
    expect(plainWords('a scope\'s sourcing partners are set by its Client Manager', T)).toBe(en['err.partner_who']);
    expect(plainWords('sourcing partner: the client itself is not its own sourcing partner', T)).toBe(en['err.partner_rule']);
    expect(plainWords('entry point: only farmer procurement for now (a lot received from another client or a supplier comes later)', T)).toBe(en['err.entry_point']);
  });
  it('Hindi for every new word', () => {
    const prefixes = ['field.procured_through', 'pick.partner', 'widget.members_of', 'widget.all_farmers', 'widget.no_partner', 'widget.direct_from_farmer', 'fm.', 'sp.',
      'err.farmer_other_client', 'err.procured_through', 'err.partner', 'err.entry_point', 'warn.expected_yield'];
    for (const k of Object.keys(en).filter((x) => prefixes.some((p) => x.startsWith(p)))) expect(hi[k], k).toBeTruthy();
    for (const k of ['pv.own_brand', 'pv.sourced_through', 'pv.not_farm_verified']) expect(hiPublic[k], k).toBeTruthy();
  });
});
