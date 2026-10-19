// F12 public verify page: what a buyer or consumer sees after scanning the bag. No login. Loaded on its own (code
// split) so the first load stays small on a 3G phone. Farmer phone numbers are never part of the data it receives.
// Migration 50 (Part D): no farmer's name either (the village, the district, the season); a recall shows here and on
// every pack; each scan is counted (time and code only).
// Migration 57 (release 10, Veda 16 Oct 2026: "make a good UI, current is so boring"; G21 "this line should not
// appear"): the provenance story of the GrainVeda design system (a deep green hero, the villages by share, the journey
// step by step, the lab readings beside each market's limit, the pack's scans). It never says that one person recorded
// and checked a step: a step says "checked by another person" only where the server says so.
// Migration 59 (Veda's brief of 19 Oct 2026): A2 a step recorded and checked by one person says so ("Recorded and
// checked by the same person."); A3 each reading's unit comes from the server; A1 a pack serial opened here before its
// lot is released shows "Packed, not yet released" (crop, batch code, date packed); "Code not found" only for a code
// that is neither a sealed lot nor a pack.
import { useEffect, type ReactNode } from 'react';
import { useParams } from 'react-router-dom';
import { useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { ErrorBox, Loading } from '../../shell/ui';
import { countScan, loadJourney, loadPack, seasonName, type Journey, type JourneyStep, type MarketLimit, type PackBeforeRelease, type PackView, stepDate } from './journey';
import { giLabel } from '../../lib/gi';

export const pvDate = (s?: string | null) => (s ? new Date(s).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'Asia/Kolkata' }) : '');   // India's time (Veda, 15 Oct)
const date = pvDate;
const kg = (n?: number | null) => (n === null || n === undefined ? '' : `${Number(n).toLocaleString('en-IN', { maximumFractionDigits: 1 })} kg`);
const pretty = (s: string) => s.replace(/_(pct|ppb|ppm|kg)$/, '').replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());

/** Pure: the "how this record is kept" sentence. It claims a check by the next person only when the server says every
 *  step had one (brief 1b). Otherwise the plain sentence, which claims no check at all: migration 57 (G21, Veda: "this
 *  line should not appear") took away the sentences that said one person recorded and checked a step. */
export const howKey = (independent: boolean | undefined) => (independent === true ? 'pv.how' : 'pv.how_basic');

/** Pure: the place a farmer step names (never the farmer: migration 50, Part D). */
export const farmPlace = (f: { village?: string | null; district?: string | null }) => [f.village, f.district].filter(Boolean).join(', ');

/** Pure: a reading's unit from its key. */
export const readingUnit = (k: string) => (k.endsWith('_pct') ? '%' : k.endsWith('_ppb') ? 'ppb' : k.endsWith('_ppm') ? 'ppm' : k.endsWith('_kg') ? 'kg' : '');

export interface ReadingRow { key: string; label: string; value: number | string | boolean; unit: string;
  /** the strictest upper limit of the markets it was judged against (null: none, or not an upper limit) */ limit: number | null;
  /** the bar's length, 0 to 100 (null: no bar) */ pct: number | null; within: boolean | null }
/** Pure (migration 57): the lab readings of the lot, each beside the strictest upper limit among the markets it was
 *  judged against (a bar for "at most"; other kinds of limit show no bar). */
export function readingRows(steps: JourneyStep[], units?: Record<string, string>): ReadingRow[] {
  const rows: ReadingRow[] = [];
  for (const s of steps) {
    if (!s.readings) continue;
    const limits: MarketLimit[] = (s.markets ?? []).flatMap((m) => m.limits ?? []);
    for (const [key, value] of Object.entries(s.readings)) {
      if (rows.some((r) => r.key === key)) continue;
      const ups = limits.filter((l) => l.param === key && (l.operator === '<=' || l.operator === '<') && typeof l.limit === 'number').map((l) => l.limit as number);
      const limit = ups.length ? Math.min(...ups) : null;
      const v = typeof value === 'number' ? value : Number.NaN;
      const pct = limit !== null && limit > 0 && Number.isFinite(v) ? Math.max(2, Math.min(100, Math.round((v / limit) * 100))) : null;
      rows.push({ key, label: pretty(key), value, unit: units?.[key] ?? readingUnit(key), limit, pct, within: limit !== null && Number.isFinite(v) ? v <= limit : null });
    }
  }
  return rows;
}

