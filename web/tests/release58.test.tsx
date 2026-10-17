// Migration 58 (release 11; Veda, 16 Oct 2026: "There should a mechanism to choose packs and in future there will be
// more than 1 lakhs packs"; "carton size - cm sets them in the pack list"; carton labels and loading "share suggestion";
// on the HR Admin's screens "report to - it sees all people which should not be the case", "department ... there should
// be drop down"; "proceed with 58"). The rules are the database's (tests/53_cartons_people_choices.sql); these hold the
// screens' mirrors of them.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';

vi.mock('../src/lib/api', async (orig) => ({ ...(await orig<typeof import('../src/lib/api')>()), rpc: vi.fn() }));
import { rpc } from '../src/lib/api';
import { PackCodes, cartonOf, checkCodes, perSku, type PackCode } from '../src/engine/PackCodes';
import { OrderCartons, cartonRange, chosenPacks, runOf, type FreeCartons } from '../src/engine/OrderCartons';
import { FULL_WIDTH, SUPPORTED, buildPayload, withLotRules } from '../src/engine/widgets';
import { showComputed, unitsText } from '../src/engine/values';
import { LIST_FIELDS, listProblems, listRow } from '../src/lib/setup';
import { PAPER_PAGE } from '../src/pages/records/PackLabels';
import { byState, DepartmentSelect, ReportsToSelect, type OrgChoices } from '../src/pages/hr/OrgChoices';
import { plainWords } from '../src/lib/plainErrors';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';
import type { FieldDef } from '../src/lib/types';

