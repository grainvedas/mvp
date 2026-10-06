// Own password (Phase 4). A login made by a manager (create-user, reset-password) starts with a temporary password the
// manager has seen; the app asks for an own password before anything else (user_metadata.must_change_password).
// The same form sits on the Account page for changing it later. Operators have no e-mail, so "forgot my password"
// is: HR resets it on the person's profile (People & access) and hands over a new temporary one.
import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { useI18n } from '../lib/i18n';
import { AppError, toAppError } from '../lib/errors';
import { useAction } from '../lib/useAsync';
import { ErrorBox, Field } from '../shell/ui';
import { useAuth } from './AuthProvider';

export const MIN_PASSWORD = 8;
export type PasswordProblem = 'short' | 'mismatch' | null;
export function passwordProblem(pw: string, again: string): PasswordProblem {
  if (pw.length < MIN_PASSWORD) return 'short';
  if (pw !== again) return 'mismatch';
  return null;
}

export function PasswordForm({ submitKey = 'account.change_password' }: { submitKey?: string }) {
  const { t } = useI18n();
  const [pw, setPw] = useState('');
  const [again, setAgain] = useState('');
  const [show, setShow] = useState(false);
  const [done, setDone] = useState(false);
  const act = useAction();
  const problem = passwordProblem(pw, again);
  const submit = (e: FormEvent) => {
    e.preventDefault();
    setDone(false);
    void act.run(async () => {
      const { error } = await supabase.auth.updateUser({ password: pw, data: { must_change_password: false } });
      if (error) {
        const code = (error as { code?: string }).code ?? '';
        if (code === 'same_password' || /different from the old password/i.test(error.message)) throw new AppError(t('account.same_password'), code, 'rule');
        if (code === 'reauthentication_needed' || /reauthentication/i.test(error.message)) throw new AppError(t('account.sign_in_again'), code, 'session');
        if (code === 'weak_password') throw new AppError(error.message, code, 'rule');
        throw toAppError(error);
      }
      setPw(''); setAgain(''); setDone(true);
    });
  };
  return (
    <form onSubmit={submit} aria-label={t('account.change_password')}>
      <Field label={t('account.new_password')} htmlFor="pw-new">
        <input id="pw-new" type={show ? 'text' : 'password'} value={pw} onChange={(e) => setPw(e.target.value)} autoComplete="new-password" required minLength={MIN_PASSWORD} />
      </Field>
      <Field label={t('account.repeat_password')} htmlFor="pw-again">
        <input id="pw-again" type={show ? 'text' : 'password'} value={again} onChange={(e) => setAgain(e.target.value)} autoComplete="new-password" required />
      </Field>
      <label className="check"><input type="checkbox" checked={show} onChange={(e) => setShow(e.target.checked)} />{t('account.show')}</label>
      <p className="hint">{t('account.rule')}</p>
      {pw.length > 0 && problem === 'short' && <p className="hint" data-testid="pw-problem">{t('account.too_short')}</p>}
      {pw.length >= MIN_PASSWORD && again.length > 0 && problem === 'mismatch' && <p className="hint" data-testid="pw-problem">{t('account.mismatch')}</p>}
      <ErrorBox error={act.error} />
      {done && <div className="alert ok" data-testid="pw-changed">{t('account.changed')}</div>}
      <button type="submit" disabled={problem !== null || act.busy}>{t(submitKey)}</button>
    </form>
  );
}

/** The whole screen, before the app, while the login still has the temporary password. */
export function MustSetPassword() {
  const { t } = useI18n();
  const { signOut, session, ctx } = useAuth();
  const signIn = session?.user.email ?? session?.user.phone ?? ctx?.user?.email ?? '';
  const joiner = ctx?.user?.status === 'invited' || ctx?.user?.status === 'onboarding';
  return (
    <main style={{ maxWidth: 420 }}>
      <div className="card" data-testid="must-change">
        <h1>{t(joiner ? 'account.invite_title' : 'account.first_title', { name: (ctx?.user?.display_name ?? '').split(' ')[0] })}</h1>
        <p className="muted">{t(joiner ? 'account.invite_body' : 'account.first_body')}</p>
        {/* the sign-in is fixed by HR: shown so the person knows which address this is, not editable */}
        <Field label={t('account.sign_in')} htmlFor="pw-signin"><input id="pw-signin" value={signIn} readOnly disabled data-testid="locked-sign-in" /></Field>
        <PasswordForm submitKey="account.set_password" />
      </div>
      <button className="secondary" onClick={() => void signOut()}>{t('nav.signout')}</button>
    </main>
  );
}
