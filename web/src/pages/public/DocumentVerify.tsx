// Migration 63 (Phase 1, Part D3): "Verify this document". A report's QR opens /d/<reference>: whether the report is
// Valid, Superseded (by which version) or Withdrawn, when it was issued and to whom, and the SHA-256 of each of its files,
// so a file in hand can be checked against what GrainVeda issued. Nothing else of the report is shown here.
// Migration 71 (E1): an evidence pack's page says what it is of (a sealed lot, a shipment, a client order) and in how many
// scopes; its files are its PDF (English, Hindi) and its JSON.
import { useParams } from 'react-router-dom';
import { rpc } from '../../lib/api';
import { useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { ErrorBox, Loading } from '../../shell/ui';
import { PublicFrame } from './PublicVerify';

interface Doc { ref: string; kind: string; final: boolean; version: number; status: 'valid' | 'superseded' | 'withdrawn'; issued_at: string; issued_to: string;
  period_from: string | null; period_to: string | null; crop: string; season: string; geography: string; state: string | null;
  superseded_by: string | null; superseded_at: string | null; withdrawn_at: string | null;
  /** migration 71 */ subject_kind?: 'lot' | 'shipment' | 'order' | null; subject?: string | null; scopes?: number;
  files: { copy: string; format: string; lang: string; sha256: string; bytes: number }[] }

const day = (s: string | null) => (s ? new Date(s).toLocaleDateString('en-IN', { dateStyle: 'medium', timeZone: 'Asia/Kolkata' }) : '—');

export function DocumentVerify() {
  const { ref = '' } = useParams();
  const { t } = useI18n();
  const d = useAsync(() => rpc<Doc | null>('public_document', { p_ref: ref }), [ref]);
  const doc = d.data;
  const pack = doc?.kind === 'evidence_pack';
  const tone = doc?.status === 'valid' ? 'ok' : doc?.status === 'withdrawn' ? 'error' : 'warn';
  return (
    <PublicFrame>
      {d.loading && <Loading />}
      <ErrorBox error={d.error} onRetry={d.reload} />
      {!d.loading && !d.error && !doc && <div className="card" data-testid="dv-not-found"><h1>{t('dv.not_found')}</h1><p>{t('dv.not_found_text', { ref })}</p></div>}
      {doc && (
        <div className="card" data-testid="dv-doc">
          <p className="small muted">{t('dv.what')}</p>
          <h1>{t(pack ? 'dv.title_ep' : 'dv.title')}</h1>
          <div className={`alert ${tone}`} role="status" data-testid="dv-status" data-status={doc.status}>
            <strong>{t(`dv.st.${doc.status}`)}</strong>
            {doc.status === 'superseded' && doc.superseded_by && <> · {t('dv.superseded_by', { ref: doc.superseded_by })}</>}
            {doc.status === 'withdrawn' && <> · {t('dv.withdrawn_on', { on: day(doc.withdrawn_at) })}</>}
          </div>
          <dl className="kv">
            <dt>{t('dv.ref')}</dt><dd className="mono" data-testid="dv-ref">{doc.ref}</dd>
            <dt>{t(pack ? 'dv.kind_ep' : 'dv.kind')}</dt><dd data-testid="dv-kind">{pack ? t('dv.ep', { n: doc.version }) : doc.final ? t('dv.final', { n: doc.version }) : t('dv.interim', { n: doc.version })}</dd>
            {pack && doc.subject && <><dt>{t('dv.of')}</dt><dd data-testid="dv-subject">{t(`dv.of.${doc.subject_kind}`, { code: doc.subject })}</dd></>}
            <dt>{t('dv.issued')}</dt><dd data-testid="dv-issued">{day(doc.issued_at)}</dd>
            <dt>{t('dv.issued_to')}</dt><dd data-testid="dv-issued-to">{doc.issued_to}</dd>
            <dt>{t('dv.covers')}</dt><dd data-testid="dv-covers">{(doc.scopes ?? 1) > 1 ? `${doc.crop} · ${doc.season} · ${t('dv.scopes', { n: doc.scopes ?? 1 })}`
              : [doc.crop, doc.season, doc.geography, doc.state].filter(Boolean).join(' · ')}</dd>
            {(doc.period_from || doc.period_to) && <><dt>{t('dv.period')}</dt><dd>{day(doc.period_from)} – {day(doc.period_to)}</dd></>}
          </dl>
          <h2>{t('dv.files')}</h2>
          {doc.files.length === 0 ? <p className="small muted">{t('dv.no_files')}</p> : (
            <ul className="dv-files" data-testid="dv-files">
              {doc.files.map((f) => (
                <li key={`${f.format}-${f.lang}-${f.copy}`} data-testid="dv-file">
                  <div className="small"><strong>{t(`dv.f.${f.format}`)}</strong>{f.format === 'json' ? '' : ` · ${f.lang === 'hi' ? 'हिन्दी' : 'English'}`} · {t(`dv.c.${f.copy}`)}</div>
                  <div className="mono small dv-hash">SHA-256 {f.sha256}</div>
                </li>))}
            </ul>)}
          <p className="small muted">{t('dv.how')}</p>
          <p className="small muted">{t('dv.footer')}</p>
        </div>)}
    </PublicFrame>
  );
}
