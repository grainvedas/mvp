// Migration 71 (Phase 3, release 4 of Veda's combined brief of 19 Oct 2026: Part E1, the evidence pack). The rules are the
// database's (tests/66_evidence_pack.sql); these hold the browser's side: the pack written down in the brief's words (title,
// footer, never "certificate" otherwise), its eight sections, a client order's pack with one section per scope; the
// shareable copy without a farmer's name, a price or an internal ID; a release on the client's acceptance never "Passed";
// the PDF A4 in English and Hindi, the same bytes each time it is drawn (so a file drawn later checks against the verify
// page); the JSON with the PDFs' SHA-256; the buyer's page drawing the same files; the card; the verify page; item 69 (1).
import { afterEach, describe, expect, it, vi } from 'vitest';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { packDocument, packVerdict, subjectLine } from '../src/lib/epModel';
import { packFileKey, packFiles, packJson, type LotPack, type OrderPack, type PackHead } from '../src/lib/evidencePacks';
import { buyerPackHead } from '../src/pages/public/BuyerView';
import { missingFiles, readerFiles } from '../src/pages/records/EvidencePacks';
import { showComputed } from '../src/engine/values';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';

const root = join(__dirname, '../..');
type Fx = { head: PackHead; shareable: LotPack; internal: LotPack };
const fx = JSON.parse(readFileSync(join(__dirname, 'fixtures/evidence_pack.json'), 'utf8')) as { shipment: Fx; lot: Fx; order: { head: PackHead; shareable: OrderPack; internal: OrderPack } };
const migration = readFileSync(join(root, 'supabase/migrations/20261114000100_evidence_pack.sql'), 'utf8');
const tr = (d: Record<string, string>) => (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = d[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
const T = tr({ ...enPublic, ...en });
const H = tr({ ...enPublic, ...en, ...hiPublic, ...hi });
const all = (x: unknown) => JSON.stringify(x);
const farmer = fx.shipment.internal.origin.farmer_list![0].name;
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe('E1 · the pack in the brief\'s words', () => {
  it('title, footer; "certificate" only in the footer\'s "It is not … a certificate"', () => {
    const rd = packDocument(fx.shipment.head, fx.shipment.shareable, T, 'https://app.test');
    expect(rd.title).toBe('Verified traceability statement: evidence pack');
    expect(rd.footer).toBe('This statement records what GrainVeda verified under its published protocol. It is not a quality, residue or Geographical Indication certificate.');
    expect(rd.verifyUrl).toBe('https://app.test/d/GV-EP-000006');
    expect(rd.banner).toBeNull();
    expect(all(rd.sections).toLowerCase()).not.toContain('certificate');
  });
  it('the sections of the brief, in order: header, origin, mass balance, quality, documents, chain, packs, verification', () => {
    const rd = packDocument(fx.shipment.head, fx.shipment.shareable, T, '');
    expect(rd.sections.map((s) => s.key)).toEqual(['header', 'origin', 'balance', 'quality', 'documents', 'chain', 'packs', 'ledger', 'verification']);
    const head = all(rd.sections[0]);
    for (const x of ['GrainVeda (Prasaadam trade scope)', 'Kalanamak rice', 'Shipment PRSDM-KNM-KH26-BSTA-SH-0001', 'Delhi Wholesale', 'INV-71-1', 'ORD-PRSDM-0001', 'GV-EP-000006', 'Version 2'])
      expect(head).toContain(x);
    expect(head).not.toContain('GI 280');                                     // GI not confirmed for this lot: no GI tag
    expect(all(rd.sections[1])).toContain('GI not confirmed');
    expect(all(rd.sections[1])).toContain('Bansi');
  });
  it('mass balance: the milling recovery against the ceiling, sold never above procured', () => {
    const rd = packDocument(fx.shipment.head, fx.shipment.shareable, T, '');
    const b = all(rd.sections.find((s) => s.key === 'balance'));
    expect(b).toContain('69.8 % (protocol ceiling 70 %)');
    expect(b).toContain('130 kg → 6 kg → 6 kg');
    expect(b).toMatch(/Sold .*6 kg.* procured .*130 kg|6 kg.*130 kg/);
  });
  it('the shareable copy: no farmer\'s name, no price, no internal ID; the internal one has the farmers and the price', () => {
    const sh = all(packDocument(fx.shipment.head, fx.shipment.shareable, T, ''));
    expect(sh).not.toContain(farmer);
    expect(sh).not.toMatch(/120(\.00)? INR\/kg/);
    expect(JSON.stringify(fx.shipment.shareable)).not.toMatch(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/);
    const int = packDocument(fx.shipment.head, fx.shipment.internal, T, '');
    expect(all(int)).toContain(farmer);
    expect(int.sections.map((s) => s.key)).toContain('price');
    expect(all(int.sections.find((s) => s.key === 'price'))).toContain('INR/kg');
    expect(int.copyNote).toBe(en['exp.footer_internal']);
  });
  it('a release on the client\'s acceptance is said as such, never "Passed"', () => {
    const rd = packDocument(fx.lot.head, fx.lot.shareable, T, '');
    const q = all(rd.sections.find((s) => s.key === 'quality'));
    expect(q).toContain(`Export (general): ${en['rep.q.accepted']}`);
    expect(q).not.toContain('Export (general): Passed');
    expect(q).toContain('Domestic: Passed');
    expect(packVerdict('fail', true, T)).toBe(en['rep.q.accepted']);
    expect(subjectLine('lot', 'X-QR-1', T)).toBe('Sealed lot X-QR-1');
  });
  it('a client order\'s pack: one invoice, one section per scope (Assam, Uttar Pradesh), each with its part', () => {
    const rd = packDocument(fx.order.head, fx.order.shareable, T, '');
    expect(rd.sections.map((s) => s.key)).toEqual(['header', 'scope-1', 'scope-2', 'verification']);
    expect(rd.sections[1].title).toContain('Assam');
    expect(rd.sections[2].title).toContain('Uttar Pradesh');
    expect(all(rd.sections[0])).toContain('Client order ORD-PRSDM-0001');
    expect(all(rd.sections[0])).toContain('2 scope(s): Assam, Uttar Pradesh');
    expect(all(rd).match(/INV-71-1/g)!.length).toBeGreaterThanOrEqual(3);   // the order's, and each part's shipment
    for (const s of rd.sections.slice(1, 3)) expect(all(s)).toContain('Mass balance');
    expect(all(rd)).not.toContain(farmer);
  });
  it('Hindi throughout: titles and section names are Hindi words; every new word has its Hindi', () => {
    const rd = packDocument(fx.order.head, fx.order.shareable, H, '');
    expect(rd.title).toBe(hi['ep.title']);
    expect(rd.footer).toBe(hi['rep.footer']);
    for (const k of Object.keys(en).filter((x) => x.startsWith('ep.') || x.startsWith('bv.pack') || x === 'cv.kind.evidence_pack' || x === 'ov.reports_packs'))
      expect(hi[k], k).toBeTruthy();
    for (const k of Object.keys(enPublic).filter((x) => x.startsWith('dv.'))) expect(hiPublic[k], k).toBeTruthy();
  });
});

describe('E1 · the files: PDF (A4, English and Hindi) and JSON', () => {
  it('the PDF of each language, A4, the same bytes each time it is drawn', async () => {
    vi.stubGlobal('fetch', async (url: string) => {
      const file = join(__dirname, '..', String(url).replace(/^\//, '').replace(/\?.*$/, ''));
      const b = readFileSync(file);
      return { arrayBuffer: async () => b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) };
    });
    const { reportPdf } = await import('../src/lib/reportPdf');
    const { PDFDocument } = await import('pdf-lib');
    for (const [lang, t] of [['en', T], ['hi', H]] as const) {
      const rd = packDocument(fx.order.head, fx.order.internal, t, 'https://app.test');
      const bytes = await reportPdf(rd, fx.order.head.issued_at);
      const again = await reportPdf(packDocument(fx.order.head, fx.order.internal, t, 'https://app.test'), fx.order.head.issued_at);
      expect(Buffer.from(again).equals(Buffer.from(bytes))).toBe(true);
      const doc = await PDFDocument.load(bytes);
      expect(doc.getPageCount()).toBeGreaterThanOrEqual(2);
      expect([Math.round(doc.getPage(0).getWidth()), Math.round(doc.getPage(0).getHeight())]).toEqual([595, 842]);
      expect(doc.getTitle()).toContain('GV-EP-000004');
      const dir = process.env.REPORT_SAMPLES_DIR;
      if (dir) {
        mkdirSync(dir, { recursive: true });
        writeFileSync(join(dir, `evidence-pack-order-internal-${lang}.pdf`), bytes);
        writeFileSync(join(dir, `evidence-pack-shipment-shareable-${lang}.pdf`),
          await reportPdf(packDocument(fx.shipment.head, fx.shipment.shareable, t, 'https://app.test'), fx.shipment.head.issued_at));
      }
    }
  }, 90_000);
  it('a pack\'s files: each copy\'s PDF in English and Hindi, then its JSON; their keys as the server keeps them', () => {
    expect(packFiles(false)).toEqual([{ copy: 'shareable', lang: 'en', format: 'pdf' }, { copy: 'shareable', lang: 'hi', format: 'pdf' }, { copy: 'shareable', lang: 'en', format: 'json' }]);
    expect(packFiles(true)).toHaveLength(6);
    expect(packFileKey('internal', 'hi', 'pdf')).toBe('pdf_hi_internal');
    expect(migration).toContain("p_format not in ('pdf', 'json')");
    const p = { internal_ok: false, status: 'valid' as const, files: { pdf_en_shareable: { sha256: 'a'.repeat(64), bytes: 1, at: '' } } };
    expect(missingFiles(p).map((f) => packFileKey(f.copy, f.lang, f.format))).toEqual(['pdf_hi_shareable', 'json_en_shareable']);
    expect(missingFiles({ ...p, status: 'withdrawn' })).toEqual([]);
    expect(readerFiles({ internal_ok: true }).filter((f) => f.copy === 'internal')).toHaveLength(3);
  });
  it('the JSON: the reference, the copy, each PDF\'s SHA-256 and the data; the shareable one without a farmer\'s name', () => {
    const files = { pdf_en_shareable: { sha256: 'a'.repeat(64), bytes: 10 }, pdf_hi_shareable: { sha256: 'b'.repeat(64), bytes: 11 }, pdf_en_internal: { sha256: 'c'.repeat(64), bytes: 12 } };
    const j = JSON.parse(packJson(fx.shipment.head, 'shareable', fx.shipment.shareable, files, 'https://app.test/d/GV-EP-000006'));
    expect(j).toMatchObject({ evidence_pack: 'GrainVeda', ref: 'GV-EP-000006', version: 2, copy: 'shareable', verify: 'https://app.test/d/GV-EP-000006' });
    expect(j.pdf_files).toEqual([{ file: 'GV-EP-000006-shareable-en.pdf', lang: 'en', sha256: 'a'.repeat(64), bytes: 10 },
      { file: 'GV-EP-000006-shareable-hi.pdf', lang: 'hi', sha256: 'b'.repeat(64), bytes: 11 }]);
    expect(JSON.stringify(j)).not.toContain(farmer);
    expect(j.data.header.shipment).toBe('PRSDM-KNM-KH26-BSTA-SH-0001');
  });
  it('the buyer\'s page draws the files GrainVeda stored: the same head, so the same PDF and the same JSON', () => {
    const h = fx.order.head;
    const files = { pdf_en_shareable: { sha256: 'a'.repeat(64), bytes: 10 } };
    const e = { ref: h.ref, version: h.version, issued_at: h.issued_at, subject_kind: h.subject_kind, subject: h.subject_code, status: h.status, issued_to: h.issued_to,
      data_hash: h.data_hash, auto: h.auto, issued_by: h.issued_by, data: fx.order.shareable, files };
    const bh = buyerPackHead(e);
    expect(packDocument(bh, e.data, T, 'https://x')).toEqual(packDocument(h, fx.order.shareable, T, 'https://x'));
    expect(packJson(bh, 'shareable', e.data, bh.files ?? {}, 'v')).toBe(packJson(h, 'shareable', fx.order.shareable, files, 'v'));
  });
});

describe('E1 · the card, the verify page, the admin\'s count; item 69 (1)', () => {
  it('the current pack with its files (stored or drawn), earlier versions folded, a new version after a confirmation', async () => {
    const api = await import('../src/lib/api');
    const head = { ...fx.shipment.head, internal_ok: true, may_store: true, files: { pdf_en_shareable: { sha256: 'a'.repeat(64), bytes: 9, at: '2026-10-27T00:00:00Z' } } };
    const old = { ...fx.shipment.head, id: 'old', ref: 'GV-EP-000001', version: 1, status: 'superseded', superseded_by: 'GV-EP-000006', files: {} };
    const spy = vi.spyOn(api, 'rpc').mockImplementation(async (fn: string) => {
      if (fn === 'evidence_packs') return { packs: [head, old], may_issue: true } as never;
      if (fn === 'issue_evidence_pack') return { ...head, version: 3 } as never;
      return null as never;
    });
    const { EvidencePacks } = await import('../src/pages/records/EvidencePacks');
    render(<MemoryRouter><EvidencePacks kind="shipment" id="s1" /></MemoryRouter>);
    const [row] = await screen.findAllByTestId('pack-row');
    expect(row.getAttribute('data-ref')).toBe('GV-EP-000006');
    expect(within(row).getByTestId('pack-file-pdf_en_shareable').getAttribute('data-stored')).toBe('yes');
    expect(within(row).getByTestId('pack-file-pdf_hi_internal').getAttribute('data-stored')).toBe('no');
    expect(within(row).getByTestId('pack-store').textContent).toBe('Store its files (5)');
    expect(within(row).getByTestId('pack-verify').getAttribute('href')).toBe('/d/GV-EP-000006');
    expect(screen.getByTestId('pack-earlier').textContent).toContain('Earlier versions (1)');
    fireEvent.click(screen.getByTestId('pack-issue'));
    expect(screen.getByTestId('pack-issue-confirm').textContent).toContain('Makes version 3');
    fireEvent.click(screen.getByTestId('pack-issue-go'));
    await waitFor(() => expect(spy).toHaveBeenCalledWith('issue_evidence_pack', { p_kind: 'shipment', p_id: 's1' }));
  });
  it('a reader of the shareable copy only: no internal files, no store button, no new version', async () => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockResolvedValue({ packs: [{ ...fx.order.head, internal_ok: false, may_store: false, files: {} }], may_issue: false } as never);
    const { EvidencePacks } = await import('../src/pages/records/EvidencePacks');
    render(<MemoryRouter><EvidencePacks kind="scope" id="sc1" /></MemoryRouter>);
    const row = await screen.findByTestId('pack-row');
    expect(row.textContent).toContain('Client order ORD-PRSDM-0001');
    expect(within(row).queryByTestId('pack-file-pdf_en_internal')).toBeNull();
    expect(within(row).getByTestId('pack-file-json_en_shareable').textContent).toBe('JSON');
    expect(screen.queryByTestId('pack-store')).toBeNull();
    expect(screen.queryByTestId('pack-issue')).toBeNull();
  });
  it('the verify page of a pack: what it is of, in how many scopes; its JSON without a language', async () => {
    const { DocumentVerify } = await import('../src/pages/public/DocumentVerify');
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockResolvedValue({ ref: 'GV-EP-000004', kind: 'evidence_pack', final: true, version: 2, status: 'valid', issued_at: '2026-10-27T05:00:00Z',
      issued_to: 'Test Client UP', period_from: null, period_to: null, crop: 'Kalanamak rice', season: 'KH26', geography: 'Basti mill', state: 'Uttar Pradesh',
      superseded_by: null, superseded_at: null, withdrawn_at: null, subject_kind: 'order', subject: 'ORD-TCUP-0001', scopes: 2,
      files: [{ copy: 'shareable', format: 'json', lang: 'en', sha256: 'b'.repeat(64), bytes: 500 }] } as never);
    render(<MemoryRouter initialEntries={['/d/GV-EP-000004']}><Routes><Route path="/d/:ref" element={<DocumentVerify />} /></Routes></MemoryRouter>);
    expect((await screen.findByTestId('dv-status')).textContent).toContain('Valid');
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('Verified traceability statement: evidence pack');
    expect(screen.getByTestId('dv-kind').textContent).toBe('Evidence pack, version 2');
    expect(screen.getByTestId('dv-subject').textContent).toBe('Client order ORD-TCUP-0001');
    expect(screen.getByTestId('dv-covers').textContent).toBe('Kalanamak rice · KH26 · 2 scopes');
    expect(screen.getByTestId('dv-files').textContent).toContain('JSON (the data) · shareable copy');
    expect(screen.queryByText('Period')).toBeNull();
  });
  it('item 69 (1): a sale\'s worked-out market in words, English and Hindi', () => {
    expect(showComputed('market', 'domestic', T)).toBe('Domestic');
    expect(showComputed('market', 'export', H)).toBe(hi['exp.mkt.export']);
  });
});
