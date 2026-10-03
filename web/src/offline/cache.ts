// Read-through cache for the few answers a form needs offline. With a working network: always the server's answer,
// and that answer is kept. With no network: the last answer kept for THIS signed-in person, or the error if there is
// none. On a link that is connected but dead (a request can wait for minutes there): the kept answer after SLOW_MS.
// Cleared on every sign-out and when the server says the login has no active user any more (AuthProvider).
import { toAppError } from '../lib/errors';
import { keptLogin } from '../lib/keptLogin';
import { available, idbClear, idbGet, idbPut } from './idb';

/** How long a screen waits for the server before working from the copy on the phone (if there is one). */
export const SLOW_MS = 8000;

// The key carries the person: read from the login kept on this phone, which is there whether or not the hourly token
// could be renewed. (Asking supabase-js instead gave "nobody" one hour into a day without network.)
const who = () => keptLogin()?.user.id ?? 'anon';
const userKey = (key: string) => `${who()}:${key}`;

export function isNetworkError(e: unknown): boolean {
  return toAppError(e).kind === 'network' || (typeof navigator !== 'undefined' && navigator.onLine === false);
}

const SLOW = Symbol('slow');
/** How long the link is remembered as dead after one answer took too long: the next screens open from the phone at
 *  once instead of each waiting SLOW_MS again. The first answer that does arrive ends it. */
export const DEAD_LINK_MS = 60_000;
let deadUntil = 0;
/** Tests only. */
export function resetCacheForTests() { deadUntil = 0; }

export async function cached<T>(key: string, fn: () => Promise<T>, slowMs = SLOW_MS): Promise<T> {
  if (!available()) return fn();
  const asked = who(), k = `${asked}:${key}`;
  const fromServer = fn().then((v) => {
    deadUntil = 0;
    // kept only for the person who asked: an answer that arrives after a sign-out is not stored
    if (who() === asked) void idbPut('cache', { v, at: Date.now() }, k).catch(() => undefined);
    return v;
  });
  fromServer.catch(() => undefined);                        // a late failure, after the kept copy was used, is nobody's error
  const kept = () => idbGet<{ v: T; at: number }>('cache', k).catch(() => undefined);
  if (Date.now() < deadUntil) { const hit = await kept(); if (hit) return hit.v; }
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([fromServer, new Promise<never>((_, reject) => { timer = setTimeout(() => reject(SLOW), slowMs); })]);
  } catch (e) {
    if (e !== SLOW && !isNetworkError(e)) throw e;          // the server answered and refused: that is the answer
    if (e === SLOW) deadUntil = Date.now() + DEAD_LINK_MS;
    const hit = await kept();
    if (hit) return hit.v;
    if (e === SLOW) return fromServer;                      // nothing kept on this phone: keep waiting for the server
    throw e;
  } finally { clearTimeout(timer); }
}

/** Put a value in the cache without reading (e.g. update the incoming list after a local change). */
export async function remember(key: string, v: unknown) {
  if (available()) await idbPut('cache', { v, at: Date.now() }, userKey(key)).catch(() => undefined);
}

export async function forgetAll() {
  if (available()) await idbClear('cache').catch(() => undefined);
}
