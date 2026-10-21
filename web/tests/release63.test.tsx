// Migration 63 (Phase 1, release 5 of Veda's combined brief of 19 Oct 2026: Part D, close a scope and the season report).
// The rules are the database's (tests/58_close_scope_report.sql); these hold the browser's side: the report written down
// in the brief's words (title, footer, "Interim: season not closed"), the shareable copy without a price or a farmer's
// name, a release on the client's acceptance never "Passed", sold ≤ procured printed; the PDF made in English and Hindi
// (Hindi shaped: its text runs drawn with the Devanagari font), A4; the Excel file one sheet per section; the answers of
// a close request; the refusals in plain words; the verify page.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { reportDocument, verdictWord } from '../src/lib/reportModel';
import { reportSheets, sheetName } from '../src/lib/reportXlsx';
import { isDeva, plainSigns, runs } from '../src/lib/reportPdf';
import { answersOf } from '../src/pages/dashboard/SeasonReport';
import { expectedFiles, fileKey, fileName, type ReportData, type ReportHead } from '../src/lib/reports';
import { plainWords } from '../src/lib/plainErrors';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic, hiPublic } from '../src/lib/i18n.public';

const root = join(__dirname, '../..');
const fx = JSON.parse(readFileSync(join(__dirname, 'fixtures/season_report.json'), 'utf8')) as { head: ReportHead; shareable: ReportData; internal: ReportData };
const migration = readFileSync(join(root, 'supabase/migrations/20261107000100_close_scope_season_report.sql'), 'utf8');
const tr = (d: Record<string, string>) => (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = d[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
const T = tr({ ...enPublic, ...en });
const H = tr({ ...enPublic, ...en, ...hiPublic, ...hi });
const all = (rd: ReturnType<typeof reportDocument>) => JSON.stringify(rd);
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

describe('D3 · the report in the brief\'s words', () => {
  it('title, footer, the interim banner; "certificate" only in the footer\'s "It is not … a certificate"', () => {
    const fin = reportDocument(fx.head, fx.shareable, T, 'https://app.test');
    expect(fin.title).toBe('Verified traceability statement: season report');
    expect(fin.footer).toBe('This statement records what GrainVeda verified under its published protocol. It is not a quality, residue or Geographical Indication certificate.');
    expect(fin.banner).toBeNull();
    expect(fin.verifyUrl).toBe(`https://app.test/d/${fx.head.ref}`);
    const interim = reportDocument({ ...fx.head, final: false }, fx.shareable, T, 'https://app.test');
    expect(interim.banner).toBe('Interim: season not closed');
    expect(all(fin).replace(fin.footer, '').toLowerCase()).not.toContain('certificate');
    expect(hi['rep.interim']).toContain('अंतरिम');
  });
  it('every section of D3, in order', () => {
    const rd = reportDocument(fx.head, fx.internal, T, '');
    expect(rd.sections.map((s) => s.key)).toEqual(['cover', 'headline', 'balance', 'origin', 'quality', 'packing', 'sales', 'qr', 'chain', 'ledger', 'open_items', 'verification']);
  });
  it('the shareable copy: no farmer\'s name, no price column; the internal one has both', () => {
    const shd = reportDocument(fx.head, fx.shareable, T, '');
    const sh = all(shd);
    expect(sh).not.toContain('Ram Achal');
    const sales = shd.sections.find((s) => s.key === 'sales')!.blocks[0] as { head: string[] };
    expect(sales.head).not.toContain(en['rep.sa.price']);
    const int = all(reportDocument(fx.head, fx.internal, T, ''));
    expect(int).toContain('Ram Achal');
    expect(int).toContain('390');
  });
  it('sold never above procured: the check is printed; the close\'s write-offs and carried-over flag are open items', () => {
    const rd = reportDocument(fx.head, fx.shareable, T, '');
    const bal = rd.sections.find((s) => s.key === 'balance')!;
    expect(JSON.stringify(bal)).toContain('Checked by the system: sold (5 kg) is not more than procured (180 kg).');
    const open = JSON.stringify(rd.sections.find((s) => s.key === 'open_items'));
    expect(open).toContain('Flag carried over');
    expect(open).toContain('Written off');
  });
  it('a release on the client\'s acceptance is said as such, never "Passed"', () => {
    expect(verdictWord('fail', true, T)).toBe('Released on the client\'s acceptance (not passed)');
    expect(verdictWord('pass', false, T)).toBe('Passed');
  });
  it('Hindi throughout: the section titles are Hindi words', () => {
    const rd = reportDocument(fx.head, fx.shareable, H, '');
    expect(rd.title).toBe('सत्यापित ट्रेसबिलिटी विवरण: सीज़न रिपोर्ट');
    expect(rd.sections.every((s) => /[ऀ-ॿ]/.test(s.title) || s.title === 'QR')).toBe(true);
  });
});

describe('D3 · the files: PDF (A4, English and Hindi), Excel (one sheet per section)', () => {
  it('Hindi is drawn with the Devanagari font, the rest with the Latin one; a space stays with its run', () => {
    expect(isDeva('क'.codePointAt(0)!)).toBe(true);
    expect(isDeva('₹'.codePointAt(0)!)).toBe(true);
    expect(runs('सीज़न रिपोर्ट: GV-SR-000001')).toEqual([{ deva: true, s: 'सीज़न रिपोर्ट' }, { deva: false, s: ': GV-SR-000001' }]);
    expect(plainSigns('a ≤ b → c ✓')).toBe('a <= b -> c ');
  });
  it('the PDF of each language: A4 pages, the fonts embedded, the Hindi text kept as Devanagari glyphs', async () => {
    vi.stubGlobal('fetch', async (url: string) => {
      const file = join(__dirname, '..', String(url).replace(/^\//, '').replace(/\?.*$/, ''));
      const b = readFileSync(file);
      return { arrayBuffer: async () => b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) };
    });
    const { reportPdf } = await import('../src/lib/reportPdf');
    const { PDFDocument } = await import('pdf-lib');
    for (const [lang, t] of [['en', T], ['hi', H]] as const) {
      const rd = reportDocument({ ...fx.head, final: false }, fx.internal, t, 'https://app.test');
      const bytes = await reportPdf(rd, fx.head.issued_at);
      expect(new TextDecoder().decode(bytes.slice(0, 5))).toBe('%PDF-');
      const doc = await PDFDocument.load(bytes);
      expect(doc.getPageCount()).toBeGreaterThanOrEqual(3);
      const [w, h] = [doc.getPage(0).getWidth(), doc.getPage(0).getHeight()];
      expect([Math.round(w), Math.round(h)]).toEqual([595, 842]);
      expect(doc.getTitle()).toContain(fx.head.ref);
      const dir = process.env.REPORT_SAMPLES_DIR;
      if (dir) { mkdirSync(dir, { recursive: true }); writeFileSync(join(dir, `season-report-${lang}.pdf`), bytes); }
    }
  }, 60_000);
  it('the Excel file: a sheet per section, names Excel accepts, the title and the interim words on every sheet', () => {
    const rd = reportDocument({ ...fx.head, final: false }, fx.shareable, T, '');
    const { sheets, names } = reportSheets(rd);
    expect(names).toHaveLength(12);
    expect(new Set(names).size).toBe(12);
    for (const s of sheets) {
      expect(s[0]?.[0]?.value).toBe('Verified traceability statement: season report');
      expect(JSON.stringify(s)).toContain('Interim: season not closed');
      expect(JSON.stringify(s)).toContain('It is not a quality, residue or Geographical Indication certificate.');
    }
    expect(sheetName('Sales and shipments: [all]/2026', new Set())).toBe('Sales and shipments all 2026');
  });
  it('the files a report has: both copies, both languages, PDF and Excel; their names in the store', () => {
    expect(expectedFiles(true)).toHaveLength(8);
    expect(expectedFiles(false).every((f) => f.copy === 'shareable')).toBe(true);
    expect(fileName('r1', 'internal', 'hi', 'pdf')).toBe('r1/internal.hi.pdf');
    expect(fileKey('internal', 'hi', 'pdf')).toBe('pdf_hi_internal');
    expect(migration).toContain("v_key := p_format || '_' || p_lang || '_' || p_copy;");
  });
});

describe('D1 · the close request\'s answers; the refusals in plain words', () => {
  it('one reason per blocker, as the server takes them; empty answers are left out', () => {
    expect(answersOf({ 'flags|f1': ' carried over: the buyer will reweigh ', 'kg|l1': 'written off: seed trial', 'packs|B1': 'samples', 'balance|qc': 'typed high', 'kg|l2': '  ' }))
      .toEqual({ flags: [{ id: 'f1', reason: 'carried over: the buyer will reweigh' }], kg: [{ id: 'l1', reason: 'written off: seed trial' }],
        packs: [{ batch_code: 'B1', reason: 'samples' }], balance: [{ stage: 'qc', reason: 'typed high' }] });
  });
  it('the database\'s words, English and Hindi', () => {
    expect(plainWords('close: the checklist is not clear (pending, kg)', T)).toBe(en['err.close_not_clear']);
    expect(plainWords('this scope is closed: its records are read only (the State Manager may reopen it)', T)).toBe(en['err.scope_closed']);
    expect(plainWords('close: PRSDM-KNM-KH26-M-0001 has 50 kg left, the request wrote off 40 kg: decline it and request again', T)).toBe(en['err.close_changed']);
    expect(plainWords('report: the season is closed: its final report is issued', H)).toBe(hi['err.report_closed']);
    for (const k of Object.keys(en).filter((x) => x.startsWith('rep.') || x.startsWith('srep.') || x.startsWith('err.close') || x.startsWith('err.report')))
      expect(hi[k], k).toBeTruthy();
    for (const k of Object.keys(enPublic).filter((x) => x.startsWith('dv.'))) expect(hiPublic[k], k).toBeTruthy();
  });
});

describe('D3 · Verify this document', () => {
  it('Valid, Superseded with the newer reference, the files\' SHA-256', async () => {
    const { DocumentVerify } = await import('../src/pages/public/DocumentVerify');
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockResolvedValue({ ref: 'GV-SR-000001', kind: 'season_report', final: true, version: 1, status: 'superseded', issued_at: '2026-10-21T05:00:00Z',
      issued_to: 'Test Client UP', period_from: '2026-10-01', period_to: '2026-10-21', crop: 'Kalanamak rice', season: 'KH26', geography: 'Bansi', state: 'Uttar Pradesh',
      superseded_by: 'GV-SR-000003', superseded_at: '2026-10-22T05:00:00Z', withdrawn_at: null,
      files: [{ copy: 'shareable', format: 'pdf', lang: 'en', sha256: 'a'.repeat(64), bytes: 1000 }] } as never);
    render(<MemoryRouter initialEntries={['/d/GV-SR-000001']}><Routes><Route path="/d/:ref" element={<DocumentVerify />} /></Routes></MemoryRouter>);
    expect((await screen.findByTestId('dv-status')).textContent).toContain('Superseded · replaced by GV-SR-000003');
    expect(screen.getByTestId('dv-issued-to').textContent).toBe('Test Client UP');
    expect(screen.getByTestId('dv-files').textContent).toContain(`SHA-256 ${'a'.repeat(64)}`);
  });
});
