// Shape returned by app.public_lot_journey (migrations 6 + 20) and helpers shared by the public page and the labels.
import { rpc } from '../../lib/api';

export interface JourneyStep {
  stage: string; code: string; qty_in_kg: number; qty_out_kg: number; verified_at: string | null; created_at: string;
  computed?: Record<string, unknown>; grade?: string | null;
  farmer?: { name: string; village: string; district: string; photo?: string | null };
  farmers?: { name: string; village: string; district: string; qty_kg: number }[];
  village?: string;
  source?: { type: string; name: string };
  readings?: Record<string, number> | null;
  batch_code?: string; destination?: string; dispatched_on?: string;
}
export interface Journey {
  qr_code: string; sealed_at: string; ledger_hash: string; batch_codes: string[]; season: string; geography: string;
  crop: { name: string; gi_tag: string | null; origin: string | null }; client: { name: string; type: string };
  verdict: { domestic: string; export: string; overridden: boolean };
  journey: JourneyStep[];
}
export const loadJourney = (code: string) => rpc<Journey | null>('public_lot_journey', { p_qr_code: code });

export const SEASONS: Record<string, string> = { KH: 'Kharif', RB: 'Rabi', ZD: 'Zaid' };
export const seasonName = (code: string) => `${SEASONS[code.slice(0, 2)] ?? code.slice(0, 2)} 20${code.slice(2)}`;
