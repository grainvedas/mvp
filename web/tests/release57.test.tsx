// Migration 57 (release 10; Veda, 16 Oct 2026: G20 "client info should not be shared", G21 the public page's same-person
// line "should not appear", "make a good UI", G22 the single-stage operator, the shipment's pack codes; "rest all ok and
// proceed with 57").
import { afterEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';

vi.mock('../src/lib/api', async (orig) => ({ ...(await orig<typeof import('../src/lib/api')>()), rpc: vi.fn() }));
import { rpc } from '../src/lib/api';
import { JourneyView, howKey, readingRows, readingUnit } from '../src/pages/public/PublicVerify';
import type { Journey, JourneyStep } from '../src/pages/public/journey';
import { PackCodes, checkCodes, codeLines, codeRuns, normCode, perSku, rangeCodes, splitCode, type PackCode } from '../src/engine/PackCodes';
import { buildPayload, withLotRules } from '../src/engine/widgets';
import { waitingSplit } from '../src/lib/waiting';
import { plainWords } from '../src/lib/plainErrors';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';
import type { FieldDef } from '../src/lib/types';

const root = join(__dirname, '../..');
const read = (p: string) => readFileSync(join(root, p), 'utf8');
const migration = read('supabase/migrations/20261101000100_people_public_page_packs.sql');
const defs = JSON.parse(read('web/tests/fixtures/stage_definitions.json')) as { stage_type: string; form_schema: FieldDef[] }[];
const t = (k: string, v?: Record<string, string | number>) => {
  let s = (v && Number(v.n) === 1 ? en[`${k}.one`] : undefined) ?? en[k] ?? enPublic[k] ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
afterEach(() => { cleanup(); vi.mocked(rpc).mockReset(); });

const step = (o: Partial<JourneyStep>): JourneyStep => ({ stage: 'procurement', code: 'X', qty_in_kg: 0, qty_out_kg: 0, verified_at: null, created_at: '2026-11-12T05:00:00Z', ...o });
const journey = (steps: JourneyStep[], o: Partial<Journey> = {}): Journey => ({
  qr_code: 'GV-ABCDEF123456', sealed_at: '2026-12-02T05:00:00Z', ledger_hash: 'a'.repeat(64), batch_codes: [], season: 'KH26', geography: 'Bansi',
  crop: { name: 'Kalanamak rice', gi_tag: '280', origin: 'Siddharthnagar' }, client: { name: 'Test Client UP', type: 'trade' }, gi_status: 'gi',
  farmer_count: 18, verdict: { domestic: 'pass', export: 'pass', overridden: false }, journey: steps, independent: false,
  villages: [{ village: 'Bansi', district: 'Siddharthnagar', share_pct: 46, farmers: 9 }, { village: 'Mithwal', district: 'Siddharthnagar', share_pct: 54, farmers: 9 }], ...o });

describe('G21 · the public page never says one person recorded and checked a step', () => {
  it('the sentence claims a check only when every step had one; otherwise the plain one, with no word about who did not check', () => {
    expect(howKey(true)).toBe('pv.how');
    expect(howKey(false)).toBe('pv.how_basic');
    expect(howKey(undefined)).toBe('pv.how_basic');
    // migration 59 (A2, Veda's brief of 19 Oct 2026): a STEP recorded and checked by one person says so; no lot-wide line
    for (const d of [enPublic, hiPublic]) expect(Object.keys(d).filter((k) => /how_same_person|how_mixed/.test(k))).toEqual([]);
  });
  it('each step says "checked by another person" only where the server says so', () => {
    const j = journey([step({ code: 'P1', checked: true, farmer: { village: 'Bansi', district: 'Siddharthnagar' } }),
      step({ code: 'M1', stage: 'milling', checked: false }), step({ code: 'Q1', stage: 'qr_activation' })]);
    render(<MemoryRouter><JourneyView j={j} /></MemoryRouter>);
    const page = screen.getByTestId('public-journey');
    expect(screen.getAllByTestId('pv-checked')).toHaveLength(1);
    expect(page.textContent).not.toMatch(/same person|recorded and checked/i);
    expect(screen.getByTestId('pv-how').textContent).toBe(enPublic['pv.how_basic']);
    expect(page.textContent).toContain('Grown in Bansi, Siddharthnagar');
    expect(screen.getByTestId('pv-villages').textContent).toMatch(/2 villages, 18 farmers.*Bansi, Siddharthnagar46 % · 9 farmers/);
    expect(screen.getByTestId('pv-farmer-count').textContent).toMatch(/^Grown by 18 farmers in 2 villages/);
  });
});

describe('the public page, new look', () => {
  it('lab readings beside the strictest upper limit of the markets they were judged against', () => {
    const rows = readingRows([step({ stage: 'qc', readings: { moisture_pct: 12.4, aflatoxin_ppb: 1, colour: 3 } as unknown as Record<string, number>,
      markets: [{ code: 'domestic', name: 'India', verdict: 'pass', limits: [{ param: 'moisture_pct', operator: '<=', limit: 14 }] },
                { code: 'eu', name: 'EU', verdict: 'pass', limits: [{ param: 'moisture_pct', operator: '<=', limit: 13 }, { param: 'aflatoxin_ppb', operator: '<=', limit: 2 }, { param: 'colour', operator: '>=', limit: 2 }] }] })]);
    expect(rows.map((r) => [r.label, r.unit, r.limit, r.pct, r.within])).toEqual([
      ['Moisture', '%', 13, 95, true], ['Aflatoxin', 'ppb', 2, 50, true], ['Colour', '', null, null, null]]);
    expect(readingUnit('x_ppm')).toBe('ppm');
  });
  it('a pack: its scans and copy state, the pack card; a seal in gold', () => {
    const j = journey([step({ code: 'P1' }), step({ code: 'Q1', stage: 'qr_activation' })]);
    render(<MemoryRouter><JourneyView j={j} warn={false} pack={{ serial: 'TCUP-2026-KNM-001-0001', batch_code: 'TCUP-2026-KNM-001', size_kg: 1, packed_on: '2026-12-01',
      best_before: null, void: false, seller: 'Test Client UP', scans: { n: 3, first_city: 'Gorakhpur', first_country: 'IN' } }} /></MemoryRouter>);
    expect(screen.getByTestId('pv-scans').textContent).toMatch(/3scans of this pack.*Gorakhpurfirst scanned.*No copies/);
    expect(screen.getByTestId('pv-pack').textContent).toContain('TCUP-2026-KNM-001-0001');
    expect(screen.getByTestId('pv-hero').textContent).toContain('Genuine pack, sealed record');
  });
  it('every new word of the public page is in its own dictionary, in English and Hindi', () => {
    const src = read('web/src/pages/public/PublicVerify.tsx');
    const keys = [...src.matchAll(/'(pv\.[a-z_0-9.]+)'/g)].map((m) => m[1]).filter((k) => !k.endsWith('.'));
    expect(keys.length).toBeGreaterThan(30);
    for (const k of keys) { expect(enPublic[k], k).toBeTruthy(); expect(hiPublic[k], k).toBeTruthy(); }
  });
});

describe('G22 · the single-stage operator', () => {
  it('two counts that cannot read as a contradiction', () => {
    expect(waitingSplit(t, 2, 3)).toBe('2 to check in · 3 checked in, ready');
    expect(waitingSplit(t, 0, 1)).toBe('1 checked in, ready');
    expect(waitingSplit(t, 0, 0)).toBe('');
  });
  it('short stage names in menus and titles, what the stage is under the title; short tab words, in both languages', () => {
    expect(en['stage.village_batch']).toBe('Collection Batch');
    expect(en['stage.lot_inward']).toBe('Lot Inward');
    for (const k of ['stage_sub.village_batch', 'stage_sub.lot_inward', 'engine.tab_waiting', 'engine.tab_new', 'engine.tab_records', 'inc.to_check_in', 'inc.ready', 'inc.n_to_check_in', 'inc.n_ready', 'inc.by'])
      { expect(en[k], k).toBeTruthy(); expect(hi[k], k).toBeTruthy(); }
    const sp = read('web/src/engine/StagePage.tsx');
    expect(sp).toContain('className="tabs one-row"');
    expect(sp).toContain("aria-label={t('engine.new_record', { stage: f.stage.label })}");   // the full words stay the tab's name
    expect(sp).toContain('data-testid="incoming-row"');
    expect(read('web/src/styles.css')).toMatch(/@media \(max-width: 420px\) \{ \.lot-filters \{ grid-template-columns: 1fr; \} \}/);
  });
});

describe('Shipment · the pack codes', () => {
  const packs: PackCode[] = [1, 2, 3, 4, 5].map((n) => ({ serial: `K-001-000${n}`, sku_id: 'a', sku: '1 kg pouch', size_kg: 1, void: n === 4, shipped_in: n === 5 ? 'SH-0009' : null }));
  it('a code as scanned or typed: a pack page\'s address gives its code', () => {
    expect(normCode('https://mvp.example/p/k-001-0001?x=1')).toBe('K-001-0001');
    expect(codeLines('k-001-0001\n K-001-0002 ,https://a.b/p/K-001-0003')).toEqual(['K-001-0001', 'K-001-0002', 'K-001-0003']);
    expect(buildPayload([{ key: 'serials', type: 'serials', label: 'x' }], { serials: 'https://a.b/p/k-1\nk-2' }).payload).toEqual({ serials: ['K-1', 'K-2'] });
  });
  it('each code checked as it comes: this batch, void, shipped already (and where), twice', () => {
    expect(checkCodes(['K-001-0001', 'K-001-0001', 'K-002-0001', 'K-001-0004', 'K-001-0005'], packs).map((c) => [c.status, c.shipped_in ?? null]))
      .toEqual([['ok', null], ['twice', null], ['other', null], ['void', null], ['shipped', 'SH-0009']]);
    expect(checkCodes(['ANY'], null)[0].status).toBe('ok');      // nothing to check against yet: the save checks
  });
  it('a range of one batch (the second code in full or its number); runs for a short list; the count per pack type', () => {
    expect(splitCode('TCUP-2026-KNM-001-0040')).toEqual({ stem: 'TCUP-2026-KNM-001-', n: 40, width: 4 });
    expect(rangeCodes('K-001-0002', '0004', packs)).toEqual(['K-001-0002', 'K-001-0003', 'K-001-0004']);
    expect(rangeCodes('K-001-0003', 'K-001-0001', packs)).toBeNull();
    expect(rangeCodes('K-001-0001', 'J-001-0003', packs)).toBeNull();
    expect(codeRuns(['K-001-0003', 'K-001-0001', 'K-001-0002', 'K-002-0001'])).toEqual([{ from: 'K-001-0001', to: 'K-001-0003', n: 3 }, { from: 'K-002-0001', to: 'K-002-0001', n: 1 }]);
    expect(perSku(checkCodes(['K-001-0001', 'K-001-0002'], packs), [{ sku_id: 'a', units: 3 }], packs)).toEqual([{ sku_id: 'a', name: '1 kg pouch', n: 2, of: 3 }]);
  });
  it('on the form: the progress, the problems with a Remove, a range added', async () => {
    vi.mocked(rpc).mockResolvedValue(packs);
    let v = 'K-001-0001\nK-002-0001';
    const { rerender } = render(<PackCodes id="s" name="serials" sourceId="order" value={v} onChange={(x) => { v = x; }} packLines={[{ sku_id: 'a', units: 3 }]} />);
    await waitFor(() => expect(screen.getAllByTestId('pc-bad')).toHaveLength(1));
    expect(rpc).toHaveBeenCalledWith('order_pack_codes', { p_fp: 'order' });
    expect(screen.getByTestId('pc-progress').textContent).toMatch(/1 of 3 packs loaded.*1 of 3 · 2 short/);
    expect(screen.getByTestId('pc-bad').textContent).toMatch(/K-002-0001Not this order's batch/);
    fireEvent.click(screen.getByRole('button', { name: 'Remove: K-002-0001' }));
    expect(v).toBe('K-001-0001');
    rerender(<PackCodes id="s" name="serials" sourceId="order" value={v} onChange={(x) => { v = x; }} packLines={[{ sku_id: 'a', units: 3 }]} />);
    fireEvent.click(screen.getByTestId('pc-range'));
    fireEvent.change(screen.getByTestId('pc-from'), { target: { value: 'K-001-0002' } });
    fireEvent.change(screen.getByTestId('pc-to'), { target: { value: '0004' } });
    expect(screen.getByTestId('pc-range-n').textContent).toBe('3 packs; 2 can be loaded');   // the void one is not offered
    fireEvent.click(screen.getByTestId('pc-range-add'));
    expect(v).toBe('K-001-0001\nK-001-0002\nK-001-0003');
  });
  it('a correction does not count its own codes as shipped', async () => {
    vi.mocked(rpc).mockResolvedValue(packs);
    render(<PackCodes id="s" name="serials" sourceId="order2" editingId="ship1" value="" onChange={() => {}} packLines={[]} />);
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('order_pack_codes', { p_fp: 'order2', p_except: 'ship1' }));
  });
  it('asked for a domestic shipment too, where the order\'s lot has packs; the words in both languages', () => {
    const f = defs.find((d) => d.stage_type === 'shipment')!.form_schema.find((x) => x.key === 'serials')! as FieldDef & { for_market?: string; with_packs?: boolean };
    expect(f.for_market).toBeUndefined();
    expect(f.with_packs).toBe(true);
    expect(withLotRules([f], { market: 'domestic', packs: true })).toHaveLength(1);
    expect(withLotRules([f], { market: 'domestic', packs: false })).toHaveLength(0);
    expect(plainWords('shipment: scan or type the codes of the packs loaded', t)).toMatch(/Scan or type the codes/);
    const src = read('web/src/engine/PackCodes.tsx');
    for (const k of [...new Set([...src.matchAll(/t\('(pc\.[a-z_]+)'/g)].map((m) => m[1]))]) { expect(en[k], k).toBeTruthy(); expect(hi[k], k).toBeTruthy(); }
  });
});

describe('G20 and the server · what migration 57 says', () => {
  it('a Client Manager: no person who works for another client; HR and the admin as before', () => {
    expect(migration).toContain('create or replace function app.busy_for_other_client(p_user uuid)');
    expect(migration).toMatch(/not \(app\.is_admin\(\) or app\.is_hr\(\)\)/);
    expect(migration.match(/case when app\.cm_limited\(\) then 0 else/g)).toHaveLength(3);
    expect(migration).toContain("select set_config('app.change_path', 'migration 57', true);");
  });
  it('the public data: no same_person, no worked-out values; the buyer\'s page: no vehicle', () => {
    const pj = migration.slice(migration.indexOf('CREATE OR REPLACE FUNCTION app.public_lot_journey'), migration.indexOf('CREATE OR REPLACE FUNCTION app.public_pack'));
    expect(pj).not.toMatch(/'same_person'/);
    expect(pj).not.toMatch(/\.computed/);
    expect(migration).toContain("'eway_bill_no', s.payload->>'eway_bill_no'");
    expect(migration).not.toContain("'vehicle_no', s.payload->>'vehicle_no'");
  });
});
