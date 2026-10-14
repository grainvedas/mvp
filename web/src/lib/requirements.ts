// Requirements (migration 46, Veda 14 Oct 2026, "GrainVeda MVP — HR requirements list and staffing a scope"): a need
// for people raised once by whoever owns it, in lines (role, stage, how many, where, by when); HR publishes, returns,
// declines or holds each line. These are the shapes the server sends and the pure rules the screens share.
import type { StageType } from './types';

export type LineRole = 'client_manager' | 'operator' | 'export_manager' | 'other';
export type LineStatus = 'requested' | 'returned' | 'held' | 'published' | 'filled' | 'withdrawn' | 'declined';
/** What a person reads: the stored status, and while published, whether someone is joining or ready on its opening. */
export type LineShown = LineStatus | 'joining' | 'ready';
export interface Named { id: string; name: string }
export interface RequirementLine {
  id: string; requirement_id: string; role: LineRole; stage: StageType | null; positions: number; posting: string | null;
  needed_by: string; note: string | null; auto: boolean; status: LineStatus; reason: string | null; status_at: string;
  status_by: string | null; opening: { id: string; code: string; group_title: string | null } | null; shown: LineShown;
  ready: Named[]; joining: (Named & { joins_on: string | null })[]; created_at: string; overdue: boolean;
}
export interface Requirement {
  id: string; kind: 'scope' | 'client' | 'state'; state_id: string; state_name: string; client_id: string | null; client_name: string | null;
  scope_id: string | null; scope_name: string | null; raised_by: string | null; raised_at: string; mine: boolean;
}
export interface ScopeRequirement { requirement: Requirement | null; lines: RequirementLine[]; can_request: boolean }
export interface HrCounts { new: number; lines: number; oldest_days: number; overdue: number }
export interface HrQueue { groups: (Requirement & { lines: RequirementLine[] })[]; can_act: boolean; counts: HrCounts }
export type HrAction = 'publish' | 'return' | 'decline' | 'hold';

export const OPEN: LineStatus[] = ['requested', 'returned', 'held', 'published'];
export const LINE_ROLES: LineRole[] = ['operator', 'export_manager', 'client_manager', 'other'];

/** The badge colour of a line's status (the app's Badge values). */
export const shownBadge = (s: LineShown): string =>
  s === 'filled' || s === 'ready' ? 'verified' : s === 'declined' || s === 'withdrawn' ? 'closed' : s === 'returned' || s === 'held' ? 'fail' : s === 'joining' ? 'active' : 'pending';

/** The line that speaks for a stage of a scope: an open one first, the newest of those; else the newest closed one. */
export function lineForStage(lines: RequirementLine[], stage: StageType): RequirementLine | null {
  const mine = lines.filter((l) => l.stage === stage && l.role === 'operator');
  const open = mine.filter((l) => OPEN.includes(l.status));
  const pick = (xs: RequirementLine[]) => xs.slice().sort((a, b) => (a.created_at < b.created_at ? 1 : a.created_at > b.created_at ? -1 : 0))[0] ?? null;
  return pick(open.filter((l) => l.auto)) ?? pick(open) ?? pick(mine);
}

/** HR's queue as she reads it: state → client → scope, each with its lines. */
export function groupQueue(groups: HrQueue['groups']): { state: string; clients: { client: string | null; reqs: HrQueue['groups'] }[] }[] {
  const out: { state: string; clients: { client: string | null; reqs: HrQueue['groups'] }[] }[] = [];
  for (const g of groups) {
    let s = out.find((x) => x.state === g.state_name);
    if (!s) { s = { state: g.state_name, clients: [] }; out.push(s); }
    let c = s.clients.find((x) => x.client === g.client_name);
    if (!c) { c = { client: g.client_name, reqs: [] }; s.clients.push(c); }
    c.reqs.push(g);
  }
  return out;
}

/** The lines HR may publish in one act for one requirement: those Requested or Held. */
export const publishable = (lines: RequirementLine[]) => lines.filter((l) => l.status === 'requested' || l.status === 'held');

/** "Procurement (farm-gate)" → "procurement": a stage's label as it reads inside a sentence. */
export const inSentence = (label: string) => label.replace(/\s*\(.*\)\s*$/, '').toLowerCase();
