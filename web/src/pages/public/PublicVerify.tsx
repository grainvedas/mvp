// F12 public verify page: what a buyer or consumer sees after scanning the bag. No login. Loaded on its own (code
// split) so the first load stays small on a 3G phone. Farmer phone numbers are never part of the data it receives.
// Migration 50 (Part D): no farmer's name either (the village, the district, the season); a recall shows here and on
// every pack; each scan is counted (time and code only).
import { useEffect, type ReactNode } from 'react';
import { useParams } from 'react-router-dom';
import { useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { ErrorBox, Loading } from '../../shell/ui';
import { countScan, loadJourney, seasonName, type Journey, type JourneyStep, stepDate } from './journey';
import { giLabel } from '../../lib/gi';

export const pvDate = (s?: string | null) => (s ? new Date(s).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'Asia/Kolkata' }) : '');   // India's time (Veda, 15 Oct)
const date = pvDate;
const kg = (n?: number | null) => (n === null || n === undefined ? '' : `${Number(n).toLocaleString('en-IN', { maximumFractionDigits: 1 })} kg`);
const pretty = (s: string) => s.replace(/_pct$/, '').replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());

/** Pure: the "how this record is kept" sentence. It claims a check by the next person only when the server says every
 *  step had one (brief 1b): a step recorded and checked by the same person, or recorded by a manager acting for the
 *  stage, gets the plainer sentence. An older server that does not say gets the sentence that claims no check at all. */
// migration 46 (Veda, 14 Oct): when one person recorded a step and checked it, the approved words say so
export const howKey = (independent: boolean | undefined, samePerson?: boolean) =>
  samePerson ? 'pv.how_same_person' : independent === true ? 'pv.how' : independent === false ? 'pv.how_mixed' : 'pv.how_basic';

/** Pure: the place a farmer step names (never the farmer: migration 50, Part D). */
export const farmPlace = (f: { village?: string | null; district?: string | null }) => [f.village, f.district].filter(Boolean).join(', ');

/** The page around a public view: the brand and the language. */
export function PublicFrame({ children }: { children: ReactNode }) {
  const { lang, setLang } = useI18n();
  return (
    <div className="pv">
      <header className="pv-top">
        <span className="brand"><img src="/icon.svg" alt="" width={28} height={28} /> GrainVeda</span>
        <select aria-label="Language" value={lang} onChange={(e) => setLang(e.target.value as 'en' | 'hi')} style={{ width: 'auto' }}>
          <option value="en">English</option><option value="hi">हिन्दी</option>
        </select>
      </header>
      <main style={{ maxWidth: 640 }}>{children}</main>
    </div>
  );
}

export function PublicVerify() {
  const { code = '' } = useParams();
  const { t } = useI18n();
  const j = useAsync(() => loadJourney(code), [code]);
  useEffect(() => { if (code) countScan(code); }, [code]);
  return (
    <PublicFrame>
      {j.loading && <Loading />}
      <ErrorBox error={j.error} onRetry={j.reload} />
      {!j.loading && !j.error && !j.data && (
        <div className="card"><h1>{t('pv.not_found')}</h1><p>{t('pv.not_found_body', { code })}</p></div>
      )}
      {j.data && <JourneyView j={j.data} />}
    </PublicFrame>
  );
}

/** A recall (or an investigation) stands above everything else on the page. */
export function ReleaseNotice({ r }: { r: Journey['release'] }) {
  const { t } = useI18n();
  if (!r || r.status === 'active') return null;
  return (
    <div className={`alert ${r.status === 'recalled' ? 'error' : 'warn'}`} role="alert" data-testid="pv-release" data-status={r.status}>
      <strong>{t(`pv.rel_${r.status}`)}</strong>{r.reason ? <div>{t('pv.rel_reason', { reason: r.reason })}</div> : null}
      {r.at && <div className="small">{pvDate(r.at)}</div>}
    </div>
  );
}

