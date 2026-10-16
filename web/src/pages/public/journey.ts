// Shape returned by app.public_lot_journey (migrations 6, 20, 28, 29) and helpers shared by the public page and the labels.
import { rpc } from '../../lib/api';

export interface JourneyStep {
  stage: string; code: string; qty_in_kg: number; qty_out_kg: number; verified_at: string | null; created_at: string;
  /** When the step was recorded on the phone (migration 29). Older servers do not send it. */
  captured_at?: string | null; grade?: string | null;
  /** migration 50 (Part D): the village and the district only; a server before it also sent the name */
  farmer?: { name?: string; village: string; district: string; photo?: string | null };
  farmers?: { name?: string; village: string; district: string; qty_kg: number }[];
  village?: string;
  source?: { type: string; name: string };
  readings?: Record<string, number> | null;
  batch_code?: string; destination?: string; dispatched_on?: string;
  /** migration 55 (C3): how long the lot was in the warehouse */
  days_in_storage?: number;
  /** migration 53 (C5): the lab's verdict per market the lot was judged against (names and verdicts only) */
  markets?: { code: string; name: string; verdict: 'pass' | 'fail' | 'pending'; failed?: string[] }[];
}
export interface Journey {
  qr_code: string; sealed_at: string; ledger_hash: string; batch_codes: string[]; season: string; geography: string;
  /** true when every step was checked by someone other than who recorded it (migration 35); absent on older servers */
  independent?: boolean;
  /** migration 46: some steps were recorded and checked by the same person */
  same_person?: boolean;
  crop: { name: string; gi_tag: string | null; origin: string | null }; client: { name: string; type: string };
  /** migration 49: distinct farmers in the sealed lot, and its GI status (GI only when every source is from the GI area) */
  farmer_count?: number; gi_status?: 'gi' | 'non_gi' | 'unknown';
  verdict: { domestic: string; export: string; overridden: boolean };
  journey: JourneyStep[];
  /** migration 50: the release's status (a recall shows on every pack) and the packs' dates */
  release?: { status: 'active' | 'under_investigation' | 'recalled'; reason?: string | null; at?: string };
  packs?: { n: number; packed_on: string | null; best_before: string | null } | null;
}
/** app.public_pack (migration 50): one pack; before release only what the label says */
export interface PackView { serial: string; batch_code: string; size_kg: number; packed_on: string; best_before: string | null; void: boolean;
  /** migration 56 (D6): this code was scanned far apart or very often and is being checked (or was found copied) */
  copy_warning?: boolean;
  /** migration 56: the client that sells it (named in the copy warning) */
  seller?: string }
export type PublicPack = (Journey & { pack: PackView; released: true })
  | { pack: PackView; released: false; crop: Journey['crop']; season: string; geography: string; gi_status?: Journey['gi_status'] };
export const loadPack = (serial: string) => rpc<PublicPack | null>('public_pack', { p_serial: serial });
export interface ScanCount { counted?: boolean; copy_warning?: boolean }
/** Every scan is counted (time and code, and since migration 56 the approximate place the host saw: city, region,
 *  country, a point rounded to about 10 km; nothing about the person). The host's /api/scan adds the place; where it does
 *  not answer JSON (the local stack, a host without it) the scan is counted without one. A failed count never stops the page. */
export async function countScan(code: string): Promise<ScanCount | null> {
  try {
    const r = await fetch('/api/scan', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code }) });
    if (r.ok && (r.headers.get('content-type') ?? '').includes('application/json')) return (await r.json()) as ScanCount;
  } catch { /* counted below without a place */ }
  try { await rpc('record_scan', { p_code: code }); } catch { /* never stops the page */ }
  return null;
}
export const loadJourney = (code: string) => rpc<Journey | null>('public_lot_journey', { p_qr_code: code });

export const SEASONS: Record<string, string> = { KH: 'Kharif', RB: 'Rabi', ZD: 'Zaid' };
export const seasonName = (code: string) => `${SEASONS[code.slice(0, 2)] ?? code.slice(0, 2)} 20${code.slice(2)}`;

/** The date shown for a step: the day it was recorded. Before migration 29 the page showed the day the NEXT stage verified it. */
export const stepDate = (s: Pick<JourneyStep, 'captured_at' | 'created_at'>) => s.captured_at ?? s.created_at;
