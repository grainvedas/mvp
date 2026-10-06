// The once-a-day sign-in code (identity layer): password every time, a code once per calendar day.
// Built and tested; switched OFF on every project until a mail sender exists (decision 5 Oct 2026). This screen is
// shown only when the server says today's code is owed (my_context.needs_daily_code).
import { useEffect, useRef, useState, type FormEvent } from 'react';
import { callFunction, rpc } from '../lib/api';
import { AppError } from '../lib/errors';
import { useI18n } from '../lib/i18n';
import { useAction, useAsync } from '../lib/useAsync';
import { ErrorBox, Field } from '../shell/ui';
import { useAuth } from './AuthProvider';

interface State { on: boolean; needed: boolean; can_send?: boolean; email_hint?: string | null; sent_at?: string | null }

export function DailyCode() {
  const { t } = useI18n();
  const { ctx, refresh, signOut } = useAuth();
  const state = useAsync(() => rpc<State>('daily_code_state'), []);
  const send = useAction();
  const check = useAction();
  const [sentTo, setSentTo] = useState<string | null>(null);
  const [code, setCode] = useState('');
  const asked = useRef(false);
  const request = () => send.run(async () => {
    const r = await callFunction<{ sent: boolean; to: string }>('daily-code', {});
    setSentTo(r.to);
  });
  // The first code goes out by itself; another needs a tap (and the server allows one a minute).
  useEffect(() => {
    if (asked.current || !state.data?.needed || !state.data.can_send) return;
    asked.current = true; void request();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.data]);
  const submit = (e: FormEvent) => { e.preventDefault(); void check.run(async () => {
    const ok = await rpc<boolean>('verify_daily_code', { p_code: code });
    if (!ok) throw new AppError(t('code.wrong'), '', 'rule');
    await refresh();
  }); };
  return (
    <main style={{ maxWidth: 420 }}>
      <div className="card" data-testid="daily-code">
        <h1>{t('code.title')}</h1>
        <p className="muted">{t('code.body', { name: ctx?.user?.display_name ?? '' })}</p>
        {state.data && state.data.can_send === false && <div className="alert error" data-testid="code-no-email">{t('code.no_email')}</div>}
        {sentTo && <div className="alert ok" data-testid="code-sent">{t('code.sent', { to: sentTo })}</div>}
        <ErrorBox error={send.error} />
        <form onSubmit={submit} aria-label={t('code.title')}>
          <Field label={t('code.label')} htmlFor="daily-code-input">
            <input id="daily-code-input" className="code-input" value={code} onChange={(e) => setCode(e.target.value.replace(/[^0-9]/g, '').slice(0, 6))}
              inputMode="numeric" autoComplete="one-time-code" maxLength={6} required />
          </Field>
          <ErrorBox error={check.error} />
          <button type="submit" disabled={check.busy || code.length !== 6}>{t('code.submit')}</button>
        </form>
        <p className="row"><button type="button" className="secondary" disabled={send.busy || state.data?.can_send === false} onClick={() => void request()} data-testid="code-resend">{t('code.resend')}</button></p>
      </div>
      <button className="secondary" onClick={() => void signOut()}>{t('nav.signout')}</button>
    </main>
  );
}
