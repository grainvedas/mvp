// Migration 56 (release 9 of the operator-stages plan; Veda, 16 Oct 2026, "proceed with 56"): Part F, a sale or a
// shipment shared with its buyer through a link; D5–D6, every scan with its approximate place, copy detection and the
// public warning; one client's data never another client's (the roster pool says, not names, another client's work);
// the Collection Batch's lot filters (village, farmer, lot code, all shown); and three small fixes of release 55
// ("every day", the farmer list loading, an export sale's market and destination marked required).
import { afterEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { cleanup } from '@testing-library/react';
import { plainWords } from '../src/lib/plainErrors';
import { actionLines } from '../src/pages/NeedsMyAction';
import { inspectionLine } from '../src/pages/records/Warehouse';
import { buyerLinkUrl, shareMessage, scanFlagText, type ScanFlag } from '../src/pages/records/BuyerShare';
import { buyerToken, evidencePack, type BuyerContent } from '../src/pages/public/BuyerView';
import { filterLots, lotVillages } from '../src/engine/widgets';
import { elsewhereLine } from '../src/lib/setup';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';
import { handle, VERSION, tokenShape } from '../../supabase/functions/buyer-file/handler';
import { VERSION as SIX_VERSION } from '../../supabase/functions/create-user/handler';
import type { FieldDef, MyActions, WarehouseInfo } from '../src/lib/types';

const root = join(__dirname, '../..');
const read = (p: string) => readFileSync(join(root, p), 'utf8');
const migration = read('supabase/migrations/20261031000100_buyer_link_scans.sql');
const defs = JSON.parse(read('web/tests/fixtures/stage_definitions.json')) as { stage_type: string; form_schema: FieldDef[] }[];
const t = (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = en[k] ?? enPublic[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replace(`{${n}}`, String(x));
  return s;
};
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

describe('Part F · the buyer link', () => {
  it('the token goes after the # (no web server receives it) and is read back only in its shape', () => {
    const tok = 'a'.repeat(48);
    expect(buyerLinkUrl('https://app.example/', tok)).toBe(`https://app.example/b#${tok}`);
    expect(buyerToken(`#${tok}`)).toBe(tok);
    expect(buyerToken('#nope')).toBeNull();
    expect(buyerToken(`#${'A'.repeat(48)}`)).toBeNull();
    expect(tokenShape(tok)).toBe(true);
  });
  it('the message names the order and the date, not a price', () => {
    const m = shareMessage('X-CM-0001', 'https://a/b#t', '2026-11-15T00:00:00Z', t);
    expect(m).toContain('X-CM-0001'); expect(m).toContain('https://a/b#t'); expect(m).not.toMatch(/price|₹|INR/i);
  });
  it('the evidence pack is the page with each file\'s SHA-256, and no file address', () => {
    const c = { kind: 'shipment', code: 'SH-1', generated_at: '', seller: 'S', crop: { name: 'K', gi_tag: null, origin: null }, season: 'KH26', gi_status: 'unknown',
      order: { code: 'CM-1', order_no: 'EX-77', buyer: 'B', buyer_country: 'NL', market: 'export', market_name: 'EU', destination_country: 'NL', packs: null, kg: 40, on: null },
      shipments: [], lab: [], documents: [], chain: [], origin: { villages: [], farmers: 1, shares_note: '' }, release: null, qr_code: null,
      files: [{ id: 'f1', label: 'lab_report', record: 'QC-1', sha256: 'ab'.repeat(32), at: '2026-10-16' }] } as BuyerContent;
    const j = JSON.parse(evidencePack(c, '2026-11-15'));
    expect(j.files).toEqual([{ label: 'lab_report', record: 'QC-1', sha256: 'ab'.repeat(32), added: '2026-10-16' }]);
    expect(j.link_expires).toBe('2026-11-15'); expect(JSON.stringify(j)).not.toMatch(/price|storage_path|"id":"f1"/);
  });
  it('the page\'s content: never a price, a farmer\'s name, another buyer, the farm gate', () => {
    const body = migration.slice(migration.indexOf('function app.buyer_content'), migration.indexOf('function app.create_buyer_link'));
    expect(body).not.toMatch(/price|currency|rate_|fm\.name|farmer_name/);
    expect(body).toContain("x.stage_type <> 'procurement'");
    expect(body).toContain("'shares_note', 'documented proportions by mass balance, not physical identity'");
  });
  it('only the fingerprint of a token is kept, and nobody reads it', () => {
    expect(migration).toMatch(/token_hash\s+text not null unique/);
    expect(migration).not.toMatch(/grant select on public\.buyer_links to authenticated;/);
    expect(migration).toMatch(/grant execute on function app\.buyer_file\(text, uuid\) to service_role/);
  });
});

describe('Part F · the buyer-file function', () => {
  const env = { SUPABASE_URL: 'https://p.example', SUPABASE_SERVICE_ROLE_KEY: 'svc' };
  it('says its own build; the six older functions keep theirs', async () => {
    const r = await handle(new Request('http://fn/buyer-file'), env);
    expect(await r.json()).toEqual({ function: 'buyer-file', version: VERSION });
    expect(r.headers.get('x-grainveda-function')).toBe(VERSION);
    expect(VERSION).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(VERSION).not.toBe(SIX_VERSION);
    expect(read('scripts/check_functions.mjs')).toContain("const APART = ['buyer-file']");
  });
  it('refuses a malformed request before asking anyone', async () => {
    const f = vi.fn(); vi.stubGlobal('fetch', f);
    const r = await handle(new Request('http://fn/buyer-file', { method: 'POST', body: JSON.stringify({ token: 'x', file: 'y' }) }), env);
    expect(r.status).toBe(400); expect(f).not.toHaveBeenCalled();
  });
  it('asks the database, then signs a two-minute download of that file only', async () => {
    const calls: { url: string; body: string }[] = [];
    vi.stubGlobal('fetch', vi.fn(async (u: string, init: RequestInit) => {
      calls.push({ url: String(u), body: String(init.body) });
      if (String(u).includes('/rpc/buyer_file')) return new Response(JSON.stringify({ ok: true, path: 'a/b c.pdf', sha256: 'h', label: 'lab_report' }), { status: 200 });
      return new Response(JSON.stringify({ signedURL: '/object/sign/evidence/a/b%20c.pdf?token=s' }), { status: 200 });
    }));
    const tok = 'f'.repeat(48), file = '00000000-0000-4000-8000-000000000001';
    const r = await handle(new Request('http://fn/buyer-file', { method: 'POST', body: JSON.stringify({ token: tok, file }) }), env);
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ url: 'https://p.example/storage/v1/object/sign/evidence/a/b%20c.pdf?token=s', label: 'lab_report', sha256: 'h' });
    expect(JSON.parse(calls[0].body)).toEqual({ p_token: tok, p_file: file });
    expect(calls[1].url).toBe('https://p.example/storage/v1/object/sign/evidence/a/b%20c.pdf');
    expect(JSON.parse(calls[1].body)).toEqual({ expiresIn: 120 });
  });
  it('a dead link or another file: 404, nothing signed', async () => {
    const f = vi.fn(async () => new Response(JSON.stringify({ ok: false, problem: 'file' }), { status: 200 }));
    vi.stubGlobal('fetch', f);
    const r = await handle(new Request('http://fn/buyer-file', { method: 'POST', body: JSON.stringify({ token: 'f'.repeat(48), file: '00000000-0000-4000-8000-000000000001' }) }), env);
    expect(r.status).toBe(404); expect(await r.json()).toEqual({ problem: 'file' }); expect(f).toHaveBeenCalledTimes(1);
  });
});

