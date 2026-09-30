// Offline maths (decision D10: the server's app.preview_reconcile is the one derivation; a TypeScript mirror exists
// ONLY for offline capture, and only for the two entry stages where field work happens without a network).
// Ported line for line from app.reconcile (migration 4, PRD §7). Any other stage saved offline is marked
// "checked when it syncs": the database decides then, and a refusal comes back to the operator in the outbox.
import type { Preview } from '../lib/types';

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

export function offlinePreview(stage: string, payload: Record<string, unknown>, columns: Record<string, unknown>,
  tolerances: Record<string, number> = {}): OfflinePreview {
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
    return { ok: true, offline: true, provisional: false, qty_in: net, qty_out: net, warnings: [],
      computed: { net_kg: net, moisture_avg: r2((ms[0] + ms[1] + ms[2]) / 3), moisture_min: Math.min(...ms), moisture_max: Math.max(...ms) } };
  }
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
