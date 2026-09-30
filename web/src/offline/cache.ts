// Read-through cache for the few answers a form needs offline. Online: always asks the server and keeps the answer.
// Offline (network error): returns the last answer for THIS signed-in user, or rethrows if there is none.
// Cleared on sign-out, so a shared phone does not keep one operator's farmer list for the next.
import { supabase } from '../lib/supabase';
import { toAppError } from '../lib/errors';
import { available, idbClear, idbGet, idbPut } from './idb';

async function userKey(key: string): Promise<string> {
  const { data } = await supabase.auth.getSession();
  return `${data.session?.user.id ?? 'anon'}:${key}`;
}

export function isNetworkError(e: unknown): boolean {
  return toAppError(e).kind === 'network' || (typeof navigator !== 'undefined' && navigator.onLine === false);
}

export async function cached<T>(key: string, fn: () => Promise<T>): Promise<T> {
  if (!available()) return fn();
  const k = await userKey(key);
  try {
    const v = await fn();
    void idbPut('cache', { v, at: Date.now() }, k).catch(() => undefined);
    return v;
  } catch (e) {
    if (!isNetworkError(e)) throw e;
    const hit = await idbGet<{ v: T; at: number }>('cache', k).catch(() => undefined);
    if (hit) return hit.v;
    throw e;
  }
}

/** Put a value in the cache without reading (e.g. update the incoming list after a local change). */
export async function remember(key: string, v: unknown) {
  if (available()) await idbPut('cache', { v, at: Date.now() }, await userKey(key)).catch(() => undefined);
}

export async function forgetAll() {
  if (available()) await idbClear('cache').catch(() => undefined);
}
