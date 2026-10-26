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
  'total_kg', 'farmers', 'villages', 'collection_point',                                     // migration 52: the Collection Batch
  'discrepancy_kg', 'discrepancy_pct', 'condition', 'bags_in', 'location', 'stack',          // migration 55: the Warehouse
  'mill', 'line_clearance', 'head_rice_kg', 'broken_kg', 'husk_kg', 'recovery_pct', 'head_rice_pct', 'transit_loss_kg',   // migration 53
  'sample_code', 'lab', 'lab_kind', 'packing_unit', 'wastage_pct',
  'clean_kg', 'reject_kg', 'reject_reasons', 'grade_split', 'yield_pct', 'bran_kg', 'loss_kg', 'expected_out_kg',
  'water_removed_kg', 'grain_loss_kg', 'pop_rate_pct', 'weight_yield_pct', 'foreign_matter_kg', 'water_uptake_kg',
  'spoilage_kg', 'packed_kg', 'wastage_kg', 'batch_code', 'sample_qty_kg', 'forwarding_kg', 'client_order', 'market', 'buyer',   // migration 70: its order
  'buyer_country', 'order_no', 'market_code', 'market_name', 'destination_country', 'sale_route', 'packs',     // migration 54: Commercial
  'units',                                                                                                     // migration 58: what the order set aside
  'invoice_no', 'serials_count', 'cartons_count', 'container_no', 'bl_pending',                                // migration 54: Shipment (58: cartons)
  'transit_loss_kg', 'final_kg', 'grade'];
/** Worked-out values kept for the system, not shown: the buyer's row id (his name and country are shown), the export
 *  market's code (its name is shown: seen on the record page at 390 px, the two lines said the same). */
const NOT_SHOWN = new Set(['buyer_id', 'market_code', 'client_order_id']);   // migration 70: the order by its code

export function orderedComputed(computed: Record<string, unknown> | null | undefined): [string, unknown][] {
  const rank = (k: string) => { const i = ORDER.indexOf(k); return i < 0 ? ORDER.length : i; };
  // the yield of a milling run is its recovery (found in release 6's checks: "Yield" stood beside "Recovery", the same figure)
  const hide = (k: string) => NOT_SHOWN.has(k) || (k === 'yield_pct' && computed != null && 'recovery_pct' in computed);
  return Object.entries(computed ?? {}).filter(([k]) => !hide(k)).sort(([a], [b]) => rank(a) - rank(b) || a.localeCompare(b));
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
  if ('units' in r && 'name' in r) return `${num(Number(r.units), 0)} × ${String(r.name)}`;     // migration 54: packs of an order, by type
  if ('units' in r) return `${num(Number(r.units), 0)} × ${kg(Number(r.size_kg ?? 0))}`;
  if ('village' in r) return `${String(r.village)} ${kg(Number(r.kg ?? 0))}${r.share_pct !== undefined ? ` (${num(Number(r.share_pct), 1)} %)` : ''}`;
  return Object.entries(r).map(([k, v]) => `${t(`field.${k}`, undefined, humanise(k))} ${String(v)}`).join(', ');
}

/** Migration 58: the units of an order in words (the codes are on the Shipment's list). */
export function unitsText(u: { kind?: string; n?: number }[], t: T): string {
  const c = u.filter((x) => x.kind === 'carton'), p = u.filter((x) => x.kind !== 'carton');
  const inC = c.reduce((a, x) => a + Number(x.n ?? 0), 0);
  const parts = [c.length ? t('units.cartons_of', { n: c.length, packs: inC }) : '', p.length ? t('units.loose', { n: p.length }) : ''].filter(Boolean);
  return parts.length ? parts.join(t('units.and')) : '—';
}

/** A worked-out value (footprints.computed): numbers with their unit, text as text, lists as words. Never "NaN". */
export function showComputed(key: string, v: unknown, t: T): string {
  if (v === null || v === undefined || v === '') return '—';
  // migration 58: the cartons and loose packs an order set aside: "3 cartons (60 packs) and 5 loose packs"
  if (key === 'units' && Array.isArray(v)) return unitsText(v as { kind?: string; n?: number }[], t);
  if (key === 'cartons_count' && typeof v === 'number') return t('units.cartons', { n: v });
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
      return `${t(`qp.${p}`, undefined, qp?.label ?? paramName(p))} ${typeof x === 'number' ? number(p, x, qp?.unit) : typeof x === 'boolean' ? t(x ? 'common.yes' : 'common.no') : String(x)}`;
    });
    return parts.length ? parts.join(' · ') : '—';
  }
  if (type === 'footprint[]' && Array.isArray(v)) return t('record.n_lots', { n: v.length });
  if (type === 'number[3]' && Array.isArray(v)) return `${v.map((x) => num(Number(x), 2)).join(' · ')}${fd?.unit ? ` ${fd.unit}` : ''}`;
  if (type === 'date' && typeof v === 'string') return fmtDate(v);
  if (type === 'collection_point') return v === 'farm' ? t('cp.at_farm') : t('cp.a_point');   // its name is with the worked-out values
  if (type === 'mill' || type === 'packing_unit' || type === 'lab' || type === 'qc_sample' || type === 'buyer') return t(`pick.${type}`);    // migration 53: likewise
  if (type === 'client_order') return t('pick.client_order');                                                              // migration 70
  if (type === 'partner') return t('pick.partner');                                                                        // migration 66
  if (type === 'serials' && Array.isArray(v)) return t('ship.codes_n', { n: v.length });                                   // migration 54
  if (type === 'gps' && typeof v === 'object' && !Array.isArray(v)) { const g = v as { lat?: unknown; lng?: unknown }; return `${String(g.lat ?? '')}, ${String(g.lng ?? '')}`; }
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
export function EnteredRows({ payload: raw, fields, stage, params, computed, t }: {
  payload: Record<string, unknown>; fields: FieldDef[]; stage: string; params?: QualityParam[]; computed?: Record<string, unknown> | null; t: T;
}) {
  // migration 52: a GPS field is kept as two numbers (gps_lat, gps_lng) and shown as one; a collection point by its name
  const payload: Record<string, unknown> = { ...raw };
  for (const f of fields.filter((x) => x.type === 'gps')) {
    if ('gps_lat' in payload || 'gps_lng' in payload) { payload[f.key] = { lat: payload.gps_lat, lng: payload.gps_lng }; delete payload.gps_lat; delete payload.gps_lng; }
  }
  // the name of what was picked from a list, from the record's worked-out values (migration 53: the mill, the packing
  // unit, the lab, the sample)
  const NAME_OF: Record<string, string> = { collection_point: 'collection_point', mill: 'mill', packing_unit: 'packing_unit', lab: 'lab', qc_sample: 'sample_code',
    buyer: 'buyer', market_profile: 'market_name', client_order: 'client_order' };   // migration 70: the order's code
  const named = (f: FieldDef) => {
    const k = NAME_OF[f.type];
    if (!k || (f.type === 'collection_point' && payload[f.key] === 'farm')) return null;
    return typeof computed?.[k] === 'string' ? String(computed[k]) : null;
  };
  const known = fields.filter((f) => f.key in payload);
  const extra = Object.keys(payload).filter((k) => !fields.some((f) => f.key === k));
  const label = (f: FieldDef) => t(`field.${stage}.${f.key}`, undefined, t(`field.${f.key}`, undefined, f.label));
  return <>
    {known.map((f) => <Fragment key={f.key}><dt>{label(f)}</dt><dd data-entered={f.key}>{named(f) ?? showEntered(f, f.key, payload[f.key], t, params)}</dd></Fragment>)}
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
