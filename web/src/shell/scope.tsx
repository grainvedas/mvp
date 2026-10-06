// The scope a person is working in (prototype: the "Scope:" switcher in the top bar). Everyone chooses among the scopes
// their assignments open (identity layer, migration 32): for each the server says whether they manage it, read the
// whole of it, or hold stages in it. "Overall" means none is chosen; it exists only for someone who reads at least
// one scope whole. A person who only holds stages works in ONE scope at a time and picks it after signing in.
// With one scope only there is nothing to choose: that scope is the one. The choice is kept on this device, per person.
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { useAuth } from '../auth/AuthProvider';
import type { StageType } from '../lib/types';

export interface ScopeChoice {
  id: string; label: string; client_id: string | null; client_name: string; status: string; chain: StageType[];
  crop_name: string | null; season_code: string | null; geography: string | null;
  /** manage: may assign, withdraw, override there. whole: reads every stage (a manager, the client's login, an export manager). */
  manage: boolean; whole: boolean; state_name?: string | null;
}
interface ScopeCtx { scopes: ScopeChoice[]; current: ScopeChoice | null; choose: (id: string | null) => void }
const Ctx = createContext<ScopeCtx>({ scopes: [], current: null, choose: () => {} });

const storageKey = (userId: string) => `grainveda-scope:${userId}`;

/** Pure: which scopes a person can work in, from what the server says about them. */
export function scopeChoices(ctx: { user: { role: string } | null; slots: { scope_id: string; scope_label: string; client_name: string; chain: StageType[]; scope_status: string }[];
  scopes: { scope_id: string; client_id: string; client_name: string; crop_name: string; season_code: string; geography: string; status: string; chain: StageType[];
    manage?: boolean; whole?: boolean; state_name?: string }[] } | null): ScopeChoice[] {
  if (!ctx?.user) return [];
  // A server from before migration 32 does not say manage / whole: there the one role decided both.
  const oldManage = ctx.user.role !== 'operator' && ctx.user.role !== 'client_view', oldWhole = ctx.user.role !== 'operator';
  const listed = ctx.scopes.filter((s) => s.status !== 'closed').map((s) => ({ id: s.scope_id, label: `${s.crop_name} · ${s.season_code} · ${s.geography}`,
    client_id: s.client_id, client_name: s.client_name, status: s.status, chain: s.chain, crop_name: s.crop_name, season_code: s.season_code, geography: s.geography,
    manage: s.manage ?? oldManage, whole: s.whole ?? oldWhole, state_name: s.state_name ?? null }));
  if (listed.length > 0 || ctx.user.role !== 'operator') return listed;
  const seen = new Map<string, ScopeChoice>();
  for (const s of ctx.slots) if (!seen.has(s.scope_id)) seen.set(s.scope_id, { id: s.scope_id, label: s.scope_label, client_id: null, client_name: s.client_name,
    status: s.scope_status, chain: s.chain, crop_name: null, season_code: null, geography: null, manage: false, whole: false });
  return [...seen.values()];
}

/** Pure: does this person only hold stages (reads no scope whole)? Then they work in one scope at a time. */
export const worksInOneScope = (scopes: ScopeChoice[]) => scopes.length > 0 && scopes.every((s) => !s.whole);

/** Pure: the scope in force. One scope: that one. Several: the stored choice if it is still there, else none ("Overall"). */
export function currentScope(scopes: ScopeChoice[], stored: string | null): ScopeChoice | null {
  if (scopes.length === 1) return scopes[0];
  return scopes.find((s) => s.id === stored) ?? null;
}

/** Pure: the scope a page belongs to, read from its address: a stage page or a scope's dashboard. Any other page: none. */
export function pageScopeId(pathname: string): string | null {
  const m = /^\/(?:work|dashboard)\/([^/]+)/.exec(pathname);
  return m ? decodeURIComponent(m[1]) : null;
}

/** Pure: the scope the frame shows (selector, Operations menu). The page's own scope if it has one the person can
 *  work in, else the chosen one. So the top bar never says "Overall" over a form that belongs to one scope. */
export function shownScope(scopes: ScopeChoice[], current: ScopeChoice | null, pathname: string): ScopeChoice | null {
  const id = pageScopeId(pathname);
  return (id ? scopes.find((s) => s.id === id) : undefined) ?? current;
}

export function ScopeProvider({ children }: { children: ReactNode }) {
  const { ctx } = useAuth();
  const userId = ctx?.user?.id ?? '';
  const scopes = useMemo(() => scopeChoices(ctx ?? null), [ctx]);
  const read = () => { try { return userId ? localStorage.getItem(storageKey(userId)) : null; } catch { return null; } };
  const [stored, setStored] = useState<string | null>(read);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { setStored(read()); }, [userId]);
  const choose = useCallback((id: string | null) => {
    setStored(id);
    try { if (id) localStorage.setItem(storageKey(userId), id); else localStorage.removeItem(storageKey(userId)); } catch { /* private mode */ }
  }, [userId]);
  const value = useMemo<ScopeCtx>(() => ({ scopes, current: currentScope(scopes, stored), choose }), [scopes, stored, choose]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export const useScope = () => useContext(Ctx);

/** True from the width at which the laptop frame (side menu, two-column forms) is drawn. Follows the window. */
export function useWide(): boolean {
  const query = '(min-width: 900px)';
  const [wide, setWide] = useState(() => typeof window !== 'undefined' && typeof window.matchMedia === 'function' && window.matchMedia(query).matches);
  useEffect(() => {
    if (typeof window.matchMedia !== 'function') return;
    const m = window.matchMedia(query);
    const on = () => setWide(m.matches);
    on(); m.addEventListener('change', on);
    return () => m.removeEventListener('change', on);
  }, []);
  return wide;
}
