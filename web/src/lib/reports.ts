// Migration 63 (Phase 1, release 5 of Veda's combined brief of 19 Oct 2026, Part D): closing a scope and the season
// report. Every rule is the database's (app.close_checklist, app.request_close, app.confirm_close, app.reopen_scope,
// app.issue_report …); this file only calls them and holds their shapes. The report's data is made and kept by the
// server when the report is issued; the browser writes it down (PDF and Excel, English and Hindi) and stores the files,
// whose SHA-256 the server keeps (app.register_report_file) and the verify page shows.
import { rpc } from './api';
import { supabase } from './supabase';
import type { Copy, StageBalance } from './exports';

export type Lang = 'en' | 'hi';
export type Format = 'pdf' | 'xlsx';
export type GroupKey = 'pending' | 'lab_hold' | 'flags' | 'kg' | 'pod' | 'packs' | 'balance';
export interface CheckItem { id?: string; code?: string; stage?: string; kind?: string; text?: string; kg?: number; since?: string; drawn_on?: string;
  lot?: string; batch_code?: string; released?: number; old_data?: number; held?: number; void?: number; difference_kg?: number; reason?: string | null }
export interface CheckGroup { key: GroupKey; ok: boolean; answerable: boolean; items: CheckItem[] }
export interface Checklist { scope_id: string; status: string; clear: boolean; groups: CheckGroup[]; checked_at: string }
/** The answers a close request carries: one reason per blocker that takes one. */
export interface Answer { id?: string; batch_code?: string; stage?: string; reason: string; /** as kept with a request */ code?: string; kg?: number; held?: number; difference_kg?: number }
export type Answers = Partial<Record<'flags' | 'kg' | 'pod' | 'packs' | 'balance', Answer[]>>;
export interface CloseState {
  status: 'draft' | 'active' | 'closed';
  request: { id: string; requested_at: string; requested_by: string; note: string | null; answers: Answers; mine: boolean } | null;
  closures: { id: string; status: string; version: number | null; requested_at: string; requested_by: string; decided_at: string | null; decided_by: string | null;
    decided_reason: string | null; reopened_at: string | null; reopened_by: string | null; reopen_reason: string | null }[];
  may: { request: boolean; withdraw: boolean; confirm: boolean; decline: boolean; reopen: boolean; interim: boolean; internal: boolean; store_files: boolean;
    withdraw_report: boolean };
}
export interface FileInfo { sha256: string; bytes: number; at: string }
export interface ReportHead { id: string; ref: string; scope_id: string; final: boolean; version: number; status: 'valid' | 'superseded' | 'withdrawn';
  issued_at: string; issued_by: string | null; issued_to: string; period_from: string | null; period_to: string | null; data_hash: string;
  superseded_by: string | null; superseded_at: string | null; withdrawn_at: string | null; withdrawn_reason: string | null; files?: Record<string, FileInfo> }
export interface Issued { id: string; ref: string; final: boolean; version: number; issued_at: string; status: string }

