// Migration 60 (Phase 1, release 2 of Veda's combined brief of 19 Oct 2026, Part C): the journey and the season are made
// on the server (app.export_journey, app.export_season), in a shareable or an internal copy. The browser only writes them
// down: the columns' names in the reader's language (each reading with its unit), the words for the values, and the
// copy's footer. The shareable copy never reaches the browser with a name or a price, so nothing here removes any.
import writeXlsxFile from 'write-excel-file';
import { rpc } from './api';
import { downloadCsv, type Cell } from './csv';
import { humanise } from './format';

export type Copy = 'shareable' | 'internal';
type T = (key: string, vars?: Record<string, string | number>, fallback?: string) => string;
type V = string | number | boolean | null | Record<string, unknown>;

export interface ScopeHead { client: string; client_code: string | null; crop: string; gi_tag: string | null; season: string; geography: string;
  state: string | null; status: string; data_note: string | null }
export interface ExportTable { columns: string[]; rows: V[][]; copy: Copy; generated_at: string; units: Record<string, string>; scope: ScopeHead }
export interface JourneyExport extends ExportTable { kind: 'journey'; lot: { code: string; qr_code: string | null } }
export interface SeasonStage { stage: string; pos: number; records: number; pending: number; verified: number; kg_in: number; kg_out: number; loss_kg: number }
export interface SeasonExport extends ExportTable { kind: 'season'; summary: SeasonStage[];
  totals: { farmers: number; kg_in: number; gi_kg: number; gi_pct: number | null; farm_verified_kg: number; loss_kg: number;
    sealed_lots: number; packs: number; open_flags: number; records: number };
  batches: { batch_code: string; packs: number; void: number; first: string; last: string }[] }

export const exportJourney = (fp: string, copy: Copy) => rpc<JourneyExport>('export_journey', { p_fp: fp, p_copy: copy });
export const exportSeason = (scope: string, copy: Copy) => rpc<SeasonExport>('export_season', { p_scope: scope, p_copy: copy });
export const mayInternalCopy = (scope: string) => rpc<boolean>('may_internal_copy', { p_scope: scope });

/** Pure: a column's name in the reader's language; a reading ("r:<key>") with its unit. */
export function columnLabel(key: string, units: Record<string, string>, t: T): string {
  if (key.startsWith('r:')) {
    const k = key.slice(2);
    const unit = units[k] ?? (k.endsWith('_pct') ? '%' : k.endsWith('_ppb') ? 'ppb' : '');
    const name = t(`qp.${k}`, undefined, humanise(k.replace(/_(pct|ppb|ppm|kg|mm)$/, '')));
    return unit ? `${name} (${unit})` : name;
  }
  return t(`exp.c.${key}`, undefined, humanise(key));
}

/** Pure: a value as the reader reads it (a stage's name, yes and no, GI status, the old-data note; the raw values as text). */
export function cellValue(key: string, v: V, t: T): Cell {
  if (v === null || v === undefined) return null;
  if (typeof v === 'object') return JSON.stringify(v);
  if (key === 'stage') return t(`stage.${v}`, undefined, humanise(String(v)));
  if (key === 'same_person' || key === 'farm_verified' || key === 'lot_closed') return v === 'yes' ? t('common.yes') : v === 'no' ? t('common.no') : String(v);
  if (key === 'gi_status') return t(`gi.${v}`, undefined, String(v));
  if (key === 'data_note') return v === 'practice_old_data' ? t('exp.old_data') : String(v);
  if (key === 'status') return t(`exp.st.${v}`, undefined, String(v));
  return v as Cell;
}

/** Pure: the footer of a copy (the internal one says who it is for and not to forward it). */
export function footerLines(e: ExportTable, t: T, origin = typeof window !== 'undefined' ? window.location.origin : ''): string[] {
  return e.copy === 'internal'
    ? [t('exp.footer_internal', { client: e.scope.client, at: e.generated_at }), t('exp.footer_logged')]
    : [t('exp.footer_shareable', { at: e.generated_at }), t('exp.footer_verify', { url: `${origin}/verify/` })];
}

/** Pure: the table as a heading and rows, in the reader's language. */
export function tableOf(e: ExportTable, t: T): { header: string[]; rows: Cell[][] } {
  return { header: e.columns.map((c) => columnLabel(c, e.units, t)), rows: e.rows.map((r) => r.map((v, i) => cellValue(e.columns[i], v, t))) };
}

