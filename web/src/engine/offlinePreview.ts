// Offline maths (decision D10: the server's app.preview_reconcile is the one derivation; a TypeScript mirror exists
// ONLY for offline capture, and only for the stages where field work happens without a network: the two entry stages
// and, from migration 52, the Collection Batch).
// Ported line for line from app.reconcile (migration 4, PRD §7). Any other stage saved offline is marked
// "checked when it syncs": the database decides then, and a refusal comes back to the operator in the outbox.
import type { GiStatus, Preview } from '../lib/types';
import { validGps } from '../lib/setup';

export type OfflinePreview = Preview & { offline: true; provisional: boolean };

const num = (p: Record<string, unknown>, k: string): number | null => {
  const v = p[k];
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string' && /^-?[0-9]+(\.[0-9]+)?$/.test(v)) return Number(v);
  return null;
};
const r2 = (x: number) => Math.round(x * 100) / 100;
const r3 = (x: number) => Math.round(x * 1000) / 1000;
const refuse = (error: string): OfflinePreview => ({ ok: false, error, offline: true, provisional: false });
const has = (p: Record<string, unknown>, k: string) => p[k] !== undefined && p[k] !== null && p[k] !== '';
const fix = (x: number, d: number) => x.toFixed(d);                 // round(x, d) as PostgreSQL prints it ("2.0")
/** numeric as PostgreSQL prints a stored number (14 → "14", 1.5 → "1.5") */
const pgNum = (x: number) => String(x);

/** Migration 52: what the phone knows of the scope, the crop and the lots, for the offline mirror. */
export interface OfflineRules {
  procurement_details_required?: boolean; record_price?: boolean;
  /** the crop's moisture limit (its quality parameter moisture_pct, "≤" limit) */ moisture_limit?: number | null;
  thresholds?: Record<string, number> | null;
  /** the lots offered to a Collection Batch, as the phone last saw them (app.incoming_lots) */
  lots?: Map<string, BatchLot>;
}
export interface BatchLot { id: string; code: string; qty: number; point: string; point_name: string | null; village: string | null;
  farmer_id: string | null; moisture_avg: number | null; gi_status: GiStatus }

/** app.payment_problem (migration 52), line for line. */
export function paymentProblem(p: Record<string, unknown>): string | null {
  const price = has(p, 'price_per_quintal') ? num(p, 'price_per_quintal') : 1;
  const st = has(p, 'payment_status') ? String(p.payment_status) : 'pending';
  const mode = has(p, 'payment_mode') ? String(p.payment_mode) : null;
  const ref = has(p, 'txn_ref') ? String(p.txn_ref).trim() : '';
  if (has(p, 'price_per_quintal') && price === null) return 'the price per quintal is a number';
  if (price !== null && price <= 0) return 'the price per quintal is more than 0';
  if (!['pending', 'paid'].includes(st)) return 'the payment is paid or pending';
  if (mode !== null && !['bank', 'upi', 'cash'].includes(mode)) return 'the payment is by bank, UPI or cash';
  if (st === 'paid' && mode === null) return 'say how it was paid (bank, UPI or cash)';
  if (st === 'paid' && mode !== 'cash' && !ref) return 'give the transaction ID of the payment';
  if (ref && !/^[A-Za-z0-9/-]{4,40}$/.test(ref)) return 'a transaction ID is 4 to 40 letters or digits (never an account number)';
  return null;
}
const PAY = ['price_per_quintal', 'payment_status', 'payment_mode', 'txn_ref'];

