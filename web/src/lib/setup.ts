// Migration 51 (Veda, 15 Oct 2026: the operator-stages brief, release 4, Part B "set-up lists", A14, A15). The database
// keeps every rule (tests/45_setup_lists.sql); these are the screens' mirrors of them, so a person sees what is wrong
// before the save, and the words the lists, the farmer form, the ledger banner and the roster pool show. All pure.

/** The same place written differently is the same place: letters only, lower case (app.norm_place). */
export const normPlace = (s: string | null | undefined) => (s ?? '').replace(/[^A-Za-z]/g, '').toLowerCase() || null;

/** A GPS point in India, or none (app.valid_gps). */
export const validGps = (lat: number | null, lng: number | null) =>
  (lat === null && lng === null) || (lat !== null && lng !== null && lat >= 6 && lat <= 37.5 && lng >= 68 && lng <= 97.5);

/** "27.2105, 82.9531" (what a map app copies) → the two numbers; anything else → null. */
export function parseGps(text: string): { lat: number; lng: number } | null {
  const m = /^\s*(-?\d{1,2}(?:[.,]\d+)?)\s*[,; ]\s*(-?\d{1,3}(?:[.,]\d+)?)\s*$/.exec(text);
  if (!m) return null;
  const lat = Number(m[1].replace(',', '.')), lng = Number(m[2].replace(',', '.'));
  return Number.isFinite(lat) && Number.isFinite(lng) ? { lat: round6(lat), lng: round6(lng) } : null;
}
export const round6 = (n: number) => Math.round(n * 1e6) / 1e6;

/** What is wrong with the two boxes of a GPS point, as a dictionary key (null: nothing; both empty is "none"). */
export function gpsProblem(lat: string, lng: string): null | 'set.gps_pair' | 'set.gps_number' | 'set.gps_india' {
  const a = lat.trim(), b = lng.trim();
  if (!a && !b) return null;
  if (!a || !b) return 'set.gps_pair';
  const x = Number(a.replace(',', '.')), y = Number(b.replace(',', '.'));
  if (!Number.isFinite(x) || !Number.isFinite(y)) return 'set.gps_number';
  return validGps(x, y) ? null : 'set.gps_india';
}
export const gpsNumber = (s: string) => (s.trim() === '' ? null : round6(Number(s.trim().replace(',', '.'))));

/** Packing materials (pack list, shelf life per material). */
export const MATERIALS = ['pouch', 'jute', 'pp_bag', 'vacuum', 'carton', 'other'] as const;
export type Material = typeof MATERIALS[number];

/** Shelf life per material: whole days from 1 to 3650 (app.shelf_life_ok); empty boxes are left out. */
export function shelfLifeMap(typed: Partial<Record<Material, string>>): { map: Record<string, number>; bad: Material[] } {
  const map: Record<string, number> = {}; const bad: Material[] = [];
  for (const m of MATERIALS) {
    const v = (typed[m] ?? '').trim();
    if (!v) continue;
    const n = Number(v);
    if (!Number.isInteger(n) || n < 1 || n > 3650) bad.push(m); else map[m] = n;
  }
  return { map, bad };
}

/** A place on the state's list (table places): a district row has no block; a block row no village. */
export interface Place { id: string; state_id: string; district: string; block: string | null; village: string | null }
export const districtsOf = (places: Place[], state: string) =>
  places.filter((p) => p.state_id === state && !p.block).map((p) => p.district).sort((a, b) => a.localeCompare(b));
export const blocksOf = (places: Place[], state: string, district: string) =>
  places.filter((p) => p.state_id === state && p.block && !p.village && normPlace(p.district) === normPlace(district)).map((p) => p.block as string).sort((a, b) => a.localeCompare(b));
export const villagesOf = (places: Place[], state: string, district: string, block: string) =>
  places.filter((p) => p.state_id === state && p.village && normPlace(p.district) === normPlace(district) && normPlace(p.block) === normPlace(block))
    .map((p) => p.village as string).sort((a, b) => a.localeCompare(b));
