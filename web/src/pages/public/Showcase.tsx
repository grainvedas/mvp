// Migration 72 (Phase 3, release 5, Part E3): the showcase page, Basic, at /verified/<client code>. The client's name;
// its verified states with their crops and seasons and the headline figures; "Verify any pack"; the active recall
// notices; a sourcing partner only where it agreed to be named. Never a price, a farmer's name or phone, a buyer's name
// (the server sends none). Never active-looking when the client is not: "Verification paused", "Verification ended on …";
// after the lifetime period only that verification ended. An own-brand client: "Operated by GrainVeda (own brand)".
// Its own chunk; its words are the public page's (src/lib/i18n.public.ts).
import { useState, type FormEvent } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useI18n } from '../../lib/i18n';
import { useAsync } from '../../lib/useAsync';
import { ErrorBox, Loading } from '../../shell/ui';
import { PublicFrame, pvDate } from './PublicVerify';
import { figure, publicShowcase, verifyPath, type ShowcaseData } from '../../lib/showcase';

function StatusLine({ status, ended }: { status: 'active' | 'paused' | 'ended'; ended: string | null }) {
  const { t } = useI18n();
  return <span className={`badge ${status === 'active' ? 'verified' : status === 'paused' ? 'pending' : 'closed'}`} data-testid="sc-state-status" data-status={status}>
    {status === 'active' ? t('sc.st.active') : status === 'paused' ? t('pv.verification_paused') : t('pv.verification_ended', { date: pvDate(ended) })}</span>;
}

/** The page's content: the public page's, and the owner's preview of it. */
export function ShowcaseView({ d, preview = false }: { d: ShowcaseData; preview?: boolean }) {
  const { t } = useI18n();
  const nav = useNavigate();
  const [code, setCode] = useState('');
  const v = d.verification;
  const go = (e: FormEvent) => { e.preventDefault(); const p = verifyPath(code); if (p) nav(p); };
  return (
    <div className="stack" data-testid="showcase" data-status={v?.status ?? 'none'}>
      {preview && <div className="alert info" role="status" data-testid="sc-preview">{t('sc.preview')}</div>}
      <section className="card">
        <p className="small muted">{t('sc.eyebrow')}</p>
        <h1 data-testid="sc-name">{d.name}</h1>
        {d.own_brand && <p data-testid="sc-own-brand"><strong>{t('pv.own_brand')}</strong></p>}
        {d.expired ? (
          <div className="alert info" role="status" data-testid="sc-expired">{t('sc.expired', { date: pvDate(v?.ended_on ?? null) })}</div>
        ) : v?.status === 'paused' ? (
          <div className="alert warn" role="status" data-testid="sc-banner" data-status="paused"><strong>{t('pv.verification_paused')}</strong>
            <div className="small">{t('sc.paused_note')}</div></div>
        ) : v?.status === 'ended' ? (
          <div className="alert info" role="status" data-testid="sc-banner" data-status="ended"><strong>{t('pv.verification_ended', { date: pvDate(v.ended_on) })}</strong>
            <div className="small">{t('sc.ended_note')}</div></div>
        ) : <p data-testid="sc-banner" data-status="active"><span className="badge verified">{t('sc.st.active')}</span></p>}
      </section>
      {!d.expired && d.totals && (
        <section className="card" data-testid="sc-totals">
          <h2>{t('sc.figures')}</h2>
          <dl className="kv">
            <dt>{t('sc.tonnes')}</dt><dd data-testid="sc-tonnes">{figure('tonnes', d.totals.tonnes)}</dd>
            <dt>{t('sc.villages')}</dt><dd data-testid="sc-villages">{figure('villages', d.totals.villages)}</dd>
            <dt>{t('sc.gi_share')}</dt><dd data-testid="sc-gi">{figure('pct', d.totals.gi_pct)}</dd>
            <dt>{t('sc.lab_pass')}</dt><dd data-testid="sc-lab">{figure('pct', d.totals.lab_pass_pct)}</dd>
          </dl>
          <p className="small muted">{t('sc.figures_note')}</p>
        </section>)}
      {!d.expired && (
        <section className="card" data-testid="sc-verify">
          <h2>{t('sc.verify_any')}</h2>
          <form className="row" onSubmit={go}>
            <input aria-label={t('sc.verify_any')} placeholder={t('sc.verify_placeholder')} value={code} onChange={(e) => setCode(e.target.value)}
              style={{ flex: '1 1 200px', minWidth: 0 }} data-testid="sc-code" autoComplete="off" />
            <button type="submit" disabled={!verifyPath(code)} data-testid="sc-go">{t('sc.verify_go')}</button>
          </form>
          <p className="small muted">{t('sc.verify_note')}</p>
        </section>)}
      {!d.expired && !!d.recalls?.length && (
        <section className="card" data-testid="sc-recalls">
          <h2>{t('sc.recalls')}</h2>
          <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
            {d.recalls.map((r) => (
              <li key={r.qr_code} className="alert error" data-testid="sc-recall">
                <strong>{t('sc.recalled')}</strong> · <Link to={`/verify/${encodeURIComponent(r.qr_code)}`} className="mono">{r.qr_code}</Link>
                <div className="small">{r.crop} · {r.season}{r.at ? ` · ${pvDate(r.at)}` : ''}</div>
                {r.reason && <div className="small">“{r.reason}”</div>}
              </li>))}
          </ul>
        </section>)}
      {!d.expired && !!d.states?.length && (
        <section className="card" data-testid="sc-states">
          <h2>{t('sc.states')}</h2>
          <div className="stack">
            {d.states.map((s) => (
              <div key={s.state} data-testid="sc-state" data-state={s.state}>
                <h3>{s.state} <StatusLine status={s.status} ended={s.ended_on} /></h3>
                {s.crops.length === 0 ? <p className="small muted">{t('sc.no_scopes')}</p> : (
                  <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
                    {s.crops.map((c) => (
                      <li key={`${c.crop}-${c.season}`} data-testid="sc-crop">
                        <strong>{c.crop}</strong> · {c.season}
                        <div className="small">{t('sc.crop_line', { t: figure('tonnes', c.tonnes), v: figure('villages', c.villages),
                          gi: figure('pct', c.gi_pct), lab: figure('pct', c.lab_pass_pct) })}</div>
                      </li>))}
                  </ul>)}
              </div>))}
          </div>
        </section>)}
      {!d.expired && !!d.partners?.length && (
        <section className="card" data-testid="sc-partners"><h2>{t('sc.partners')}</h2><p>{d.partners.join(', ')}</p></section>)}
      <p className="small muted" data-testid="sc-footer">{t('dv.footer')}</p>
    </div>
  );
}

export default function Showcase() {
  const { code = '' } = useParams();
  const { t } = useI18n();
  const s = useAsync(() => publicShowcase(code), [code]);
  return (
    <PublicFrame>
      {s.loading && <Loading />}
      <ErrorBox error={s.error} onRetry={s.reload} />
      {!s.loading && !s.error && !s.data && (
        <div className="card" data-testid="sc-none"><h1>{t('sc.none_title')}</h1><p>{t('sc.none', { code: code.toUpperCase() })}</p></div>)}
      {s.data && <ShowcaseView d={s.data} />}
    </PublicFrame>
  );
}
