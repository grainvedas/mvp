import { appDb, supabase, SUPABASE_URL } from './supabase';
import { toAppError } from './errors';

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

/** Call an Edge Function with the signed-in user's token. */
export async function callFunction<T = unknown>(name: string, body: unknown): Promise<T> {
  const { data: s } = await supabase.auth.getSession();
  const token = s.session?.access_token;
  const res = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token ?? ''}`, 'content-type': 'application/json',
      apikey: (supabase as unknown as { supabaseKey: string }).supabaseKey },
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
