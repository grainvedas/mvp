// Identity layer (migrations 31–33): the shapes the people screens read, and the small pure rules they share.
// Everything that decides ACCESS is in the database; what is here only shapes what is typed and what is shown.
import type { EmployeeStatus, EmploymentType, Lens, OpRole, StageType, SystemRole } from './types';

export interface AssignmentInfo {
  id: string; lens: Lens; op_role: OpRole; scope_id: string | null; client_id: string | null; client_name: string | null;
  state_id: string | null; state_name: string | null; label: string; scope_status: string | null; stages: StageType[];
  posting: string | null; season_code: string | null; ends_on: string | null; lapsed: boolean; active: boolean;
  created_at: string; ended_at: string | null; end_reason: string | null; created_by: string | null; can_end: boolean;
}
export interface OrgFacts {
  employment_type: EmploymentType | null; designation_band: string | null; department: string | null; job_title: string | null;
  reports_to?: string | null; buddy?: string | null; reports_to_name?: string | null; buddy_name?: string | null;
}
export interface DirectoryPerson {
  id: string; name: string; email: string | null; phone: string | null; status: EmployeeStatus; system_role: SystemRole;
  external: boolean; join_date: string | null; has_login: boolean; org: OrgFacts;
  assignments: AssignmentInfo[]; elsewhere: number; unassigned: boolean;
}
export interface Profile {
  identity: { id: string; name: string; email: string | null; phone: string | null; status: EmployeeStatus; external: boolean;
    join_date: string | null; created_at: string; has_login: boolean };
  org: OrgFacts; system_role: SystemRole; assignments: AssignmentInfo[]; history: AssignmentInfo[]; elsewhere: number;
  exits: { exit_date: string; reason: string | null }[];
  can: { assign: boolean; suspend: boolean; reinstate: boolean; offboard: boolean; rehire: boolean; reset_login: boolean; set_role: boolean; hr_record: boolean };
}
export type TaskOwner = 'hire' | 'hr' | 'it';
export type TaskKind = 'sign' | 'identity' | 'bank' | 'countersign' | 'nomination' | 'it' | 'buddy' | 'goals' | 'other';
export interface Task {
  id: string; seq: number; code: string; title: string; owner: TaskOwner; due_on: string; statutory: boolean; kind: TaskKind;
  status: 'pending' | 'done'; done_at: string | null; note: string | null; overdue?: boolean; done_by?: string | null;
}
export interface MaskedDocs {
  pan_last4: string | null; aadhaar_last4: string | null; bank_name: string | null; bank_ifsc: string | null; bank_last4: string | null;
  pf_uan_last4: string | null; gratuity_nominee: string | null; nominee_relation: string | null; form16_ref?: string | null;
}
export interface HrFile { id: string; kind: string; file_name: string | null; storage_path?: string; task_id: string | null; created_at: string; uploaded_by?: string | null }
export interface Goal { id: string; horizon: 30 | 60 | 90; goal: string }
export interface Contact { name: string; email: string | null; phone: string | null }
export interface MyOnboarding {
  status: EmployeeStatus; name: string; join_date: string | null; today: string; days_to_join: number | null;
  org: OrgFacts; reports_to: Contact | null; buddy: Contact | null; docs: MaskedDocs; files: HrFile[]; tasks: Task[]; goals: Goal[];
}
export interface PipelineRow {
  id: string; name: string; email: string | null; phone: string | null; status: EmployeeStatus; system_role: SystemRole;
  join_date: string | null; days_to_join: number | null; has_login: boolean; employment_type: EmploymentType | null;
  job_title: string | null; department: string | null; total: number; done: number; overdue: number; pct: number;
  blocked_by: TaskOwner | null; next_task: string | null; next_due: string | null; waiting_on?: TaskOwner[];
}
/** Whose turn is it? Everyone with a task due by today; if nobody is late, whoever owns the next task. Pure. */
export function waitingOn(r: Pick<PipelineRow, 'blocked_by' | 'waiting_on'>): TaskOwner[] {
  const due = r.waiting_on ?? [];
  return due.length > 0 ? (['hire', 'hr', 'it'] as TaskOwner[]).filter((o) => due.includes(o)) : r.blocked_by ? [r.blocked_by] : [];
}
export const onUs = (r: Pick<PipelineRow, 'blocked_by' | 'waiting_on'>) => waitingOn(r).some((o) => o !== 'hire');
export const onThem = (r: Pick<PipelineRow, 'blocked_by' | 'waiting_on'>) => waitingOn(r).includes('hire');
export interface JoinerDetail {
  person: { id: string; name: string; email: string | null; phone: string | null; status: EmployeeStatus; system_role: SystemRole;
    join_date: string | null; created_at: string; days_to_join: number | null; has_login: boolean; created_by: string | null };
  can_manage: boolean; org: OrgFacts; docs: MaskedDocs; files: HrFile[]; tasks: Task[];
  /** "Mark as joined", as app.activate_joiner decides it (migration 36); absent on an older server. */
  can_activate?: boolean;
  notes: { id: number; note: string; at: string; by: string | null }[]; goals: Goal[];
  exits: { exit_date: string; reason: string | null; final_settlement: string | null; form16_ref: string | null; at: string }[];
  assignments: number;
}
export interface Warning { code: string; [k: string]: unknown }
export interface Roster {
  scope: { id: string; status: string; season_code: string; geography: string; season_end: string | null; client_id: string; client_name: string;
    crop_name: string; state_id: string; state_name: string };
  can_manage: boolean; gaps: StageType[];
  stages: { stage: StageType; position: number; label: string;
    holders: { assignment_id: string; employee_id: string; name: string; status: EmployeeStatus; posting: string | null; since: string; lapsed: boolean }[] }[];
  managers: { employee_id: string; name: string; op_role: OpRole; status: EmployeeStatus }[];
}
export interface StateOverviewData {
  state: { id: string; name: string; code: string } | null;
  supervisors: { employee_id: string; name: string; status: EmployeeStatus }[];
  scopes: { scope_id: string; client_id: string; client_name: string; crop_name: string; season_code: string; geography: string; status: string;
    stages: number; gaps: StageType[]; people: number }[];
  clients: number; people: number; unassigned: number;
}
export interface Seat { id: string; name: string; email: string | null; status: EmployeeStatus; has_login?: boolean; system_role?: SystemRole }
export interface Seats { admins: Seat[]; hr_admin: Seat | null; hr_resources: Seat[]; candidates: Seat[]; daily_code: { on: boolean; without_email: number } }
export interface AuditLine {
  id: number; at: string; action: string; flagged: boolean; detail: Record<string, unknown>; actor: string | null; actor_name: string;
  actor_role: SystemRole | null; target: string | null; target_name: string | null;
}

