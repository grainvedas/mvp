import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '../lib/supabase';
import { forgetLogin, keptLogin } from '../lib/keptLogin';
import { rpc } from '../lib/api';
import type { MyContext, Role } from '../lib/types';
import { toAppError, type AppError } from '../lib/errors';
import { cached, forgetAll } from '../offline/cache';

interface Auth {
  session: Session | null;
  ctx: MyContext | null;
  loading: boolean;
  error: AppError | null;
  refresh: () => Promise<void>;
  signOut: () => Promise<void>;
}
const AuthCtx = createContext<Auth>(null as unknown as Auth);

const QUIET_REFRESH_MS = 60_000;
/** How long "Sign out" waits for the server before signing out on this phone only. */
const SIGN_OUT_WAIT_MS = 4000;

// PRD §9 Authentication: "session expiry 30 days on device, 12 h on web". Field operators work on their own phone for
// weeks; managers work on shared office computers. Counted from the last sign-in with a password, not from the last
// token refresh. The server-side limit for everyone is the project's "time-box user sessions" setting (docs/DEPLOY.md).
export const SESSION_HOURS = { manager: 12, operator: 24 * 30 } as const;
export function sessionExpired(role: Role, lastSignInAt: string | null | undefined, now = Date.now()): boolean {
  if (!lastSignInAt) return false;
  const hours = role === 'operator' ? SESSION_HOURS.operator : SESSION_HOURS.manager;
  return now - new Date(lastSignInAt).getTime() > hours * 3600_000;
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [ctx, setCtx] = useState<MyContext | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<AppError | null>(null);
  const who = useRef<string | null>(null);          // the login the app is currently drawn for
  const lastQuiet = useRef(0);

  const load = useCallback(async (s: Session | null) => {
    const mine = s?.user.id ?? null;
    who.current = mine;
    setSession(s);
    if (!s) {
      // Nobody is signed in (signed out here, ended by the server, or never signed in): what was kept on this phone
      // for offline work goes. Saves still waiting in the outbox stay; they are sent when the same person signs in.
      void forgetAll();
      setCtx(null); setError(null); setLoading(false);
      return;
    }
    try {
      const c = await cached('my_context', () => rpc<MyContext>('my_context'));   // from the phone when there is no network
      if (who.current !== mine) return;                    // signed out, or someone else signed in, while this was on its way
      if (!c.user) void forgetAll();                        // deactivated: the server has no active user for this login any more
      setCtx(c); setError(null);
      lastQuiet.current = Date.now();
    } catch (e) { if (who.current === mine) setError(toAppError(e)); }
    finally { if (who.current === mine) setLoading(false); }
  }, []);

  /** Same person, app already on screen: pick up new stage assignments without redrawing anything. */
  const quietRefresh = useCallback(async () => {
    if (Date.now() - lastQuiet.current < QUIET_REFRESH_MS) return;
    lastQuiet.current = Date.now();
    const mine = who.current;
    try {
      const c = await cached('my_context', () => rpc<MyContext>('my_context'));
      if (who.current !== mine) return;
      if (!c.user) void forgetAll();
      setCtx(c);
    } catch { /* offline or refused: keep what is on screen */ }
  }, []);

  useEffect(() => {
    // Start from the login kept on this phone, read from storage: no network needed, and it is there even when the
    // hourly token ran out hours ago (a day in the field). The first request renews the token if it can.
    void load(keptLogin());
    const { data: sub } = supabase.auth.onAuthStateChange((event, s) => {
      if (event === 'INITIAL_SESSION') return;                       // the line above owns the first load
      const same = (s?.user.id ?? null) === who.current;
      if (event === 'SIGNED_OUT' || !same) { setLoading(true); void load(s); return; }   // nobody, or somebody else
      // The same person. supabase-js also says SIGNED_IN every time the tab comes back into view (after a phone call,
      // the calculator, the camera): redrawing the app here would wipe a half-filled form. Keep the screen, take the
      // fresh token, and refresh the assignments in the background.
      setSession(s);
      if (event === 'SIGNED_IN') void quietRefresh();
    });
    return () => sub.subscription.unsubscribe();
  }, [load, quietRefresh]);

  /**
   * Tells the server when it can be reached, and signs out on this phone in every case. supabase-js on its own leaves
   * the login in place when it cannot reach the server, so with no network the button did nothing (after wiping the
   * forms kept for offline work).
   */
  const signOut = useCallback(async () => {
    const told = await Promise.race([
      supabase.auth.signOut().then((r) => !r.error, () => false),
      new Promise<boolean>((resolve) => window.setTimeout(() => resolve(false), SIGN_OUT_WAIT_MS)),
    ]);
    if (!told || keptLogin()) { forgetLogin(); await load(null); }
  }, [load]);

  const role = ctx?.user?.role;
  const lastSignIn = session?.user.last_sign_in_at;
  useEffect(() => {
    if (!role || !lastSignIn) return;
    const check = () => { if (sessionExpired(role, lastSignIn)) void signOut(); };
    check();
    const t = window.setInterval(check, 60_000);
    return () => window.clearInterval(t);
  }, [role, lastSignIn, signOut]);

  const value: Auth = {
    session, ctx, loading, error,
    refresh: () => load(keptLogin()),                      // e.g. after a scope was created: new assignments, same screen
    signOut,
  };
  return <AuthCtx.Provider value={value}>{children}</AuthCtx.Provider>;
}

export const useAuth = () => useContext(AuthCtx);
export const useMe = () => useContext(AuthCtx).ctx?.user ?? null;