/** A district typed or picked is on the list (a state with no list accepts what is typed: app.district_listed). */
export const districtListed = (places: Place[], state: string, district: string) => {
  const ds = districtsOf(places, state);
  return ds.length === 0 || ds.some((d) => normPlace(d) === normPlace(district));
};
/** Whether a block (and village) is new to the list, so the save adds it first (app.add_place). */
export const placeIsNew = (places: Place[], state: string, district: string, block: string, village: string) => {
  if (!block.trim()) return false;
  if (!blocksOf(places, state, district).some((b) => normPlace(b) === normPlace(block))) return true;
  return !!village.trim() && !villagesOf(places, state, district, block).some((v) => normPlace(v) === normPlace(village));
};

// ---------------------------------------------------------------------------------------------------------------------
// The Client Manager's lists and the State Manager's labs: one editor, driven by these descriptions
// ---------------------------------------------------------------------------------------------------------------------
export type ListKind = 'collection_points' | 'mills' | 'packing_units' | 'buyers' | 'pack_skus' | 'labs';
export const CLIENT_LISTS: ListKind[] = ['collection_points', 'mills', 'packing_units', 'buyers', 'pack_skus'];
export interface ListField { key: string; type: 'text' | 'select' | 'number' | 'crop' | 'gps' | 'country'; options?: readonly string[]; required?: boolean; max?: number }
export const LIST_FIELDS: Record<ListKind, ListField[]> = {
  collection_points: [
    { key: 'name', type: 'text', required: true, max: 80 }, { key: 'kind', type: 'select', options: ['centre', 'field_point', 'store'], required: true },
    { key: 'district', type: 'text', required: true, max: 80 }, { key: 'block', type: 'text', max: 80 }, { key: 'village', type: 'text', max: 80 }, { key: 'gps', type: 'gps' }],
  mills: [
    { key: 'name', type: 'text', required: true, max: 80 }, { key: 'place', type: 'text', required: true, max: 120 }, { key: 'gps', type: 'gps' },
    { key: 'ownership', type: 'select', options: ['own', 'hired'], required: true }, { key: 'dedicated_crop_id', type: 'crop' }],
  packing_units: [
    { key: 'name', type: 'text', required: true, max: 80 }, { key: 'place', type: 'text', required: true, max: 120 },
    { key: 'ownership', type: 'select', options: ['own', 'contract'], required: true }, { key: 'fssai_licence', type: 'text', max: 14 }],
  buyers: [
    { key: 'name', type: 'text', required: true, max: 120 }, { key: 'country', type: 'country', required: true }, { key: 'gstin', type: 'text', max: 15 },
    { key: 'importer_id', type: 'text', max: 60 }, { key: 'address', type: 'text', required: true, max: 300 }, { key: 'fssai_licence', type: 'text', max: 14 },
    { key: 'contact_name', type: 'text', max: 80 }, { key: 'contact_email', type: 'text', max: 120 }, { key: 'contact_phone', type: 'text', max: 16 }],
  pack_skus: [
    { key: 'size', type: 'number', required: true }, { key: 'unit', type: 'select', options: ['kg', 'g'], required: true },
    { key: 'material', type: 'select', options: MATERIALS, required: true }, { key: 'market', type: 'select', options: ['domestic', 'export', 'any'], required: true },
    { key: 'label_type', type: 'select', options: ['sticker', 'printed', 'tag'], required: true }],
  labs: [
    { key: 'name', type: 'text', required: true, max: 120 }, { key: 'kind', type: 'select', options: ['external', 'in_house'], required: true },
    { key: 'accreditation_no', type: 'text', max: 40 }, { key: 'location', type: 'text', required: true, max: 120 }],
};
/** The countries a buyer is in (ISO codes; India first). Another one is typed as its two letters. */
export const COUNTRIES = ['IN', 'AE', 'SA', 'QA', 'OM', 'KW', 'BH', 'GB', 'DE', 'NL', 'FR', 'IT', 'US', 'CA', 'AU', 'SG', 'MY', 'NP', 'BD', 'LK'] as const;