export const DESIGNATION_BANDS = ['Trainee', 'Associate', 'Executive', 'Senior Executive', 'Manager', 'Senior Manager', 'Head'] as const;
export const EMPLOYMENT_TYPES: EmploymentType[] = ['full_time', 'intern', 'contract', 'consultant'];
export const FILE_KINDS = ['offer_letter', 'nda', 'pan', 'aadhaar', 'bank_proof', 'contract', 'pf_form', 'form16', 'other'] as const;

/** Statutory tasks (PF, gratuity) are for full-time employees only. Mirrors app.stamp_tasks; used for the hint on the form. */
export const skipsStatutory = (t: EmploymentType | '' | null | undefined) => !!t && t !== 'full_time';

// ── identity numbers: checked in full on the device, sent as their last four characters only ──
/** PAN: five letters, four digits, one letter. */
export const validPan = (s: string) => /^[A-Z]{5}[0-9]{4}[A-Z]$/.test(s.trim().toUpperCase());

const VD = [[0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 2, 3, 4, 0, 6, 7, 8, 9, 5], [2, 3, 4, 0, 1, 7, 8, 9, 5, 6], [3, 4, 0, 1, 2, 8, 9, 5, 6, 7],
  [4, 0, 1, 2, 3, 9, 5, 6, 7, 8], [5, 9, 8, 7, 6, 0, 4, 3, 2, 1], [6, 5, 9, 8, 7, 1, 0, 4, 3, 2], [7, 6, 5, 9, 8, 2, 1, 0, 4, 3],
  [8, 7, 6, 5, 9, 3, 2, 1, 0, 4], [9, 8, 7, 6, 5, 4, 3, 2, 1, 0]];