const root = join(__dirname, '../..');
const read = (p: string) => readFileSync(join(root, p), 'utf8');
const migration = read('supabase/migrations/20261102000100_cartons_reports_departments.sql');
const defs = JSON.parse(read('web/tests/fixtures/stage_definitions.json')) as { stage_type: string; form_schema: FieldDef[] }[];
const t = (k: string, v?: Record<string, string | number>) => {
  let s = (v && Number(v.n) === 1 ? en[`${k}.one`] : undefined) ?? en[k] ?? enPublic[k] ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
afterEach(() => { cleanup(); vi.mocked(rpc).mockReset(); });

// an order that set aside two cartons of 20 (C0009, C0010) and five loose pouches; C0011 was opened since
const B = 'PRSDM-KNM-KH26-B0001';
const unit = (o: Partial<PackCode>): PackCode => ({ serial: '', sku_id: 'a', sku: '1 kg pouch', size_kg: 1, void: false, shipped_in: null, kind: 'pack', n: 1, ...o });
const units: PackCode[] = [
  unit({ serial: `${B}-C0009`, kind: 'carton', n: 20, first_serial: `${B}-0155`, last_serial: `${B}-0174` }),
  unit({ serial: `${B}-C0010`, kind: 'carton', n: 20, first_serial: `${B}-0175`, last_serial: `${B}-0194` }),
  unit({ serial: `${B}-C0011`, kind: 'carton', n: 20, first_serial: `${B}-0195`, last_serial: `${B}-0214`, opened: true }),
  ...[300, 301, 302, 303, 304].map((n) => unit({ serial: `${B}-0${n}` })),
];

describe('Loading · a carton\'s code counts its packs', () => {
  it('a carton is 20 packs; a pouch of a carton set aside is accepted on its own; never with its carton', () => {
    const c = checkCodes([`${B}-C0009`, `${B}-0180`, `${B}-0300`], units);
    expect(c.map((x) => [x.status, x.kind, x.n])).toEqual([['ok', 'carton', 20], ['ok', 'pack', 1], ['ok', 'pack', 1]]);
    expect(cartonOf(`${B}-0180`, units)?.serial).toBe(`${B}-C0010`);
    expect(checkCodes([`${B}-C0009`, `${B}-0160`], units).map((x) => x.status)).toEqual(['ok', 'twice']);       // the pouch after its carton
    expect(checkCodes([`${B}-0160`, `${B}-C0009`], units).map((x) => x.status)).toEqual(['ok', 'twice']);       // the carton after its pouch
    expect(checkCodes([`${B}-C0011`], units)[0].status).toBe('opened');
    expect(checkCodes([`${B}-C0012`, `${B}-0400`], units).map((x) => x.status)).toEqual(['other', 'other']);
    expect(perSku(checkCodes([`${B}-C0009`, `${B}-C0010`, `${B}-0300`], units), [{ sku_id: 'a', units: 45 }], units))
      .toEqual([{ sku_id: 'a', name: '1 kg pouch', n: 41, of: 45 }]);
  });
  it('on the form: packs counted by cartons, an opened carton named, "not set aside" for an order of cartons', async () => {
    vi.mocked(rpc).mockResolvedValue(units);
    render(<PackCodes id="s" name="serials" sourceId="order" value={`${B}-C0009\n${B}-C0010\n${B}-C0011\n${B}-0215`} onChange={() => {}} packLines={[{ sku_id: 'a', units: 45 }]} />);
    await waitFor(() => expect(screen.getAllByTestId('pc-bad')).toHaveLength(2));
    expect(screen.getByTestId('pc-progress').textContent).toMatch(/^40 of 45 packs loaded · 2 cartons/);
    expect(screen.getByTestId('pc-run').textContent).toMatch(/C0009 … 0010.*2 cartons · 40 packs/);
    expect(screen.getAllByTestId('pc-bad')[0].textContent).toMatch(/C0011Carton opened: scan its packs one by one/);
    expect(screen.getAllByTestId('pc-bad')[1].textContent).toMatch(/0215Not set aside for this order/);
    expect(screen.queryByTestId('pc-whole')).toBeNull();                                  // no "add the whole batch" for an order of cartons
  });
});

describe('The order · the cartons it chooses', () => {
  const free: FreeCartons[] = [{ sku_id: 'a', sku: '1 kg pouch', per_carton: 20, cartons: 5, packs: 90,
    runs: [{ from: `${B}-C0012`, to: `${B}-C0012`, cartons: 1, packs: 20 }, { from: `${B}-C0014`, to: `${B}-C0016`, cartons: 3, packs: 50 }] }];
  it('a range of carton codes; which run a code is in; the packs chosen (the last carton of a run holds what is left)', () => {
    expect(cartonRange(`${B}-C0014`, '16')).toEqual([`${B}-C0014`, `${B}-C0015`, `${B}-C0016`]);
    expect(cartonRange(`${b(14)}`, `${B}-0016`)).toBeNull();                              // not cartons
    expect(cartonRange(`${B}-C0016`, `${B}-C0014`)).toBeNull();
    expect(runOf(`${B}-C0015`, free)?.run.from).toBe(`${B}-C0014`);
    expect(runOf(`${B}-C0013`, free)).toBeNull();
    expect(chosenPacks([`${B}-C0012`, `${B}-C0016`], free).get('a')).toBe(30);               // 20 and the last, of 10
  });
  it('on the form: the free runs; not chosen, the oldest are set aside; chosen, a range is added, the packs against the order', async () => {
    vi.mocked(rpc).mockResolvedValue(free);
    let v: string[] = [];
    const { rerender } = render(<OrderCartons id="c" sourceId="packing" editingId="order1" value={v} onChange={(x) => { v = x; }} packLines={[{ sku_id: 'a', units: 40 }]} />);
    await waitFor(() => expect(screen.getAllByTestId('oc-run')).toHaveLength(2));
    expect(rpc).toHaveBeenCalledWith('available_cartons', { p_packing: 'packing', p_except: 'order1' });
    expect(screen.getByTestId('oc-sku').textContent).toMatch(/1 kg pouch5 free cartons · 90 packs · 20 per carton/);
    expect(screen.getByTestId('oc-oldest').textContent).toMatch(/oldest free cartons are set aside/);
    fireEvent.click(screen.getByTestId('oc-choose'));
    fireEvent.click(screen.getAllByTestId('oc-run')[1]);
    expect(screen.getByTestId('oc-add').textContent).toBe('Add 3 cartons');
    fireEvent.click(screen.getByTestId('oc-add'));
    expect(v).toEqual([`${B}-C0014`, `${B}-C0015`, `${B}-C0016`]);
    rerender(<OrderCartons id="c" sourceId="packing" editingId="order1" value={v} onChange={(x) => { v = x; }} packLines={[{ sku_id: 'a', units: 40 }]} />);
    expect(screen.getByTestId('oc-sku-n').textContent).toMatch(/50 packs: more than the 40 of the order/);
  });
  it('a lot not in cartons says so; the field is the Commercial form\'s, where the lot has packs; the payload is the codes', async () => {
    vi.mocked(rpc).mockResolvedValue([]);
    render(<OrderCartons id="c" sourceId="packing" value={[]} onChange={() => {}} packLines={[]} />);
    await waitFor(() => expect(screen.getByTestId('oc-none').textContent).toBe(en['oc.none']));
    const f = defs.find((d) => d.stage_type === 'commercial')!.form_schema.find((x) => x.key === 'cartons')! as FieldDef & { with_packs?: boolean };
    expect(f.type).toBe('order_cartons');
    expect(f.with_packs).toBe(true);
    expect(SUPPORTED.has('order_cartons') && FULL_WIDTH.has('order_cartons')).toBe(true);
    expect(withLotRules([f], { market: 'domestic', packs: false })).toHaveLength(0);
    expect(buildPayload([f], { cartons: [` ${B.toLowerCase()}-c0014`, `${B}-C0014`, ''] }).payload).toEqual({ cartons: [`${B}-C0014`] });
    expect(buildPayload([f], { cartons: [] }).payload).toEqual({});
  });
  it('what an order set aside, in words; the cartons loaded', () => {
    expect(unitsText([{ kind: 'carton', n: 20 }, { kind: 'carton', n: 20 }, { kind: 'pack', n: 1 }], t)).toBe('2 cartons (40 packs) and 1 loose pack');
    expect(showComputed('units', [{ kind: 'carton', n: 10 }], t)).toBe('1 carton (10 packs)');
    expect(showComputed('cartons_count', 2, t)).toBe('2 cartons');
  });
});

describe('The pack list · packs per carton, set by the Client Manager', () => {
  it('a whole number from 1 to 1,000, or empty (not in cartons)', () => {
    expect(LIST_FIELDS.pack_skus.some((f) => f.key === 'packs_per_carton' && !f.required)).toBe(true);
    const r = { size: '1', unit: 'kg', material: 'pouch', market: 'domestic', label_type: 'sticker' };
    expect(listProblems('pack_skus', { ...r, packs_per_carton: '20' })).toEqual([]);
    expect(listProblems('pack_skus', { ...r, packs_per_carton: '' })).toEqual([]);
    for (const bad of ['0', '1001', '2.5', 'ten']) expect(listProblems('pack_skus', { ...r, packs_per_carton: bad }), bad).toEqual(['set.bad_per_carton']);
    expect(listRow('pack_skus', { ...r, packs_per_carton: '20' })).toMatchObject({ packs_per_carton: 20 });
    expect(listRow('pack_skus', { ...r, packs_per_carton: '' })).toMatchObject({ packs_per_carton: null });
    expect(migration).toContain('check (packs_per_carton is null or packs_per_carton between 1 and 1000)');
  });
});

describe('Carton labels', () => {
  it('two papers: an A4 sheet of 8, a label printer\'s 100 × 150 mm; the QR is the plain code', () => {
    expect(PAPER_PAGE).toEqual({ a4_8: 'A4', label_100x150: '100mm 150mm' });
    const src = read('web/src/pages/records/PackLabels.tsx');
    expect(src).toContain('QRCode.toDataURL(c.code,');                                   // no address: nothing behind a carton's code
    expect(read('web/src/styles.css')).toMatch(/\.carton-sheet\.a4_8 \{ grid-template-columns: repeat\(2, 1fr\); \}/);
  });
});

describe('People · Reports to, the buddy, the department', () => {
  const choices: OrgChoices = {
    managers: [{ id: 'm1', name: 'UP State Manager', band: 'Senior Manager', seat: 'state_manager', state: 'Uttar Pradesh' },
      { id: 'm0', name: 'Veda (Admin)', band: null, seat: 'admin', state: null }, { id: 'm2', name: 'Asha', band: 'Manager', seat: 'hr_admin', state: 'Uttar Pradesh' }],
    buddies: [], departments: ['Operations', 'Quality'] };
  it('the managers by state, head office first; with the seat and the band', () => {
    expect(byState(choices.managers).map((g) => [g.state, g.people.map((p) => p.name)])).toEqual([[null, ['Veda (Admin)']], ['Uttar Pradesh', ['Asha', 'UP State Manager']]]);
    render(<ReportsToSelect id="r" value="old" onChange={() => {}} choices={choices} before="Ravi Kumar" exclude="m2" />);
    const opts = [...(screen.getByTestId('r') as HTMLSelectElement).options].map((o) => o.textContent);
    expect(opts).toEqual(['—', 'Ravi Kumar (chosen before; not a choice now)', 'Veda (Admin) · Admin', 'UP State Manager · State Manager, Senior Manager']);
  });
  it('the department: the list; a department typed before stays, marked; the list\'s spelling is chosen', () => {
    const { rerender } = render(<DepartmentSelect id="d" value="People" onChange={() => {}} choices={choices} />);
    expect([...(screen.getByTestId('d') as HTMLSelectElement).options].map((o) => o.textContent)).toEqual(['—', 'People (typed before; not on the list)', 'Operations', 'Quality']);
    rerender(<DepartmentSelect id="d" value="quality" onChange={() => {}} choices={choices} />);
    expect((screen.getByTestId('d') as HTMLSelectElement).value).toBe('Quality');
  });
  it('the screens ask the server for the choices; no list of everyone is left', () => {
    const hr = read('web/src/pages/hr/Hr.tsx');
    expect(hr).not.toContain("id=\"j-dept\" value={f.department} onChange={set('department')} />");
    expect(hr).not.toMatch(/usePeople\(\)/);
    expect(read('web/src/pages/hr/OrgChoices.tsx')).toContain("rpc<OrgChoices>('org_choices', { p_state: state || null })");
    expect(migration).toContain('create trigger employee_org_b5_choices before insert or update on public.employee_org');
  });
});

describe('Every raise of migration 58 has its plain words, in both languages', () => {
  it('the new messages', () => {
    const own = migration.slice(0, migration.indexOf('Patches of the current definitions'));
    const patches = migration.slice(migration.indexOf('Patches of the current definitions'));
    const msgs = [...own.matchAll(/raise exception '((?:[^']|'')+)'/g), ...patches.matchAll(/raise exception '((?:shipment|commercial): (?:[^']|'')*(?:carton|set aside)(?:[^']|'')*)'/g)]
      .map((m) => m[1].replaceAll("''", "'").replaceAll('%', '12'));
    expect(msgs.length).toBeGreaterThanOrEqual(15);
    for (const m of new Set(msgs)) {
      if (m === 'record not found') continue;
      expect(plainWords(m, t), m).not.toBeNull();
    }
    expect(plainWords('shipment: PRSDM-KNM-KH26-B0001-C0011 not set aside for this order', t)).toMatch(/^Not set aside for this order: PRSDM-KNM-KH26-B0001-C0011\./);
    expect(plainWords('commercial: only 25 packs of 1 kg pouch can be set aside for this order (the rest are set aside for other orders)', t)).toMatch(/^Only 25 packs of 1 kg pouch/);
  });
  it('every new word has its Hindi; the import\'s warnings too', () => {
    const files = ['web/src/engine/OrderCartons.tsx', 'web/src/pages/hr/OrgChoices.tsx', 'web/src/pages/records/PackLabels.tsx', 'web/src/engine/PackCodes.tsx', 'web/src/lib/plainErrors.ts'];
    const keys = new Set<string>();
    for (const f of files) for (const m of read(f).matchAll(/(?:t\(|key: )'((?:oc|org|pk|pc|err|units)\.[a-z0-9_]+)'/g)) keys.add(m[1]);
    expect(keys.size).toBeGreaterThan(40);
    for (const k of keys) { expect(en[k], k).toBeTruthy(); expect(hi[k], k).toBeTruthy(); }
    for (const k of ['imp.reports_to_not_manager', 'imp.department_unknown', 'computed.units', 'computed.cartons_count', 'set.f_packs_per_carton']) { expect(en[k], k).toBeTruthy(); expect(hi[k], k).toBeTruthy(); }
    expect(enPublic['pv.farmers_of.one']).toBe('1 farmer of {village}');
    expect(hiPublic['pv.farmers_of.one']).toBeTruthy();
    expect(enPublic['pv.carton'] && hiPublic['pv.carton']).toBeTruthy();
  });
});

function b(n: number) { return `${B}-${String(n).padStart(4, '0')}`; }
