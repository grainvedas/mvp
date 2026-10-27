// Migration 71 (Phase 3, release 4 of Veda's combined brief of 19 Oct 2026, Part E1): the evidence pack. The server makes
// a pack when a lot is sealed (the shipment's, where the lot went out in one; and the client order's, where the shipment is
// a part of one) and on demand, keeps both copies' data, versions it and writes a ledger block (app.ep_issue). This file
// calls its functions and holds its shapes; the PDF (A4, English and Hindi) and the JSON are written in the browser from
// the data the server kept, stored once, and their SHA-256 kept by the server and shown on "Verify this document".
import { rpc } from './api';
import type { Copy } from './exports';
import type { FileInfo, Lang, ReportHead } from './reports';
import { sha256Hex } from './reports';
import { supabase } from './supabase';

export type PackKind = 'lot' | 'shipment' | 'order';
export type PackFormat = 'pdf' | 'json';

export interface PackHead extends ReportHead { kind: 'evidence_pack'; subject_kind: PackKind; subject_id: string; subject_code: string;
  scope_ids: string[]; auto: boolean; internal_ok?: boolean }
export interface Packs { packs: PackHead[]; may_issue: boolean }

export interface LotPack {
  kind?: 'lot' | 'shipment'; internal: boolean;
  header: { client: string; client_code: string | null; crop: string; gi_tag: string | null; season: string; geography: string; state: string | null;
    scope: string; scope_id: string | null; top: string; top_stage: string; lot: string; qr_code: string | null; sealed_at: string | null;
    shipment: string | null; dispatch_date: string | null; invoice_no: string | null; sale: string | null; buyer: string | null; buyer_country: string | null;
    market: string | null; market_name: string | null; destination_country: string | null; order_no: string | null; client_order: string | null;
    data_note: string | null };
  origin: { villages: { village: string | null; district: string | null; share_pct: number; farmers: number }[]; districts: { district: string | null; share_pct: number }[];
    farmers: number; gi_pct: number | null; farm_verified_pct: number | null; gi_status: 'gi' | 'non_gi' | 'unknown' | string; farm_verified: boolean | null;
    shares_note: string; farmer_list?: { code: string; name: string; village: string | null; district: string | null; share_pct: number }[] };
  mass_balance: { stages: { stage: string; pos: number; records: number; in_kg: number | null; out_kg: number | null; by_products_kg: number | null;
      other_kg: number | null; transit_kg: number | null; floor_loss_kg: number | null; closed_kg: number | null; written_off_kg: number | null;
      head_rice_kg?: number | null; broken_kg?: number | null; husk_kg?: number | null; bran_kg?: number | null; outturn_pct?: number; ceiling_pct?: number;
      over_ceiling?: boolean; wastage_kg?: number | null; wastage_pct?: number; sample_kg?: number | null }[];
    procured_kg: number; sold_kg: number; shipped_kg: number; sold_within_procured: boolean };
  quality: { code: string; on: string | null; lab: string | null; accreditation_no: string | null; report_no: string | null; report_date: string | null;
    sample: string | null; domestic: string | null; export: string | null; accepted: boolean; accepted_market: string | null;
    markets: { code: string; name: string; verdict: string }[]; files: { label: string; sha256: string; at: string }[] }[];
  documents: { export: { doc: string; status: string | null; note: string | null; done: boolean; sha256: string | null }[];
    shipment: { code: string; market: string | null; invoice_no: string | null; lr_no: string | null; eway_bill_no: string | null; container_no: string | null;
      seal_no: string | null; shipping_bill_no: string | null; bl_no: string | null; delivered: { on: string; received_kg: number } | null } | null;
    files: { label: string; record: string; sha256: string; at: string }[] };
  chain: { stage: string; pos: number; records: number; codes: string[]; recorded_by: string[] | null; verified_by: string[] | null; first_on: string | null;
    last_on: string | null; same_person: number; client_staff: number; verified: boolean;
    returns: { code: string; reason: string; status: string }[]; flags: { code: string; kind: string; text: string; status: string }[] }[];
  packs: { batches: { batch_code: string; packs: number; kg: number; sizes: string | null; packed_on: string | null; best_before: string | null; ranges: string[] }[];
    count: number; old_data: boolean; scanned: string[] | null };
  verification: { seal: { qr_code: string; sealed_at: string; ledger_hash: string } | null; blocks: { code: string; stage: string; event: string; seq: number; hash: string }[];
    procurement_blocks: number };
  price?: { price_per_kg: number | null; currency: string | null; incoterms: string | null; total_value: number | null } | null;
}
export interface OrderPack {
  kind: 'order'; internal: boolean;
  header: { client: string; client_code: string | null; crop: string; gi_tag: string | null; client_order: string; order_no: string | null; buyer: string | null;
    buyer_country: string | null; market: string | null; market_name: string | null; destination_country: string | null; invoice_no: string | null };
  scopes: { scope_id: string | null; scope: string; state: string | null; season: string; geography: string; lots: LotPack[] }[];
}
export type PackData = LotPack | OrderPack;
export const isOrderPack = (d: PackData): d is OrderPack => d.kind === 'order';

