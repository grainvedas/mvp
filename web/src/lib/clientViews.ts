// Migration 68 (Phase 3, release 2 of Veda's combined brief of 19 Oct 2026: Parts C and E4). What client users see:
// the portfolio (every scope the reader reaches, by state and crop and in total), one scope, across scopes, the
// farmers; each as an export. The server reads each view for whoever may read it (app.client_portfolio,
// app.client_scope_detail, app.client_across) and makes its export from the same data (app.export_client_view): a
// shareable copy (no price, no farmer's name) or an internal one; every download is in the Audit log. The browser only
// writes them down, in the reader's language.
import writeXlsxFile from 'write-excel-file';
import { rpc } from './api';
import { downloadCsv, type Cell } from './csv';
import { humanise, istStamp } from './format';
import type { Copy } from './exports';

export type View = 'portfolio' | 'scope' | 'farmers' | 'across';
type T = (key: string, vars?: Record<string, string | number>, fallback?: string) => string;
type V = string | number | boolean | null;

export interface Figures {
  procured_kg: number; in_process_kg: number; packed_packs: number; packed_kg: number; sold_kg: number; shipped_kg: number;
  released_packs: number; scans: number; copy_flags: number; lab_open: number; lab_waiting: number; lab_failed: number;
  recalls: number; investigations: number; waiting: number;
}
export interface PortfolioScope extends Figures { scope_id: string; state_id: string | null; state: string | null; crop_id: string; crop: string;
  season: string; place: string; status: string; delivery_model: string; label: string }
export interface PortfolioGroup extends Figures { state_id: string | null; state: string | null; crop_id: string; crop: string; scopes: number }
export interface ClientHead { id: string; name: string; code: string | null }
export interface Portfolio { client: ClientHead; may_internal: boolean; scopes: PortfolioScope[]; groups: PortfolioGroup[]; total: Figures & { scopes: number } }

export interface ScopeDetail {
  client: ClientHead; may_internal: boolean; internal: boolean;
  head: { scope_id: string; label: string; client: string; crop: string; gi_tag: string | null; season: string; geography: string; state: string | null;
    status: string; delivery_model: string; markets: string[]; gi_user_no: string | null; chain: string[] };
  figures: Figures;
  pipeline: { stage: string; pos: number; records: number; pending: number; verified: number; kg_out: number; kg_waiting: number }[];
  lots: { lot: string; qr_code: string; sealed_at: string; batches: string; release: string; packs_live: number }[];
  batches: { batch_code: string; packs: number; kg: number; packed_on: string | null; best_before: string | null; released: number; held: number; void: number }[];
  qc: { code: string; status: string; tested_on: string | null; lab: string | null; report_no: string | null; report_date: string | null;
    domestic: string | null; export: string | null; accepted: boolean; decided: boolean }[];
  documents: { kind: string; what: string | null; status: string; record: string | null; on_file: boolean; at: string | null }[];
  reports: { ref: string; kind: string; final: boolean; version: number; status: string; issued_at: string }[];
  people: { stage: string; name: string; client_staff: boolean }[];
}

export interface Order { code: string; scope_id: string; scope: string; on: string; buyer: string | null; market: string | null; destination_country: string | null;
  order_no: string | null; qty_kg: number; shipped_kg: number; status: string; price_per_kg?: number | null; currency?: string | null; total_value?: number | null }
export interface Across {
  client: ClientHead; may_internal: boolean; internal: boolean; orders: Order[];
  buyers: { buyer: string; orders: number; qty_kg: number; shipped_kg: number }[];
  scans_by_city: { city: string | null; region: string | null; country: string | null; scans: number; last_at: string }[];
  copy_flags: { serial: string; kind: string; status: string; raised_at: string; scope: string }[];
  recalls: { qr_code: string; scope: string; status: string; reason: string | null; at: string }[];
  outputs: { ref: string; kind: string; final: boolean; version: number; status: string; issued_at: string; scope: string }[];
}

export interface ExportTableC { key: string; columns: string[]; rows: V[][] }
export interface ClientExport { kind: 'client_view'; view: View; copy: Copy; generated_at: string; generated_by: string | null;
  client: { name: string; code: string | null }; scope: (ScopeDetail['head'] & { label: string }) | null; units: Record<string, string>; tables: ExportTableC[] }

export const clientPortfolio = (client: string) => rpc<Portfolio>('client_portfolio', { p_client: client });
export const clientScopeDetail = (scope: string) => rpc<ScopeDetail>('client_scope_detail', { p_scope: scope });
export const clientAcross = (client: string) => rpc<Across>('client_across', { p_client: client });
export const exportClientView = (view: View, client: string | null, scope: string | null, copy: Copy) =>
  rpc<ClientExport>('export_client_view', { p_view: view, p_client: client, p_scope: scope, p_copy: copy });

/** The portfolio's figures, in the order the screen and the export show them. */
export const FIGURES: (keyof Figures)[] = ['procured_kg', 'in_process_kg', 'packed_packs', 'packed_kg', 'sold_kg', 'shipped_kg', 'released_packs',
  'scans', 'copy_flags', 'lab_open', 'recalls', 'waiting'];