/** The report's data as the server keeps it (app.season_report_data). */
export interface ReportData {
  copy: Copy;
  cover: { client: string; client_code: string | null; crop: string; gi_tag: string | null; gi_earned: boolean; season: string; geography: string;
    state: string | null; status: string; data_note: string | null; scope_code: string | null; districts: string[]; delivery_model: string | null;
    period_from: string | null; period_to: string | null };
  units: Record<string, string>;
  headline: { procured_kg: number; packed_kg: number; sold_kg: number; shipped_kg: number; farmers: number; villages: number; gi_pct: number | null;
    farm_verified_pct: number | null; qc: { market: string; lots: number; passed: number; failed: number; accepted: number; pending: number; pass_pct: number | null }[];
    packs_released: number; packs_released_old: number; packs_held: number; scans: number; copy_flags: number; recalls: number; sealed_lots: number };
  balance: { stages: (StageBalance & { written_off_kg?: number })[]; milling: { in_kg: number; head_rice_kg: number; broken_kg: number; husk_kg: number;
    bran_kg: number; floor_loss_kg: number; records: number } | null; written_off_kg: number; check: { procured_kg: number; sold_kg: number; ok: boolean };
    differences: number };
  origin: { villages: { village: string | null; district: string | null; kg: number; pct: number | null; farmers: number }[]; farmers: number;
    gi_pct: number | null; farm_verified_pct: number | null;
    farmer_list: { code: string; name: string; village: string | null; district: string | null; kg: number; lots: number }[] | null };
  quality: { code: string; on: string | null; domestic: string | null; export: string | null; accepted: string | null; readings: Record<string, unknown>;
    lab: string | null; lab_accreditation: string | null; report_no: string | null; report_date: string | null; sample: string | null; files: string | null }[];
  packing: { batch_code: string; packing: string | null; packs: number; void: number; first: string; last: string; by_size: string | null;
    packed_on: string | null; best_before: string | null; net_weight: string | null; wastage_kg: number | null; wastage_pct: number | null }[];
  sales: { code: string; on: string | null; buyer: string | null; market: string | null; country: string | null; order_no: string | null; packs: string | null;
    kg: number; incoterms: string | null; price_per_kg: number | null; currency: string | null; total_value: number | null;
    shipments: { code: string; kg: number; invoice_no: string | null; dispatch_date: string | null; destination: string | null; container_no: string | null;
      bl_no: string | null; delivered_on: string | null; received_kg: number | null; transit_loss_kg: number | null; pod: 'attached' | 'awaiting' | 'not_needed';
      sealed: string | null }[] }[];
  qr: { batches: { batch_code: string; released: number; old_data: number; held: number; void: number }[];
    scans_by_city: { city: string; country: string; scans: number }[];
    copy_flags: { serial: string; kind: string; status: string; raised_at: string; decided_at: string | null; reason: string | null }[];
    releases: { qr_code: string; status: string; reason: string | null; at: string }[] };
  chain: { stage: string; pos: number; records: number; recorded_by: string[]; verified_by: string[]; same_person: number;
    returns: { code: string; reason: string; status: string }[]; flags: { code: string; kind: string; text: string; status: string }[];
    warnings: number; manager_records: { code: string; reason: string }[] }[];
  ledger: { last_check: { at: string; ok: boolean; blocks: number; problem: string | null } | null; blocks: number; first_hash: string | null; last_hash: string | null };
  open_items: { flags: { code: string; kind: string; text: string }[]; awaiting_pod: string[]; pending: number; lab_hold: number; packs_held: number };
  closure?: { version: number; requested_by: string | null; requested_at: string; confirmed_by: string | null; confirmed_at: string | null; note: string | null;
    answers: Answers;
    written_off: { code: string; stage: string; kg: number; reason: string }[] };
}
export interface ReportContent { report: ReportHead; copy: Copy; data: ReportData }
export interface PublicDocument { ref: string; kind: string; final: boolean; version: number; status: 'valid' | 'superseded' | 'withdrawn'; issued_at: string;
  issued_to: string; period_from: string | null; period_to: string | null; crop: string; season: string; geography: string; state: string | null;
  superseded_by: string | null; superseded_at: string | null; withdrawn_at: string | null;
  files: { copy: Copy; format: Format; lang: Lang; sha256: string; bytes: number }[] }
export interface IssuedRow { month: string; client: string; client_code: string | null; final: number; interim: number; /** migration 71: the evidence packs issued (the billing count) */ evidence_packs?: number; total: number }

