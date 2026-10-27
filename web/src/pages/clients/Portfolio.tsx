// Migration 68 (Phase 3, release 2 of Veda's combined brief of 19 Oct 2026: Parts C and E4). What client users see,
// and the exports of every view.
//   /portfolio                 the signed-in client account's own client (its owner and viewers; a viewer the scopes it
//                              reaches); tabs: the portfolio, across scopes, the farmers
//   /portfolio/:clientId       the same for GrainVeda's people who read the client (the admin, its State and Client
//                              Managers), from the client's page
//   /portfolio/scope/:scopeId  one scope
// The server decides who reads what and what a reader may see (prices and farmers' names only for those who may take
// the internal copy); nothing here hides anything the server sent. Each view downloads as Excel or CSV: the shareable
// copy by default, the internal one for those allowed; every download is in the Audit log.
import { useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import { useAuth } from '../../auth/AuthProvider';
import { useI18n } from '../../lib/i18n';
import { useAsync, useAction } from '../../lib/useAsync';
import { date, dateTime, humanise, kg, num } from '../../lib/format';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { Stat } from '../dashboard/parts';
import { EvidencePacks } from '../records/EvidencePacks';
import { ShowcaseCard } from './ShowcaseCard';
import type { Copy } from '../../lib/exports';
import { clientAcross, clientPortfolio, clientScopeDetail, cvCsv, cvXlsx, exportClientView, FIGURES, type Figures, type View } from '../../lib/clientViews';

type T = (key: string, vars?: Record<string, string | number>, fallback?: string) => string;

/** Pure: a figure as the screen shows it (kilograms with their unit; counts as numbers). */
export function figureText(key: keyof Figures, v: number | string | null | undefined): string {
  return key.endsWith('_kg') ? kg(v) : num(v, 0);
}

/** The download of a view: the copy (the internal one only for those allowed), then Excel or CSV. */
export function ExportBar({ view, client, scope, mayInternal }: { view: View; client: string | null; scope: string | null; mayInternal: boolean }) {
  const { t } = useI18n();
  const act = useAction();
  const [copy, setCopy] = useState<Copy>('shareable');
  const go = (fmt: 'xlsx' | 'csv') => void act.run(async () => {
    const e = await exportClientView(view, client, scope, copy);
    if (fmt === 'xlsx') await cvXlsx(e, t); else cvCsv(e, t);
  });
  return (
    <div className="stack no-print" data-testid={`cv-export-${view}`}>
      {mayInternal && (
        <Field label={t('cv.copy')} htmlFor={`cv-copy-${view}`}>
          <select id={`cv-copy-${view}`} value={copy} onChange={(e) => setCopy(e.target.value as Copy)} data-testid="cv-copy">
            <option value="shareable">{t('exp.copy_shareable')}</option>
            <option value="internal">{t('exp.copy_internal')}</option>
          </select>
        </Field>)}
      <div className="row" style={{ justifyContent: 'flex-start' }}>
        <button type="button" className="secondary" onClick={() => go('xlsx')} disabled={act.busy} data-testid={`cv-xlsx-${view}`}>{t('cv.excel')}</button>
        <button type="button" className="secondary" onClick={() => go('csv')} disabled={act.busy} data-testid={`cv-csv-${view}`}>{t('cv.csv')}</button>
      </div>
      <p className="small muted">{t(copy === 'internal' ? 'cv.internal_note' : 'cv.shareable_note')}</p>
      <ErrorBox error={act.error} />
    </div>
  );
}

/** A scope's or a group's figures: two to a row on a phone, four on a laptop (styles.css, .cv-figs). */
function FigureList({ f, t, testId }: { f: Figures; t: T; testId?: string }) {
  return (
    <div className="cv-figs" data-testid={testId}>
      {FIGURES.map((k) => <div key={k} className="cv-fig"><span>{t(`cv.c.${k}`)}</span><strong data-testid={`fig-${k}`}>{figureText(k, f[k])}</strong></div>)}
    </div>
  );
}

export function PortfolioPage() {
  const { clientId: param } = useParams();
  const { ctx } = useAuth();
  const { t } = useI18n();
  const [sp, setSp] = useSearchParams();
  const own = ctx?.user?.client_account?.kind !== 'operator' ? ctx?.user?.client_account?.client_id : undefined;
  const clientId = param ?? own ?? '';
  const tab = (['portfolio', 'across', 'farmers'].includes(sp.get('tab') ?? '') ? sp.get('tab') : 'portfolio') as 'portfolio' | 'across' | 'farmers';
  const pf = useAsync(() => (clientId ? clientPortfolio(clientId) : Promise.resolve(null)), [clientId]);
  if (!clientId) return <div><h1>{t('cv.title')}</h1><Empty>{t('cv.no_client')}</Empty></div>;
  const d = pf.data;
  return (
    <div data-testid="portfolio">
      {param && <p className="small muted"><Link to={`/clients/${clientId}`}>{d?.client.name ?? t('nav.clients')}</Link></p>}
      <h1>{t('cv.title')}</h1>
      {d && <p className="muted">{d.client.name}{d.client.code && <> · <span className="mono">{d.client.code}</span></>}</p>}
      <div className="tabs" role="tablist">
        {(['portfolio', 'across', 'farmers'] as const).map((k) => (
          <button key={k} type="button" role="tab" aria-selected={tab === k} className={tab === k ? 'active' : ''}
            onClick={() => setSp(k === 'portfolio' ? {} : { tab: k }, { replace: true })} data-testid={`cv-tab-${k}`}>{t(`cv.tab.${k}`)}</button>))}
      </div>
      {pf.loading && !d ? <Loading /> : <ErrorBox error={pf.error} onRetry={pf.reload} />}
      {d && tab === 'portfolio' && <PortfolioTab d={d} t={t} />}
      {d && tab === 'across' && <AcrossTab clientId={clientId} t={t} />}
      {d && tab === 'farmers' && <FarmersTab clientId={clientId} mayInternal={d.may_internal} isClient={!param} t={t} />}
    </div>
  );
}

function PortfolioTab({ d, t }: { d: NonNullable<Awaited<ReturnType<typeof clientPortfolio>>>; t: T }) {
  const tt = d.total;
  return (
    <>
      <div className="stats" data-testid="cv-totals">
        <Stat value={kg(tt.procured_kg)} label={t('cv.c.procured_kg')} sub={t('cv.n_scopes', { n: tt.scopes })} />
        <Stat value={num(tt.packed_packs, 0)} label={t('cv.c.packed_packs')} sub={kg(tt.packed_kg)} />
        <Stat value={kg(tt.shipped_kg)} label={t('cv.c.shipped_kg')} sub={`${t('cv.c.sold_kg')}: ${kg(tt.sold_kg)}`} />
        <Stat value={num(tt.waiting, 0)} label={t('cv.c.waiting')} sub={t('cv.waiting_sub')} />
      </div>
      {d.scopes.length === 0 && <Empty>{t('cv.no_scopes')}</Empty>}
      {d.groups.length > 0 && (
        <div className="card">
          <h2>{t('cv.by_state_crop')}</h2>
          <div className="stack">
            {d.groups.map((g) => (
              <div key={`${g.state_id}-${g.crop_id}`} className="cv-group" data-testid="cv-group">
                <h3>{g.state ?? '—'} · {g.crop} <span className="muted small">{t('cv.n_scopes', { n: g.scopes })}</span></h3>
                <FigureList f={g} t={t} />
              </div>))}
          </div>
        </div>)}
      {d.scopes.length > 0 && (
        <div className="card">
          <h2>{t('cv.scopes')}</h2>
          <div className="stack">
            {d.scopes.map((s) => (
              <div key={s.scope_id} className="cv-scope" data-testid="cv-scope">
                <h3><Link to={`/portfolio/scope/${s.scope_id}`}>{s.label}</Link></h3>
                <p className="small muted">{s.state ?? '—'} · <Badge value={s.status} /> · {t(`sd.${s.delivery_model}`, undefined, humanise(s.delivery_model))}</p>
                <FigureList f={s} t={t} />
              </div>))}
          </div>
        </div>)}
      <div className="card">
        <h2>{t('cv.download')}</h2>
        <ExportBar view="portfolio" client={d.client.id} scope={null} mayInternal={d.may_internal} />
      </div>
      <ShowcaseCard clientId={d.client.id} />   {/* migration 72 (E3) */}
    </>
  );
}

function AcrossTab({ clientId, t }: { clientId: string; t: T }) {
  const a = useAsync(() => clientAcross(clientId), [clientId]);
  if (a.loading && !a.data) return <Loading />;
  if (!a.data) return <ErrorBox error={a.error} onRetry={a.reload} />;
  const d = a.data;
  return (
    <>
      {(d.client_orders ?? []).length > 0 && (
        <div className="card" data-testid="cv-client-orders">
          <h2>{t('cv.t.client_orders')}</h2>
          <p className="small muted">{t('cv.client_orders_what')}</p>
          <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
            {(d.client_orders ?? []).map((o) => (
              <li key={o.id} className="cv-row" data-testid="cv-client-order">
                <div><Link to={`/orders/${o.id}`} className="mono"><strong>{o.code}</strong></Link> · {o.buyer ?? '—'} · <span className="mono small">{o.order_no}</span></div>
                <div className="small muted">{t(`exp.mkt.${o.market === 'domestic' ? 'domestic' : 'export'}`)}{o.destination_country ? ` · ${o.destination_country}` : ''}
                  {o.invoice_no ? <> · {t('ord.invoice')} <span className="mono">{o.invoice_no}</span></> : ''}</div>
                <div className="small">{t('ord.parts_line', { parts: o.parts, scopes: o.scopes })} · {t('cv.order_line', { kg: kg(o.qty_kg), shipped: kg(o.shipped_kg) })}</div>
              </li>))}
          </ul>
        </div>)}
      <div className="card" data-testid="cv-orders">
        <h2>{t('cv.t.orders')}</h2>
        {d.orders.length === 0 ? <Empty /> : (
          <div className="stack">
            {d.orders.map((o) => (
              <div key={o.code} className="cv-row" data-testid="cv-order">
                <div><strong>{o.buyer ?? '—'}</strong> · <span className="mono small">{o.order_no ?? o.code}</span></div>
                <div className="small muted">{o.scope} · {date(o.on)} · {t(`exp.mkt.${o.market}`, undefined, o.market ?? '')}{o.destination_country ? ` · ${o.destination_country}` : ''}
                  {o.client_order && <> · {t('cv.part_of', { code: o.client_order })}</>}</div>
                <div className="small">{t('cv.order_line', { kg: kg(o.qty_kg), shipped: kg(o.shipped_kg) })}
                  {d.internal && o.price_per_kg != null && <span data-testid="cv-price"> · {o.currency ? t('cv.price_line', { price: num(o.price_per_kg), currency: o.currency, total: num(o.total_value) })
                    : t('cv.price_line_nocur', { price: num(o.price_per_kg), total: num(o.total_value) })}</span>}</div>
              </div>))}
          </div>)}
        {!d.internal && d.orders.length > 0 && <p className="small muted">{t('cv.no_prices')}</p>}
      </div>
      <div className="card" data-testid="cv-buyers">
        <h2>{t('cv.t.buyers')}</h2>
        {d.buyers.length === 0 ? <Empty /> : (
          <div className="table-wrap"><table>
            <thead><tr><th>{t('cv.c.buyer')}</th><th>{t('cv.c.orders')}</th><th>{t('cv.c.qty_kg')}</th><th>{t('cv.c.shipped_kg')}</th></tr></thead>
            <tbody>{d.buyers.map((b) => <tr key={b.buyer}><td>{b.buyer}</td><td className="num">{b.orders}</td><td className="num">{kg(b.qty_kg)}</td><td className="num">{kg(b.shipped_kg)}</td></tr>)}</tbody>
          </table></div>)}
      </div>
      <div className="card" data-testid="cv-scans">
        <h2>{t('cv.t.scans_by_city')}</h2>
        {d.scans_by_city.length === 0 ? <Empty /> : (
          <div className="table-wrap"><table>
            <thead><tr><th>{t('cv.c.city')}</th><th>{t('cv.c.scans')}</th><th>{t('cv.c.last_at')}</th></tr></thead>
            <tbody>{d.scans_by_city.map((c, i) => (
              <tr key={i}><td>{[c.city ?? t('cv.unknown_place'), c.country].filter(Boolean).join(', ')}</td><td className="num">{c.scans}</td><td>{dateTime(c.last_at)}</td></tr>))}</tbody>
          </table></div>)}
      </div>
      <div className="card" data-testid="cv-flags">
        <h2>{t('cv.t.copy_flags')}</h2>
        {d.copy_flags.length === 0 ? <Empty /> : (
          <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
            {d.copy_flags.map((f) => (
              <li key={`${f.serial}-${f.kind}`}><span className="mono small">{f.serial}</span> · {t(`cv.kind.${f.kind}`, undefined, humanise(f.kind))} · <Badge value={f.status} />
                <div className="small muted">{f.scope} · {dateTime(f.raised_at)}</div></li>))}
          </ul>)}
      </div>
      <div className="card" data-testid="cv-recalls">
        <h2>{t('cv.t.recalls')}</h2>
        {d.recalls.length === 0 ? <Empty>{t('cv.no_recalls')}</Empty> : (
          <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
            {d.recalls.map((r) => (
              <li key={r.qr_code}><span className="mono">{r.qr_code}</span> · <Badge value={r.status === 'recalled' ? 'fail' : 'pending'} label={t(`cv.release.${r.status}`)} />
                <div className="small muted">{r.scope} · {dateTime(r.at)}{r.reason ? ` · “${r.reason}”` : ''}</div></li>))}
          </ul>)}
      </div>
      <div className="card" data-testid="cv-outputs">
        <h2>{t('cv.t.outputs')}</h2>
        {d.outputs.length === 0 ? <Empty>{t('cv.no_outputs')}</Empty> : (
          <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
            {d.outputs.map((r) => (
              <li key={`${r.ref}-${r.version}`}><span className="mono">{r.ref}</span> · {t(`cv.kind.${r.kind}`, undefined, humanise(r.kind))} · v{r.version} · <Badge value={r.status} />
                <div className="small muted">{r.scope} · {dateTime(r.issued_at)}</div></li>))}
          </ul>)}
      </div>
      <div className="card">
        <h2>{t('cv.download')}</h2>
        <ExportBar view="across" client={clientId} scope={null} mayInternal={d.may_internal} />
      </div>
    </>
  );
}

function FarmersTab({ clientId, mayInternal, isClient, t }: { clientId: string; mayInternal: boolean; isClient: boolean; t: T }) {
  return (
    <div className="card" data-testid="cv-farmers">
      <h2>{t('cv.tab.farmers')}</h2>
      <p>{t('cv.farmers_what')}</p>
      {isClient && <p><Link to="/farmers">{t('cv.farmers_open')}</Link></p>}
      <ExportBar view="farmers" client={clientId} scope={null} mayInternal={mayInternal} />
    </div>
  );
}

export function ScopeView() {
  const { scopeId = '' } = useParams();
  const { ctx } = useAuth();
  const { t } = useI18n();
  const r = useAsync(() => clientScopeDetail(scopeId), [scopeId]);
  if (r.loading && !r.data) return <Loading />;
  if (!r.data) return <ErrorBox error={r.error} onRetry={r.reload} />;
  const d = r.data;
  const seasonReports = d.reports.filter((x) => x.kind === 'season_report');   // migration 71: the packs have their own card
  const mine = ctx?.user?.client_account?.client_id === d.client.id;
  const stage = (s: string) => t(`stage.${s}`, undefined, humanise(s));
  return (
    <div data-testid="cv-scope-view">
      <p className="small muted"><Link to={mine ? '/portfolio' : `/portfolio/${d.client.id}`}>{t('cv.title')}</Link> · {d.client.name}</p>
      <h1>{d.head.label}</h1>
      <p className="muted">{[d.head.geography, d.head.state].filter(Boolean).join(', ')} · <Badge value={d.head.status} /> · {t(`sd.${d.head.delivery_model}`, undefined, humanise(d.head.delivery_model))}
        {d.head.gi_tag && <> · {d.head.gi_tag}</>}</p>

      <div className="card">
        <h2>{t('cv.figures')}</h2>
        <FigureList f={d.figures} t={t} testId="cv-scope-figs" />
      </div>

      <div className="card" data-testid="cv-pipeline">
        <h2>{t('cv.t.pipeline')}</h2>
        <div className="table-wrap"><table>
          <thead><tr><th>{t('cv.c.stage')}</th><th>{t('cv.c.records')}</th><th>{t('cv.pending_short')}</th><th>{t('cv.c.kg_out')}</th><th>{t('cv.kg_waiting_short')}</th></tr></thead>
          <tbody>{d.pipeline.map((p) => (
            <tr key={p.stage}><td>{p.pos}. {stage(p.stage)}</td><td className="num">{p.records}</td><td className="num">{p.pending}</td>
              <td className="num">{kg(p.kg_out)}</td><td className="num">{kg(p.kg_waiting)}</td></tr>))}</tbody>
        </table></div>
      </div>

      <div className="card" data-testid="cv-lots">
        <h2>{t('cv.t.lots')}</h2>
        {d.lots.length === 0 ? <Empty /> : (
          <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
            {d.lots.map((l) => (
              <li key={l.qr_code}><span className="mono">{l.qr_code}</span> · <Badge value={l.release === 'active' ? 'verified' : l.release === 'recalled' ? 'fail' : 'pending'} label={t(`cv.release.${l.release}`)} />
                <div className="small muted">{l.lot} · {dateTime(l.sealed_at)} · {t('cv.packs_live', { n: l.packs_live })}</div>
                {l.batches && <div className="small muted mono">{l.batches}</div>}</li>))}
          </ul>)}
        <h3>{t('cv.t.batches')}</h3>
        {d.batches.length === 0 ? <Empty /> : (
          <ul className="stack" style={{ listStyle: 'none', padding: 0 }} data-testid="cv-batches">
            {d.batches.map((b) => (
              <li key={b.batch_code}><span className="mono small">{b.batch_code}</span>
                <div className="small">{t('cv.batch_line', { packs: b.packs, released: b.released, held: b.held })}
                  {b.void > 0 && <> · {t('cv.batch_void', { n: b.void })}</>}{b.best_before && <> · {t('cv.c.best_before')} {date(b.best_before)}</>}</div></li>))}
          </ul>)}
      </div>

      <div className="card" data-testid="cv-qc">
        <h2>{t('cv.t.qc')}</h2>
        {d.qc.length === 0 ? <Empty /> : (
          <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
            {d.qc.map((q) => (
              <li key={q.code}><span className="mono small">{q.code}</span> · <Badge value={q.status} />
                <div className="small">{[q.lab, q.report_no && t('cv.report_no', { no: q.report_no }), q.report_date && date(q.report_date)].filter(Boolean).join(' · ') || '—'}</div>
                <div className="small">
                  {(['domestic', 'export'] as const).filter((m) => q[m]).map((m) => (
                    <span key={m} className="cv-verdict">{t(`exp.mkt.${m}`, undefined, m)}: <Badge value={q[m] === 'pass' ? 'verified' : q[m] === 'fail' ? 'fail' : 'pending'} label={t(`cv.verdict.${q[m]}`)} /> </span>))}
                  {q.accepted && <span className="muted"> · {t('cv.accepted')}</span>}{q.decided && <span className="muted"> · {t('cv.decided')}</span>}
                </div></li>))}
          </ul>)}
      </div>

      <div className="card" data-testid="cv-documents">
        <h2>{t('cv.t.documents')}</h2>
        {d.documents.length === 0 ? <Empty /> : (
          <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
            {d.documents.map((x, i) => (
              <li key={i}>{t(`cv.kind.${x.kind}`, undefined, humanise(x.kind))}: {x.what ?? '—'}
                <span className="small muted"> · {x.on_file ? t('cv.on_file') : t('cv.not_on_file')}{x.record ? ` · ${x.record}` : ''}</span></li>))}
          </ul>)}
      </div>

      <div className="card" data-testid="cv-reports">
        <h2>{t('cv.t.reports')}</h2>
        {seasonReports.length === 0 ? <Empty>{t('cv.no_outputs')}</Empty> : (
          <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
            {seasonReports.map((x) => (
              <li key={`${x.ref}-${x.version}`}><span className="mono">{x.ref}</span> · {t(`cv.kind.${x.kind}`, undefined, humanise(x.kind))} · v{x.version} · <Badge value={x.status} />
                <div className="small muted">{dateTime(x.issued_at)}</div></li>))}
          </ul>)}
      </div>
      {/* migration 71 (E1): the scope's evidence packs, each with its files (the internal copy where the account may read it) */}
      <EvidencePacks kind="scope" id={scopeId} />

      <div className="card" data-testid="cv-people">
        <h2>{t('cv.t.people')}</h2>
        <p className="small muted">{t('cv.people_note')}</p>
        {d.people.length === 0 ? <Empty /> : (
          <dl className="kv">
            {d.people.map((p, i) => <PersonPair key={i} stage={stage(p.stage)} name={p.name} staff={p.client_staff} t={t} />)}
          </dl>)}
      </div>

      <div className="card">
        <h2>{t('cv.download')}</h2>
        <ExportBar view="scope" client={null} scope={scopeId} mayInternal={d.may_internal} />
      </div>
    </div>
  );
}
function PersonPair({ stage, name, staff, t }: { stage: string; name: string; staff: boolean; t: T }) {
  return <><dt>{stage}</dt><dd>{name}{staff && <span className="muted small"> · {t('cv.client_staff')}</span>}</dd></>;
}
