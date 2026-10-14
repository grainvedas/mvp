// Onboarding at scale (migration 38, Veda's brief of 11 Oct 2026): the shapes the Openings, import, joiners list and
// invite screens read, and the small pure rules they share. What is allowed is decided by the database.
import type { EmployeeStatus, StageType } from './types';
import type { PipelineRow } from './people';
import { callFunction } from './api';

export type HireRole = 'state_manager' | 'client_manager' | 'operator' | 'export_manager' | 'hr' | 'other';
export const HIRE_ROLES: HireRole[] = ['state_manager', 'client_manager', 'operator', 'export_manager', 'hr', 'other'];
export type OpeningStatus = 'open' | 'on_hold' | 'closed';
export interface OpeningNumbers { positions: number; joining: number; joined: number; assigned: number; waiting_wave: number; ready: number; vacant: number }
export interface Opening extends OpeningNumbers {
  id: string; code: string; state_id: string; state_name: string; role: HireRole; stage: StageType | null;
  client_id: string | null; client_name: string | null; scope_id: string | null; scope_name: string | null;
  target_join: string | null; status: OpeningStatus; title: string | null; note: string | null; ready_target: boolean;
  /** migration 46: where it came from ("From requirement by …" / "Created by HR"), and the group of a scope's stages */
  source?: 'hr' | 'requirement'; requested_by_name?: string | null; requirement_line_id?: string | null; group_id?: string | null; group_title?: string | null;
}

/** Pure (migration 46, section D): a state's openings by client, then by scope (or a group made for a scope's stages),
 *  each with its subtotal of the open ones (a closed opening plans nothing, as in the state's total). */
export function groupOpenings(list: Opening[]): { client: string | null; scopes: { key: string; title: string | null; group: boolean; rows: Opening[]; total: OpeningNumbers }[] }[] {
  const out: ReturnType<typeof groupOpenings> = [];
  for (const o of list) {
    let c = out.find((x) => x.client === o.client_name);
    if (!c) { c = { client: o.client_name, scopes: [] }; out.push(c); }
    const key = o.group_id ?? o.scope_id ?? '';
    let s = c.scopes.find((x) => x.key === key);
    if (!s) { s = { key, title: o.group_title ?? o.scope_name, group: !!o.group_id, rows: [], total: Object.fromEntries(NUMBER_KEYS.map((k) => [k, 0])) as unknown as OpeningNumbers }; c.scopes.push(s); }
    s.rows.push(o);
    if (o.status !== 'closed') for (const k of NUMBER_KEYS) (s.total as unknown as Record<string, number>)[k] += Number(o[k] ?? 0);
  }
  return out;
}
export interface OpeningsSummary {
  openings: Opening[]; states: (OpeningNumbers & { state_id: string; state_name: string })[]; total: OpeningNumbers;
  not_linked: number; can_plan: boolean; can_seat: boolean;
}
export const NUMBER_KEYS: (keyof OpeningNumbers)[] = ['positions', 'joining', 'joined', 'assigned', 'waiting_wave', 'ready', 'vacant'];

export type InviteState = 'not_sent' | 'sent' | 'failed' | 'accepted' | 'expired' | 'replaced';
export interface JoinerRow extends PipelineRow {
  role: HireRole | null; stage: StageType | null; opening_id: string | null; opening_code: string | null; state_name: string | null;
  district?: string | null; hr_owner: string | null; hr_owner_name: string | null; invite: { state: InviteState; at: string; expires_at: string } | null;
}
export interface JoinersPage {
  total: number; rows: JoinerRow[]; limit: number; offset: number;
  stats: { joining: number; on_us: number; on_them: number; overdue: number; mine: number };
}
export interface JoinerFilter {
  q: string; state: string; role: string; opening: string; status: '' | 'joining' | 'invited' | 'onboarding' | 'active';
  owner: '' | 'mine' | 'none'; overdue: boolean; waiting: '' | 'us' | 'joiner' | 'it';
}
export const NO_FILTER: JoinerFilter = { q: '', state: '', role: '', opening: '', status: '', owner: '', overdue: false, waiting: '' };
/** Pure: the filter as the server reads it (empty values left out). */
export function filterArgs(f: JoinerFilter, limit: number, offset: number): Record<string, unknown> {
  const o: Record<string, unknown> = { limit, offset };
  for (const [k, v] of Object.entries(f)) if (v !== '' && v !== false && v !== null && v !== undefined) o[k] = typeof v === 'string' ? v.trim() : v;
  return o;
}
export const pageCount = (total: number, size: number) => Math.max(1, Math.ceil(total / size));

// ── the import ─────────────────────────────────────────────────────────────────────────────────────────────────────
export const IMPORT_COLUMNS = ['full_name', 'personal_email', 'phone', 'join_date', 'employment_type', 'designation_band',
  'department', 'job_title', 'reports_to', 'opening', 'state', 'district'] as const;
