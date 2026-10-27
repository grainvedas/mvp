// Migration 64 (Phase 2, release 1: the client registry; release 2, migration 65: several states, the status, the
// warnings, the renewals). One legal entity, one record, keyed on PAN; the three gates
// per state; the admin's approval of the first Active. Every rule is the server's (tests/59_client_registry.sql); the
// screens ask and show. The numbers are checked here only to say early what the server will say (the same formats).
import { rpc, sha256Hex } from './api';
import { supabase } from './supabase';

export type EntityType = 'company' | 'llp' | 'firm' | 'individual' | 'trust' | 'society' | 'cooperative' | 'huf' | 'government';
export const ENTITY_TYPES: EntityType[] = ['company', 'llp', 'firm', 'individual', 'trust', 'society', 'cooperative', 'huf', 'government'];
export type ClientStatus = 'prospect' | 'diagnostic' | 'active' | 'suspended' | 'ended';
export type DocKind = 'diagnostic_order' | 'incorporation' | 'msa' | 'consent_addendum' | 'signatory_authority' | 'fssai' | 'iec' | 'rcmc';
export const NATIONAL_DOCS: DocKind[] = ['incorporation', 'msa', 'consent_addendum', 'signatory_authority', 'iec', 'rcmc'];

/** The PAN's 4th letter for each type (A2); the server checks the same. */
export const PAN_LETTER: Record<EntityType, string> = {
  company: 'C', llp: 'F', firm: 'F', individual: 'P', trust: 'T', society: 'A', cooperative: 'A', huf: 'H', government: 'G',
};
export const normId = (v: string) => v.replace(/\s/g, '').toUpperCase();
export const panShape = (v: string) => /^[A-Z]{5}[0-9]{4}[A-Z]$/.test(normId(v));
/** null when the PAN fits the type; else the key of what is wrong. */
export function panProblem(pan: string, type: EntityType | ''): 'format' | 'letter' | null {
  const v = normId(pan);
  if (!panShape(v)) return 'format';
  if (type && v[3] !== PAN_LETTER[type]) return 'letter';
  return null;
}
export const maskPan = (v: string) => (v.length === 10 ? `${v.slice(0, 5)}****${v.slice(9)}` : v);
/** The registration number a type asks at Gate 2 (CIN, LLPIN, a registration number), or none. */
export const regKind = (t: EntityType): 'cin' | 'llpin' | 'reg_no' | null =>
  t === 'company' ? 'cin' : t === 'llp' ? 'llpin' : t === 'cooperative' || t === 'society' ? 'reg_no' : null;

export interface Num { masked: string; value?: string | null; expires_on?: string | null; kind?: string }
/** path is null for a national document another state's State Manager reads "on file" (migration 65) */
export interface Doc { id: string; kind: DocKind; file_name: string | null; path: string | null; sha256: string; bytes: number;
  signed_on: string | null; term_end?: string | null; expires_on: string | null; amount: number | null; created_at: string }
export interface GateItem { key: string; needed: boolean; done: boolean }
export interface Gates { client_id: string; state_id: string; status: ClientStatus; legacy: boolean; gates: { gate: 1 | 2 | 3; items: GateItem[] }[] }
export interface Identity { client_id: string; legal_name: string; trade_name: string | null; name: string; pan_masked: string | null;
  pan_pending: boolean; entity_type: EntityType; office_city: string | null; office_state: string | null; status: ClientStatus; code: string;
  own_brand: boolean; pan?: string | null; reg_office?: { address?: string; city?: string; state?: string }; approved_at?: string | null;
  code_edited?: boolean; type?: string }
export interface Contact { name?: string; designation?: string; phone?: string; email?: string }
export interface StateRow { state_id: string; state: string; status: ClientStatus; legacy: boolean; gstin: Num | null; gst_not_registered_reason: string | null;
  signatory: { name?: string; designation?: string }; billing: { contact?: string; email?: string }; address: { address?: string; city?: string };
  state_contact: Contact; brand_on_pack: boolean; fssai: Num | null; kyc_at: string | null; kyc_by: string | null; activation_requested_at: string | null;
  /** migration 65: the end's date, the reason of the current status, and whether the admin set it (then the admin moves it back) */
  ended_on?: string | null; status_reason?: string | null; status_by_admin?: boolean;
  gates: Gates | null; documents: Doc[]; events: { act: string; from: ClientStatus | null; to: ClientStatus | null; reason: string | null; at: string; by: string | null }[];
  mine: boolean }
export interface ClientView { identity: Identity; shared_only: boolean; contact?: Contact; source?: string | null;
  states_of_interest?: { id: string; name: string }[]; crops_of_interest?: { id: string; name: string }[];
  exports?: { export: boolean; apeda: boolean };
  national?: { reg_number: Num | null; iec: Num | null; rcmc: Num | null; documents: Doc[] };
  states: StateRow[];
  may: { edit?: boolean; edit_states?: string[]; edit_identity?: boolean; edit_code?: boolean; set_pan?: boolean; approve?: boolean; full_numbers?: boolean; add_state?: boolean;
    /** migration 65: the reader's own states not yet the client's (Part C); status moves; the national documents; renewals */
    add_states?: { id: string; name: string }[]; set_status?: boolean; national_docs?: boolean; renew?: boolean;
    /** migration 67: the client's accounts card (the admin, the owner, the Client Manager) */
    accounts?: boolean } }
