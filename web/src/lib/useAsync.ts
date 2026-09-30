import { useCallback, useEffect, useRef, useState } from 'react';
import { AppError, toAppError } from './errors';

export function useAsync<T>(fn: () => Promise<T>, deps: unknown[]) {
  const [data, setData] = useState<T | undefined>(undefined);
  const [error, setError] = useState<AppError | null>(null);
  const [loading, setLoading] = useState(true);
  const seq = useRef(0);
  const run = useCallback(async () => {
    const my = ++seq.current;
    setLoading(true); setError(null);
    try { const d = await fn(); if (my === seq.current) setData(d); }
    catch (e) { if (my === seq.current) setError(toAppError(e)); }
    finally { if (my === seq.current) setLoading(false); }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  useEffect(() => { void run(); }, [run]);
  return { data, error, loading, reload: run, setData };
}

/** Wraps an action (save, verify…) with busy + error state. */
export function useAction() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<AppError | null>(null);
  const run = useCallback(async <T,>(fn: () => Promise<T>): Promise<T | undefined> => {
    setBusy(true); setError(null);
    try { return await fn(); } catch (e) { setError(toAppError(e)); return undefined; } finally { setBusy(false); }
  }, []);
  return { busy, error, setError, run };
}
