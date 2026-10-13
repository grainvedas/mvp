// The crop registry (migration 42, Veda 13 Oct 2026): what a crop holds, when it is ready, how a chain is split for the
// scope wizard, and the farmer's good farming practice. Every rule here is also the database's; these are the screens'
// mirrors (what to offer, what to say), never the only check.
import type { QualityParam, StageType } from './types';

export type GapType = 'date' | 'yesno' | 'number' | 'text' | 'choice';
export interface GapItem { key: string; label: string; type: GapType; options?: string[]; required?: boolean }

export interface CropFull {
  id: string; name: string; code: string; gi_tag: string | null; origin: string | null; primary_unit: string;
  quality_params: QualityParam[]; allowed_stages: StageType[]; state_id?: string | null;
  yield_per_acre_kg?: number | null; recommended_chain?: StageType[]; gap_items?: GapItem[];
  harvest_from?: number | null; harvest_to?: number | null; export_docs?: string[];
  retired_at?: string | null; retire_reason?: string | null;
}
/** a row of app.crop_registry */
export interface RegistryRow extends CropFull {
  state_name: string | null; missing: string[]; ready: boolean; retired_by_name: string | null;
  use: { scopes_active: number; scopes_setup: number; scopes_closed: number; farmers_gap: number };
}

/** What a crop still lacks before a scope can be activated with it (mirror of app.crop_missing). */
export function cropMissing(c: Pick<CropFull, 'primary_unit' | 'yield_per_acre_kg' | 'quality_params' | 'recommended_chain'>): string[] {
  const out: string[] = [];
  if (!c.primary_unit?.trim()) out.push('unit');
  if (c.yield_per_acre_kg === null || c.yield_per_acre_kg === undefined) out.push('yield');
  if (!c.quality_params?.length) out.push('limits');
  if (!c.recommended_chain?.length) out.push('chain');
  return out;
}

/** A crop the scope wizard offers: not retired, ready. A server before migration 42 has neither: everything, as before. */
export const offeredForScope = (c: CropFull) => !c.retired_at && (c.recommended_chain === undefined || cropMissing(c).length === 0);

/** The wizard's choices for a whole chain (entry, village batch, processing before and after the lab, exits). */
export function splitChain(c: StageType[], isProcessing: (s: StageType) => boolean) {
  const qi = c.indexOf('qc');
  return {
    entry: (c[0] === 'lot_inward' ? 'lot_inward' : 'procurement') as StageType,
    villageBatch: c.includes('village_batch'),
    before: (qi < 0 ? [] : c.slice(1, qi)).filter(isProcessing),
    after: (qi < 0 ? [] : c.slice(qi + 1)).filter(isProcessing),
    commercial: c.includes('commercial'),
    shipment: c.includes('shipment'),
  };
}

/** Builds the ordered chain from the builder's choices (the scope wizard and the crop's recommended chain). */
export function assembleChain(o: { entry: StageType; villageBatch: boolean; before: StageType[]; after: StageType[]; commercial: boolean; shipment: boolean }): StageType[] {
  return [o.entry, ...(o.villageBatch && o.entry === 'procurement' ? ['village_batch' as StageType] : []), ...o.before, 'qc',
    ...o.after, ...(o.commercial ? ['commercial' as StageType] : []), ...(o.shipment ? ['shipment' as StageType] : []), 'qr_activation'];
}

/** The processing stages a chain uses: they must be among the crop's allowed stages. */
export const processingOf = (chain: StageType[], isProcessing: (s: StageType) => boolean) => chain.filter(isProcessing);

export const MONTHS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
/** "Oct–Dec" in the reader's language (the month names of the browser). */
export function monthName(m: number, lang: string) {
  return new Date(2000, m - 1, 1).toLocaleString(lang === 'hi' ? 'hi-IN' : 'en-IN', { month: 'short' });
}
export const harvestText = (c: Pick<CropFull, 'harvest_from' | 'harvest_to'>, lang: string) =>
  c.harvest_from && c.harvest_to ? `${monthName(c.harvest_from, lang)}–${monthName(c.harvest_to, lang)}` : '';

/** The practices not answered (mirror of app.gap_missing): required ones refuse a lot at Procurement. */
export function gapMissing(items: GapItem[] = [], answers: Record<string, unknown> = {}) {
  const open = items.filter((i) => answers[i.key] === undefined || answers[i.key] === null || answers[i.key] === '');
  return { required: open.filter((i) => i.required).map((i) => i.label), optional: open.filter((i) => !i.required).map((i) => i.label) };
}

/** A typed reading as entered: a number stays a number, yes/no a boolean, a grade its text. */
export function readingValue(s: string): number | boolean | string | undefined {
  const x = s.trim();
  if (x === '') return undefined;
  if (/^-?[\d.]+$/.test(x) && !Number.isNaN(Number(x))) return Number(x);
  if (/^(yes|true)$/i.test(x)) return true;
  if (/^(no|false)$/i.test(x)) return false;
  return x;
}

/** A limit as a line of words: "≤ 13 / 12 %", "grade A, B / A", "no / no". */
export function limitSummary(p: QualityParam, yes: string, no: string): string {
  const t = p.type ?? 'number';
  const list = (x: QualityParam['domestic_pass']) => (Array.isArray(x) ? x.join(', ') : '');
  if (t === 'grade') return `${list(p.domestic_pass)} / ${list(p.export_pass)}`;
  if (t === 'yesno') return `${p.domestic_pass ? yes : no} / ${p.export_pass ? yes : no}`;
  const lim = (l: QualityParam['domestic_limit']) => (Array.isArray(l) ? `${l[0]}–${l[1]}` : String(l));
  const op = p.operator === '<=' ? '≤' : p.operator === '>=' ? '≥' : '';
  return `${op} ${lim(p.domestic_limit)} / ${lim(p.export_limit)}${p.unit ? ` ${p.unit}` : ''}`.trim();
}

/** Pure: the crops a State Manager works with: his states' and those with no state yet (he may set it); everyone else all. */
export const cropsFor = <T extends { state_id?: string | null }>(list: T[], states: string[] | null): T[] =>
  states === null ? list : list.filter((c) => !c.state_id || states.includes(c.state_id));

/** Text that can still become a number as typing goes on: digits with at most one point. */
export const limitTyping = (text: string) => /^\d*\.?\d*$/.test(text.trim());

/** A quality limit as typed: a number, or null while it is not one (empty, "12.", a letter). */
export function limitInput(text: string): number | null {
  const s = text.trim();
  if (s === '' || s.endsWith('.') || !/^\d*\.?\d+$/.test(s)) return null;
  return Number(s);
}