const VP = [[0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 5, 7, 6, 2, 8, 3, 0, 9, 4], [5, 8, 0, 3, 7, 9, 6, 1, 4, 2], [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
  [9, 4, 5, 3, 1, 2, 6, 8, 7, 0], [4, 2, 8, 6, 5, 7, 3, 9, 0, 1], [2, 7, 9, 3, 8, 0, 6, 4, 1, 5], [7, 0, 4, 6, 9, 1, 3, 2, 5, 8]];
/** Aadhaar: twelve digits, not starting with 0 or 1, with a valid Verhoeff check digit (catches a mistyped digit). */
export function validAadhaar(s: string): boolean {
  const d = s.replace(/[\s-]/g, '');
  if (!/^[2-9][0-9]{11}$/.test(d)) return false;
  let c = 0;
  [...d].reverse().forEach((ch, i) => { c = VD[c][VP[i % 8][Number(ch)]]; });
  return c === 0;
}
export const validIfsc = (s: string) => /^[A-Z]{4}0[A-Z0-9]{6}$/.test(s.trim().toUpperCase());
export const validAccount = (s: string) => /^[0-9]{9,18}$/.test(s.replace(/[\s-]/g, ''));
/** The only part of a number that leaves the device. */
export const last4 = (s: string) => s.replace(/[\s-]/g, '').toUpperCase().slice(-4);
export const masked = (v: string | null | undefined) => (v ? `•••• ${v}` : '—');

// ── the joiner's checklist ──
/** A hire's own tasks open one at a time, in order: the first one still pending is open, later ones wait. */
export function taskState(tasks: Task[], t: Task): 'done' | 'open' | 'locked' | 'ours' {
  if (t.status === 'done') return 'done';
  if (t.owner !== 'hire') return 'ours';
  const firstOpen = tasks.filter((x) => x.owner === 'hire' && x.status === 'pending').sort((a, b) => a.seq - b.seq)[0];
  return firstOpen?.id === t.id ? 'open' : 'locked';
}
export const progress = (tasks: { status: string }[]) => {
  const total = tasks.length, done = tasks.filter((t) => t.status === 'done').length;
  return { total, done, pct: total === 0 ? 100 : Math.round((done * 100) / total) };
};
/** "in 5 days" / "today" / "3 days ago" as a key and a number, for t(). */
export function countdown(days: number | null | undefined): { key: 'join.unknown' | 'join.today' | 'join.in_days' | 'join.tomorrow' | 'join.days_ago'; n: number } {
  if (days === null || days === undefined) return { key: 'join.unknown', n: 0 };
  if (days === 0) return { key: 'join.today', n: 0 };
  if (days === 1) return { key: 'join.tomorrow', n: 1 };
  return days > 0 ? { key: 'join.in_days', n: days } : { key: 'join.days_ago', n: -days };
}

// ── the directory ──
export interface DirectoryFilter { text: string; client: string; state: string; status: '' | EmployeeStatus; unassigned: boolean; kind: 'employees' | 'client_logins' }
/** Pure: the two lenses are independent filters. A person matches a lens when one of the assignments the reader may see looks through it. */
export function filterPeople(people: DirectoryPerson[], f: DirectoryFilter): DirectoryPerson[] {
  const needle = f.text.trim().toLowerCase();
  return people.filter((p) => {
    if ((f.kind === 'client_logins') !== p.external) return false;
    if (f.status && p.status !== f.status) return false;
    if (f.unassigned && !p.unassigned) return false;
    if (f.client && !p.assignments.some((a) => a.client_id === f.client)) return false;
    if (f.state && !p.assignments.some((a) => a.state_id === f.state)) return false;
    if (needle && ![p.name, p.email, p.phone, p.org?.job_title, p.org?.department].some((x) => (x ?? '').toLowerCase().includes(needle))) return false;
    return true;
  });
}
/** Which colour a status or an access badge wears (tokens in styles.css). */
export const statusTone: Record<EmployeeStatus, string> = { invited: 'draft', onboarding: 'pending', active: 'verified', suspended: 'fail', offboarded: 'closed' };
export const lensTone: Record<Lens, string> = { scope: 'lens-scope', client: 'lens-client', state: 'lens-state' };

/** Which stage is given or taken when a box on the roster is changed; whether the last stage of an operator is going. */
export function stagesAfter(current: StageType[], stage: StageType, on: boolean): StageType[] {
  return on ? (current.includes(stage) ? current : [...current, stage]) : current.filter((s) => s !== stage);
}

/** A file name safe for a storage path, keeping its extension. */
export function safeFileName(name: string): string {
  const dot = name.lastIndexOf('.');
  const ext = dot > 0 ? name.slice(dot + 1).toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 5) : '';
  const base = (dot > 0 ? name.slice(0, dot) : name).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'file';
  return ext ? `${base}.${ext}` : base;
}

/** A code for a task added in the template builder: from its title, unique within the template. */
export function taskCode(title: string, taken: string[]): string {
  const base = title.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 32) || 'task';
  let code = base.length < 2 ? `${base}_task` : base, n = 2;
  while (taken.includes(code)) code = `${base.slice(0, 29)}_${n++}`;
  return code;
}
