// Who may do what, as the SCREENS ask it (migration 34). The database decides; these only keep buttons from being
// offered to people the database would refuse. All of it reads what the server sent in my_context.
import type { MyContext } from './types';

export type Ctx = MyContext | null | undefined;

/** The admin oversees: reads everything, runs no stage, farmer, client, scope or roster. */
export const oversees = (ctx: Ctx) => !!(ctx?.user?.can?.oversee ?? ctx?.user?.can?.admin);

/** Holds the client's account (the Client Manager of that client): adds and verifies its farmers (step 1). */
export const holdsClientAccount = (ctx: Ctx, clientId: string | null | undefined) =>
  !!clientId && !oversees(ctx) && (ctx?.assignments ?? []).some((a) => a.lens === 'client' && a.op_role === 'client_account' && a.client_id === clientId);

/** A State Manager of this state: verifies the location of its farmers (step 2) and issues the Farmer ID. */
export const supervisesState = (ctx: Ctx, stateId: string | null | undefined) =>
  !!stateId && !oversees(ctx) && (ctx?.assignments ?? []).some((a) => a.lens === 'state' && a.state_id === stateId);

/** A State Manager of any state (crops, clients of the state). */
export const isStateManager = (ctx: Ctx) => !oversees(ctx) && (ctx?.assignments ?? []).some((a) => a.lens === 'state');

/** Manages this scope (its roster, withdrawals, verdict overrides, flags), by the server's own answer. */
export const managesScope = (ctx: Ctx, scopeId: string | null | undefined) =>
  !!scopeId && !oversees(ctx) && !!(ctx?.scopes ?? []).find((s) => s.scope_id === scopeId)?.manage;

/** Seats State Managers (gives a person a state): the HR Admin, by the server's word (migration 35). */
export const seatsStateManagers = (ctx: Ctx) => !!ctx?.user?.can?.state_seat;

/** Gives assignments from the People screens: a State or Client Manager (scope, client's account), the HR Admin (a
 *  state: seats State Managers). Never the admin (Veda, 10 Oct: the admin adds states and the HR Admin, nothing else). */
export const givesAssignments = (ctx: Ctx) => !oversees(ctx) && (!!ctx?.user?.can?.assign || seatsStateManagers(ctx));

/** Migration 41: a State Manager acting as one (owns his state; builds no scope, adds no farmer, overrides nothing). */
export const actsAsStateManager = (ctx: Ctx) => !!ctx?.user?.can?.state_manager;

/** The states he owns (his state seats). */
export const myStateIds = (ctx: Ctx): string[] =>
  [...new Set((ctx?.assignments ?? []).filter((a) => a.lens === 'state' && a.state_id).map((a) => a.state_id as string))];

/** Builds scopes (the Client Manager of a client): "New scope". A scope's own editor asks `buildsScope`. */
export const buildsScopes = (ctx: Ctx) => !oversees(ctx) && !!ctx?.user?.can?.build_scope;
export const buildsScope = (ctx: Ctx, scopeId: string | null | undefined) =>
  !!scopeId && !oversees(ctx) && !!(ctx?.scopes ?? []).find((s) => s.scope_id === scopeId)?.build;

/** Adds a client's farmers (by hand or Excel): its Client Manager, or someone at Procurement or Village Batch in one of
 *  its scopes. Never a State Manager (he verifies after the Client Manager) and never the admin (migration 41). */
export const addsFarmers = (ctx: Ctx, clientId: string | null | undefined) =>
  !!clientId && !oversees(ctx) && (holdsClientAccount(ctx, clientId)
    || (ctx?.slots ?? []).some((sl) => (sl.stage_type === 'procurement' || sl.stage_type === 'village_batch')
         && (ctx?.scopes ?? []).find((s) => s.scope_id === sl.scope_id)?.client_id === clientId));

/** Migration 48 (D3–D5): the clients whose account he holds (a Client Manager): his grouped menu, his client's ledger. */
export const myClientAccounts = (ctx: Ctx): string[] => oversees(ctx) ? [] :
  [...new Set((ctx?.assignments ?? []).filter((a) => a.lens === 'client' && a.op_role === 'client_account' && a.client_id).map((a) => a.client_id as string))];

/** Migration 59 (B1, Veda's brief of 19 Oct 2026): the client's own login reads only. No stage page, no "Work in this
 *  scope", no flag, no file: the database refuses every write from it (trigger client_login_reads_only). */
export const isClientLogin = (ctx: Ctx) => !!ctx?.user?.external && ctx?.user?.client_account?.kind !== 'operator';

/** Migration 67 (Phase 3, A1): the client's own staff (an operator): records and verifies at its stages on a Hybrid or
 *  Self-run scope of its client, as GrainVeda's operators do; reads nothing else of the client. */
export const isClientOperator = (ctx: Ctx) => !!ctx?.user?.external && ctx?.user?.client_account?.kind === 'operator';

/** Migration 67 (A1): the client's owner (of this client): shares with buyers, uploads its acceptance and renewals,
 *  invites viewers. The server's rule is app.client_may; this only keeps buttons from people it would refuse. */
export const isClientOwner = (ctx: Ctx, clientId?: string | null) => !!ctx?.user?.external && ctx?.user?.client_account?.kind === 'owner'
  && ctx?.user?.client_account?.status === 'active' && (!clientId || ctx?.user?.client_account?.client_id === clientId);
