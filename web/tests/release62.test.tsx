// Migration 62 (Phase 1, release 4 of Veda's combined brief of 19 Oct 2026: E2.1, only shipped packs are released). The
// rules are the database's (tests/57_shipped_packs.sql); these hold the browser's side: the pack page of a pack released
// by a shipment of before says "Released, serials not recorded (old data)" instead of "Genuine pack"; the lot page says
// so too; the season's batches count released, released without codes and not yet released; the Shipment form asks the
// codes wherever the lot is packed; the refusals in plain words.
import { afterEach, describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { JourneyView } from '../src/pages/public/PublicVerify';
import type { Journey, PackView } from '../src/pages/public/journey';
import { seasonSheets, type SeasonExport } from '../src/lib/exports';
import { withLotRules } from '../src/engine/widgets';
import type { FieldDef } from '../src/lib/types';
import { plainWords } from '../src/lib/plainErrors';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';

const root = join(__dirname, '../..');
const migration = readFileSync(join(root, 'supabase/migrations/20261106000100_shipped_packs_release.sql'), 'utf8');
const tr = (d: Record<string, string>) => (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = d[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
const T = tr({ ...enPublic, ...en });
const H = tr({ ...hiPublic, ...hi });
afterEach(() => cleanup());

const lot = (o: Partial<Journey> = {}): Journey => ({ qr_code: 'GV-ABCDEF123456', sealed_at: '2026-10-17T05:00:00Z', ledger_hash: 'a'.repeat(64), batch_codes: [],
  season: 'KH26', geography: 'Bansi', crop: { name: 'Kalanamak rice', gi_tag: '280', origin: 'Siddharthnagar' }, client: { name: 'Test Client UP', type: 'trade' },
  gi_status: 'gi', farmer_count: 2, verdict: { domestic: 'pass', export: 'pass', overridden: false }, independent: false, journey: [], ...o });
const pack = (o: Partial<PackView> = {}): PackView => ({ serial: 'B1-0150', batch_code: 'B1', size_kg: 0.5, packed_on: '2026-10-16', best_before: null, void: false, ...o });

describe('E2.1 (3) · a pack released by a shipment of before', () => {
  it('says "Released, serials not recorded (old data)", never "Genuine pack"', () => {
    render(<MemoryRouter><JourneyView j={lot()} pack={pack({ old_data: true })} /></MemoryRouter>);
    expect(screen.getByTestId('pv-seal-title').textContent).toBe('Released, serials not recorded (old data)');
    cleanup();
    render(<MemoryRouter><JourneyView j={lot()} pack={pack()} /></MemoryRouter>);
    expect(screen.getByTestId('pv-seal-title').textContent).toBe('Genuine pack, sealed record');
    expect(hiPublic['pv.sealed_title_pack_old']).toContain('पुराना डेटा');
  });
  it('the lot page says its packs were released before shipments recorded codes; it counts only the packs that went live', () => {
    render(<MemoryRouter><JourneyView j={lot({ packs: { n: 0, packed_on: null, best_before: null, old_data: true } })} /></MemoryRouter>);
    expect(screen.getByTestId('pv-packs-old').textContent).toMatch(/old data/);
    expect(screen.queryByTestId('pv-packs')).toBeNull();
    cleanup();
    render(<MemoryRouter><JourneyView j={lot({ packs: { n: 5, packed_on: '2026-10-16', best_before: null } })} /></MemoryRouter>);
    expect(screen.getByTestId('pv-packs').textContent).toMatch(/^5 packs/);
    expect(screen.queryByTestId('pv-packs-old')).toBeNull();
  });
});

describe('E2.1 (2) · every shipment of a packed lot says which packs it carries', () => {
  const ser = { key: 'serials', type: 'serials', label: 'Pack codes loaded', required: false, when_packed: true } as FieldDef;
  it('the codes are on the form, and required, wherever the lot is packed; not for a lot with no packs', () => {
    expect(withLotRules([ser], { market: 'domestic', packs: false, packed: true })[0].required).toBe(true);
    expect(withLotRules([ser], { market: 'domestic', packs: false, packed: false })).toHaveLength(0);
  });
  it('the refusals in plain words, English and Hindi', () => {
    expect(plainWords('shipment: the packs loaded weigh 15 kg, the shipment 20 kg', T)).toBe('The packs loaded weigh 15 kg; the shipment is 20 kg. Add or remove codes.');
    expect(plainWords('shipment: the packs loaded weigh 15 kg, the shipment 20 kg', H)).toContain('15 kg');
  });
});

describe('E2.1 (4) · the season and the QR step count the packs', () => {
  it('each batch: released, released without codes, not yet released, void', () => {
    const e = { columns: ['code'], rows: [], copy: 'shareable', generated_at: '2026-10-21 10:00', units: {}, kind: 'season',
      scope: { client: 'C', client_code: 'C', crop: 'K', gi_tag: null, season: 'KH26', geography: 'B', state: null, status: 'active', data_note: null },
      summary: [], totals: { farmers: 0, kg_in: 0, gi_kg: 0, gi_pct: null, farm_verified_kg: 0, by_products: { broken_kg: 0, husk_kg: 0, bran_kg: 0, reject_kg: 0, foreign_matter_kg: 0 },
        by_products_kg: 0, floor_loss_kg: 0, transit_loss_kg: 0, closed_kg: 0, differences: 0, sealed_lots: 0, packs: 0, open_flags: 0, records: 0 },
      batches: [{ batch_code: 'B1', packs: 190, released: 10, released_old: 14, held: 166, void: 0, first: 'B1-0001', last: 'B1-0190' }] } as SeasonExport;
    const { sheets } = seasonSheets(e, T);
    const txt = sheets[1].map((r) => (r ?? []).map((c) => (c as { value?: unknown } | null)?.value ?? '').join('|')).join('\n');
    expect(txt).toContain('Batch code|Packs|Released|Released, codes not recorded (old data)|Not yet released|Voided');
    expect(txt).toContain('B1|190|10|14|166|0|B1-0001|B1-0190');
  });
  it('the QR step\'s words say how many go live and how many stay held; the migration holds the rules', () => {
    expect(T('rel.packs', { n: 3, batches: 'B1', held: 19 })).toBe('Packs that go live with this seal: 3 (batch B1). Not yet released: 19.');
    expect(hi['rel.packs_old']).toContain('{old}');
    expect(migration).toContain("create or replace function app.pack_release(p_serial text) returns jsonb");
    expect(migration).toContain("raise exception 'shipment: the packs loaded weigh % kg, the shipment % kg'");
  });
});