export type ListRow = Record<string, string>;
/** Pure: what is wrong with a row before it is sent, as dictionary keys (the same rules as the tables' checks). */
export function listProblems(kind: ListKind, r: ListRow): string[] {
  const out: string[] = [];
  const v = (k: string) => (r[k] ?? '').trim();
  for (const f of LIST_FIELDS[kind]) {
    if (f.type === 'gps') continue;
    if (f.required && !v(f.key)) { out.push(`set.need_${f.key}`); continue; }
    if (f.type === 'text' && v(f.key) && (f.key === 'name' || f.key === 'place' || f.key === 'district' || f.key === 'location') && v(f.key).length < 2) out.push(`set.short_${f.key}`);
  }
  if (LIST_FIELDS[kind].some((f) => f.type === 'gps')) { const g = gpsProblem(r.lat ?? '', r.lng ?? ''); if (g) out.push(g); }
  if (v('fssai_licence') && !/^[0-9]{14}$/.test(v('fssai_licence'))) out.push('set.bad_fssai');
  if (kind === 'buyers') {
    if (v('country') && !/^[A-Z]{2}$/.test(v('country'))) out.push('set.bad_country');
    if (v('gstin') && !/^[0-9]{2}[A-Z0-9]{13}$/.test(v('gstin').toUpperCase())) out.push('set.bad_gstin');   // sent in capitals (listRow)
    if (v('country') === 'IN' && !v('gstin') && !v('fssai_licence')) out.push('set.buyer_domestic');
    if (v('address') && v('address').length < 5) out.push('set.short_address');
    if (v('contact_email') && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v('contact_email'))) out.push('set.bad_email');
    if (v('contact_phone') && !/^\+?[0-9 ]{8,16}$/.test(v('contact_phone'))) out.push('set.bad_phone');
  }
  if (kind === 'pack_skus' && v('size') && !(Number(v('size').replace(',', '.')) > 0)) out.push('set.bad_size');
  if (kind === 'labs' && v('kind') === 'external' && !v('accreditation_no')) out.push('set.lab_accreditation');
  if (kind === 'labs' && v('accreditation_no') && v('accreditation_no').length < 3) out.push('set.short_accreditation_no');
  return out;
}

/** Pure: the row as the table takes it (empty boxes are nulls; the GPS split into its columns; codes in capitals). */
export function listRow(kind: ListKind, r: ListRow): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const f of LIST_FIELDS[kind]) {
    if (f.type === 'gps') { out.lat = gpsNumber(r.lat ?? ''); out.lng = gpsNumber(r.lng ?? ''); continue; }
    const x = (r[f.key] ?? '').trim();
    if (f.type === 'number') out[f.key] = x === '' ? null : Number(x.replace(',', '.'));
    else if (f.key === 'gstin' || f.key === 'country') out[f.key] = x === '' ? null : x.toUpperCase();
    else out[f.key] = x === '' ? null : x;
  }
  return out;
}

/** "500 g pouch · domestic" */
export const skuLabel = (s: { size: number | string; unit: string; material: string }, materialWord: (m: string) => string) =>
  `${Number(s.size).toLocaleString('en-IN', { maximumFractionDigits: 3 })} ${s.unit} ${materialWord(s.material)}`;

// ---------------------------------------------------------------------------------------------------------------------
// Market profiles (the State Manager's, per crop): parameters from the library with their limits
// ---------------------------------------------------------------------------------------------------------------------
export interface LibraryParam { param: string; name: string; unit: string | null; type: 'number' | 'grade' | 'yesno'; method: string | null; done_by: string; grp: string; sort_order: number;
  /** Migration 52: the same test under a second name points at the first; it is not offered again. */
  alias_of?: string | null }
export interface ProfileParam { param: string; operator?: string; limit?: number; pass?: string[] | boolean }
export interface MarketProfile { id: string; crop_id: string; code: string; name: string; version: number; status: 'draft' | 'active' | 'retired';
  params: ProfileParam[]; export_docs: string[]; source_file_id: string | null; source_note: string | null; created_at: string; activated_at: string | null }
