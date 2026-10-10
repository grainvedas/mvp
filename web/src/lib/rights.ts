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
