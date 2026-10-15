import type { ReactNode } from 'react';
import { tidy, type AppError } from '../lib/errors';
import { useI18n } from '../lib/i18n';
import { humanise } from '../lib/format';
import { looksTechnical, plainWords } from '../lib/plainErrors';

/**
 * The app's own messages are shown in the reader's language. What the database says in refusing something is matched
 * to plain words in both languages (lib/plainErrors.ts, migration 48); a plain sentence it wrote for people and that
 * is not in the list yet is shown as it is (English); its inside words never.
 */
export function errorText(error: AppError, t: (key: string, v?: Record<string, string | number>, f?: string) => string): string {
  // a refusal of the id-numbers function carries a dictionary key and a code only (lib/idNumbers.ts)
  if (/^id\.[a-z_]+$/.test(error.message)) return t(error.message);
  if (error.kind === 'network') return t('error.network');
  if (error.kind === 'session') return t('error.session');
  // The server is set up wrongly (a function not deployed, or older than the app): nothing the person can correct.
  if (error.kind === 'setup') return `${t(error.code === 'FN_MISSING' ? 'error.fn_missing' : 'error.fn_outdated')} ${error.message}`;
  return plainText(error.raw ?? error.message, t, error.code, error.kind);
}

/** Migration 48 (A4/G13): the database's words in plain words, English or Hindi; never its inside words. */
export function plainText(raw: string, t: (key: string, v?: Record<string, string | number>, f?: string) => string, code = '', kind?: AppError['kind']): string {
  const plain = plainWords(raw, t);
  if (plain) return plain;
  if (kind === 'duplicate') return t('error.duplicate');
  if (/row-level security/i.test(raw) || raw === 'Not allowed for your role or stage.') return t('error.not_allowed');
  if (looksTechnical(raw)) return t('err.generic', { ref: code || '—' });
  return tidy(raw);
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