/** The page around a public view: the brand and the language. */
export function PublicFrame({ children }: { children: ReactNode }) {
  const { lang, setLang } = useI18n();
  return (
    <div className="pv">
      <header className="pv-top">
        <span className="brand"><img src="/icon.svg" alt="" width={26} height={26} /> GrainVeda</span>
        <select aria-label="Language" value={lang} onChange={(e) => setLang(e.target.value as 'en' | 'hi')} className="pv-lang">
          <option value="en">English</option><option value="hi">हिन्दी</option>
        </select>
      </header>
      <main>{children}</main>
    </div>
  );
}

export function PublicVerify() {
  const { code = '' } = useParams();
  const { t } = useI18n();
  // migration 59 (A1): a code that is no sealed lot may be a pack's serial (a label read by another app, or typed)
  const j = useAsync(async () => {
    const lot = await loadJourney(code);
    return { lot, pack: lot ? null : await loadPack(code) };
  }, [code]);
  useEffect(() => { if (code) void countScan(code); }, [code]);
  const lot = j.data?.lot ?? null, pk = j.data?.pack ?? null;
  return (
    <PublicFrame>
      {j.loading && <Loading />}
      <ErrorBox error={j.error} onRetry={j.reload} />
      {!j.loading && !j.error && !lot && !pk && (
        <div className="card"><h1>{t('pv.not_found')}</h1><p>{t('pv.not_found_body', { code })}</p></div>
      )}
      {lot && <JourneyView j={lot} />}
      {pk && pk.released && <JourneyView j={pk} pack={pk.pack} warn={pk.pack.copy_warning === true} />}
      {pk && !pk.released && <PackNotReleased p={pk} />}
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

// ---- icons (inline, drawn in the text colour; the design system's emoji are not used on this page) ----
const P: Record<string, ReactNode> = {
  wheat: <><path d="M12 21V9" /><path d="M12 9c-2.5 0-4-1.8-4-4 2.5 0 4 1.8 4 4zm0 0c2.5 0 4-1.8 4-4-2.5 0-4 1.8-4 4z" /><path d="M12 15c-2.5 0-4-1.8-4-4 2.5 0 4 1.8 4 4zm0 0c2.5 0 4-1.8 4-4-2.5 0-4 1.8-4 4z" /></>,
  truck: <><path d="M3 6h11v10H3z" /><path d="M14 10h4l3 3v3h-7" /><circle cx="7" cy="17" r="2" /><circle cx="17" cy="17" r="2" /></>,
  store: <><path d="M3 10l9-6 9 6v10H3z" /><path d="M8 20v-6h8v6" /></>,
  gear: <><circle cx="12" cy="12" r="3" /><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1" /></>,
  flask: <><path d="M9 3h6" /><path d="M10 3v6l-5 9a2 2 0 0 0 1.8 3h10.4a2 2 0 0 0 1.8-3l-5-9V3" /></>,
  box: <><path d="M3 7l9-4 9 4v10l-9 4-9-4z" /><path d="M3 7l9 4 9-4" /><path d="M12 11v10" /></>,
  doc: <><path d="M6 3h9l3 3v15H6z" /><path d="M9 10h6M9 14h6M9 18h4" /></>,
  check: <path d="M5 12.5l4.5 4.5L19 7.5" />,
  shield: <><path d="M12 3l7 3v5c0 4.5-3 8.2-7 9.5C8 19.2 5 15.5 5 11V6l7-3z" /><path d="M9 12l2 2 4-4" /></>,
  pin: <><path d="M12 21s-6-5.6-6-11a6 6 0 0 1 12 0c0 5.4-6 11-6 11z" /><circle cx="12" cy="10" r="2.2" /></>,
  scan: <><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3" /><path d="M7 12h10" /></>,
  people: <><circle cx="9" cy="8" r="3" /><path d="M3 20c0-3.3 2.7-6 6-6s6 2.7 6 6" /><circle cx="17" cy="9" r="2.4" /><path d="M15.5 14.2A5 5 0 0 1 21 19" /></>,
  alert: <><path d="M12 4l9 16H3z" /><path d="M12 10v4M12 17v.5" /></>,
};
export function Icon({ name, size = 20, width = 1.8 }: { name: keyof typeof P | string; size?: number; width?: number }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={width} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{P[name] ?? P.doc}</svg>;
}
const STAGE_ICON: Record<string, string> = {
  procurement: 'wheat', lot_inward: 'truck', village_batch: 'truck', warehouse: 'store', cold_storage: 'store',
  milling: 'gear', sorting: 'gear', grading: 'gear', drying: 'gear', popping: 'gear', cleaning: 'gear', blanching: 'gear',
  qc: 'flask', packing: 'box', commercial: 'doc', shipment: 'truck', qr_activation: 'check',
};

export function JourneyView({ j, pack, warn }: { j: Journey; pack?: PackView; warn?: boolean }) {
  const { t } = useI18n();
  const villages = j.villages ?? [];
  const gi = !!j.crop.gi_tag && j.gi_status !== 'non_gi' && j.gi_status !== 'unknown';
  const rows = readingRows(j.journey, j.units);
  const markets = j.journey.flatMap((s) => s.markets ?? []);
  return (
    <div data-testid="public-journey">
      <ReleaseNotice r={j.release} />
      <section className="pv-hero" data-testid="pv-hero">
        <p className="pv-kicker"><Icon name="shield" size={18} width={2} /> {t(gi ? 'pv.kicker_gi' : 'pv.kicker')}</p>
        <h1>{j.crop.name}</h1>
        {villages.length > 0 && (j.farmer_count ?? 0) > 0
          ? <p className="pv-lede" data-testid="pv-farmer-count">{t(villages.length === 1 ? 'pv.grown_farmers_1v' : 'pv.grown_farmers', { n: j.farmer_count!, v: villages.length })} · {j.geography} · {seasonName(j.season)}</p>
          : <>{j.farmer_count !== undefined && j.farmer_count > 0 && <p className="pv-lede" data-testid="pv-farmer-count">{t('pv.farmer_count', { n: j.farmer_count })}</p>}
              <p className="pv-lede">{seasonName(j.season)} · {j.geography}</p></>}
        <div className="pv-chips">
          <span className="pv-chip mono">{pack ? pack.serial : j.qr_code}</span>
          {/* migration 49 (G7): "GI Tag No. 280", and only when every source of the lot is from the GI area */}
          {gi && <span className="pv-chip" data-testid="pv-gi">{giLabel(j.crop.gi_tag!, t)}</span>}
        </div>
        <div className="pv-seal">
          <span className="pv-seal-dot"><Icon name="check" size={22} width={2.4} /></span>
          <div><strong>{t(pack ? 'pv.sealed_title_pack' : 'pv.sealed_title')}</strong>
            <span>{t('pv.sealed_line', { date: date(j.sealed_at), client: j.client.name })}</span></div>
        </div>
      </section>

      <div className="pv-body">
        {pack && <PackAlerts pack={pack} warn={!!warn} />}
        {pack && pack.scans && !pack.void && <ScanTiles pack={pack} warn={!!warn} />}

        {villages.length > 0 && (
          <section className="pv-card" data-testid="pv-villages">
            <p className="pv-label">{t('pv.where_grown')}</p>
            <h2>{t(villages.length === 1 ? 'pv.villages_title_1v' : 'pv.villages_title', { v: villages.length, n: j.farmer_count ?? villages.reduce((a, x) => a + x.farmers, 0) })}</h2>
            {villages.map((v) => (
              <div className="pv-bar-row" key={`${v.village}-${v.district}`}>
                <div className="pv-bar-hd"><strong>{farmPlace(v)}</strong><span>{t('pv.share_line', { pct: Number(v.share_pct).toLocaleString('en-IN'), n: v.farmers })}</span></div>
                <div className="pv-bar"><span style={{ width: `${Math.max(2, Math.min(100, Number(v.share_pct)))}%` }} /></div>
              </div>))}
            <p className="pv-note">{t('pv.shares_note')}</p>
          </section>
        )}

        <section className="pv-card" data-testid="pv-journey">
          <p className="pv-label">{t('pv.journey_to_you')}</p>
          <h2>{t('pv.journey')}</h2>
          <ol className="pv-timeline">{j.journey.map((s, i) => <Step key={s.code} s={s} last={i === j.journey.length - 1} />)}</ol>
        </section>

        <section className="pv-card" data-testid="pv-lab">
          <p className="pv-label">{t('pv.lab')}</p>
          {/* an export released by the client's written acceptance is "released", never "passed" (migration 50) */}
          <p className="pv-verdicts">{t('pv.quality')}: {t('pv.domestic')} <span className={`badge ${j.verdict.domestic}`}>{t(`pv.v_${j.verdict.domestic}`)}</span>
            {' · '}{t('pv.export')} <span className={`badge ${j.verdict.export}`}>{t(`pv.v_${j.verdict.export}`)}</span></p>
          {j.verdict.overridden && <p className="small" data-testid="pv-released-not-passed">{t('pv.override')}</p>}
          {markets.length > 0 && (
            <p className="small" data-testid="pv-markets">{t('pv.by_market')}: {markets.map((m, i) => (
              <span key={`${m.code}-${i}`}>{i > 0 ? ' · ' : ''}{m.name} <span className={`badge ${m.verdict}`}>{t(`pv.v_${m.verdict}`)}</span></span>))}</p>
          )}
          {rows.map((r) => (
            <div className="pv-bar-row" key={r.key} data-testid="pv-reading">
              <div className="pv-bar-hd"><strong>{r.label}</strong>
                <span><b>{String(r.value)}{r.unit ? ` ${r.unit}` : ''}</b>{r.limit !== null && <span className="pv-muted"> · {t('pv.limit', { v: `${r.limit}${r.unit ? ` ${r.unit}` : ''}` })}</span>}</span></div>
              {r.pct !== null && <div className="pv-bar thin"><span className={r.within === false ? 'over' : ''} style={{ width: `${r.pct}%` }} /></div>}
            </div>))}
        </section>

        {pack ? <PackCard pack={pack} lot={j.packs} /> : j.packs && j.packs.n > 0 && (
          <section className="pv-card sand"><p className="small" data-testid="pv-packs">{t('pv.packs', { n: j.packs.n, on: pvDate(j.packs.packed_on) })}
            {j.packs.best_before ? ` · ${t('pv.best_before', { date: pvDate(j.packs.best_before) })}` : ''}</p>
            {j.batch_codes.length > 0 && <p className="small mono">{t('pv.batch')} {j.batch_codes.join(', ')}</p>}</section>
        )}

        <section className="pv-foot">
          <p className="pv-story" data-testid="pv-how">{t(howKey(j.independent))}</p>
          <p className="small pv-muted">{t('pv.sealed_on', { date: date(j.sealed_at) })} · {t('pv.fingerprint')} <span className="mono">{j.ledger_hash.slice(0, 16)}…</span></p>
        </section>
      </div>
    </div>
  );
}

function Step({ s, last }: { s: JourneyStep; last: boolean }) {
  const { t } = useI18n();
  const gate = s.stage === 'qr_activation';
  const meta = [date(stepDate(s)).toUpperCase(), s.farmer ? s.farmer.village : ''].filter(Boolean).join(' · ');
  return (
    <li className={`pv-step${last ? ' last' : ''}`}>
      <div className="pv-rail"><span className={`pv-icon${gate ? ' gold' : ''}`}><Icon name={STAGE_ICON[s.stage] ?? 'doc'} width={gate ? 2.4 : 1.8} /></span>{!last && <span className="pv-line" />}</div>
      <div className="pv-step-body">
        <span className="pv-meta">{meta}</span>
        <strong className="pv-step-title">{t(`pv.stage_${s.stage}`, undefined, pretty(s.stage))}</strong>
        <span className="pv-detail">{[s.qty_out_kg && !gate ? kg(s.qty_out_kg) : '', s.grade ? `Grade ${s.grade}` : ''].filter(Boolean).join(' · ')}</span>
        {s.farmer && <span className="pv-detail" data-testid="pv-grown-in">{t('pv.grown_in', { place: farmPlace(s.farmer) })}</span>}
        {s.farmers && s.farmers.length > 0 && <span className="pv-detail">{t('pv.farmers_of', { n: s.farmers.length, village: s.village ?? '' })}</span>}
        {s.source && <span className="pv-detail">{t('pv.from_source', { name: s.source.name })}</span>}
        {typeof s.days_in_storage === 'number' && <span className="pv-detail" data-testid="pv-storage">{t('pv.days_in_storage', { n: s.days_in_storage })}</span>}
        {s.batch_code && <span className="pv-detail">{t('pv.batch')} <span className="mono">{s.batch_code}</span></span>}
        {s.destination && <span className="pv-detail">{t('pv.shipped_to', { place: s.destination })}{s.dispatched_on ? ` · ${date(s.dispatched_on)}` : ''}</span>}
        {gate && <span className="pv-detail">{t('pv.sealed_step')}</span>}
        {s.checked === true && <span className="pv-checked" data-testid="pv-checked"><Icon name="people" size={14} width={2} />{t('pv.checked')}</span>}
        {s.same_person === true && <span className="pv-detail" data-testid="pv-same-person">{t('pv.same_person')}</span>}
      </div>
    </li>
  );
}

function PackAlerts({ pack, warn }: { pack: PackView; warn: boolean }) {
  const { t } = useI18n();
  return (<>
    {warn && !pack.void && <div className="pv-warn" role="alert" data-testid="pv-copy-warning"><Icon name="alert" size={22} width={2} />
      <span>{pack.seller ? t('pv.copy_warning', { seller: pack.seller }) : t('pv.copy_warning_plain')}</span></div>}
    {pack.void && <div className="alert error" role="alert" data-testid="pv-void">{t('pv.pack_void')}</div>}
  </>);
}

function ScanTiles({ pack, warn }: { pack: PackView; warn: boolean }) {
  const { t } = useI18n();
  const sc = pack.scans!;
  return (
    <div className="pv-tiles" data-testid="pv-scans">
      <div className="pv-tile"><Icon name="scan" size={18} width={2} /><b>{sc.n.toLocaleString('en-IN')}</b><span>{t('pv.scans_n')}</span></div>
      <div className="pv-tile"><Icon name="pin" size={18} width={2} /><b className="pv-city">{sc.first_city ?? '—'}</b><span>{t('pv.first_scan')}</span></div>
      <div className={`pv-tile${warn ? ' warn' : ' good'}`}><Icon name={warn ? 'alert' : 'shield'} size={18} width={2} />
        <b className="pv-city">{t(warn ? 'pv.being_checked' : 'pv.no_copies')}</b><span>{t(warn ? 'pv.being_checked_sub' : 'pv.no_copies_sub')}</span></div>
    </div>
  );
}

function PackCard({ pack, lot }: { pack: PackView; lot?: Journey['packs'] }) {
  const { t } = useI18n();
  return (
    <section className="pv-card sand" data-testid="pv-pack">
      <p className="pv-label">{t('pv.this_pack')}</p>
      <dl className="pv-kv">
        <dt>{t('pv.pack')}</dt><dd className="mono">{pack.serial}</dd>
        <dt>{t('pv.weight')}</dt><dd>{Number(pack.size_kg).toLocaleString('en-IN')} kg</dd>
        <dt>{t('pv.batch')}</dt><dd className="mono">{pack.batch_code}</dd>
        {pack.carton && <><dt>{t('pv.carton')}</dt><dd className="mono" data-testid="pv-carton">{pack.carton}</dd></>}
        <dt>{t('pv.packed')}</dt><dd>{pvDate(pack.packed_on)}</dd>
        {pack.best_before && <><dt>{t('pv.best_before_label')}</dt><dd>{pvDate(pack.best_before)}</dd></>}
        {pack.seller && <><dt>{t('pv.sold_by')}</dt><dd>{pack.seller}</dd></>}
      </dl>
      {lot && lot.n > 0 && <p className="small pv-muted" data-testid="pv-packs" style={{ margin: 0 }}>{t('pv.packs', { n: lot.n, on: pvDate(lot.packed_on) })}</p>}
    </section>
  );
}

/** A pack that is not released yet (migration 59, A1): "Packed, not yet released", the crop, the batch code and the
 *  date packed; nothing else. */
/** A pack before its lot is released (migration 59, A1): the crop, serial, batch code and date packed. A voided pack says
 *  so; a code scanned far apart or very often is warned of, without the seller's name. */
export function PackNotReleased({ p, warn = false }: { p: PackBeforeRelease; warn?: boolean }) {
  const { t } = useI18n();
  return (
    <div data-testid="public-pack">
      <section className="pv-hero">
        <h1>{p.crop.name}</h1>
        <div className="pv-chips"><span className="pv-chip mono">{p.pack.serial}</span></div>
      </section>
      <div className="pv-body">
        {p.pack.void ? <div className="alert error" role="alert" data-testid="pv-void">{t('pv.pack_void')}</div>
          : <div className="alert info" data-testid="pv-not-released">{t('pv.not_released')}</div>}
        {!p.pack.void && (warn || p.pack.copy_warning === true) && <div className="pv-warn" role="alert" data-testid="pv-copy-warning"><Icon name="alert" size={22} width={2} />
          <span>{t('pv.copy_warning_plain')}</span></div>}
        <section className="pv-card sand" data-testid="pv-pack">
          <dl className="pv-kv">
            <dt>{t('pv.batch')}</dt><dd className="mono">{p.pack.batch_code}</dd>
            <dt>{t('pv.packed')}</dt><dd>{pvDate(p.pack.packed_on)}</dd>
          </dl>
        </section>
      </div>
    </div>
  );
}
