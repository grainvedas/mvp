// Migration 63 (Part D3): the season report as a PDF, A4, in English or Hindi, made in the browser from the report's model
// (lib/reportModel.ts). Hindi is shaped by the font engine (conjuncts, the i-matra, reph): text is cut into runs by script
// and each run drawn with its own font (Noto Sans Devanagari and its Latin companion, SIL Open Font License, files in
// src/assets/fonts). Loaded only when a report is made (a chunk of its own), never with the app's first page.
import 'regenerator-runtime/runtime.js';
import { PDFDocument, rgb, type PDFFont, type PDFPage, type RGB } from 'pdf-lib';
import fontkit from '@pdf-lib/fontkit';
import QRCode from 'qrcode';
import latin400 from '../assets/fonts/noto-sans-devanagari-latin-400-normal.woff?url';
import latin700 from '../assets/fonts/noto-sans-devanagari-latin-700-normal.woff?url';
import deva400 from '../assets/fonts/noto-sans-devanagari-devanagari-400-normal.woff?url';
import deva700 from '../assets/fonts/noto-sans-devanagari-devanagari-700-normal.woff?url';
import type { Block, ReportDoc, Tone } from './reportModel';

const W = 595.28, H = 841.89, M = 42, CW = W - 2 * M, TOP = H - 64, BOTTOM = 78;
const INK = rgb(0.11, 0.13, 0.12), GREY = rgb(0.36, 0.38, 0.37), LINE = rgb(0.82, 0.83, 0.82), FILL = rgb(0.94, 0.95, 0.93);
const RED = rgb(0.706, 0.137, 0.094), GREEN = rgb(0.024, 0.463, 0.278), FOREST = rgb(0.118, 0.302, 0.208);
const tone = (t: Tone): RGB => (t === 'danger' ? RED : t === 'ok' ? GREEN : t === 'muted' ? GREY : INK);

/** Pure: is this a character of the Devanagari font (the script, its signs, the rupee sign)? */
export function isDeva(cp: number) {
  return (cp >= 0x0900 && cp <= 0x097f) || (cp >= 0xa8e0 && cp <= 0xa8ff) || (cp >= 0x1cd0 && cp <= 0x1cff) || cp === 0x20b9;
}
const JOINERS = new Set([0x200c, 0x200d, 0x25cc]);
/** Pure: text cut into runs of one font (a space or a joiner stays with the run it is in). */
export function runs(text: string): { deva: boolean; s: string }[] {
  const out: { deva: boolean; s: string }[] = [];
  for (const ch of text) {
    const cp = ch.codePointAt(0)!;
    const neutral = ch === ' ' || JOINERS.has(cp);
    const deva = neutral && out.length ? out[out.length - 1].deva : isDeva(cp);
    if (out.length && out[out.length - 1].deva === deva) out[out.length - 1].s += ch; else out.push({ deva, s: ch });
  }
  return out;
}
/** Pure: the few signs the fonts do not have, in words or plain signs. */
export function plainSigns(s: string) {
  return s.replace(/≤/g, '<=').replace(/≥/g, '>=').replace(/→/g, '->').replace(/✓/g, '').replace(/✗/g, 'x').replace(/[   ]/g, ' ');
}

interface Fonts { l: PDFFont; lb: PDFFont; d: PDFFont; db: PDFFont; lset: Set<number>; dset: Set<number> }