export function offlinePreview(stage: string, payload: Record<string, unknown>, columns: Record<string, unknown>,
  tolerances: Record<string, number> = {}, rules: OfflineRules = {}): OfflinePreview {
  // the price and the payment (migration 52): kept apart from the record, checked as the save checks them
  if (PAY.some((k) => has(payload, k))) {
    if (stage !== 'procurement') return refuse('price and payment are recorded at Procurement');
    if (!rules.record_price) return refuse('this scope does not record price and payment (its Client Manager turns it on)');
    const pp = paymentProblem(payload);
    if (pp) return refuse(`payment: ${pp}`);
  }
  if (stage === 'procurement') {
    const gross = num(payload, 'gross_kg'), bags = num(payload, 'bags'), tare = num(payload, 'tare_kg_per_bag');
    if (gross === null || bags === null || tare === null) return refuse('gross_kg, bags and tare_kg_per_bag are required numbers');
    const m = payload.moisture_pct;
    if (!Array.isArray(m) || m.length !== 3 || m.some((x) => typeof x !== 'number' || !Number.isFinite(x)))
      return refuse('payload.moisture_pct must be an array of 3 readings');
    const net = r3(gross - bags * tare);
    if (net <= 0) return refuse('net weight must be positive (gross - bags x tare)');
    if (!columns.farmer_id) return refuse('procurement requires farmer_id');
    const ms = m as number[];
    const avg = (ms[0] + ms[1] + ms[2]) / 3, lo = Math.min(...ms), hi = Math.max(...ms);
    const computed: Record<string, unknown> = { net_kg: net, moisture_avg: r2(avg), moisture_min: lo, moisture_max: hi };
    // migration 52 (C1): where it was weighed, its GPS, who delivered it. A collection point is checked against the
    // client's list when the record reaches the server (the phone's copy of the list may be old).
    const cp = has(payload, 'collection_point_id') ? String(payload.collection_point_id).trim() : null;
    if (cp === 'farm') computed.collection_point = 'farm';
    if (has(payload, 'gps_lat') || has(payload, 'gps_lng')) {
      const la = num(payload, 'gps_lat'), ln = num(payload, 'gps_lng');
      if (la === null || ln === null || !validGps(la, ln)) return refuse('procurement: the GPS point is two numbers in India');
    }
    const by = has(payload, 'delivered_by') ? String(payload.delivered_by) : 'farmer';
    if (!['farmer', 'family', 'agent'].includes(by)) return refuse('procurement: delivered by the farmer, his family or an agent');
    if (by === 'agent' && String(payload.agent_name ?? '').trim().length < 2) return refuse('procurement: name the agent who delivered the lot');
    if (has(payload, 'condition') && !['good', 'damp', 'pest', 'mixed'].includes(String(payload.condition)))
      return refuse('procurement: the condition is good, damp, pest or mixed');
    if (rules.procurement_details_required) {
      if (!cp) return refuse('procurement: say where the lot was weighed (a collection point, or at the farm)');
      if (!has(payload, 'gps_lat')) return refuse('procurement: the GPS of where the lot was weighed is required');
      if (!has(payload, 'delivered_by')) return refuse('procurement: say who delivered the lot (the farmer, his family or an agent)');
    }
    const warnings: string[] = [];
    const lim = rules.moisture_limit;
    if (lim !== null && lim !== undefined && avg > lim) warnings.push(`moisture ${fix(avg, 1)} % is above the crop's limit of ${pgNum(lim)} %`);
    const spread = rules.thresholds?.moisture_spread_pct ?? 1.5;
    if (hi - lo > spread) warnings.push(`the moisture readings are ${fix(hi - lo, 1)} points apart (more than ${pgNum(spread)}): read them again`);
    return { ok: true, offline: true, provisional: false, qty_in: net, qty_out: net, warnings, computed };
  }
  if (stage === 'village_batch') return batchPreview(payload, rules);
  if (stage === 'lot_inward') {
    const declared = num(payload, 'declared_kg'), weighed = num(payload, 'weighed_kg');
    if (declared === null || weighed === null) return refuse('declared_kg and weighed_kg are required numbers');
    if (weighed <= 0) return refuse('weighed_kg must be positive');
    if (!payload.source_type || !payload.source_name) return refuse('payload.source_type and source_name are required');
    if (num(payload, 'moisture_pct') === null) return refuse('moisture_pct is required');
    const variancePct = declared > 0 ? r2(((declared - weighed) / declared) * 100) : null;
    const tol = tolerances.lot_inward_variance_pct ?? 2;
    return { ok: true, offline: true, provisional: false, qty_in: weighed, qty_out: weighed,
      computed: { variance_kg: r3(declared - weighed), variance_pct: variancePct },
      warnings: declared > 0 && Math.abs(declared - weighed) / declared * 100 > tol ? ['declared vs weighed variance exceeds tolerance'] : [] };
  }
  return { ok: true, offline: true, provisional: true, warnings: [] };
}

/** The Collection Batch (migration 52, C2), as app.reconcile works it out, from the lots the phone last saw. A lot the
 *  phone does not know (or an empty list) leaves the batch "checked when it syncs". */
