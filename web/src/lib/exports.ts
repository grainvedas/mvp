// Migration 60 (Phase 1, release 2 of Veda's combined brief of 19 Oct 2026, Part C): the journey and the season are made
// on the server (app.export_journey, app.export_season), in a shareable or an internal copy. The browser only writes them
// down: the columns' names in the reader's language (each reading with its unit), the words for the values, and the
// copy's footer. The shareable copy never reaches the browser with a farmer's name or a price, so nothing here removes
// any. Migration 61: a column per field, the mass balance per stage in the Summary, the brief's own footer words.
import writeXlsxFile from 'write-excel-file';
import { rpc } from './api';
import { downloadCsv, type Cell } from './csv';
import { humanise } from './format';

export type Copy = 'shareable' | 'internal';
type T = (key: string, vars?: Record<string, string | number>, fallback?: string) => string;
type V = string | number | boolean | null | Record<string, unknown>;

export interface ScopeHead { client: string; client_code: string | null; crop: string; gi_tag: string | null; season: string; geography: string;
  state: string | null; status: string; data_note: string | null }
export interface ExportTable { columns: string[]; rows: V[][]; copy: Copy; generated_at: string; units: Record<string, string>; scope: ScopeHead;
  /** migration 61 (C2.2): who made it */ generated_by?: string | null }
export interface JourneyExport extends ExportTable { kind: 'journey'; lot: { code: string; qr_code: string | null } }
/** One stage of the scope's mass balance (app.stage_balance, migration 61, E2.5): came in = went on + by-products +
 *  samples and water + floor loss + lost in transit + closed as floor loss + left; any difference is shown. */
export interface StageBalance { stage: string; pos: number; records: number; pending: number; verified: number; kg_in: number; kg_out: number;
  by_products_kg: number; other_kg: number; floor_loss_kg: number; transit_loss_kg: number; closed_kg: number; handed_on_kg: number; left_kg: number;
  /** migration 63: written off at the scope's close */ written_off_kg?: number;
  difference_kg: number; balanced: boolean; last: boolean }
export type SeasonStage = StageBalance;
export interface SeasonExport extends ExportTable { kind: 'season'; summary: SeasonStage[];
  totals: { farmers: number; kg_in: number; gi_kg: number; gi_pct: number | null; farm_verified_kg: number;
    by_products: { head_rice_kg?: number; broken_kg: number; husk_kg: number; bran_kg: number; reject_kg: number; foreign_matter_kg: number };
    by_products_kg: number; other_kg?: number; floor_loss_kg: number; transit_loss_kg: number; closed_kg: number; differences: number;
    sealed_lots: number; packs: number; open_flags: number; records: number };
  batches: { batch_code: string; packs: number; void: number; first: string; last: string; by_size?: string | null; best_before?: string | null;
    /** migration 62 (E2.1) */ released?: number; released_old?: number; held?: number }[] }

export const exportJourney = (fp: string, copy: Copy) => rpc<JourneyExport>('export_journey', { p_fp: fp, p_copy: copy });
export const exportSeason = (scope: string, copy: Copy) => rpc<SeasonExport>('export_season', { p_scope: scope, p_copy: copy });
export const mayInternalCopy = (scope: string) => rpc<boolean>('may_internal_copy', { p_scope: scope });
export const stageBalance = (scope: string) => rpc<StageBalance[]>('stage_balance', { p_scope: scope });
/** Pure: a balance line as the dashboard shows it (by-products with samples and water; floor loss with transit). */
export const balanceParts = (b: StageBalance) => ({ byp: Number(b.by_products_kg) + Number(b.other_kg), loss: Number(b.floor_loss_kg) + Number(b.transit_loss_kg) });

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

const OPTION_KEYS = new Set(['line_clearance', 'polish', 'condition', 'delivered_by', 'payment_status', 'source_type']);
/** Pure: a value as the reader reads it (a stage's name, yes and no, GI status, the old-data note, a choice's words, the
 *  floor-loss closure's line; the raw values as text). */
export function cellValue(key: string, v: V, t: T): Cell {
  if (v === null || v === undefined) return null;
  if (typeof v === 'object') return JSON.stringify(v);
  if (key === 'stage') return v === 'floor_loss_closure' ? t('exp.closure_line') : v === 'written_off' ? t('exp.written_off_line') : t(`stage.${v}`, undefined, humanise(String(v)));
  if (key === 'best_before' && v === 'not_recorded') return t('exp.bb_old');
  if (key === 'collection_point' && v === 'farm') return t('opt.farm');
  if (key === 'market') return t(`exp.mkt.${v}`, undefined, String(v));
  if (OPTION_KEYS.has(key)) return t(`opt.${v}`, undefined, humanise(String(v)));
  if (key === 'same_person' || key === 'farm_verified' || key === 'lot_closed') return v === 'yes' ? t('common.yes') : v === 'no' ? t('common.no') : String(v);
  if (key === 'gi_status') return t(`gi.${v}`, undefined, String(v));
  if (key === 'data_note') return v === 'practice_old_data' ? t('exp.old_data') : String(v);
  if (key === 'status') return t(`exp.st.${v}`, undefined, String(v));
  return v as Cell;
}

