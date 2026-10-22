// Migration 67 (Phase 3, release 1 of Veda's combined brief: Part A, with Phase 2's B4). The client's own accounts (an
// owner, a viewer, the client's own staff) and a scope's delivery model and GI authorised user. Every rule is the
// database's (app.client_may and the functions below); these only call them.
import { callFunction, rpc, sha256Hex } from './api';
import { supabase } from './supabase';
import type { ClientAccountKind } from './types';

export type Reach = 'client' | 'state' | 'scopes';
export type AccountStatus = 'active' | 'suspended' | 'removed';
export interface ClientAccount {
  id: string; name: string; email: string | null; kind: ClientAccountKind; status: AccountStatus; reach: Reach;
  state_id: string | null; state: string | null; scopes: { id: string; label: string }[]; internal_copies: boolean;
  made_as: 'admin' | 'owner' | 'client_manager' | 'migration'; created_at: string; status_reason: string | null; has_login: boolean;
  stages: { scope_id: string; stages: string[] }[] | null;
  may: { manage: boolean; internal: boolean; promote: boolean };
}
export interface ClientAccounts {
  accounts: ClientAccount[];
  /** what the reader may make: an owner (the admin), a viewer (an owner, the Client Manager), client staff (the Client Manager) */
  may: { owner: boolean; viewer: boolean; viewer_whole_client: boolean; operator: boolean; internal: boolean };
  states: { id: string; name: string; status: string }[];
  scopes: { id: string; state_id: string; status: string; delivery_model: DeliveryModel; label: string }[];
}
export type DeliveryModel = 'managed' | 'hybrid' | 'self_run';
export const DELIVERY_MODELS: DeliveryModel[] = ['managed', 'hybrid', 'self_run'];

export const clientAccounts = (client: string) => rpc<ClientAccounts>('client_accounts_of', { p_client: client });

export interface NewAccount { kind: ClientAccountKind; name: string; email: string; reach: Reach; state: string | null; scopes: string[]; internal: boolean }
/** The creator says first what the account is (the server checks who may make it and what it may see), then its
 *  sign-in is made as before (create-user, kind viewer), which makes exactly that. The temporary password is shown once. */
export async function makeClientAccount(client: string, a: NewAccount): Promise<{ sign_in: string; temporary_password: string }> {
  await rpc('prepare_client_account', { p_client: client, p_kind: a.kind, p_email: a.email.trim(), p_reach: a.kind === 'viewer' ? a.reach : 'client',
    p_state: a.kind === 'viewer' && a.reach === 'state' ? a.state : null, p_scopes: a.kind === 'viewer' && a.reach === 'scopes' ? a.scopes : [],
    p_internal: a.kind === 'viewer' && a.internal });
  return callFunction<{ sign_in: string; temporary_password: string }>('create-user', { kind: 'viewer', client_id: client, display_name: a.name.trim(), email: a.email.trim() });
}
export const setAccountStatus = (user: string, status: AccountStatus, reason: string) =>
  rpc('set_client_account_status', { p_user: user, p_status: status, p_reason: reason });
export const setViewerReach = (user: string, reach: Reach, state: string | null, scopes: string[]) =>
  rpc('set_client_viewer', { p_user: user, p_reach: reach, p_state: reach === 'state' ? state : null, p_scopes: reach === 'scopes' ? scopes : [] });
export const setViewerInternal = (user: string, allowed: boolean) => rpc('set_viewer_internal', { p_user: user, p_allowed: allowed });
export const makeOwner = (user: string) => rpc('make_client_owner', { p_user: user });

export const setDeliveryModel = (scope: string, model: DeliveryModel, reason: string | null) =>
  rpc('set_scope_delivery', { p_scope: scope, p_model: model, p_reason: reason });
export const setGiUser = (scope: string, number: string | null, path: string | null, sha256: string | null) =>
  rpc('set_scope_gi_user', { p_scope: scope, p_number: number, p_path: path, p_sha256: sha256 });
const EXT: Record<string, string> = { 'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
/** The GI authorised-user number with its certificate: the file goes to <client>/scopes/<scope>/<file id> in client-docs. */
export async function saveGiUser(scope: string, client: string, number: string | null, file: File | null) {
  if (!file) return setGiUser(scope, number, null, null);
  const ext = EXT[file.type];
  if (!ext) throw new Error('A PDF or a photo (JPG, PNG, WEBP).');
  const path = `${client}/scopes/${scope}/${crypto.randomUUID()}.${ext}`;
  const up = await supabase.storage.from('client-docs').upload(path, file, { contentType: file.type, upsert: false });
  if (up.error) throw up.error;
  return setGiUser(scope, number, path, await sha256Hex(file));
}

/** A viewer made by the Client Manager sees one state's scopes (B5): the reach his form offers. */
export function reachLabel(a: Pick<ClientAccount, 'kind' | 'reach' | 'state' | 'scopes'>, t: (k: string, v?: Record<string, string | number>) => string): string {
  if (a.kind !== 'viewer' || a.reach === 'client') return t('ca.reach.client');
  if (a.reach === 'state') return t('ca.reach.state', { state: a.state ?? '—' });
  return t('ca.reach.scopes', { list: a.scopes.map((s) => s.label).join(', ') || '—' });
}
