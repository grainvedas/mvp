import { accessToken, appDb, SUPABASE_ANON_KEY, SUPABASE_URL } from './supabase';
import { AppError, toAppError } from './errors';

/** Call an RPC in the `app` schema and throw a plain-language AppError on refusal. */
export async function rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await appDb.rpc(fn, args);
  if (error) throw toAppError(error);
  return data as T;
}

/** Unwrap a supabase-js table response. */
export async function q<T>(p: PromiseLike<{ data: T | null; error: unknown }>): Promise<T> {
  const { data, error } = await p;
  if (error) throw toAppError(error);
  return data as T;
}

/**
 * A link that is connected but dead can hold a request for minutes. Rejects as "no connection" when `p` has not
 * answered within `ms`; the request itself is left alone (if it does get through, the save id makes the retry safe).
 */
export function within<T>(ms: number, p: Promise<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const t = setTimeout(() => reject(new AppError('No connection to the server. Check the network and try again.', '', 'network')), ms);
    p.then((v) => { clearTimeout(t); resolve(v); }, (e) => { clearTimeout(t); reject(e); });
  });
}

/**
 * The build of the server functions this app needs (supabase/functions/<name>/handler.ts: VERSION). The functions are
 * deployed separately from the app and from the database (`supabase functions deploy`), so they can be left behind:
 * on 4 Oct 2026 staging ran the create-user of 1 Oct against a database that no longer linked the logins it made, and
 * "New user" failed every time with words that named no cause (FIX_LIST fault 32). Functions before this date answer
 * without the header at all.
 */
export const FUNCTIONS_NEEDED = '2026-10-06';
export type FunctionState = 'ok' | 'outdated' | 'missing' | 'unknown';

/** Pure: what a function's answer says about its build. A date written as text compares as text. */
export function buildState(header: string | null | undefined): 'ok' | 'outdated' {
  return header && /^\d{4}-\d{2}-\d{2}/.test(header) && header >= FUNCTIONS_NEEDED ? 'ok' : 'outdated';
}

/** Does the server answer at all? (A function that is not deployed looks like "no network" to a browser.) */
async function serverAnswers(): Promise<boolean> {
  try {
    // no-cors: an answer the page may not read is still an answer; only "nothing came back" rejects.
    await fetch(`${SUPABASE_URL}/auth/v1/health`, { mode: 'no-cors', cache: 'no-store', signal: AbortSignal.timeout(6000) });
    return true;
  } catch { return false; }
}

const setupError = (state: 'outdated' | 'missing', name: string, detail = '') =>
  new AppError(state === 'missing' ? `Detail: the server has no "${name}" function.`
    : `Detail: the server's "${name}" function is older than this app${detail ? `; it answered "${detail}"` : ''}.`,
    state === 'missing' ? 'FN_MISSING' : 'FN_OUTDATED', 'setup');

/** Which build of a server function is deployed. Never throws; "unknown" when the server cannot be reached. */
export async function functionState(name: string): Promise<FunctionState> {
  try {
    const token = await accessToken();
    const res = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
      headers: { authorization: `Bearer ${token ?? ''}`, apikey: SUPABASE_ANON_KEY }, signal: AbortSignal.timeout(8000) });
    // the build is in a header and, for a GET, in the answer itself (a host may not let the page read the header)
    const said = (await res.json().catch(() => null)) as { version?: string } | null;
    return buildState(res.headers.get('x-grainveda-function') ?? said?.version);
  } catch {
    return (typeof navigator === 'undefined' || navigator.onLine) && await serverAnswers() ? 'missing' : 'unknown';
  }
}

/** Call an Edge Function with the signed-in user's token. */
export async function callFunction<T = unknown>(name: string, body: unknown): Promise<T> {
  const token = await accessToken().catch((e) => { throw toAppError(e); });     // renewed first if the hourly token has run out
  const res = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token ?? ''}`, 'content-type': 'application/json', apikey: SUPABASE_ANON_KEY },
    body: JSON.stringify(body),
  }).catch(async (e) => {
    // The request never got an answer. If the server answers otherwise, this function is not deployed there.
    if (toAppError(e).kind === 'network' && await serverAnswers()) throw setupError('missing', name);
    throw toAppError(e);
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    // A refusal of the person's own request (not signed in, not allowed, a duplicate, a wrong phone number) is shown as
    // it is. A failure inside an outdated function is not the person's doing: say what is wrong with the server.
    if (res.status >= 500 && buildState(res.headers.get('x-grainveda-function')) === 'outdated' && await functionState(name) === 'outdated')
      throw setupError('outdated', name, String(data.error ?? res.statusText));
    throw toAppError({ code: String(res.status === 403 ? '42501' : res.status), message: data.error ?? res.statusText });
  }
  return data as T;
}

/** SHA-256 of a file, hex. Recorded with every piece of evidence. */
export async function sha256Hex(file: Blob): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', await file.arrayBuffer());
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