export const evidencePacks = (kind: PackKind | 'scope', id: string) => rpc<Packs>('evidence_packs', { p_kind: kind, p_id: id });
export const issueEvidencePack = (kind: PackKind, id: string) => rpc<PackHead>('issue_evidence_pack', { p_kind: kind, p_id: id });
export const packContent = (report: string, copy: Copy) => rpc<{ report: PackHead; copy: Copy; data: PackData }>('report_content', { p_report: report, p_copy: copy });

/** Pure: a pack's files, in the order they are made (the PDFs first: the JSON keeps their SHA-256). */
export function packFiles(internal: boolean): { copy: Copy; lang: Lang; format: PackFormat }[] {
  const out: { copy: Copy; lang: Lang; format: PackFormat }[] = [];
  for (const copy of (internal ? ['shareable', 'internal'] : ['shareable']) as Copy[]) {
    out.push({ copy, lang: 'en', format: 'pdf' }, { copy, lang: 'hi', format: 'pdf' }, { copy, lang: 'en', format: 'json' });
  }
  return out;
}
export const packFileKey = (copy: Copy, lang: Lang, format: PackFormat) => `${format}_${lang}_${copy}`;

/** Pure: the pack's JSON: what the server kept for this copy, the reference, and each PDF's SHA-256 (so a PDF in hand
 *  can be checked against it, and the JSON against the verify page). */
export function packJson(head: PackHead, copy: Copy, data: PackData, files: Record<string, Pick<FileInfo, 'sha256' | 'bytes'>>, verifyUrl: string): string {
  const pdfs = Object.entries(files).filter(([k]) => k.startsWith('pdf_') && k.endsWith(`_${copy}`))
    .map(([k, v]) => ({ file: `${head.ref}-${copy}-${k.split('_')[1]}.pdf`, lang: k.split('_')[1], sha256: v.sha256, bytes: v.bytes }))
    .sort((a, b) => a.lang.localeCompare(b.lang));
  return `${JSON.stringify({ evidence_pack: 'GrainVeda', ref: head.ref, version: head.version, issued_at: head.issued_at, issued_to: head.issued_to,
    subject_kind: head.subject_kind, subject: head.subject_code, copy, verify: verifyUrl, pdf_files: pdfs, data }, null, 2)}\n`;
}

const fileName = (report: string, copy: Copy, lang: Lang, format: PackFormat) => `${report}/${copy}.${lang}.${format}`;
const TYPE: Record<PackFormat, string> = { pdf: 'application/pdf', json: 'application/json' };