export const closeChecklist = (scope: string, answers: Answers = {}) => rpc<Checklist>('close_checklist', { p_scope: scope, p_items: answers });
export const closeState = (scope: string) => rpc<CloseState>('scope_close_state', { p_scope: scope });
export const requestClose = (scope: string, answers: Answers, note: string) => rpc('request_close', { p_scope: scope, p_items: answers, p_note: note || null });
export const decideClose = (closure: string, reason: string) => rpc('decide_close_request', { p_closure: closure, p_reason: reason });
export const confirmClose = (closure: string) => rpc<{ closure_id: string; version: number; written_off_kg: number; report: Issued }>('confirm_close', { p_closure: closure });
export const reopenScope = (scope: string, reason: string) => rpc('reopen_scope', { p_scope: scope, p_reason: reason });
export const generateInterim = (scope: string) => rpc<Issued>('generate_interim_report', { p_scope: scope });
export const scopeReports = (scope: string) => rpc<ReportHead[]>('scope_reports', { p_scope: scope });
export const reportContent = (report: string, copy: Copy) => rpc<ReportContent>('report_content', { p_report: report, p_copy: copy });
export const withdrawReport = (report: string, reason: string) => rpc<ReportHead>('withdraw_report', { p_report: report, p_reason: reason });
export const publicDocument = (ref: string) => rpc<PublicDocument | null>('public_document', { p_ref: ref });
export const reportsIssued = (months = 12) => rpc<IssuedRow[]>('reports_issued', { p_months: months });

/** Pure: the store's name of a report's file, and its key in `files`. */
export const fileName = (report: string, copy: Copy, lang: Lang, format: Format) => `${report}/${copy}.${lang}.${format}`;
export const fileKey = (copy: Copy, lang: Lang, format: Format) => `${format}_${lang}_${copy}`;
/** Pure: the files a report should have for a reader (the internal ones only for its readers). */
export function expectedFiles(internal: boolean): { copy: Copy; lang: Lang; format: Format }[] {
  const out: { copy: Copy; lang: Lang; format: Format }[] = [];
  for (const copy of (internal ? ['shareable', 'internal'] : ['shareable']) as Copy[])
    for (const format of ['pdf', 'xlsx'] as Format[]) for (const lang of ['en', 'hi'] as Lang[]) out.push({ copy, lang, format });
  return out;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', bytes as unknown as ArrayBuffer);
  return Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Puts one file in the store and has the server keep its SHA-256 (a file is stored once). */
export async function storeReportFile(report: string, copy: Copy, lang: Lang, format: Format, bytes: Uint8Array) {
  const type = format === 'pdf' ? 'application/pdf' : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  const up = await supabase.storage.from('reports').upload(fileName(report, copy, lang, format), new Blob([bytes as unknown as ArrayBuffer], { type }),
    { contentType: type, upsert: false });
  let kept = bytes;
  if (up.error) {
    // a file left in the store by an interrupted attempt: what is in the store is the file, so its own SHA-256 is kept
    if (!/exist|duplicate/i.test(up.error.message)) throw up.error;
    const got = await supabase.storage.from('reports').download(fileName(report, copy, lang, format));
    if (got.error || !got.data) throw got.error ?? up.error;
    kept = new Uint8Array(await got.data.arrayBuffer());
  }
  return rpc('register_report_file', { p_report: report, p_copy: copy, p_format: format, p_lang: lang, p_sha256: await sha256Hex(kept), p_bytes: kept.byteLength });
}

/** A stored file for the reader: the download is logged first (Part C), then the file comes from the store (its read
 *  rule is the server's) and is saved under a name that says what it is. The reader stays on the page. */
export async function openReportFile(report: string, ref: string, copy: Copy, lang: Lang, format: Format) {
  const path = await rpc<string>('note_report_download', { p_report: report, p_copy: copy, p_format: format, p_lang: lang });
  const { data, error } = await supabase.storage.from('reports').download(path);
  if (error || !data) throw error ?? new Error('no file');
  const url = URL.createObjectURL(data);
  const a = document.createElement('a');
  a.href = url; a.download = `grainveda-season-report-${ref}-${copy}-${lang}.${format}`;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}