class Writer {
  page!: PDFPage; y = TOP; pages: PDFPage[] = [];
  constructor(public doc: PDFDocument, public f: Fonts, public rd: ReportDoc) { this.newPage(); }
  newPage() {
    this.page = this.doc.addPage([W, H]); this.pages.push(this.page); this.y = TOP;
    this.text(`GrainVeda · ${this.rd.title}`, M, H - 30, 7.5, false, GREY);
    const r = this.width(this.rd.ref, 7.5, true);
    this.text(this.rd.ref, W - M - r, H - 30, 7.5, true, GREY);
    this.page.drawLine({ start: { x: M, y: H - 36 }, end: { x: W - M, y: H - 36 }, thickness: 0.5, color: LINE });
    if (this.rd.banner) {
      this.page.drawRectangle({ x: M, y: H - 56, width: CW, height: 16, color: rgb(0.996, 0.894, 0.886) });
      this.text(this.rd.banner, M + 6, H - 51.5, 9, true, RED);
    }
  }
  ensure(h: number) { if (this.y - h < BOTTOM) this.newPage(); }
  clean(s: string, deva: boolean) {
    const set = deva ? this.f.dset : this.f.lset;
    let out = '';
    for (const ch of s) { const cp = ch.codePointAt(0)!; out += set.has(cp) || JOINERS.has(cp) ? ch : '?'; }
    return out;
  }
  font(deva: boolean, bold: boolean) { return deva ? (bold ? this.f.db : this.f.d) : (bold ? this.f.lb : this.f.l); }
  width(s: string, size: number, bold: boolean) {
    return runs(plainSigns(s)).reduce((w, r) => w + this.font(r.deva, bold).widthOfTextAtSize(this.clean(r.s, r.deva), size), 0);
  }
  text(s: string, x: number, y: number, size: number, bold: boolean, color: RGB = INK) {
    let cx = x;
    for (const r of runs(plainSigns(s))) {
      const font = this.font(r.deva, bold); const str = this.clean(r.s, r.deva);
      this.page.drawText(str, { x: cx, y, size, font, color });
      cx += font.widthOfTextAtSize(str, size);
    }
  }
  /** Pure-ish: words into lines no wider than w (a word longer than the line is cut by characters). */
  wrap(s: string, size: number, bold: boolean, w: number): string[] {
    const lines: string[] = [];
    for (const para of String(s).split('\n')) {
      let line = '';
      for (const word of para.split(/ +/)) {
        const tryLine = line ? `${line} ${word}` : word;
        if (this.width(tryLine, size, bold) <= w) { line = tryLine; continue; }
        if (line) lines.push(line);
        if (this.width(word, size, bold) <= w) { line = word; continue; }
        let part = '';
        for (const ch of word) { if (this.width(part + ch, size, bold) > w && part) { lines.push(part); part = ch; } else part += ch; }
        line = part;
      }
      lines.push(line);
    }
    return lines;
  }
  para(s: string, size = 9, bold = false, color: RGB = INK, gap = 4) {
    const lh = size * 1.45;
    for (const l of this.wrap(s, size, bold, CW)) { this.ensure(lh); this.text(l, M, this.y - size, size, bold, color); this.y -= lh; }
    this.y -= gap;
  }
  heading(s: string, width = CW) {
    this.ensure(90); this.y -= 8;   // a heading never ends a page: room for it and the first lines under it
    this.text(s, M, this.y - 13, 13, true, FOREST); this.y -= 19;
    this.page.drawLine({ start: { x: M, y: this.y }, end: { x: M + width, y: this.y }, thickness: 0.8, color: FOREST }); this.y -= 8;
  }
  kv(rows: [string, string][], width = CW) {
    const lw = Math.min(170, width * 0.36), vw = width - lw - 8, size = 8.5, lh = size * 1.45;
    for (const [k, v] of rows) {
      const kl = this.wrap(k, size, true, lw), vl = this.wrap(v, size, false, vw);
      const h = Math.max(kl.length, vl.length) * lh + 3;
      this.ensure(h);
      kl.forEach((l, i) => this.text(l, M, this.y - size - i * lh, size, true, GREY));
      vl.forEach((l, i) => this.text(l, M + lw + 8, this.y - size - i * lh, size, false, INK));
      this.y -= h;
    }
    this.y -= 4;
  }
  table(head: string[], rows: string[][], tones?: (Tone | undefined)[]) {
    const size = head.length > 7 ? 6.6 : 7.4, lh = size * 1.4, pad = 3;
    // column widths from what they hold, within the page
    const nat = head.map((h, i) => Math.max(this.width(h, size, true), ...rows.map((r) => this.width(r[i] ?? '', size, false))) + 2 * pad);
    const minW = head.map((h) => Math.min(Math.max(this.width(h.split(' ')[0], size, true) + 2 * pad, 34), 70));
    let ws = nat.map((n, i) => Math.max(minW[i], Math.min(n, 220)));
    const total = ws.reduce((a, b) => a + b, 0);
    if (total > CW) { const over = total - CW; const flex = ws.map((w, i) => Math.max(w - minW[i], 0)); const sf = flex.reduce((a, b) => a + b, 0) || 1;
      ws = ws.map((w, i) => w - (over * flex[i]) / sf); }
    else ws = ws.map((w) => (w * CW) / total);
    const drawRow = (cells: string[], bold: boolean, fill: RGB | null, color: RGB) => {
      const wrapped = cells.map((c, i) => this.wrap(c ?? '', size, bold, ws[i] - 2 * pad));
      const h = Math.max(...wrapped.map((w) => w.length)) * lh + 2 * pad;
      return { h, draw: () => {
        let x = M;
        if (fill) this.page.drawRectangle({ x: M, y: this.y - h, width: ws.reduce((a, b) => a + b, 0), height: h, color: fill });
        wrapped.forEach((ls, i) => { ls.forEach((l, j) => this.text(l, x + pad, this.y - pad - size - j * lh + 1.5, size, bold, color)); x += ws[i]; });
        this.page.drawLine({ start: { x: M, y: this.y - h }, end: { x: M + ws.reduce((a, b) => a + b, 0), y: this.y - h }, thickness: 0.4, color: LINE });
        this.y -= h;
      } };
    };
    const header = () => { const r = drawRow(head, true, FILL, INK); this.ensure(r.h); r.draw(); };
    header();
    rows.forEach((row, k) => {
      const r = drawRow(row, false, null, tone(tones?.[k]));
      if (this.y - r.h < BOTTOM) { this.newPage(); header(); }
      r.draw();
    });
    this.y -= 8;
  }
  block(b: Block) {
    if (b.kind === 'kv') this.kv(b.rows);
    else if (b.kind === 'table') { if (b.rows.length) this.table(b.head, b.rows, b.tones); }
    else if (b.kind === 'sub') { this.ensure(24); this.y -= 2; this.para(b.text, 9.5, true, INK, 2); }
    else this.para(b.text, 8.5, false, tone(b.tone));
  }
  footers() {
    const n = this.pages.length;
    this.pages.forEach((p, i) => {
      this.page = p;
      p.drawLine({ start: { x: M, y: BOTTOM - 10 }, end: { x: W - M, y: BOTTOM - 10 }, thickness: 0.5, color: LINE });
      let y = BOTTOM - 20;
      for (const l of this.wrap(this.rd.footer, 7, false, CW - 60)) { this.text(l, M, y, 7, false, GREY); y -= 9.5; }
      for (const l of this.wrap(this.rd.copyNote, 7, true, CW - 60)) { this.text(l, M, y, 7, true, GREY); y -= 9.5; }
      const pg = `${i + 1} / ${n}`;
      this.text(pg, W - M - this.width(pg, 7.5, true), BOTTOM - 20, 7.5, true, GREY);
    });
  }
}

