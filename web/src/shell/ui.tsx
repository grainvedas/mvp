import type { ReactNode } from 'react';
import type { AppError } from '../lib/errors';
import { useI18n } from '../lib/i18n';
import { humanise } from '../lib/format';

export function ErrorBox({ error, onRetry }: { error: AppError | null | undefined; onRetry?: () => void }) {
  const { t } = useI18n();
  if (!error) return null;
  return (
    <div className="alert error" role="alert">
      {error.message}
      {onRetry && <> <button className="secondary" onClick={onRetry} style={{ marginLeft: 8 }}>{t('common.retry')}</button></>}
    </div>
  );
}

export function Loading() {
  const { t } = useI18n();
  return <p className="muted" aria-live="polite">{t('common.loading')}</p>;
}

export function Badge({ value, label }: { value: string; label?: string }) {
  return <span className={`badge ${value}`}>{label ?? humanise(value)}</span>;
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
