import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '../lib/supabase';
import { rpc } from '../lib/api';
import type { MyContext } from '../lib/types';
import { toAppError, type AppError } from '../lib/errors';
import { cached } from '../offline/cache';

interface Auth {
  session: Session | null;
  ctx: MyContext | null;
  loading: boolean;
  error: AppError | null;
  refresh: () => Promise<void>;
  signOut: () => Promise<void>;
}
const AuthCtx = createContext<Auth>(null as unknown as Auth);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [ctx, setCtx] = useState<MyContext | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<AppError | null>(null);

  const load = useCallback(async (s: Session | null) => {
    setSession(s);
    if (!s) { setCtx(null); setLoading(false); return; }
    try { setCtx(await cached('my_context', () => rpc<MyContext>('my_context'))); setError(null); }   // works offline after one online sign-in
    catch (e) { setError(toAppError(e)); }
    finally { setLoading(false); }
  }, []);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => load(data.session));
    const { data: sub } = supabase.auth.onAuthStateChange((event, s) => {
      if (event === 'SIGNED_IN' || event === 'SIGNED_OUT' || event === 'USER_UPDATED') { setLoading(true); void load(s); }
      else setSession(s);
    });
    return () => sub.subscription.unsubscribe();
  }, [load]);

  const value: Auth = {
    session, ctx, loading, error,
    refresh: async () => { const { data } = await supabase.auth.getSession(); await load(data.session); },
    signOut: async () => { await supabase.auth.signOut(); },
  };
  return <AuthCtx.Provider value={value}>{children}</AuthCtx.Provider>;
}

export const useAuth = () => useContext(AuthCtx);
export const useMe = () => useContext(AuthCtx).ctx?.user ?? null;
