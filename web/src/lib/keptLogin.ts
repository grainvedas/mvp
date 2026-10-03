// The login kept on this phone.
//
// supabase-js keeps a signed-in person as one entry in localStorage: an access token that lasts one hour, a long-lived
// renewal token, and the user. Asked "who is signed in?", the library first renews the hourly token over the network;
// when that cannot be done it answers "nobody", after up to 25 seconds of retries, and sends the next request with the
// project's public key instead. On a field phone that is wrong three times over: an operator one hour away from the
// last network gets the sign-in screen (and cannot sign in), the forms kept for offline work are looked up under the
// wrong name, and a waiting save goes out with nobody's name on it, is refused, and is marked "needs attention".
//
// So the app reads the entry itself. Who is signed in is a fact about this phone, not about the network; a token that
// cannot be renewed right now means "no network", never "signed out". Only the server can end a login: when it
// refuses the renewal token (password reset, deactivated, 30 days over), supabase-js removes the entry and says so.
import type { Session } from '@supabase/supabase-js';

export const AUTH_STORAGE_KEY = 'grainveda-auth';
/** The margin supabase-js uses: a token with under 90 seconds left counts as run out (it could expire on the way). */
export const TOKEN_MARGIN_MS = 90_000;

/** The signed-in person on this phone, read from storage. Never touches the network. */
export function keptLogin(): Session | null {
  try {
    const raw = localStorage.getItem(AUTH_STORAGE_KEY);
    if (!raw) return null;
    const s = JSON.parse(raw) as Partial<Session> | null;
    if (!s || typeof s.access_token !== 'string' || typeof s.refresh_token !== 'string' || !s.refresh_token) return null;
    if (typeof s.expires_at !== 'number' || typeof s.user?.id !== 'string') return null;
    return s as Session;
  } catch { return null; }                                   // storage blocked (private mode) or not JSON: nobody
}

/** The hourly token has run out (or is about to): requests must wait for a renewal. */
export function tokenRunOut(s: Pick<Session, 'expires_at'>, now = Date.now()): boolean {
  return typeof s.expires_at !== 'number' || s.expires_at * 1000 - now < TOKEN_MARGIN_MS;
}

/** Signs out on this phone without asking the server (used when the server cannot be reached). */
export function forgetLogin(): void {
  try { localStorage.removeItem(AUTH_STORAGE_KEY); localStorage.removeItem(`${AUTH_STORAGE_KEY}-user`); } catch { /* storage blocked */ }
}