/** Pure: the first problem of a profile's parameters, as the server words it (app.profile_params_problems). */
export function profileProblem(params: ProfileParam[], lib: LibraryParam[]): { key: string; vars?: Record<string, string> } | null {
  const seen = new Set<string>();
  for (const x of params) {
    const l = lib.find((p) => p.param === x.param);
    if (!l) return { key: 'set.prof_not_in_library', vars: { param: x.param || '?' } };
    if (seen.has(l.param)) return { key: 'set.prof_twice', vars: { param: l.name } };
    seen.add(l.param);
    if (l.type === 'number' && (!['<=', '>=', '<', '>'].includes(x.operator ?? '') || typeof x.limit !== 'number' || !Number.isFinite(x.limit))) return { key: 'set.prof_limit', vars: { param: l.name } };
    if (l.type === 'grade' && (!Array.isArray(x.pass) || x.pass.length === 0)) return { key: 'set.prof_grades', vars: { param: l.name } };
    if (l.type === 'yesno' && typeof x.pass !== 'boolean') return { key: 'set.prof_yesno', vars: { param: l.name } };
  }
  return null;
}
/** Pure: the versions of one profile, newest first; which one is in use. */
export function profileVersions(all: MarketProfile[], crop: string, code: string) {
  const v = all.filter((p) => p.crop_id === crop && p.code === code).sort((a, b) => b.version - a.version);
  return { versions: v, active: v.find((p) => p.status === 'active') ?? null, draft: v.find((p) => p.status === 'draft') ?? null };
}
/** Pure: one limit in words ("≤ 10 µg/kg"; grades "A, B"; yes/no). */
export const limitWords = (x: ProfileParam, l: LibraryParam | undefined, yes: string, no: string) =>
  !l ? x.param : l.type === 'number' ? `${(x.operator ?? '<=').replace('<=', '≤').replace('>=', '≥')} ${x.limit ?? '—'}${l.unit ? ` ${l.unit}` : ''}`
    : l.type === 'grade' ? (Array.isArray(x.pass) ? x.pass.join(', ') : '—') : x.pass === true ? yes : x.pass === false ? no : '—';

// ---------------------------------------------------------------------------------------------------------------------
// A14 the ledger banner; A15 the roster pool
// ---------------------------------------------------------------------------------------------------------------------
export interface LedgerStatus { checked_at: string | null; ok: boolean | null; blocks: number | null; source: string | null; blocks_now: number; added_since: number }
/** Pure: which sentence the banner says ("Last full check 2:00 am: 18 blocks intact · 34 blocks added since"). */
export function ledgerBanner(s: LedgerStatus, now = Date.now()): { key: string; tone: 'muted' | 'warn' | 'error' } {
  if (!s.checked_at) return { key: 'led.never', tone: 'warn' };
  if (s.ok === false) return { key: 'home.ledger_bad', tone: 'error' };
  if (now - new Date(s.checked_at).getTime() > 36 * 3600 * 1000) return { key: 'home.ledger_stale', tone: 'warn' };
  return { key: s.added_since > 0 ? 'led.since' : 'led.none_since', tone: 'muted' };
}

export interface Elsewhere { scope_id: string; label: string; status: string; client: string; stages: string[] }
export interface PoolPerson { id: string; name: string; me?: boolean; ready_for?: string | null; elsewhere?: Elsewhere[] }
/** Pure: "Milling on KH26 · gkp (active)", one per scope. */
export const elsewhereLine = (e: Elsewhere, t: (k: string, v?: Record<string, string | number>, f?: string) => string) =>
  t('pool.work', { stages: e.stages.map((s) => t(`stage.${s}`, undefined, s)).join(', '), scope: e.label, status: t(`pool.st_${e.status}`, undefined, e.status) });
/** Pure: the pool in its two groups, free people first (the server orders them; a person in both is impossible). */
export const poolGroups = <P extends PoolPerson>(pool: P[]) => ({
  free: pool.filter((p) => !(p.elsewhere?.length)), busy: pool.filter((p) => (p.elsewhere?.length ?? 0) > 0) });
