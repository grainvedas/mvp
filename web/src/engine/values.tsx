// How a record's values are shown to people: a name in the reader's language and a value with its unit.
// One place for the arrival check, the review step, the record page and the lot journey. Before this file each of them
// pushed every worked-out value through a number formatter (text such as a batch code or a buyer came out as "NaN")
// and printed lists as code text.
import { Fragment } from 'react';
import { date as fmtDate, humanise, kg, num } from '../lib/format';
import type { FieldDef, QualityParam } from '../lib/types';

export type T = (key: string, vars?: Record<string, string | number>, fallback?: string) => string;

/** The order worked-out values are listed in, whatever order the server (or the phone, offline) sends them. */
const ORDER = ['net_kg', 'moisture_avg', 'moisture_min', 'moisture_max', 'variance_kg', 'variance_pct', 'source_count',
  'clean_kg', 'reject_kg', 'reject_reasons', 'grade_split', 'yield_pct', 'bran_kg', 'loss_kg', 'expected_out_kg',
  'water_removed_kg', 'grain_loss_kg', 'pop_rate_pct', 'weight_yield_pct', 'foreign_matter_kg', 'water_uptake_kg',
  'spoilage_kg', 'packed_kg', 'wastage_kg', 'batch_code', 'sample_qty_kg', 'forwarding_kg', 'market', 'buyer',
  'transit_loss_kg', 'final_kg', 'grade'];

export function orderedComputed(computed: Record<string, unknown> | null | undefined): [string, unknown][] {
  const rank = (k: string) => { const i = ORDER.indexOf(k); return i < 0 ? ORDER.length : i; };
  return Object.entries(computed ?? {}).sort(([a], [b]) => rank(a) - rank(b) || a.localeCompare(b));
}

export const computedLabel = (key: string, t: T) => t(`computed.${key}`, undefined, humanise(key));
/** A lab parameter with no name of its own: its key without the unit suffix ("broken_pct" → "Broken", not "Broken Pct"). */
export const paramName = (p: string) => humanise(p.replace(/_(pct|kg)$/, ''));

const pct = (n: number) => `${num(n, 2)} %`;
function number(key: string, n: number, unit?: string): string {
  if (unit === 'kg' || key.endsWith('_kg')) return kg(n);
  if (unit === '%' || key.endsWith('_pct') || key.startsWith('moisture_')) return pct(n);
  return unit ? `${num(n, 3)} ${unit}` : num(n, 3);
}

/** One row of a list value: a reject reason with its weight, a packet size with its count. */
function row(x: unknown, t: T): string {
  if (x === null || typeof x !== 'object') return String(x ?? '');
  const r = x as Record<string, unknown>;
  if ('reason' in r) return `${String(r.reason)} ${kg(Number(r.kg ?? 0))}`;
  if ('units' in r) return `${num(Number(r.units), 0)} × ${kg(Number(r.size_kg ?? 0))}`;
  return Object.entries(r).map(([k, v]) => `${t(`field.${k}`, undefined, humanise(k))} ${String(v)}`).join(', ');
}

/** A worked-out value (footprints.computed): numbers with their unit, text as text, lists as words. Never "NaN". */
export function showComputed(key: string, v: unknown, t: T): string {
  if (v === null || v === undefined || v === '') return '—';
  if (typeof v === 'number') return number(key, v);
  if (typeof v === 'boolean') return t(v ? 'common.yes' : 'common.no');
  if (Array.isArray(v)) return v.length ? v.map((x) => row(x, t)).join(' · ') : '—';
  if (typeof v === 'object') {                             // grade split {A: 240, B: 80, C: 22}
    const parts = Object.entries(v as Record<string, unknown>).map(([k, x]) => `${k} ${typeof x === 'number' ? kg(x) : String(x)}`);
    return parts.length ? parts.join(' · ') : '—';
  }
  return t(`opt.${String(v)}`, undefined, String(v));       // a market word in the reader's language; any other text as it is
}