async function storeFile(report: string, copy: Copy, lang: Lang, format: PackFormat, bytes: Uint8Array) {
  const up = await supabase.storage.from('reports').upload(fileName(report, copy, lang, format), new Blob([bytes as unknown as ArrayBuffer], { type: TYPE[format] }),
    { contentType: TYPE[format], upsert: false });
  let kept = bytes;
  if (up.error) {
    // a file left in the store by an interrupted attempt: what is in the store is the file, so its own SHA-256 is kept
    if (!/exist|duplicate/i.test(up.error.message)) throw up.error;
    const got = await supabase.storage.from('reports').download(fileName(report, copy, lang, format));
    if (got.error || !got.data) throw got.error ?? up.error;
    kept = new Uint8Array(await got.data.arrayBuffer());
  }
  const sha256 = await sha256Hex(kept);
  await rpc('register_report_file', { p_report: report, p_copy: copy, p_format: format, p_lang: lang, p_sha256: sha256, p_bytes: kept.byteLength });
  return { sha256, bytes: kept.byteLength };
}

/** Makes and stores the pack's files the reader may make and that are not stored yet: each copy's PDF in English and
 *  Hindi, then its JSON with their SHA-256. A file stored already is not made again (an interrupted run is finished by
 *  running it again). */
export async function makePackFiles(head: PackHead, internal: boolean, onStep: (n: number, of: number) => void = () => {},
  origin = window.location.origin) {
  const [{ packDocument }, { reportPdf }, { translate }] = await Promise.all([import('./epModel'), import('./reportPdf'), import('./i18n')]);
  const have: Record<string, Pick<FileInfo, 'sha256' | 'bytes'>> = { ...(head.files ?? {}) };
  const want = packFiles(internal).filter((f) => !(packFileKey(f.copy, f.lang, f.format) in have));
  let done = 0;
  onStep(done, want.length);
  for (const copy of ['shareable', 'internal'] as Copy[]) {
    const mine = want.filter((f) => f.copy === copy);
    if (mine.length === 0) continue;
    const content = await packContent(head.id, copy);
    for (const f of mine) {
      let bytes: Uint8Array;
      if (f.format === 'pdf') {
        const rd = packDocument(content.report, content.data, (k, v, fb) => translate(f.lang, k, v, fb), origin);
        bytes = await reportPdf(rd, content.report.issued_at);
      } else {
        bytes = new TextEncoder().encode(packJson(content.report, copy, content.data, have, `${origin}/d/${head.ref}`));
      }
      have[packFileKey(copy, f.lang, f.format)] = await storeFile(head.id, copy, f.lang, f.format, bytes);
      done += 1; onStep(done, want.length);
    }
  }
}

/** A stored file for the reader: the download is logged first (the Audit log), then the file comes from the store. */
export async function openPackFile(head: PackHead, copy: Copy, lang: Lang, format: PackFormat) {
  const path = await rpc<string>('note_report_download', { p_report: head.id, p_copy: copy, p_format: format, p_lang: lang });
  const { data, error } = await supabase.storage.from('reports').download(path);
  if (error || !data) throw error ?? new Error('no file');
  saveBlob(data, `grainveda-evidence-pack-${head.ref}-${copy}${format === 'pdf' ? `-${lang}` : ''}.${format}`);
}

/** The reader's own copy when the file is not stored yet: drawn from the data the server kept (the same bytes as the
 *  stored file would be). The reading is in the Audit log (report_content). */
export async function drawPackFile(head: PackHead, copy: Copy, lang: Lang, format: PackFormat, origin = window.location.origin) {
  const content = await packContent(head.id, copy);
  let blob: Blob;
  if (format === 'pdf') {
    const [{ packDocument }, { reportPdf }, { translate }] = await Promise.all([import('./epModel'), import('./reportPdf'), import('./i18n')]);
    const rd = packDocument(content.report, content.data, (k, v, fb) => translate(lang, k, v, fb), origin);
    blob = new Blob([(await reportPdf(rd, content.report.issued_at)) as unknown as ArrayBuffer], { type: TYPE.pdf });
  } else {
    blob = new Blob([packJson(content.report, copy, content.data, head.files ?? {}, `${origin}/d/${head.ref}`)], { type: TYPE.json });
  }
  saveBlob(blob, `grainveda-evidence-pack-${head.ref}-${copy}${format === 'pdf' ? `-${lang}` : ''}.${format}`);
}

export function saveBlob(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = name;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}