describe('D5–D6 · scans, their place, and copies', () => {
  it('the host\'s function reads the place headers and calls record_scan_at with the public key', () => {
    const s = read('web/api/scan.js');
    for (const h of ['x-vercel-ip-city', 'x-vercel-ip-country', 'x-vercel-ip-country-region', 'x-vercel-ip-latitude', 'x-vercel-ip-longitude']) expect(s).toContain(h);
    expect(s).toContain('/rest/v1/rpc/record_scan_at'); expect(s).toContain('VITE_SUPABASE_ANON_KEY');
    expect(s).not.toMatch(/SERVICE_ROLE|x-forwarded-for|user-agent/i);
  });
  it('vercel.json leaves /api/ to the functions (the app is every other path)', () => {
    const v = JSON.parse(read('web/vercel.json'));
    expect(v.rewrites[0].source.startsWith('/((?!api/|assets/')).toBe(true);
  });
  it('a scan flag says what was seen', () => {
    const far = { kind: 'far_apart', detail: { km: 6342.4, limit_km: 300, places: [{ city: 'New Delhi', country: 'IN', at: '' }, { city: 'Rotterdam', country: 'NL', at: '' }] } } as unknown as ScanFlag;
    expect(scanFlagText(far, t)).toBe('Scanned 6342 km apart within the window (New Delhi, IN and Rotterdam, NL; the limit is 300 km).');
    const many = { kind: 'many', detail: { scans_24h: 51, limit: 50 } } as unknown as ScanFlag;
    expect(scanFlagText(many, t)).toBe('Scanned 51 times in a day (the limit is 50).');
  });
  it('"Needs my action" counts the scan flags for the managers', () => {
    const a = { returned: [], to_verify: [], proposals: 0, farmers_to_verify: 0, requirement_lines: 0, flags: 0, conditions: 0, scan_flags: 2 } as MyActions;
    expect(actionLines(a, t)).toEqual([expect.objectContaining({ key: 'scanflags', n: 2, to: '/flags' })]);
  });
  it('the public warning is in the public page\'s own words, in both languages', () => {
    for (const k of ['pv.copy_warning', 'pv.copy_warning_plain']) { expect(enPublic[k]).toBeTruthy(); expect(hiPublic[k]).toBeTruthy(); }
    expect(enPublic['pv.copy_warning']).toContain('{seller}'); expect(hiPublic['pv.copy_warning']).toContain('{seller}');
  });
  it('the public journey still reads no worked-out values', () => {
    const j = migration.indexOf('public_lot_journey');
    expect(j === -1 || !migration.slice(j, migration.indexOf('$function$', j + 200)).includes('computed')).toBe(true);
  });
});

