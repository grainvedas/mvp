import { useState, type FormEvent } from 'react';
import { supabase, configured } from '../lib/supabase';
import { useI18n, type Lang } from '../lib/i18n';
import { toAppError, type AppError } from '../lib/errors';
import { ErrorBox, Field } from '../shell/ui';

// Development sign-in: email + password (managers) or phone + password (operators). Production operators switch to
// phone OTP once DLT registration is done (execution plan D, D4); only the phone branch changes.
export function SignIn() {
  const { t, lang, setLang } = useI18n();
  const [mode, setMode] = useState<'email' | 'phone'>('phone');
  const [id, setId] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<AppError | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true); setError(null);
    const digits = id.replace(/[^0-9]/g, '');
    const phone = digits.length === 10 ? `91${digits}` : digits;
    const { error: err } = mode === 'email'
      ? await supabase.auth.signInWithPassword({ email: id.trim(), password })
      : await supabase.auth.signInWithPassword({ phone, password });
    if (err) setError(toAppError({ message: err.message === 'Invalid login credentials' ? t('signin.wrong') : err.message }));
    setBusy(false);
  }

  return (
    <div className="signin-page">
      <main className="signin-box" style={{ margin: 0 }}>
        <div className="signin-logo"><img src="/icon.svg" alt="" width={36} height={36} />{t('app.name')}</div>
        <div className="signin-sub">{t('app.tagline')}</div>
        <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'nowrap', marginBottom: 12 }}>
          <h1>{t('signin.title')}</h1>
          <select aria-label="Language" value={lang} onChange={(e) => setLang(e.target.value as Lang)} style={{ width: 'auto' }} data-testid="signin-language">
            <option value="en">English</option>
            <option value="hi">हिन्दी</option>
          </select>
        </div>
        {!configured && <div className="alert error">{t('signin.not_configured')}</div>}
        <div className="tabs" role="tablist">
          <button type="button" role="tab" aria-selected={mode === 'phone'} className={mode === 'phone' ? 'active' : ''} onClick={() => setMode('phone')}>{t('signin.by_phone')}</button>
          <button type="button" role="tab" aria-selected={mode === 'email'} className={mode === 'email' ? 'active' : ''} onClick={() => setMode('email')}>{t('signin.by_email')}</button>
        </div>
        <form onSubmit={submit}>
          <Field label={mode === 'email' ? t('signin.email') : t('signin.phone')} htmlFor="signin-id">
            <input id="signin-id" name="id" value={id} onChange={(e) => setId(e.target.value)} required
              type={mode === 'email' ? 'email' : 'tel'} inputMode={mode === 'email' ? 'email' : 'tel'}
              autoComplete={mode === 'email' ? 'email' : 'tel'} placeholder={mode === 'email' ? 'name@example.com' : '98765 43210'} />
          </Field>
          <Field label={t('signin.password')} htmlFor="signin-password">
            <input id="signin-password" name="password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} required autoComplete="current-password" />
          </Field>
          <ErrorBox error={error} />
          <button type="submit" disabled={busy || !configured}>{t('signin.submit')}</button>
        </form>
        <p className="signin-forgot">{t('signin.forgot')}</p>
        <p className="signin-foot">{t('signin.company')}</p>
      </main>
    </div>
  );
}
