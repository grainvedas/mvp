// Migration 59 (Phase 1, release 1 of Veda's combined brief, 19 Oct 2026: Part A fixes, Part B the client login reads
// only). The rules are the database's (tests/54_fixes_client_reads_only.sql); these hold the screens' side of them.
import { afterEach, describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { JourneyView, PackNotReleased, readingRows } from '../src/pages/public/PublicVerify';
import type { Journey, JourneyStep } from '../src/pages/public/journey';
import { readingText } from '../src/pages/public/BuyerView';
import { labLine, readingsLine } from '../src/pages/trace/LotTrace';
import { pendingByStage } from '../src/pages/ClientWaiting';
import { isClientLogin } from '../src/lib/rights';
import { isSameFile } from '../src/engine/DupFile';
import { AppError } from '../src/lib/errors';
import { plainWords } from '../src/lib/plainErrors';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';
import type { MyContext } from '../src/lib/types';

const root = join(__dirname, '../..');
const read = (p: string) => readFileSync(join(root, p), 'utf8');
const migration = read('supabase/migrations/20261103000100_fixes_client_reads_only.sql');
const tr = (d: Record<string, string>) => (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = d[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
afterEach(() => cleanup());

const step = (o: Partial<JourneyStep>): JourneyStep => ({ stage: 'procurement', code: 'X', qty_in_kg: 0, qty_out_kg: 0, verified_at: null, created_at: '2026-11-12T05:00:00Z', ...o });
const journey = (steps: JourneyStep[], o: Partial<Journey> = {}): Journey => ({
  qr_code: 'GV-ABCDEF123456', sealed_at: '2026-12-02T05:00:00Z', ledger_hash: 'a'.repeat(64), batch_codes: [], season: 'KH26', geography: 'Bansi',
  crop: { name: 'Kalanamak rice', gi_tag: '280', origin: 'Siddharthnagar' }, client: { name: 'Test Client UP', type: 'trade' }, gi_status: 'gi',
  farmer_count: 2, verdict: { domestic: 'pass', export: 'pass', overridden: false }, journey: steps, independent: false, ...o });

describe('A1 · a pack before release', () => {
  it('shows "Packed, not yet released" with the crop, the batch code and the date packed, nothing else', () => {
    render(<MemoryRouter><PackNotReleased p={{ released: false, crop: { name: 'Kalanamak rice' }, pack: { serial: 'TCUP-KNM-KH26-B0004-0007', batch_code: 'TCUP-KNM-KH26-B0004', packed_on: '2026-10-17' } }} /></MemoryRouter>);
    expect(screen.getByTestId('pv-not-released').textContent).toMatch(/^Packed, not yet released/);
    expect(screen.getByText('Kalanamak rice')).toBeTruthy();
    expect(screen.getByText('TCUP-KNM-KH26-B0004')).toBeTruthy();
    expect(screen.getByTestId('public-pack').textContent).toContain('17 Oct 2026');
    expect(screen.getByTestId('public-pack').textContent).not.toMatch(/Sold by|Best before|scans|Kharif/);
  });
  it('a code scanned far apart is warned of before release too, without the seller', () => {
    render(<MemoryRouter><PackNotReleased p={{ released: false, crop: { name: 'Kalanamak rice' }, pack: { serial: 'S-0001', batch_code: 'S', packed_on: '2026-10-17', copy_warning: true } }} /></MemoryRouter>);
    expect(screen.getByTestId('pv-copy-warning').textContent).toBe(enPublic['pv.copy_warning_plain']);
    expect(screen.getByTestId('pv-not-released')).toBeTruthy();
  });
  it('a voided pack says it is voided, not "not yet released"', () => {
    render(<MemoryRouter><PackNotReleased p={{ released: false, crop: { name: 'Kalanamak rice' }, pack: { serial: 'TCUP-KNM-KH26-B0004-0158', batch_code: 'TCUP-KNM-KH26-B0004', packed_on: '2026-10-17', void: true } }} /></MemoryRouter>);
    expect(screen.getByTestId('pv-void')).toBeTruthy();
    expect(screen.queryByTestId('pv-not-released')).toBeNull();
  });
  it('the database returns no more than that (migration text)', () => {
    expect(migration).toContain("'pack', jsonb_build_object('serial', p.serial, 'batch_code', p.batch_code, 'packed_on', p.packed_on, 'void', p.status = 'void',\n                                 'copy_warning', app.scan_warning(p.serial)),\n      'crop', jsonb_build_object('name', cr.name));");
  });
});

describe('A2 · a step recorded and checked by one person says so', () => {
  it('the sentence of the brief, in English and Hindi, on that step only', () => {
    expect(enPublic['pv.same_person']).toBe('Recorded and checked by the same person.');
    expect(hiPublic['pv.same_person']).toBeTruthy();
    render(<MemoryRouter><JourneyView j={journey([step({ code: 'P1', same_person: true }), step({ code: 'Q1', stage: 'qc', checked: true }), step({ code: 'R1', stage: 'qr_activation' })])} /></MemoryRouter>);
    expect(screen.getAllByTestId('pv-same-person')).toHaveLength(1);
    expect(screen.getAllByTestId('pv-checked')).toHaveLength(1);
  });
});

describe('A3 · units from the server', () => {
  it('the public page, the buyer page and the journey use the unit the server gives, else the key\'s', () => {
    const rows = readingRows([step({ stage: 'qc', readings: { moisture_pct: 12.6, aflatoxin: 1.5, grain_length_mm: 7.1 } })], { aflatoxin: 'µg/kg', grain_length_mm: 'mm' });
    expect(rows.map((r) => `${r.value} ${r.unit}`)).toEqual(['12.6 %', '1.5 µg/kg', '7.1 mm']);
    expect(readingText('aflatoxin', 1.5, { aflatoxin: 'µg/kg' })).toBe('1.5 µg/kg');
    expect(readingText('moisture_pct', 12.6)).toBe('12.6 %');
    expect(readingsLine({ moisture_pct: 12.6, aflatoxin_ppb: 1.5 }, { moisture_pct: '%' })).toBe('Moisture 12.6 % · Aflatoxin 1.5 ppb');
  });
});

describe('A5 · the lab', () => {
  it('its name and accreditation number wherever the report number is', () => {
    expect(labLine({ name: 'Gorakhpur Grain Lab', accreditation_no: 'TC-5521', report_no: 'GGL/118', report_date: '2026-10-15' }))
      .toBe('Gorakhpur Grain Lab (accreditation TC-5521) · report GGL/118 of 2026-10-15');
    expect(read('supabase/migrations/20261104000100_exports.sql')).toMatch(/'same_person'[\s\S]*'lab'[\s\S]*'data_note'\]/);   // the exports (migration 60)
    expect(en['lab.accreditation']).toContain('{no}'); expect(hi['lab.accreditation']).toContain('{no}');
  });
});

describe('A6 · one file as two kinds of document', () => {
  it('the refusal is recognised and said in plain words, the kind of document in the reader\'s language', () => {
    const raw = 'same file: this exact file is already attached as lab report on TCUP-KNM-KH26-BNS-QC-0002';
    expect(isSameFile(new AppError(raw, 'GVDUP', 'other', raw))).toBe(true);
    expect(isSameFile(new AppError('something else', '23514', 'rule', 'something else'))).toBe(false);
    expect(plainWords(raw, tr(en))).toBe('This exact file is already attached as lab report on TCUP-KNM-KH26-BNS-QC-0002. Give a reason to attach it here too.');
    expect(plainWords(raw, tr(hi))).toContain('लैब रिपोर्ट');
    expect(plainWords('same file: this exact file is already attached as proof of delivery on X-1', tr(hi))).toContain('डिलीवरी का प्रमाण');
  });
});

describe('A8 · old data and typed batch codes', () => {
  it('the exports carry the note; the refusal of a typed code in use is plain', () => {
    expect(read('supabase/migrations/20261104000100_exports.sql')).toContain("'received_at', 'data_note']");   // the exports (migration 60)
    expect(plainWords('batch code TCUP-2026-KNM-001 is in use already: a batch code is given by the system', tr(en))).toBe('Batch code TCUP-2026-KNM-001 is already in use: batch codes are given by the system.');
    expect(en['scope.old_data']).toMatch(/^Practice \(old data\)/);
  });
});

describe('B · the client login reads only', () => {
  it('is known from the server\'s word (external), not from the role word', () => {
    const ctx = (external: boolean, role: string) => ({ user: { id: 'u', role, external } } as unknown as MyContext);
    expect(isClientLogin(ctx(true, 'client_view'))).toBe(true);
    expect(isClientLogin(ctx(false, 'client_view'))).toBe(false);
    expect(isClientLogin(null)).toBe(false);
  });
  it('a refusal of its write is plain, in English and Hindi', () => {
    const raw = 'a client login reads only: it cannot change records, files, flags or lists';
    expect(plainWords(raw, tr(en))).toMatch(/reading only/);
    expect(plainWords(raw, tr(hi))).toMatch(/केवल देखने/);
  });
  it('"Waiting on GrainVeda": the records not yet checked, counted per stage', () => {
    expect(pendingByStage([{ code: 'a', stage: 'qc', scope_id: 's', since: '' }, { code: 'b', stage: 'packing', scope_id: 's', since: '' }, { code: 'c', stage: 'qc', scope_id: 's', since: '' }]))
      .toEqual([{ stage: 'qc', n: 2 }, { stage: 'packing', n: 1 }]);
  });
  it('the database refuses it at the tables, the files and the farmers\' phones (migration text)', () => {
    for (const tbl of ['footprints', 'attachments', 'flags', 'farmers', 'scopes', 'buyers', 'buyer_links', 'bills_of_lading', 'deliveries'])
      expect(migration).toContain(`create trigger a00_client_login_reads_only before insert or update or delete on public.${tbl} `);
    expect(migration).toContain("(bucket_id = 'evidence') and not app.is_client_login()");
    expect(migration).toContain("'••••••' || right(regexp_replace(f.phone, '[^0-9]', '', 'g'), 4)");
    expect(migration).toContain('revoke select on public.app_users from authenticated;');
  });
  it('every new string has its Hindi', () => {
    for (const k of Object.keys(en).filter((x) => /^(cw|dup|dockind|lab|scope\.old_data|err\.(client_reads_only|same_file|batch_in_use)|home\.open_scope|trace\.lab)/.test(x)))
      expect(hi[k], k).toBeTruthy();
  });
});