const SYNONYMS: Record<string, string> = {
  name: 'full_name', full_name: 'full_name', email: 'personal_email', personal_email: 'personal_email', mobile: 'phone', phone: 'phone',
  phone_number: 'phone', mobile_number: 'phone', join_date: 'join_date', joining_date: 'join_date', date_of_joining: 'join_date',
  employment_type: 'employment_type', type: 'employment_type', designation: 'designation_band', designation_band: 'designation_band',
  band: 'designation_band', department: 'department', job_title: 'job_title', title: 'job_title', reports_to: 'reports_to',
  reports_to_email: 'reports_to', manager_email: 'reports_to', opening: 'opening', opening_code: 'opening',
  state: 'state', base_state: 'state', based_in: 'state', district: 'district', base_district: 'district', location: 'district',
};
const iso = (y: number, m: number, d: number) => `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
/** Pure: a date as typed in a spreadsheet → YYYY-MM-DD, or the text as it was (the server says it is not a date). */
export function importDate(v: unknown): string {
  if (v instanceof Date && !Number.isNaN(v.getTime())) return iso(v.getUTCFullYear(), v.getUTCMonth() + 1, v.getUTCDate());
  if (typeof v === 'number' && v > 20000 && v < 80000) {                          // an Excel day number
    const d = new Date(Date.UTC(1899, 11, 30) + v * 864e5); return iso(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate());
  }
  const s = String(v ?? '').trim();
  let m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/); if (m) return iso(+m[1], +m[2], +m[3]);
  m = s.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$/); if (m) return iso(+m[3], +m[2], +m[1]);   // India: day first
  return s;
}
/** Pure: the first sheet → one object per row with the template's column names (common other names accepted). */
export function joinerRows(sheet: unknown[][]): Record<string, string>[] {
  if (!sheet.length) return [];
  const heads = sheet[0].map((h) => SYNONYMS[String(h ?? '').trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '')] ?? '');
  return sheet.slice(1).filter((r) => r.some((c) => c !== null && c !== undefined && String(c).trim() !== '')).map((r) => {
    const o: Record<string, string> = {};
    heads.forEach((h, j) => {
      if (!h) return;
      const v = r[j];
      if (v === null || v === undefined || String(v).trim() === '') return;
      o[h] = h === 'join_date' ? importDate(v) : typeof v === 'number' ? String(Math.round(v)) : String(v).trim();
    });
    return o;
  });
}
export interface ImportRowResult { row: number; name: string; email: string | null; opening: string | null; state?: string | null; role: HireRole | null;
  stage: StageType | null; status: 'ready' | 'warning' | 'error' | 'skipped'; reasons: string[]; id?: string; created?: boolean }
export interface ImportResult { batch: string; dry_run: boolean; rows: ImportRowResult[];
  counts: { rows: number; ready: number; warning: number; error: number; skipped: number; created: number } }

// ── invites ────────────────────────────────────────────────────────────────────────────────────────────────────────
export interface InviteResult { id: string; name: string; link: string | null; expires_at?: string; sent: 'email' | 'not_sent' | 'failed' }
/** Invites for many people, 50 per request (the server function takes at most 100). */
export async function sendInvites(ids: string[]): Promise<{ results: InviteResult[]; skipped: { id: string; name: string | null; reason: string }[]; mail: boolean }> {
  const out = { results: [] as InviteResult[], skipped: [] as { id: string; name: string | null; reason: string }[], mail: false };
  for (let i = 0; i < ids.length; i += 50) {
    const r = await callFunction<typeof out>('invite', { action: 'send', employee_ids: ids.slice(i, i + 50) });
    out.results.push(...r.results); out.skipped.push(...r.skipped); out.mail = r.mail;
  }
  return out;
}
/** Pure: "name — link" lines for pasting into a message to a group. */
export const linksText = (rs: InviteResult[]) => rs.filter((r) => r.link).map((r) => `${r.name} — ${r.link}`).join('\n');

// ── a joiner's own overdue steps (B: reminders in the app) ─────────────────────────────────────────────────────────
export const overdueMine = <T extends { owner: string; status: string; due_on: string; title: string }>(tasks: T[], today: string): T[] =>
  tasks.filter((t) => t.owner === 'hire' && t.status === 'pending' && t.due_on < today);

export const statusIsJoining = (s: EmployeeStatus) => s === 'invited' || s === 'onboarding';

/** Pure: the dictionary key for why one person in a bulk act was refused (the server's English sentence otherwise). */
export function bulkError(msg: string | undefined): string | null {
  const m = (msg ?? '').toLowerCase();
  if (m.startsWith('a statutory step is still open')) return 'bulk.err_statutory';
  if (m.startsWith('steps are still open')) return 'bulk.err_reason';
  if (/^this person is \w+ already/.test(m)) return 'bulk.err_status';
  if (m.startsWith('only hr') || m.startsWith('you cannot give') || m === 'not_allowed') return 'bulk.err_not_allowed';
  return /^[a-z_]+$/.test(m) ? `bulk.err_${m}` : null;
}
