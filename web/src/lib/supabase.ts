import { createClient } from '@supabase/supabase-js';
import { AUTH_STORAGE_KEY, keptLogin, tokenRunOut } from './keptLogin';

const env = import.meta.env as Record<string, string | undefined>;
const DEFAULT_URL = 'https://zogkrhgzatplarimbmxk.supabase.co';
const DEFAULT_ANON_KEY = 'sb_publishable_5r4zZ4DgTj8gOXL5KcVOaw_kEGNDq7v';

export const SUPABASE_URL = env.VITE_SUPABASE_URL ?? env.NEXT_PUBLIC_SUPABASE_URL ?? DEFAULT_URL;
export const SUPABASE_ANON_KEY =
  env.VITE_SUPABASE_ANON_KEY ?? env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? DEFAULT_ANON_KEY;

export const configured = Boolean(SUPABASE_URL && SUPABASE_ANON_KEY);
const url = SUPABASE_URL || DEFAULT_URL, key = SUPABASE_ANON_KEY || DEFAULT_ANON_KEY;

// Two clients on purpose (the reasons are in keptLogin.ts).
//
//   authClient   signs people in and out and renews the hourly token, and does nothing else. It does not renew in the
//                background (autoRefreshToken off): with no network every failed attempt starts a one-minute pause
//                inside the library, and the renewal would then be late when the network comes back.
//   dataClient   every table, function and file request. It asks accessToken() below for the token, so a login whose
//                token cannot be renewed right now behaves as "no network" and nothing is ever sent with the public
//                key in place of a signed-in person's own token.
/** A sign-in or renewal request with no answer is stopped after this long; a dead link would hold it for minutes, and
 *  with it every later renewal. (Data requests are not limited here: a photo upload may rightly take longer.) */
const AUTH_TIMEOUT_MS = 20_000;
const authFetch: typeof fetch = (input, init) => {
  const stop = new AbortController();
  const timer = setTimeout(() => stop.abort(), AUTH_TIMEOUT_MS);
  init?.signal?.addEventListener('abort', () => stop.abort());
  return fetch(input, { ...init, signal: stop.signal }).finally(() => clearTimeout(timer));
};
const authClient = createClient(url, key, {
  global: { fetch: authFetch },
  auth: { persistSession: true, autoRefreshToken: false, storageKey: AUTH_STORAGE_KEY },
});

/** How long a request waits for a renewal before it is treated as "no network". The renewal itself keeps going. */
export const RENEW_WAIT_MS = 8000;
let renewing: { done: Promise<boolean>; since: number } | null = null;
/** Tests only. */
export function resetRenewalForTests() { renewing = null; }
const fresh = () => { const s = keptLogin(); return !!s && !tokenRunOut(s); };

/**
 * Renews the hourly token of the login kept on this phone. True when the login has a fresh token afterwards.
 * Concurrent callers share one attempt. If the server refuses the renewal token itself, supabase-js removes the login
 * and announces SIGNED_OUT (AuthProvider shows the sign-in screen); the answer here is then simply false.
 */
export function renewLogin(waitMs = RENEW_WAIT_MS): Promise<boolean> {
  if (fresh()) return Promise.resolve(true);
  if (!keptLogin()) return Promise.resolve(false);
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return Promise.resolve(false);   // certainly no network: do not try
  if (!renewing) {
    const done = authClient.auth.getSession().then(fresh, () => false).finally(() => { renewing = null; });
    renewing = { done, since: Date.now() };
  }
  const left = Math.max(0, waitMs - (Date.now() - renewing.since));
  return Promise.race([renewing.done, new Promise<boolean>((resolve) => setTimeout(() => resolve(fresh()), left))]);
}

/** The token a data request is sent with: the signed-in person's own, renewed first if it has run out. */
export async function accessToken(): Promise<string | null> {
  const s = keptLogin();
  if (!s) return null;                                   // nobody is signed in here: the public key (sign-in, public verify page)
  if (!tokenRunOut(s)) return s.access_token;
  if (await renewLogin()) { const now = keptLogin(); if (now) return now.access_token; }
  // Someone is signed in on this phone but the token cannot be renewed now. The request is not sent: to the screens
  // this is exactly a lost connection (they fall back to what is kept on the phone, saves go to the outbox).
  throw new TypeError('Failed to fetch');
}

const dataClient = createClient(url, key, { accessToken });

/** One object for the rest of the app: sign-in from the auth client, everything else from the data client. */
export const supabase = {
  auth: authClient.auth,
  from: dataClient.from.bind(dataClient) as typeof dataClient.from,
  storage: dataClient.storage,
};

/** The `app` schema: RPCs such as stage_form, preview_reconcile, verify_footprint, seal_lot. */
export const appDb = dataClient.schema('app');