function batchPreview(payload: Record<string, unknown>, rules: OfflineRules): OfflinePreview {
  const ids = Array.isArray(payload.source_footprint_ids) ? (payload.source_footprint_ids as string[]) : [];
  const lots = ids.map((id) => rules.lots?.get(id));
  if (!ids.length || lots.some((l) => !l)) return { ok: true, offline: true, provisional: true, warnings: [] };
  const ls = lots as BatchLot[];
  const total = r3(ls.reduce((a, l) => a + l.qty, 0));
  if (total <= 0) return refuse('village_batch needs payload.source_footprint_ids with quantity');
  if (ls.some((l) => l.gi_status === 'gi') && ls.some((l) => l.gi_status === 'non_gi'))
    return refuse(`GI and non-GI lots are not batched together (${ls.map((l) => `${l.code} ${l.gi_status.replace('_', '-')}`).join(', ')})`);
  const points = new Set(ls.map((l) => l.point));
  if (points.size > 1) {
    const where = (l: BatchLot) => l.point_name ?? (l.point === 'farm' ? 'at the farm' : 'no place recorded');
    return refuse(`collection batch: the lots are from different collection points (${[...ls].sort((a, b) => a.code.localeCompare(b.code)).map((l) => `${l.code} ${where(l)}`).join(', ')}): a batch is the lots at one place`);
  }
  // villages with their share, largest first (the same village written differently is one village)
  const byVillage = new Map<string, { village: string; kg: number }>();
  for (const l of ls) {
    const k = (l.village ?? '').toLowerCase().replace(/[^a-z]/g, '')                        /* app.norm_place */;
    const g = byVillage.get(k);
    if (g) { g.kg += l.qty; if ((l.village ?? '') < g.village) g.village = l.village ?? ''; } else byVillage.set(k, { village: l.village ?? '', kg: l.qty });
  }
  const villages = [...byVillage.values()].sort((a, b) => b.kg - a.kg || a.village.localeCompare(b.village))
    .map((g) => ({ village: g.village, kg: r3(g.kg), share_pct: Math.round(g.kg / total * 1000) / 10 }));
  if (payload.single_origin === true && villages.length > 1)
    return refuse(`collection batch: a single-origin batch is from one village (these lots are from ${villages.map((v) => v.village).join(', ')})`);
  const withM = ls.filter((l) => l.moisture_avg !== null);
  const mKg = withM.reduce((a, l) => a + l.qty, 0);
  const moisture = mKg > 0 ? r2(withM.reduce((a, l) => a + l.qty * (l.moisture_avg as number), 0) / mKg) : null;
  const bags = has(payload, 'bags') ? num(payload, 'bags') : null;
  if (bags !== null && bags < 1) return refuse('collection batch: the bags are 1 or more');
  const fresh = has(payload, 'moisture_fresh_pct') ? num(payload, 'moisture_fresh_pct') : null;
  if (fresh !== null && (fresh < 0 || fresh >= 100)) return refuse('moisture must be below 100');
  const warnings: string[] = [];
  let out = total;
  const computed: Record<string, unknown> = { source_count: ids.length, total_kg: total, farmers: new Set(ls.map((l) => l.farmer_id)).size,
    villages, moisture_avg: moisture, collection_point: ls[0].point === '' ? null : ls[0].point === 'farm' ? 'farm' : ls[0].point_name };
  if (has(payload, 'reweighed_kg')) {
    const e = num(payload, 'reweighed_kg');
    if (e === null || e <= 0) return refuse('collection batch: the re-weighed total is more than 0');
    if (e > total + 0.01)                                         /* app.kg_tolerance() */ return refuse(`collection batch: the re-weighed total (${pgNum(e)} kg) is more than the lots (${pgNum(total)} kg)`);
    out = Math.min(e, total);
    const lossPct = (total - out) / total * 100;
    if (lossPct > (rules.thresholds?.batch_loss_pct ?? 1)) warnings.push(`the batch weighs ${fix(total - out, 1)} kg (${fix(lossPct, 1)} %) less than its lots`);
    computed.loss_kg = r3(total - out);
  }
  return { ok: true, offline: true, provisional: false, qty_in: total, qty_out: out, warnings, computed };
}