/** Pure: a column's name in the reader's language (the export's own words first, then the season export's). */
export const cvColumn = (key: string, t: T) => t(`cv.c.${key}`, undefined, t(`exp.c.${key}`, undefined, humanise(key)));

const TIME_KEYS = new Set(['sealed_at', 'raised_at', 'at', 'issued_at', 'last_at']);
/** Pure: a value as the reader reads it (a stage, a status, yes and no, a verdict, the delivery model, a kind; times in IST). */
export function cvValue(key: string, v: V, t: T): Cell {
  if (v === null || v === undefined || v === '') return null;
  if (typeof v === 'boolean') return v ? t('common.yes') : t('common.no');
  if (key === 'stage') return t(`stage.${v}`, undefined, humanise(String(v)));
  if (key === 'domestic' || key === 'export') return t(`cv.verdict.${v}`, undefined, String(v));
  if (key === 'delivery_model') return t(`sd.${v}`, undefined, humanise(String(v)));
  if (key === 'release') return t(`cv.release.${v}`, undefined, humanise(String(v)));
  if (key === 'kind') return t(`cv.kind.${v}`, undefined, humanise(String(v)));
  if (key === 'market') return t(`exp.mkt.${v}`, undefined, String(v));
  if (key === 'status') return t(`cv.st.${v}`, undefined, humanise(String(v)));
  if (TIME_KEYS.has(key)) return istStamp(String(v));
  return v;
}

/** Pure: a table of an export in the reader's language. */
export function cvTable(tb: ExportTableC, t: T): { title: string; header: string[]; rows: Cell[][] } {
  return { title: t(`cv.t.${tb.key}`, undefined, humanise(tb.key)), header: tb.columns.map((c) => cvColumn(c, t)),
    rows: tb.rows.map((r) => r.map((v, i) => cvValue(tb.columns[i], v, t))) };
}

/** Pure: the footer of a copy (the internal one says who it is for and not to forward it; both say the download is logged). */
export function cvFooter(e: ClientExport, t: T, origin = typeof window !== 'undefined' ? window.location.origin : ''): string[] {
  return e.copy === 'internal'
    ? [t('exp.footer_internal'), t('cv.footer_internal_for', { client: e.client.name, at: e.generated_at }), t('exp.footer_logged')]
    : [t('exp.footer_shareable', { at: e.generated_at }), t('exp.footer_verify', { url: `${origin}/verify/` }), t('exp.footer_logged')];
}

/** Pure: the heading lines (what this is, for whom, which copy, when, by whom). */
export function cvHeading(e: ClientExport, t: T): [string, string][] {
  return [
    [t('exp.h.client'), e.client.code ? `${e.client.name} (${e.client.code})` : e.client.name],
    ...(e.scope ? [[t('cv.h.scope'), e.scope.label] as [string, string], [t('exp.h.place'), [e.scope.geography, e.scope.state].filter(Boolean).join(', ')] as [string, string]] : []),
    [t('exp.h.copy'), t(`exp.copy_${e.copy}`)],
    [t('exp.h.generated'), `${e.generated_at} IST`],
    ...(e.generated_by ? [[t('exp.h.generated_by'), e.generated_by] as [string, string]] : []),
  ];
}

const slug = (s: string) => s.replace(/[^\w-]+/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '');
export const cvFileName = (e: ClientExport, ext: 'xlsx' | 'csv') =>
  `grainveda-${e.view}-${slug(e.scope ? `${e.scope.season}-${e.scope.geography}` : (e.client.code ?? e.client.name))}-${e.copy}.${ext}`;

const bold = (v: Cell) => ({ value: v ?? null, fontWeight: 'bold' as const });
const cell = (v: Cell) => (v === null || v === undefined || v === '' ? null : { value: v });

/** Pure: the sheets of an export: the heading, then one per table, each ending with the copy's footer. */
export function cvSheets(e: ClientExport, t: T) {
  const foot = cvFooter(e, t).map((l) => [cell(l)]);
  const heading = [[bold(t(`cv.title.${e.view}`))], ...cvHeading(e, t).map(([k, v]) => [cell(k), cell(v)]), [], ...foot];
  const sheets = [heading, ...e.tables.map((tb) => {
    const x = cvTable(tb, t);
    return [x.header.map(bold), ...x.rows.map((r) => r.map(cell)), [], ...foot];
  })];
  const names = [t('exp.sheet_heading'), ...e.tables.map((tb) => cvTable(tb, t).title.slice(0, 31))];
  return { sheets, names };
}

/** Pure: the CSV lines: the heading, then each table under its title, then the footer. */
export function cvCsvRows(e: ClientExport, t: T): Cell[][] {
  const out: Cell[][] = [...cvHeading(e, t), []];
  for (const tb of e.tables) {
    const x = cvTable(tb, t);
    out.push([x.title], x.header, ...x.rows, []);
  }
  return [...out, ...cvFooter(e, t).map((l) => [l])];
}

export async function cvXlsx(e: ClientExport, t: T) {
  const { sheets, names } = cvSheets(e, t);
  await writeXlsxFile(sheets as never, { sheets: names, fileName: cvFileName(e, 'xlsx') });
}
export function cvCsv(e: ClientExport, t: T) {
  downloadCsv(cvFileName(e, 'csv'), [t(`cv.title.${e.view}`)], cvCsvRows(e, t));
}