async function bytesOf(url: string) { return new Uint8Array(await (await fetch(url)).arrayBuffer()); }

/** The report as a PDF file (bytes): cover with the verify QR, every section, the footer on every page. */
export async function reportPdf(rd: ReportDoc, issuedAt: string): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  doc.registerFontkit(fontkit);
  const [a, b, c, d] = await Promise.all([latin400, latin700, deva400, deva700].map(bytesOf));
  const l = await doc.embedFont(a, { subset: true }), lb = await doc.embedFont(b, { subset: true });
  const dv = await doc.embedFont(c, { subset: true }), dvb = await doc.embedFont(d, { subset: true });
  const fonts: Fonts = { l, lb, d: dv, db: dvb, lset: new Set(l.getCharacterSet()), dset: new Set(dv.getCharacterSet()) };
  const when = new Date(issuedAt);
  doc.setTitle(`${rd.title} · ${rd.ref}`); doc.setAuthor('GrainVeda'); doc.setCreator('GrainVeda'); doc.setProducer('GrainVeda');
  doc.setCreationDate(when); doc.setModificationDate(when);

  const w = new Writer(doc, fonts, rd);
  // the cover: title, the lines, the verify QR
  const qr = await doc.embedPng(await QRCode.toDataURL(rd.verifyUrl, { margin: 1, width: 300, errorCorrectionLevel: 'M' }));
  w.y -= 6;
  for (const line of w.wrap(rd.title, 18, true, CW - 120)) { w.text(line, M, w.y - 18, 18, true, FOREST); w.y -= 24; }
  for (const line of rd.lines) w.para(line, 10, false, INK, 1);
  const qy = w.y - 4;
  w.page.drawImage(qr, { x: W - M - 96, y: qy - 96, width: 96, height: 96 });
  w.text(rd.verifyLabel, W - M - 96, qy - 106, 7, true, GREY);
  for (const [i, line] of w.wrap(rd.verifyUrl, 6.5, false, 96).entries()) w.text(line, W - M - 96, qy - 116 - i * 8, 6.5, false, GREY);
  w.y -= 6;
  rd.sections.forEach((s, i) => {
    if (i === 0) {   // the cover's facts beside the QR
      w.heading(s.title, CW - 110);
      for (const blk of s.blocks) if (blk.kind === 'kv') { const save = w.y; w.kv(blk.rows, CW - 110); if (w.y > save - 1) w.y = save; } else w.block(blk);
      w.y = Math.min(w.y, qy - 140);
      return;
    }
    w.heading(s.title);
    s.blocks.forEach((blk) => w.block(blk));
  });
  w.footers();
  return doc.save({ useObjectStreams: true });
}