export function JourneyView({ j, top }: { j: Journey; top?: ReactNode }) {
  const { t } = useI18n();
  return (
    <div data-testid="public-journey">
      <ReleaseNotice r={j.release} />
      {top}
      <section className="pv-hero card">
        <p className="pv-ok">✓ {t('pv.verified')}</p>
        <h1>{j.crop.name}</h1>
        {/* migration 49 (G7): "GI Tag No. 280", and only when every source of the lot is from the GI area (an older server: as before) */}
        {j.crop.gi_tag && j.gi_status !== 'non_gi' && j.gi_status !== 'unknown' && <p data-testid="pv-gi"><span className="badge gi">{giLabel(j.crop.gi_tag, t)}</span> {j.crop.origin}</p>}
        {j.farmer_count !== undefined && j.farmer_count > 0 && <p data-testid="pv-farmer-count">{t('pv.farmer_count', { n: j.farmer_count })}</p>}
        <p className="muted">{seasonName(j.season)} · {j.geography} · {j.client.name}</p>
        {/* an export released by the client's written acceptance is "released", never "passed" (migration 50) */}
        <p>{t('pv.quality')}: {t('pv.domestic')} <span className={`badge ${j.verdict.domestic}`}>{t(`pv.v_${j.verdict.domestic}`)}</span>
          {' · '}{t('pv.export')} <span className={`badge ${j.verdict.export}`}>{t(`pv.v_${j.verdict.export}`)}</span>
        </p>
        {j.verdict.overridden && <p className="small" data-testid="pv-released-not-passed">{t('pv.override')}</p>}
        {j.packs && j.packs.n > 0 && <p className="small" data-testid="pv-packs">{t('pv.packs', { n: j.packs.n, on: pvDate(j.packs.packed_on) })}
          {j.packs.best_before ? ` · ${t('pv.best_before', { date: pvDate(j.packs.best_before) })}` : ''}</p>}
        <p className="mono small">{j.qr_code}{j.batch_codes.length > 0 && ` · ${t('pv.batch')} ${j.batch_codes.join(', ')}`}</p>
      </section>
      <h2>{t('pv.journey')}</h2>
      <ol className="pv-timeline">{j.journey.map((s) => <Step key={s.code} s={s} />)}</ol>
      <section className="card small">
        <p data-testid="pv-how">{t(howKey(j.independent, j.same_person))}</p>
        <p className="muted">{t('pv.sealed_on', { date: date(j.sealed_at) })} · {t('pv.fingerprint')} <span className="mono">{j.ledger_hash.slice(0, 16)}…</span></p>
      </section>
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
        {s.farmer && <div data-testid="pv-grown-in">{t('pv.grown_in', { place: farmPlace(s.farmer) })}</div>}
        {s.farmers && s.farmers.length > 0 && (
          <div>{t('pv.farmers_of', { n: s.farmers.length, village: s.village ?? '' })}
            <ul className="small">{s.farmers.map((f, i) => <li key={`${f.village}-${i}`}>{farmPlace(f)} · {kg(f.qty_kg)}</li>)}</ul></div>
        )}
        {s.source && <div>{t('pv.from_source', { name: s.source.name })}</div>}
        {s.readings && Object.keys(s.readings).length > 0 && (
          <table className="small"><tbody>{Object.entries(s.readings).map(([k, v]) => <tr key={k}><td>{pretty(k)}</td><td className="num">{v}{k.endsWith('_pct') ? ' %' : k.endsWith('_kg') ? ' kg' : ''}</td></tr>)}</tbody></table>
        )}
        {s.markets && s.markets.length > 0 && (
          <div className="small" data-testid="pv-markets">{t('pv.by_market')}: {s.markets.map((m, i) => (
            <span key={m.code}>{i > 0 ? ' · ' : ''}{m.name} <span className={`badge ${m.verdict}`}>{t(`pv.v_${m.verdict}`)}</span></span>))}</div>
        )}
        {typeof s.days_in_storage === 'number' && <div data-testid="pv-storage">{t('pv.days_in_storage', { n: s.days_in_storage })}</div>}
        {s.batch_code && <div className="small">{t('pv.batch')} <span className="mono">{s.batch_code}</span></div>}
        {s.destination && <div>{t('pv.shipped_to', { place: s.destination })}{s.dispatched_on ? ` · ${date(s.dispatched_on)}` : ''}</div>}
      </div>
    </li>
  );
}
