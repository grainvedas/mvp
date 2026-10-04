// F12 public verify page: what a buyer or consumer sees after scanning the bag. No login. Loaded on its own (code
// split) so the first load stays small on a 3G phone. Farmer phone numbers are never part of the data it receives.
import { useParams } from 'react-router-dom';
import { useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { ErrorBox, Loading } from '../../shell/ui';
import { loadJourney, seasonName, type JourneyStep, stepDate } from './journey';

const date = (s?: string | null) => (s ? new Date(s).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '');
const kg = (n?: number | null) => (n === null || n === undefined ? '' : `${Number(n).toLocaleString('en-IN', { maximumFractionDigits: 1 })} kg`);
const pretty = (s: string) => s.replace(/_pct$/, '').replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());

export function PublicVerify() {
  const { code = '' } = useParams();
  const { t, lang, setLang } = useI18n();
  const j = useAsync(() => loadJourney(code), [code]);
  return (
    <div className="pv">
      <header className="pv-top">
        <span className="brand"><img src="/icon.svg" alt="" width={28} height={28} /> GrainVeda</span>
        <select aria-label="Language" value={lang} onChange={(e) => setLang(e.target.value as 'en' | 'hi')} style={{ width: 'auto' }}>
          <option value="en">English</option><option value="hi">हिन्दी</option>
        </select>
      </header>
      <main style={{ maxWidth: 640 }}>
        {j.loading && <Loading />}
        <ErrorBox error={j.error} onRetry={j.reload} />
        {!j.loading && !j.error && !j.data && (
          <div className="card"><h1>{t('pv.not_found')}</h1><p>{t('pv.not_found_body', { code })}</p></div>
        )}
        {j.data && (
          <div data-testid="public-journey">
            <section className="pv-hero card">
              <p className="pv-ok">✓ {t('pv.verified')}</p>
              <h1>{j.data.crop.name}</h1>
              {j.data.crop.gi_tag && <p><span className="badge gi">{j.data.crop.gi_tag}</span> {j.data.crop.origin}</p>}
              <p className="muted">{seasonName(j.data.season)} · {j.data.geography} · {j.data.client.name}</p>
              <p>{t('pv.quality')}: {t('pv.domestic')} <span className={`badge ${j.data.verdict.domestic}`}>{t(`pv.v_${j.data.verdict.domestic}`)}</span>
                {' · '}{t('pv.export')} <span className={`badge ${j.data.verdict.export}`}>{t(`pv.v_${j.data.verdict.export}`)}</span>
                {j.data.verdict.overridden && <> <span className="badge pending">{t('pv.override')}</span></>}</p>
              <p className="mono small">{j.data.qr_code}{j.data.batch_codes.length > 0 && ` · ${t('pv.batch')} ${j.data.batch_codes.join(', ')}`}</p>
            </section>
            <h2>{t('pv.journey')}</h2>
            <ol className="pv-timeline">{j.data.journey.map((s) => <Step key={s.code} s={s} />)}</ol>
            <section className="card small">
              <p>{t('pv.how')}</p>
              <p className="muted">{t('pv.sealed_on', { date: date(j.data.sealed_at) })} · {t('pv.fingerprint')} <span className="mono">{j.data.ledger_hash.slice(0, 16)}…</span></p>
            </section>
          </div>
        )}
      </main>
    </div>
  );
}

function Step({ s }: { s: JourneyStep }) {
  const { t } = useI18n();
  return (
    <li className="pv-step">
      <div className="pv-dot" aria-hidden="true" />
      <div>
        <strong>{t(`pv.stage_${s.stage}`, undefined, pretty(s.stage))}</strong>
        <span className="muted small"> · {date(stepDate(s))}{s.qty_out_kg ? ` · ${kg(s.qty_out_kg)}` : ''}{s.grade ? ` · Grade ${s.grade}` : ''}</span>
        {s.farmer && <div>{t('pv.grown_by', { name: s.farmer.name, place: `${s.farmer.village}, ${s.farmer.district}` })}</div>}
        {s.farmers && s.farmers.length > 0 && (
          <div>{t('pv.farmers_of', { n: s.farmers.length, village: s.village ?? '' })}
            <ul className="small">{s.farmers.map((f) => <li key={f.name}>{f.name}, {f.village} · {kg(f.qty_kg)}</li>)}</ul></div>
        )}
        {s.source && <div>{t('pv.from_source', { name: s.source.name })}</div>}
        {s.readings && Object.keys(s.readings).length > 0 && (
          <table className="small"><tbody>{Object.entries(s.readings).map(([k, v]) => <tr key={k}><td>{pretty(k)}</td><td className="num">{v}{k.endsWith('_pct') ? ' %' : ''}</td></tr>)}</tbody></table>
        )}
        {s.batch_code && <div className="small">{t('pv.batch')} <span className="mono">{s.batch_code}</span></div>}
        {s.destination && <div>{t('pv.shipped_to', { place: s.destination })}{s.dispatched_on ? ` · ${date(s.dispatched_on)}` : ''}</div>}
      </div>
    </li>
  );
}
