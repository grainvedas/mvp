import type { ReactNode } from 'react';
import type { AppError } from '../lib/errors';
import { useI18n } from '../lib/i18n';
import { humanise } from '../lib/format';

/**
 * The app's own messages are shown in the reader's language. What the database says in refusing something (a rule,
 * with its numbers) is shown in its own words, which are English.
 */
export function errorText(error: AppError, t: (key: string) => string): string {
  // a refusal of the id-numbers function carries a dictionary key and a code only (lib/idNumbers.ts)
  if (/^id\.[a-z_]+$/.test(error.message)) return t(error.message);
  if (error.kind === 'network') return t('error.network');
  if (error.kind === 'session') return t('error.session');
  if (error.kind === 'duplicate') return t('error.duplicate');
  if (error.message === 'Not allowed for your role or stage.') return t('error.not_allowed');
  // The server is set up wrongly (a function not deployed, or older than the app): nothing the person can correct.
  if (error.kind === 'setup') return `${t(error.code === 'FN_MISSING' ? 'error.fn_missing' : 'error.fn_outdated')} ${error.message}`;
  return error.message;
}

export function ErrorBox({ error, onRetry }: { error: AppError | null | undefined; onRetry?: () => void }) {
  const { t } = useI18n();
  if (!error) return null;
  return (
    <div className="alert error" role="alert">
      {errorText(error, t)}
      {onRetry && <> <button className="secondary" onClick={onRetry} style={{ marginLeft: 8 }}>{t('common.retry')}</button></>}
    </div>
  );
}

export function Loading() {
  const { t } = useI18n();
  return <p className="muted" aria-live="polite">{t('common.loading')}</p>;
}

/** A status word (pending, verified, pass…). Without a label of its own it is shown in the reader's language. */
export function Badge({ value, label }: { value: string; label?: string }) {
  const { t } = useI18n();
  return <span className={`badge ${value}`}>{label ?? t(`badge.${value}`, undefined, humanise(value))}</span>;
}

export function Field({ label, hint, children, htmlFor }: { label: string; hint?: string; children: ReactNode; htmlFor?: string }) {
  return (
    <div className="field">
      <label htmlFor={htmlFor}>{label}{hint && <> <span className="hint">{hint}</span></>}</label>
      {children}
    </div>
  );
}

export function Empty({ children }: { children?: ReactNode }) {
  const { t } = useI18n();
  return <p className="muted">{children ?? t('common.none')}</p>;
}