export interface PageRow { client_id: string; name: string; legal_name: string; code: string; pan_masked: string | null; pan_pending: boolean;
  own_brand: boolean; entity_type: EntityType; national_status: ClientStatus;
  states: { state_id: string; state: string; status: ClientStatus; legacy: boolean; awaiting_approval: boolean; progress: { done: number; of: number } | null }[] }
export interface Lookup { situation: 'new' | 'client' | 'known'; similar?: boolean; identity?: Identity; in_my_state?: boolean; add_states?: { id: string; name: string }[] }
export interface Approval { client_id: string; name: string; code: string; state_id: string; state: string; requested_at: string; requested_by: string | null }

export const lookupPan = (pan: string, name: string | null, type: EntityType | null) =>
  rpc<Lookup>('lookup_pan', { p_pan: normId(pan), p_name: name || null, p_type: type || null });
export const createClient = (p: Record<string, unknown>) => rpc<{ client_id: string; code: string; similar: boolean }>('create_client', { p });
export const clientView = (id: string) => rpc<ClientView>('client_view', { p_client: id });
export const clientsPage = () => rpc<PageRow[]>('clients_page');
export const clientApprovals = () => rpc<Approval[]>('client_approvals');
export const saveDetails = (client: string, state: string, p: Record<string, unknown>) =>
  rpc<Gates>('save_client_details', { p_client: client, p_state: state, p });
export const kycTick = (client: string, state: string) => rpc<Gates>('client_kyc', { p_client: client, p_state: state });
export const moveClient = (client: string, state: string, to: 'diagnostic' | 'active', reason?: string) =>
  rpc<Gates & { awaiting_approval?: boolean }>('client_move', { p_client: client, p_state: state, p_to: to, p_reason: reason ?? null });
export const decideActivation = (client: string, state: string, approve: boolean, reason?: string) =>
  rpc<Gates>('decide_client_activation', { p_client: client, p_state: state, p_approve: approve, p_reason: reason ?? null });
export const editIdentity = (client: string, p: Record<string, unknown>, reason: string) =>
  rpc<Identity>('edit_client_identity', { p_client: client, p, p_reason: reason });
export const setPan = (client: string, pan: string, type: EntityType) =>
  rpc<Identity>('set_client_pan', { p_client: client, p_pan: normId(pan), p_type: type });