const slug = (s: string) => s.replace(/[^\w-]+/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '');

/** The journey as CSV: the table, a blank line, the footer. */
export function journeyCsv(e: JourneyExport, t: T) {
  const { header, rows } = tableOf(e, t);
  const tail: Cell[][] = [[], ...footerLines(e, t).map((l) => [l])];
  downloadCsv(`grainveda-journey-${slug(e.lot.qr_code ?? e.lot.code)}-${e.copy}.csv`, header, [...rows, ...tail]);
}

const bold = (v: Cell) => ({ value: v ?? null, fontWeight: 'bold' as const });
const cell = (v: Cell) => (v === null || v === undefined || v === '' ? null : { value: v });

/** Pure: the three sheets of the season (Heading, Summary, Records), each ending with the copy's footer. */
export function seasonSheets(e: SeasonExport, t: T) {
  const foot = footerLines(e, t).map((l) => [cell(l)]);
  const s = e.scope;
  const heading = [
    [bold(t('exp.season_title'))],
    [cell(t('exp.h.client')), cell(s.client)],
    [cell(t('exp.h.crop')), cell(s.gi_tag ? `${s.crop} · ${s.gi_tag}` : s.crop)],
    [cell(t('exp.h.season')), cell(s.season)],
    [cell(t('exp.h.place')), cell([s.geography, s.state].filter(Boolean).join(', '))],
    [cell(t('exp.h.status')), cell(t(`exp.sst.${s.status}`, undefined, s.status))],
    [cell(t('exp.h.copy')), cell(t(`exp.copy_${e.copy}`))],
    [cell(t('exp.h.generated')), cell(`${e.generated_at} IST`)],
    ...(s.data_note === 'practice_old_data' ? [[cell(t('exp.h.data_note')), cell(t('scope.old_data'))]] : []),
    [], ...foot];
  const tt = e.totals;
  const summary = [
    [t('exp.s.stage'), t('exp.s.records'), t('exp.s.pending'), t('exp.s.verified'), t('exp.c.qty_in_kg'), t('exp.c.qty_out_kg'), t('exp.c.loss_kg')].map(bold),
    ...e.summary.map((x) => [cell(`${x.pos}. ${t(`stage.${x.stage}`, undefined, humanise(x.stage))}`), cell(x.records), cell(x.pending), cell(x.verified),
      cell(Number(x.kg_in)), cell(Number(x.kg_out)), cell(Number(x.loss_kg))]),
    [],
    [bold(t('exp.s.totals'))],
    [cell(t('exp.s.farmers')), cell(tt.farmers)],
    [cell(t('exp.s.kg_in')), cell(Number(tt.kg_in))],
    [cell(t('exp.s.gi_kg')), cell(Number(tt.gi_kg)), cell(tt.gi_pct === null ? null : `${tt.gi_pct} %`)],
    [cell(t('exp.s.farm_verified_kg')), cell(Number(tt.farm_verified_kg))],
    [cell(t('exp.s.loss_kg')), cell(Number(tt.loss_kg))],
    [cell(t('exp.s.sealed_lots')), cell(tt.sealed_lots)],
    [cell(t('exp.s.packs')), cell(tt.packs)],
    [cell(t('exp.s.open_flags')), cell(tt.open_flags)],
    [cell(t('exp.s.records_all')), cell(tt.records)],
    [],
    [t('exp.c.batch_code'), t('exp.c.packs'), t('exp.s.void'), t('exp.s.first'), t('exp.s.last')].map(bold),
    ...e.batches.map((b) => [cell(b.batch_code), cell(b.packs), cell(b.void), cell(b.first), cell(b.last)]),
    [], ...foot];
  const { header, rows } = tableOf(e, t);
  const records = [header.map(bold), ...rows.map((r) => r.map(cell)), [], ...foot];
  return { sheets: [heading, summary, records], names: [t('exp.sheet_heading'), t('exp.sheet_summary'), t('exp.sheet_records')] };
}

/** The season as one Excel file. */
export async function seasonXlsx(e: SeasonExport, t: T) {
  const { sheets, names } = seasonSheets(e, t);
  await writeXlsxFile(sheets as never, { sheets: names, fileName: `grainveda-season-${slug(`${e.scope.season}-${e.scope.geography}`)}-${e.copy}.xlsx` });
}
