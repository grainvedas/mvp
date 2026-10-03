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

/** Call an Edge Function with the signed-in user's token. */
export async function callFunction<T = unknown>(name: string, body: unknown): Promise<T> {
  const token = await accessToken().catch((e) => { throw toAppError(e); });     // renewed first if the hourly token has run out
  const res = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token ?? ''}`, 'content-type': 'application/json', apikey: SUPABASE_ANON_KEY },
    body: JSON.stringify(body),
  }).catch((e) => { throw toAppError(e); });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw toAppError({ code: String(res.status === 403 ? '42501' : res.status), message: data.error ?? res.statusText });
  return data as T;
}

/** SHA-256 of a file, hex. Recorded with every piece of evidence. */
export async function sha256Hex(file: Blob): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', await file.arrayBuffer());
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
