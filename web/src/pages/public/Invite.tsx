// The invite page (migration 38, brief "Onboarding at scale", decision 4). A joiner opens the one-time link HR sent:
// `/invite#<token>`. The token is after the #, so no web server ever receives it; this page reads it, takes it out of
// the address bar at once, and gives it only to the `invite` server function. The joiner chooses their own password
// and is signed in. A link works once, for 72 hours; an old one says so and to ask HR for a new one.
// Its own chunk (like the signed-in app): it brings the full dictionaries with it; the public verify page stays small.
import { useEffect, useState, type FormEvent } from 'react';
import { registerDictionary, useI18n, type Lang } from '../../lib/i18n';
import { en } from '../../lib/i18n.en';
import { hi } from '../../lib/i18n.hi';
import { SUPABASE_ANON_KEY, SUPABASE_URL, supabase } from '../../lib/supabase';
import { MIN_PASSWORD, passwordProblem } from '../../auth/SetPassword';
import { Field } from '../../shell/ui';

registerDictionary('en', en);
registerDictionary('hi', hi);

/** Pure: the token from the address (`#<token>`, or `#t=<token>`), or null. */
export function tokenFrom(hash: string): string | null {
  const v = hash.replace(/^#/, '').replace(/^t=/, '');
  return /^[A-Za-z0-9_-]{43}$/.test(v) ? v : null;
}

async function call(body: Record<string, unknown>): Promise<{ status: number; data: Record<string, string> }> {
  const r = await fetch(`${SUPABASE_URL}/functions/v1/invite`, { method: 'POST', cache: 'no-store',
    headers: { apikey: SUPABASE_ANON_KEY, authorization: `Bearer ${SUPABASE_ANON_KEY}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });
  return { status: r.status, data: await r.json().catch(() => ({})) };
}

type Seen = { state: 'loading' } | { state: 'ok'; first_name: string; email_masked: string } | { state: string };
export default function InvitePage() {
  const { t, lang, setLang } = useI18n();
  const [token] = useState(() => tokenFrom(window.location.hash));
  const [seen, setSeen] = useState<Seen>({ state: token ? 'loading' : 'not_found' });
  const [pw, setPw] = useState('');
  const [again, setAgain] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  useEffect(() => {
    // the token leaves the address bar (and so the history and any screenshot of it) as soon as it is read
    if (window.location.hash) window.history.replaceState(null, '', window.location.pathname);
    if (!token) return;
    call({ action: 'check', token }).then((r) => setSeen(r.status === 200 ? (r.data as Seen) : { state: 'failed' }), () => setSeen({ state: 'network' }));
  }, [token]);
  const problem = passwordProblem(pw, again);
  const submit = (e: FormEvent) => {
    e.preventDefault(); if (problem || !token) return;
    setBusy(true); setErr('');
    void (async () => {
      try {
        const r = await call({ action: 'accept', token, password: pw });
        if (r.status !== 200) { setErr(t(`invite.err_${(r.data.code ?? 'failed').toLowerCase()}`, undefined, t('invite.err_failed'))); return; }
        const { error } = await supabase.auth.signInWithPassword({ email: r.data.sign_in, password: pw });
        if (error) { setErr(t('invite.signin_after')); return; }
        window.location.replace('/');
      } catch { setErr(t('invite.err_network')); } finally { setBusy(false); }
    })();
  };
  return (
    <div className="signin-page">
      <main className="signin-box" style={{ margin: 0 }} data-testid="invite-page">
        <div className="signin-logo"><img src="/icon.svg" alt="" width={36} height={36} />{t('app.name')}</div>
        <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'nowrap', margin: '8px 0 12px' }}>
          <h1>{t('invite.title')}</h1>
          <select aria-label="Language" value={lang} onChange={(e) => setLang(e.target.value as Lang)} style={{ width: 'auto' }} data-testid="invite-language">
            <option value="en">English</option><option value="hi">हिन्दी</option></select>
        </div>
        {seen.state === 'loading' && <p className="muted">{t('common.loading')}</p>}
        {seen.state === 'ok' && 'first_name' in seen && (
          <form onSubmit={submit} aria-label={t('invite.title')}>
            <p data-testid="invite-hello">{t('invite.hello', { name: seen.first_name, email: seen.email_masked })}</p>
            <Field label={t('account.new_password')} htmlFor="inv-pw"><input id="inv-pw" type="password" autoComplete="new-password" value={pw} onChange={(e) => setPw(e.target.value)} data-testid="invite-pw" /></Field>
            <Field label={t('account.repeat_password')} htmlFor="inv-pw2"><input id="inv-pw2" type="password" autoComplete="new-password" value={again} onChange={(e) => setAgain(e.target.value)} data-testid="invite-pw2" /></Field>
            {pw.length > 0 && problem === 'short' && <p className="hint" data-testid="invite-problem">{t('account.too_short')}</p>}
            {pw.length >= MIN_PASSWORD && again.length > 0 && problem === 'mismatch' && <p className="hint" data-testid="invite-problem">{t('account.mismatch')}</p>}
            {err && <div className="alert error" role="alert" data-testid="invite-error">{err}</div>}
            <button type="submit" disabled={busy || !!problem} data-testid="invite-submit">{t('invite.submit')}</button>
            <p className="small muted">{t('invite.note')}</p>
          </form>)}
        {seen.state !== 'loading' && seen.state !== 'ok' && (
          <div className="alert warn" data-testid="invite-dead" data-state={seen.state}>{t(`invite.state_${seen.state}`, undefined, t('invite.state_not_found'))} {t('invite.ask_hr')}</div>)}
      </main>
    </div>
  );
}
