// One way out for mail (the invite note to a joiner, the once-a-day sign-in code). There is NO sender yet (decision
// 5 Oct 2026): until these three secrets are set, mailConfigured() is false, invites are handed over by HR in person
// and the sign-in code stays switched off.
//   supabase secrets set MAIL_API_URL=https://api.resend.com/emails MAIL_API_KEY=<key> MAIL_FROM="GrainVeda <no-reply@your-domain>"
// The request is the Resend shape ({ from, to[], subject, text } with a Bearer key); any service that accepts that shape works.
type Env = Record<string, string | undefined>;

export const mailConfigured = (env: Env): boolean => !!(env.MAIL_API_URL && env.MAIL_API_KEY && env.MAIL_FROM);

export async function sendMail(env: Env, m: { to: string; subject: string; text: string }): Promise<{ ok: boolean; error?: string }> {
  if (!mailConfigured(env)) return { ok: false, error: 'no sender is set up' };
  try {
    const r = await fetch(env.MAIL_API_URL!, {
      method: 'POST',
      headers: { authorization: `Bearer ${env.MAIL_API_KEY}`, 'content-type': 'application/json' },
      body: JSON.stringify({ from: env.MAIL_FROM, to: [m.to], subject: m.subject, text: m.text }),
      signal: AbortSignal.timeout(10000),
    });
    return r.ok ? { ok: true } : { ok: false, error: `the mail service answered ${r.status}` };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}

/** g•••@gmail.com: enough for the person to know where to look, not enough to read off a screen. */
export const maskEmail = (e: string): string => { const at = e.indexOf('@'); return at < 1 ? '•••' : `${e[0]}•••${e.slice(at)}`; };
