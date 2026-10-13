// The farmer register of a state (migration 43, Veda 13 Oct 2026). Pure helpers, unit-tested in tests/farmer_register.test.ts.

export type RegisterFlag = 'duplicate' | 'over_yield' | 'no_gi_land';
export const REGISTER_FLAGS: RegisterFlag[] = ['duplicate', 'over_yield', 'no_gi_land'];

export interface RegisterRow {
  id: string; farmer_code: string | null; name: string; guardian_name: string; village: string; district: string;
  client: string; client_id: string; status: 'draft' | 'under_review' | 'active' | 'inactive';
  phone_last4: string; land_area_acres: number | null; gi_land_acres: number | null;
  sold_kg: number | null; expected_kg: number | null; ratio: number | null;
  flags: RegisterFlag[]; duplicates: { id: string; name: string; farmer_code: string | null; client: string }[];
}
export interface RegisterCards {
  farmers: number; active: number; under_review: number; draft: number; inactive: number;
  gi_acres: number; land_acres: number; sold_kg: number; expected_kg: number; selling: number;
  over_yield: number; duplicates: number; no_gi_land: number;
  by_district: { district: string; farmers: number; sold_kg: number; gi_acres: number }[];
}
export interface Register {
  state: { id: string; name: string }; season: string | null; seasons: string[]; total: number;
  rows: RegisterRow[]; cards: RegisterCards;
  filters: { clients: { id: string; name: string }[]; districts: string[] }; limit: number; offset: number;
}
export interface RegisterFilter { season: string; client: string; district: string; status: string; flag: string; q: string }
export const NO_FILTER: RegisterFilter = { season: '', client: '', district: '', status: '', flag: '', q: '' };
export const PAGE = 25;

/** The request to app.farmer_register: empty filters are left out, the page becomes limit/offset. */
export function registerParams(state: string, f: RegisterFilter, page: number) {
  const p: Record<string, string | number> = { state, limit: PAGE, offset: Math.max(0, page) * PAGE };
  for (const k of ['season', 'client', 'district', 'status', 'flag', 'q'] as const) {
    const v = f[k].trim();
    if (v) p[k] = v;
  }
  return p;
}

/** A phone on this screen: never the number, only its last four digits. */
export const maskedPhone = (last4: string | null | undefined) => (last4 ? `••••••${String(last4).slice(-4)}` : '—');

/** What the farmer sold this season as a share of what his GI land should give; null when nothing is expected. */
export function yieldShare(sold: number | string | null | undefined, expected: number | string | null | undefined): number | null {
  const s = Number(sold ?? 0), e = Number(expected ?? 0);
  if (!(e > 0) || sold === null || sold === undefined) return null;
  return Math.round((s / e) * 100);
}

/** How the share reads: within, above (warned on the lot), or past 120 % (flagged for the State Manager). */
export const yieldLevel = (pct: number | null): 'none' | 'within' | 'above' | 'flagged' =>
  pct === null ? 'none' : pct > 120 ? 'flagged' : pct > 100 ? 'above' : 'within';

/** The Farmer ID needs the GI land (and the database also refuses it while a possible duplicate is open). */
export const needsGiLand = (f: { gi_land_acres?: number | string | null }) =>
  f.gi_land_acres === null || f.gi_land_acres === undefined || String(f.gi_land_acres).trim() === '';

/** The GI land typed in the form: empty is allowed on a draft; otherwise more than 0 and not more than the land. */
export function giLandProblem(gi: string, land: string): 'gi_positive' | 'gi_over_land' | null {
  const g = gi.trim().replace(',', '.');
  if (!g) return null;
  const n = Number(g), l = Number(land.trim().replace(',', '.'));
  if (!Number.isFinite(n) || n <= 0) return 'gi_positive';
  if (Number.isFinite(l) && l > 0 && n > l) return 'gi_over_land';
  return null;
}