/** Pure: the footer of a copy (the internal one says who it is for and not to forward it). */
export function footerLines(e: ExportTable, t: T, origin = typeof window !== 'undefined' ? window.location.origin : ''): string[] {
  return e.copy === 'internal'   // migration 61: the brief's own words first
    ? [t('exp.footer_internal'), t('exp.footer_internal_for', { client: e.scope.client, at: e.generated_at }), t('exp.footer_logged')]
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
    ...(e.generated_by ? [[cell(t('exp.h.generated_by')), cell(e.generated_by)]] : []),
    ...(s.data_note === 'practice_old_data' ? [[cell(t('exp.h.data_note')), cell(t('scope.old_data'))]] : []),
    [], ...foot];
  const tt = e.totals;
  const bp = tt.by_products;
  // migration 61 (C2.1/E2.5): each stage's mass balance; a difference in red
  const diff = (x: SeasonStage) => (x.balanced ? cell(Number(x.difference_kg)) : { value: Number(x.difference_kg), color: '#B42318', fontWeight: 'bold' as const });
  const summary = [
    [t('exp.s.stage'), t('exp.s.records'), t('exp.s.pending'), t('exp.s.verified'), t('exp.c.qty_in_kg'), t('exp.c.qty_out_kg'), t('exp.s.by_products'),
     t('exp.s.other'), t('exp.s.floor_loss'), t('exp.s.transit'), t('exp.s.closed'), t('exp.s.written_off'), t('exp.s.handed_on'), t('exp.s.left'), t('exp.s.difference')].map(bold),
    ...e.summary.map((x) => [cell(`${x.pos}. ${t(`stage.${x.stage}`, undefined, humanise(x.stage))}`), cell(x.records), cell(x.pending), cell(x.verified),
      cell(Number(x.kg_in)), cell(Number(x.kg_out)), cell(Number(x.by_products_kg)), cell(Number(x.other_kg)), cell(Number(x.floor_loss_kg)),
      cell(Number(x.transit_loss_kg)), cell(Number(x.closed_kg)), cell(Number(x.written_off_kg ?? 0)), cell(Number(x.handed_on_kg)), cell(Number(x.left_kg)), diff(x)]),
    [cell(t('exp.s.balance_note'))],
    [],
    [bold(t('exp.s.totals'))],
    [cell(t('exp.s.farmers')), cell(tt.farmers)],
    [cell(t('exp.s.kg_in')), cell(Number(tt.kg_in))],
    [cell(t('exp.s.gi_kg')), cell(Number(tt.gi_kg)), cell(tt.gi_pct === null ? null : `${tt.gi_pct} %`)],
    [cell(t('exp.s.farm_verified_kg')), cell(Number(tt.farm_verified_kg))],
    // head rice is the main product, not a by-product (staging, 20 Oct): its own line, then the by-products
    ...(Number(bp?.head_rice_kg ?? 0) > 0 ? [[cell(t('exp.c.head_rice_kg')), cell(Number(bp.head_rice_kg))]] : []),
    [bold(t('exp.s.by_products_title'))],
    ...(['broken_kg', 'husk_kg', 'bran_kg', 'reject_kg', 'foreign_matter_kg'] as const)
      .filter((k) => Number(bp?.[k] ?? 0) > 0).map((k) => [cell(t(`exp.c.${k}`)), cell(Number(bp[k]))]),
    [cell(t('exp.s.loss_kg')), cell(Number(tt.floor_loss_kg))],
    [cell(t('exp.s.transit_all')), cell(Number(tt.transit_loss_kg))],
    [cell(t('exp.s.closed_all')), cell(Number(tt.closed_kg))],
    [cell(t('exp.s.differences')), tt.differences > 0 ? { value: tt.differences, color: '#B42318', fontWeight: 'bold' as const } : cell(tt.differences)],
    [cell(t('exp.s.sealed_lots')), cell(tt.sealed_lots)],
    [cell(t('exp.s.packs')), cell(tt.packs)],
    [cell(t('exp.s.open_flags')), cell(tt.open_flags)],
    [cell(t('exp.s.records_all')), cell(tt.records)],
    [],
    [t('exp.c.batch_code'), t('exp.c.packs'), t('exp.s.released'), t('exp.s.released_old'), t('exp.s.held'), t('exp.s.void'), t('exp.s.first'), t('exp.s.last'),
     t('exp.s.by_size'), t('exp.s.best_before')].map(bold),
    // migration 62 (E2.1): each batch's packs released, released without codes (old data), not yet released
    ...e.batches.map((b) => [cell(b.batch_code), cell(b.packs), cell(b.released ?? null), cell(b.released_old ?? null), cell(b.held ?? null), cell(b.void),
      cell(b.first), cell(b.last), cell(b.by_size ?? null), cell(cellValue('best_before', b.best_before ?? null, t))]),
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
