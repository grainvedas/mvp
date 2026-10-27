// Migration 71 (Phase 3, release 4, Part E1): the "Evidence packs" card, on a shipment's or a sealed lot's record, a
// client order's page, the scope dashboard and the client's scope view. A pack is issued by the server when a lot is
// sealed (and on demand, by who reads the whole scope and runs it); each version is listed with its files: the PDF in
// English and Hindi and the JSON, of the shareable copy, and of the internal copy for those who may read it. A stored
// file is taken from the store (the download is in the Audit log); one not stored yet is drawn from the data the server
// kept. Those who may store a pack's files store them, and their SHA-256 shows on "Verify this document".
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { dateTime } from '../../lib/format';
import { Badge, ErrorBox, Loading } from '../../shell/ui';
import type { Copy } from '../../lib/exports';
import {
  drawPackFile, evidencePacks, issueEvidencePack, makePackFiles, openPackFile, packFileKey, packFiles,
  type PackFormat, type PackHead, type PackKind,
} from '../../lib/evidencePacks';
import type { Lang } from '../../lib/reports';

/** Pure: the files a reader may take of a pack, by copy (the internal copy only for its readers). */
export function readerFiles(p: Pick<PackHead, 'internal_ok'>) {
  return packFiles(!!p.internal_ok);
}
/** Pure: the files still to store (none for a pack withdrawn). */
export function missingFiles(p: Pick<PackHead, 'internal_ok' | 'files' | 'status'>) {
  if (p.status === 'withdrawn') return [];
  return packFiles(!!p.internal_ok).filter((f) => !(packFileKey(f.copy, f.lang, f.format) in (p.files ?? {})));
}

function PackRow({ p, showSubject, onStored }: { p: PackHead & { may_store?: boolean }; showSubject: boolean; onStored: () => void }) {
  const { t } = useI18n();
  const dl = useAction();
  const mk = useAction();
  const [progress, setProgress] = useState<string | null>(null);
  const files = p.files ?? {};
  const missing = missingFiles(p);
  const take = (copy: Copy, lang: Lang, format: PackFormat) => dl.run(() => (packFileKey(copy, lang, format) in files
    ? openPackFile(p, copy, lang, format) : drawPackFile(p, copy, lang, format)));
  const store = () => mk.run(async () => {
    try { await makePackFiles(p, !!p.internal_ok, (n, of) => setProgress(t('ep.making', { n, m: of }))); }
    finally { setProgress(null); onStored(); }
  });
  return (
    <li data-testid="pack-row" data-ref={p.ref} data-status={p.status} data-subject={p.subject_kind}>
      <div className="row">
        <strong>{showSubject ? t(`ep.of.${p.subject_kind}`, { code: p.subject_code }) : t('ep.version', { n: p.version })}</strong>
        <span className="mono small">{p.ref}</span>
        <Badge value={p.status === 'valid' ? 'verified' : p.status === 'withdrawn' ? 'fail' : 'closed'} label={t(`srep.st.${p.status}`)} />
      </div>
      <div className="small muted">{showSubject ? `${t('ep.version', { n: p.version })} · ` : ''}{dateTime(p.issued_at)}{p.issued_by ? ` · ${p.issued_by}` : ''}
        {` · ${t(p.auto ? 'ep.auto' : 'ep.on_demand')}`}
        {p.superseded_by && <> · {t('srep.superseded_by', { ref: p.superseded_by })}</>}</div>
      <div className="stack small" data-testid="pack-files">
        {(['shareable', 'internal'] as Copy[]).map((copy) => {
          const mine = readerFiles(p).filter((f) => f.copy === copy);
          return mine.length === 0 ? null : (
            <div key={copy} className="report-files"><span className="muted">{t(`exp.copy_${copy}`)}:</span>
              {mine.map((f) => {
                const k = packFileKey(f.copy, f.lang, f.format);
                return (
                  <button key={k} type="button" className="linkish" disabled={dl.busy} data-testid={`pack-file-${k}`} data-stored={k in files ? 'yes' : 'no'}
                    onClick={() => void take(f.copy, f.lang, f.format)}>
                    {f.format === 'json' ? t('ep.file_json') : `${t('srep.file.pdf')} ${f.lang === 'hi' ? 'हिन्दी' : 'English'}`}</button>);
              })}
            </div>);
        })}
        <Link to={`/d/${p.ref}`} data-testid="pack-verify">{t('srep.verify_page')}</Link>
      </div>
      {p.may_store && missing.length > 0 && (
        <button className="small" disabled={mk.busy} onClick={() => void store()} data-testid="pack-store">{t('ep.store', { n: missing.length })}</button>)}
      {progress && <p className="small" role="status" data-testid="pack-progress">{progress}</p>}
      <ErrorBox error={dl.error ?? mk.error} />
    </li>
  );
}

/** The card. `kind` 'scope' lists every pack of a scope (no issuing there: a pack is issued from its record or order). */
export function EvidencePacks({ kind, id }: { kind: PackKind | 'scope'; id: string }) {
  const { t } = useI18n();
  const d = useAsync(() => evidencePacks(kind, id), [kind, id]);
  const act = useAction();
  const [confirm, setConfirm] = useState(false);
  const packs = (d.data?.packs ?? []) as (PackHead & { may_store?: boolean })[];
  const current = packs.filter((p) => p.status === 'valid');
  const earlier = packs.filter((p) => p.status !== 'valid');
  const showSubject = kind === 'scope';
  if (d.loading && !d.data) return <div className="card"><Loading /></div>;
  if (!d.data) return <div className="card"><ErrorBox error={d.error} onRetry={d.reload} /></div>;
  if (packs.length === 0 && !d.data.may_issue) return null;   // nothing this reader may read or make (a stage's operator)
  return (
    <div className="card" data-testid="evidence-packs" data-kind={kind}>
      <h2>{t('ep.card')}</h2>
      <p className="small muted">{t(kind === 'order' ? 'ep.card_note_order' : 'ep.card_note')}</p>
      {packs.length === 0 && <p className="small muted" data-testid="pack-none">{t(kind === 'lot' || kind === 'shipment' ? 'ep.none_record' : 'ep.none')}</p>}
      {current.length > 0 && <ul className="reports" data-testid="pack-list">
        {current.map((p) => <PackRow key={p.id} p={p} showSubject={showSubject} onStored={d.reload} />)}</ul>}
      {earlier.length > 0 && (
        <details className="small" data-testid="pack-earlier"><summary>{t('ep.earlier', { n: earlier.length })}</summary>
          <ul className="reports">{earlier.map((p) => <PackRow key={p.id} p={p} showSubject={showSubject} onStored={d.reload} />)}</ul>
        </details>)}
      {d.data.may_issue && kind !== 'scope' && (confirm
        ? <div className="stack" data-testid="pack-issue-confirm">
            <p className="small">{t(packs.length ? 'ep.issue_again_note' : 'ep.issue_note', { n: (packs[0]?.version ?? 0) + 1 })}</p>
            <div className="row">
              <button disabled={act.busy} data-testid="pack-issue-go" onClick={() => void act.run(async () => {
                await issueEvidencePack(kind, id); setConfirm(false); d.reload();
              })}>{t('ep.issue_go')}</button>
              <button className="secondary" disabled={act.busy} onClick={() => setConfirm(false)}>{t('common.cancel')}</button>
            </div>
          </div>
        : <button className="secondary small" onClick={() => setConfirm(true)} data-testid="pack-issue">{t(packs.length ? 'ep.issue_again' : 'ep.issue')}</button>)}
      <ErrorBox error={act.error} />
    </div>
  );
}