describe('one client\'s data is never another client\'s', () => {
  it('the roster pool says another client\'s work, without naming it', () => {
    const other = elsewhereLine({ other_client: true, status: 'active', stages: ['milling'] }, t);
    expect(other).toContain('for another client'); expect(other).toContain(t('stage.milling', undefined, 'milling'));
    expect(elsewhereLine({ scope_id: 's', label: 'KH26 · gkp', client: 'C', status: 'active', stages: ['milling'] }, t)).toContain('KH26 · gkp');
  });
  it('the migration closes the three leaks the probe found', () => {
    expect(migration).toContain('using (client_id is null or app.can_access_client(client_id))');
    expect(migration).toContain("'other_client', true");
    expect(migration).toMatch(/activation_missing[\s\S]*can_access_client\(\(select s\.client_id from public\.scopes s where s\.id = p_scope\)\)/);
    expect(migration).toMatch(/revoke execute on function app\.isolation_owner\(text, jsonb\), app\.isolation_probe\(boolean, boolean\) from public, anon, authenticated/);
  });
});

describe('the Collection Batch\'s lot filters', () => {
  const names = { f1: { name: 'Ram Achal', village: 'Itwa', farmer_code: 'PRS-F-0001' }, f2: { name: 'Suresh Yadav', village: 'Bansi', farmer_code: 'PRS-F-0002' },
    f3: { name: 'Ram Prasad', village: 'itwa ', farmer_code: 'PRS-F-0003' } };
  const lots = [{ id: '1', farmer_id: 'f1', footprint_code: 'P-0001' }, { id: '2', farmer_id: 'f2', footprint_code: 'P-0002' },
    { id: '3', farmer_id: 'f3', footprint_code: 'P-0003' }, { id: '4', farmer_id: 'f1', footprint_code: 'P-0004' }, { id: '5', farmer_id: null, footprint_code: 'P-0005' }];
  it('the villages, by name, with their lots (spelling and spaces aside)', () => {
    expect(lotVillages(lots, names)).toEqual([{ key: 'bansi', village: 'Bansi', n: 1 }, { key: 'itwa', village: 'Itwa', n: 3 }, { key: '-', village: '—', n: 1 }].sort((a, b) => a.village.localeCompare(b.village)));
  });
  it('a village, a farmer\'s name, his code or a lot code', () => {
    expect(filterLots(lots, names, 'itwa', '').map((l) => l.id)).toEqual(['1', '3', '4']);
    expect(filterLots(lots, names, 'itwa', 'achal').map((l) => l.id)).toEqual(['1', '4']);
    expect(filterLots(lots, names, '', 'prs-f-0002').map((l) => l.id)).toEqual(['2']);
    expect(filterLots(lots, names, '', 'p-0005').map((l) => l.id)).toEqual(['5']);
    expect(filterLots(lots, names, '-', '').map((l) => l.id)).toEqual(['5']);
  });
});

