// Migration 59 (A6, Veda's brief of 19 Oct 2026): a file whose fingerprint is attached already, for the same client, as
// another kind of document is refused by the database ("same file: this exact file is already attached as … on …") until
// the person gives a reason of 10 characters or more. This asks for it where a file is attached, and tries again with it.
import { useState } from 'react';
import { useI18n } from '../lib/i18n';
import { toAppError, type AppError } from '../lib/errors';
import { ErrorBox, Field, plainText } from '../shell/ui';

/** True when the database refused a file because it is attached elsewhere as another kind of document. */
export const isSameFile = (e: unknown) => !!e && (toAppError(e).code === 'GVDUP' || /same file:/i.test(toAppError(e).raw ?? toAppError(e).message));

/** The reason the person gives for attaching the same file again (kept on the attachment and in the Audit log). */
export function useDupReason() {
  const [reason, setReason] = useState('');
  return { reason, setReason, value: reason.trim().length >= 10 ? reason.trim() : null };
}

/** Shows the error; for a "same file" refusal, the warning, a box for the reason and "Attach with this reason". */
export function ErrorOrSameFile({ error, reason, setReason, retry, busy }: {
  error: AppError | null | undefined; reason: string; setReason: (s: string) => void; retry: () => void; busy: boolean }) {
  const { t } = useI18n();
  if (!error) return null;
  if (!isSameFile(error)) return <ErrorBox error={error} />;
  return (
    <div className="alert warn stack" role="alert" data-testid="same-file">
      <span>{plainText(error.raw ?? error.message, t)}</span>
      <Field label={t('dup.reason')} htmlFor="dup-reason">
        <textarea id="dup-reason" rows={2} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="same-file-reason" />
      </Field>
      <div className="row"><button className="secondary" disabled={busy || reason.trim().length < 10} onClick={retry} data-testid="same-file-retry">{t('dup.attach_anyway')}</button></div>
    </div>
  );
}
