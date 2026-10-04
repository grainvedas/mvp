// Database rules are the app's validation: turn their refusals into plain words (execution plan §6, "Error display").
export class AppError extends Error {
  code: string;
  kind: 'rule' | 'permission' | 'not_found' | 'duplicate' | 'session' | 'network' | 'setup' | 'other';
  constructor(message: string, code = '', kind: AppError['kind'] = 'other') {
    super(message);
    this.code = code;
    this.kind = kind;
  }
}

const UUID = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;

/** Removes internal ids and tidies the database's wording. */
export function tidy(message: string): string {
  const m = message.replace(UUID, '').replace(/\s{2,}/g, ' ').replace(/\buser\s+may\b/i, 'you may').trim();
  return m.charAt(0).toUpperCase() + m.slice(1);
}

export function toAppError(e: unknown): AppError {
  if (e instanceof AppError) return e;
  const err = e as { code?: string; message?: string; status?: number; name?: string } | null;
  const code = err?.code ?? '';
  const message = err?.message ?? String(e ?? 'Something went wrong');
  // An answer that carries a database code (SQLSTATE or PGRST…) came from the server, whatever its words: it is never
  // "no connection". AbortError / TimeoutError: a save that waited too long on a dead link, stopped by the app itself.
  const fromServer = /^[0-9A-Z]{5}$|^PGRST/.test(code);
  // (A TypeError with other words is a fault in the app, not the network: it must be shown, not queued.)
  if (!fromServer && (/Failed to fetch|fetch failed|NetworkError|network|Load failed|^(AbortError|TimeoutError)\b|signal (is|was) aborted|signal timed out/i.test(message)
    || err?.name === 'AbortError' || err?.name === 'TimeoutError'))
    return new AppError('No connection to the server. Check the network and try again.', code, 'network');
  if (code === 'PGRST301' || code === 'PGRST303' || /JWT expired|invalid jwt/i.test(message))
    return new AppError('Your session has ended. Please sign in again.', code, 'session');
  if (code === '23514') return new AppError(tidy(message), code, 'rule');
  if (code === '42501' || /row-level security/i.test(message))
    return new AppError(/row-level security/i.test(message) ? 'Not allowed for your role or stage.' : tidy(message), code, 'permission');
  if (code === 'P0002' || code === 'PGRST116') return new AppError(tidy(message) || 'Not found.', code, 'not_found');
  if (code === '23505') return new AppError('This already exists (same phone, email or code).', code, 'duplicate');
  return new AppError(tidy(message), code, 'other');
}