describe('three fixes of release 55', () => {
  it('"every day", not "every 1 days"', () => {
    const w = { days: 1, bags_in: 4, bags_out: 0, inspections: [], moves: [], inspection: { state: 'ok', next_due: '2026-10-17', interval_days: 1 } } as unknown as WarehouseInfo;
    expect(inspectionLine(w, t)).toMatch(/\(every day\)$/);
    expect(inspectionLine({ ...w, inspection: { ...w.inspection!, interval_days: 15 } } as WarehouseInfo, t)).toMatch(/every 15 days/);
    expect(en['wp.days_1']).toBe('1 day');
  });
  it('an export sale\'s market and destination are marked required (shown only for export)', () => {
    const c = defs.find((d) => d.stage_type === 'commercial')!.form_schema;
    for (const k of ['market_code', 'destination_country']) {
      const f = c.find((x) => x.key === k)!;
      expect(f.required).toBe(true); expect(f.shown_if).toEqual({ market: 'export' });
    }
    expect(read('supabase/seeds/01_stage_definitions.sql')).toContain("Migration 56: an export sale asks its market's profile");
  });
  it('the farmer list says "loading" until it has come, then "no farmer yet" only if there is none', () => {
    const w = read('web/src/engine/widgets.tsx');
    expect(w).toMatch(/groups\.length === 0 && \(loaded \? <p className="small muted" data-testid="no-farmers">/);
    expect(w).toContain("setLoaded(true)");
    expect(en['widget.farmers_loading']).toBeTruthy(); expect(hi['widget.farmers_loading']).toBeTruthy();
  });
});

describe('words', () => {
  const raised = [...migration.matchAll(/raise exception '((?:[^']|'')*)'/g)].map((m) => m[1].replace(/''/g, "'"))
    .filter((r) => r !== 'not authenticated');
  it('every refusal of the migration has its plain words', () => {
    expect(raised.length).toBeGreaterThan(10);
    for (const r of raised) expect(plainWords(r.replace(/%/g, 'pending'), t), r).not.toBeNull();
  });
  it('every new word in English and in Hindi', () => {
    const block = (s: string) => s.slice(s.indexOf("migration 56: the buyer's link"));
    const ek = [...block(read('web/src/lib/i18n.en.ts')).matchAll(/^\s*'([^']+)':/gm)].map((m) => m[1]);
    const hk = [...block(read('web/src/lib/i18n.hi.ts')).matchAll(/^\s*'([^']+)':/gm)].map((m) => m[1]);
    expect(ek.length).toBeGreaterThan(100); expect(hk).toEqual(ek);
    for (const k of ek) { expect(en[k], k).toBeTruthy(); expect(hi[k], k).toBeTruthy(); }
    // every key the new pages use is in the dictionaries
    for (const f of ['web/src/pages/records/BuyerShare.tsx', 'web/src/pages/public/BuyerView.tsx']) {
      for (const m of read(f).matchAll(/t\('((?:bk|bv|sf)\.[a-z_]+)'/g)) expect(en[m[1]], m[1]).toBeTruthy();
    }
  });
});