/** A value the operator typed (footprints.payload), by the field's definition in the stage registry. */
export function showEntered(fd: FieldDef | undefined, key: string, v: unknown, t: T, params: QualityParam[] = []): string {
  if (v === null || v === undefined || v === '') return '—';
  const type = fd?.type ?? '';
  if (type === 'readings' && typeof v === 'object' && !Array.isArray(v)) {
    const parts = Object.entries(v as Record<string, unknown>).map(([p, x]) => {
      const qp = params.find((q) => q.param === p);
      return `${t(`qp.${p}`, undefined, qp?.label ?? paramName(p))} ${typeof x === 'number' ? number(p, x, qp?.unit) : String(x)}`;
    });
    return parts.length ? parts.join(' · ') : '—';
  }
  if (type === 'footprint[]' && Array.isArray(v)) return t('record.n_lots', { n: v.length });
  if (type === 'number[3]' && Array.isArray(v)) return `${v.map((x) => num(Number(x), 2)).join(' · ')}${fd?.unit ? ` ${fd.unit}` : ''}`;
  if (type === 'date' && typeof v === 'string') return fmtDate(v);
  if (typeof v === 'number') return number(key, v, fd?.unit);
  if (typeof v === 'boolean') return t(v ? 'common.yes' : 'common.no');
  if (Array.isArray(v)) return v.length ? v.map((x) => row(x, t)).join(' · ') : '—';
  if (typeof v === 'object') return Object.entries(v as Record<string, unknown>).map(([k, x]) => `${humanise(k)} ${String(x)}`).join(' · ');
  return t(`opt.${String(v)}`, undefined, String(v));
}

/** Worked-out values as rows of a definition list. */
export function ComputedRows({ computed, t }: { computed: Record<string, unknown> | null | undefined; t: T }) {
  return <>{orderedComputed(computed).map(([k, v]) => (
    <Fragment key={k}><dt>{computedLabel(k, t)}</dt><dd data-computed={k}>{showComputed(k, v, t)}</dd></Fragment>
  ))}</>;
}

/** Entered values as rows of a definition list, in the order of the stage's form; anything not in the form comes last. */
export function EnteredRows({ payload, fields, stage, params, t }: {
  payload: Record<string, unknown>; fields: FieldDef[]; stage: string; params?: QualityParam[]; t: T;
}) {
  const known = fields.filter((f) => f.key in payload);
  const extra = Object.keys(payload).filter((k) => !fields.some((f) => f.key === k));
  const label = (f: FieldDef) => t(`field.${stage}.${f.key}`, undefined, t(`field.${f.key}`, undefined, f.label));
  return <>
    {known.map((f) => <Fragment key={f.key}><dt>{label(f)}</dt><dd data-entered={f.key}>{showEntered(f, f.key, payload[f.key], t, params)}</dd></Fragment>)}
    {extra.map((k) => <Fragment key={k}><dt>{t(`field.${k}`, undefined, humanise(k))}</dt><dd data-entered={k}>{showEntered(undefined, k, payload[k], t, params)}</dd></Fragment>)}
  </>;
}

/**
 * What will be left on the source lot once this record is saved. The server's preview reports what the lot holds NOW;
 * shown as "still available" it read as if this record had already been taken off. Not shown for a stage that takes
 * several lots at once (the figure is that of one of them).
 */
export function leftAfter(p: { qty_in?: number; available_on_prev?: number | null }, aggregates: boolean): number | null {
  if (aggregates || p.available_on_prev === null || p.available_on_prev === undefined || p.qty_in === undefined) return null;
  const left = Math.round((Number(p.available_on_prev) - Number(p.qty_in)) * 1000) / 1000;
  return left < 0 ? null : left;
}

/** "Recorded" on a record: the time it was captured, and, when it waited on the phone, when it was sent. */
export function capturedAt(f: { created_at: string; captured_at?: string | null }): { at: string; sentLater: boolean } {
  const at = f.captured_at ?? f.created_at;
  return { at, sentLater: new Date(f.created_at).getTime() - new Date(at).getTime() > 120_000 };
}
