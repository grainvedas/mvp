// Sending an identity or bank number to the id-numbers server function (migration 37, brief part A1).
// The number goes in the body of ONE request, over HTTPS, to that function and nowhere else: not to the database, not
// to the offline outbox, not to the browser's storage, not into any error. A refusal comes back as a fixed code and is
// turned into words here, so nothing the person typed can travel on in a message (client_errors, the screen, a log).
import { accessToken, SUPABASE_ANON_KEY, SUPABASE_URL } from './supabase';
import { AppError } from './errors';
import type { IdKind } from './people';

export type IdCode = 'DUPLICATE' | 'BAD_FORMAT' | 'BAD_REQUEST' | 'SIGN_IN' | 'NOT_ALLOWED' | 'STEP_CLOSED' | 'NOT_CONFIGURED' | 'NOT_SAVED' | 'FAILED' | 'NETWORK';

/** Pure: the dictionary key for a refusal. Never takes, never returns anything typed. */
export const idCodeKey = (code: string): string => ({
  DUPLICATE: 'id.duplicate', BAD_FORMAT: 'id.bad_format', SIGN_IN: 'id.sign_in', NOT_ALLOWED: 'id.not_allowed', STEP_CLOSED: 'id.step_closed',
  NOT_CONFIGURED: 'id.not_configured', NETWORK: 'id.network',
} as Record<string, string>)[code] ?? 'id.failed';

/** An AppError carrying only a code and a dictionary key: its message is the key, never the number. */
export class IdNumberError extends AppError {
  readonly idCode: string;
  constructor(idCode: string) { super(idCodeKey(idCode), idCode, 'rule'); this.idCode = idCode; }
}

export async function sendIdNumber(taskId: string, kind: IdKind, number: string, ifsc?: string): Promise<{ last4: string; outcome: 'saved' | 'warned' }> {
  const token = await accessToken().catch(() => { throw new IdNumberError('SIGN_IN'); });
  let res: Response;
  try {
    res = await fetch(`${SUPABASE_URL}/functions/v1/id-numbers`, {
      method: 'POST', cache: 'no-store',
      headers: { authorization: `Bearer ${token ?? ''}`, 'content-type': 'application/json', apikey: SUPABASE_ANON_KEY },
      body: JSON.stringify({ task_id: taskId, kind, number, ...(kind === 'bank' ? { ifsc } : {}) }),
    });
  } catch { throw new IdNumberError('NETWORK'); }
  const data = (await res.json().catch(() => ({}))) as { code?: string; last4?: string; outcome?: 'saved' | 'warned' };
  if (!res.ok || !data.last4) throw new IdNumberError(String(data.code ?? 'FAILED'));
  return { last4: data.last4, outcome: data.outcome ?? 'saved' };
}