const EXT: Record<string, string> = { 'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
export const docAccept = Object.keys(EXT).join(',');
/** Upload a document to the client's folder, then record it (its SHA-256 kept by the server). */
export async function addDocument(client: string, state: string, kind: DocKind, file: File, meta: Record<string, unknown>) {
  const ext = EXT[file.type];
  if (!ext) throw new Error('A PDF or a photo (JPG, PNG, WEBP).');
  const path = `${client}/${crypto.randomUUID()}.${ext}`;
  const up = await supabase.storage.from('client-docs').upload(path, file, { contentType: file.type, upsert: false });
  if (up.error) throw up.error;
  return rpc<Doc>('add_client_document', { p_client: client, p_state: state, p_kind: kind, p_path: path,
    p_sha256: await sha256Hex(file), p_bytes: file.size, p_file_name: file.name, p_meta: meta });
}
export async function openDocument(d: Doc) {
  if (!d.path) throw new Error('on file');
  const { data, error } = await supabase.storage.from('client-docs').download(d.path);
  if (error || !data) throw error ?? new Error('no file');
  const url = URL.createObjectURL(data);
  window.open(url, '_blank', 'noopener');
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

/** "3 of 7 done" for one gate: only what that gate needs counts. */
export function gateCount(g: Gates | null, gate: 1 | 2 | 3) {
  const items = (g?.gates.find((x) => x.gate === gate)?.items ?? []).filter((i) => i.needed);
  return { done: items.filter((i) => i.done).length, of: items.length };
}
export const gateDone = (g: Gates | null, gate: 1 | 2 | 3, except: string[] = []) =>
  !!g && (g.gates.find((x) => x.gate === gate)?.items ?? []).every((i) => !i.needed || i.done || except.includes(i.key));
/** What the next move is for a state, and whether it can be made now. */
export function nextMove(g: Gates | null, row: StateRow): { to: 'diagnostic' | 'active' | 'kyc' | null; ready: boolean } {
  if (!g) return { to: null, ready: false };
  if (row.status === 'prospect') return { to: 'diagnostic', ready: gateDone(g, 1) && gateDone(g, 2) };
  if (row.status === 'diagnostic') {
    if (row.activation_requested_at) return { to: null, ready: false };
    const filesDone = gateDone(g, 1) && gateDone(g, 2) && gateDone(g, 3, ['kyc', 'approval']);
    if (!row.kyc_at) return { to: 'kyc', ready: filesDone };
    return { to: 'active', ready: filesDone };
  }
  return { to: null, ready: false };
}

// ── migration 65 (Phase 2, release 2: Part C and Part D) ─────────────────────────────────────────────────────────────
/** Part C: the State Manager adds his state to a client already registered (the record comes back). */
export const addClientState = (client: string, state: string) => rpc<ClientView>('add_client_state', { p_client: client, p_state: state });
/** The states a scope of this client may be made in (Diagnostic or Active there), for the scope's form. */
export const clientScopeStates = (client: string) => rpc<{ id: string; name: string; status: ClientStatus }[]>('client_scope_states', { p_client: client });
/** Part D: suspend (to 'suspended'), resume ('active'), end ('ended'), return ('diagnostic'); state null: every state (the admin). */
export type StatusMove = 'suspended' | 'active' | 'ended' | 'diagnostic';
export const setClientStatus = (client: string, state: string | null, to: StatusMove, reason: string) =>
  rpc<ClientView>('client_set_status', { p_client: client, p_state: state, p_to: to, p_reason: reason });
/** The moves a status allows, in the order the screen offers them. */
export function statusMoves(s: ClientStatus): StatusMove[] {
  if (s === 'active') return ['suspended', 'ended'];
  if (s === 'suspended') return ['active', 'ended'];
  if (s === 'ended') return ['diagnostic'];
  return ['ended'];
}
export interface Expiry { client_id: string; name: string; code: string; state_id: string | null; state: string | null; kind: 'fssai' | 'rcmc' | 'msa';
  expires_on: string; days_left: number; level: 'd60' | 'd15' | 'expired' }
export const clientExpiries = () => rpc<Expiry[]>('client_expiries');
export interface Notice { id: string; kind: string; client_id: string | null; state_id: string | null; created_at: string; read: boolean;
  data: { client?: string; code?: string; state?: string | null; by?: string; reason?: string; national?: boolean; kind?: string; /** migration 72 */ on?: string } }
export const myNotifications = () => rpc<Notice[]>('my_notifications');
export const readNotifications = (ids: string[]) => rpc<number>('read_notifications', { p_ids: ids });
/** The words of a notification ("ABC Exim added in Uttarakhand by …"). */
export function noticeText(n: Notice, t: (k: string, v?: Record<string, string | number>) => string): string {
  const v = { client: n.data.client ?? '', state: n.data.state ?? '', by: n.data.by ?? '', doc: n.data.kind ? t(`cdoc.${n.data.kind}`) : '',
    on: n.data.on ? new Date(`${n.data.on}T12:00:00+05:30`).toLocaleDateString('en-IN', { dateStyle: 'medium', timeZone: 'Asia/Kolkata' }) : '' };
  const key = n.kind === 'client_renewal' ? 'note.client_renewal' : `note.${n.kind}${n.data.national ? '_all' : ''}`;
  return t(key, v) + (n.data.reason ? ` (${n.data.reason})` : '');
}
export type RenewalKind = 'fssai' | 'rcmc' | 'msa';
export interface Renewal { id: string; kind: RenewalKind; state_id: string | null; state: string | null; file_name: string | null; path: string;
  signed_on: string | null; term_end: string | null; expires_on: string | null; proposed_at: string; decided_at: string | null;
  accepted: boolean | null; reason: string | null; may_decide: boolean }
export const clientRenewals = (client: string) => rpc<Renewal[]>('client_renewals', { p_client: client });
export const decideRenewal = (id: string, accept: boolean, reason?: string) =>
  rpc<Renewal[]>('decide_client_renewal', { p_renewal: id, p_accept: accept, p_reason: reason ?? null });
/** B5: the client's own login uploads a renewed licence or agreement to its folder; its State Manager accepts it. */
export async function proposeRenewal(client: string, state: string | null, kind: RenewalKind, file: File, meta: Record<string, unknown>) {
  const ext = EXT[file.type];
  if (!ext) throw new Error('A PDF or a photo (JPG, PNG, WEBP).');
  const path = `${client}/${crypto.randomUUID()}.${ext}`;
  const up = await supabase.storage.from('client-docs').upload(path, file, { contentType: file.type, upsert: false });
  if (up.error) throw up.error;
  return rpc<Renewal>('propose_client_renewal', { p_client: client, p_state: state, p_kind: kind, p_path: path,
    p_sha256: await sha256Hex(file), p_bytes: file.size, p_file_name: file.name, p_meta: meta });
}
export async function openPath(path: string) {
  const { data, error } = await supabase.storage.from('client-docs').download(path);
  if (error || !data) throw error ?? new Error('no file');
  const url = URL.createObjectURL(data);
  window.open(url, '_blank', 'noopener');
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}
