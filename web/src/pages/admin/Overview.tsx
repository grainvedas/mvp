// The admin's first screen (Veda, 10 Oct 2026: "Admin is oversight only… uses the dashboard to make strategic
// decisions"). Everything here is read: one call (app.platform_overview) counts the whole platform on the server.
//   role guide and set-up checklist (ticks itself) · number cards that open their detail · state selector and client
//   cards grouped by state · a client opened read-only · pipeline · volume by state and by crop.
// Nothing on this screen writes; the admin's own acts (states, seats, State Managers, ledger check) are on their pages.
import { useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { useAuth } from '../../auth/AuthProvider';
import { rpc } from '../../lib/api';
import { useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { date, humanise, kg, num } from '../../lib/format';
import { Badge, Empty, ErrorBox, Loading } from '../../shell/ui';
import { RoleGuide } from '../../shell/RoleGuide';
import { useScope } from '../../shell/scope';
import { LedgerHealth, StatButton } from '../dashboard/parts';

export interface OverviewClient {
  id: string; name: string; code: string; type: string; state_id: string | null; state_name: string | null;
  scopes_active: number; scopes_total: number; kg: number; qr: number; people: number; unstaffed: number; has_manager: boolean;
}
export interface Overview {
  clients: { total: number; active: number; dormant: number; without_manager: number; list: OverviewClient[] };
  crops: { total: number; list: { id: string; name: string; code: string; scopes_active: number; scopes_total: number }[] };
  scopes: { active: number; setup: number; closed: number; qr_issued: number };
  attention: {
    open_flags: number; farmers_step1: number; farmers_step2: number; unstaffed: number;
    unstaffed_list: { scope_id: string; client_id: string; client: string; scope: string; stage_type: string; stage: string }[];
    flags_list: { id: string; text: string; created_at: string; footprint_id: string; record: string; client: string }[];
  };
  states: { id: string; name: string; code: string; managers: number }[];
  pipeline: { stage_type: string; label: string; sort_order: number; pending: number; done: number; kg_pending: number; oldest_pending: string | null }[];
  volume_by_state: { id: string; name: string; kg: number; lots: number; qr: number }[];
  volume_by_crop: { id: string; name: string; unit: string | null; kg: number; lots: number; qr: number }[];
  setup: { states: number; hr_admin: boolean; state_managers: number };
}

/** Pure: the "needs attention" total is the sum of what its panel lists, so the card and the panel never disagree. */
export const attentionTotal = (a: Overview['attention']) =>
  Number(a.open_flags) + Number(a.farmers_step1) + Number(a.farmers_step2) + Number(a.unstaffed);

/** Pure: client cards grouped by state, in state order; one state when a state is chosen. */
export function clientsByState(list: OverviewClient[], stateId: string): { state: string; clients: OverviewClient[] }[] {
  const out = new Map<string, OverviewClient[]>();
  for (const c of list) {
    if (stateId && c.state_id !== stateId) continue;
    const k = c.state_name ?? '—';
    out.set(k, [...(out.get(k) ?? []), c]);
  }
  return [...out.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([state, clients]) => ({ state, clients }));
}

type Panel = 'clients' | 'crops' | 'scopes' | 'attention' | null;

export function AdminOverview() {
  const { ctx } = useAuth();
  const { t } = useI18n();
  const me = ctx!.user!;
  const [params, setParams] = useSearchParams();
  const o = useAsync(() => rpc<Overview>('platform_overview'), []);
  const [panel, setPanel] = useState<Panel>(null);
  const [stateId, setStateId] = useState('');
  const clientId = params.get('client');
  const open = (p: Panel) => setPanel((x) => (x === p ? null : p));
  const d = o.data;
  const client = d && clientId ? d.clients.list.find((c) => c.id === clientId) ?? null : null;
  const exitClient = () => { const n = new URLSearchParams(params); n.delete('client'); setParams(n, { replace: true }); };
  const openClient = (id: string) => { const n = new URLSearchParams(params); n.set('client', id); setParams(n); };

  return (
    <>
      <div className="band">
        <div><h1>{t('ov.title')}</h1><div className="sub">{t('ov.sub')}</div></div>
        <div className="side">{me.display_name}<br />{t('role.admin')}</div>
      </div>
      {o.loading && !d ? <Loading /> : <ErrorBox error={o.error} onRetry={() => void o.reload()} />}
      {d && client && <ClientView c={client} d={d} onExit={exitClient} />}
      {d && clientId && !client && <div className="alert warn">{t('ov.client_gone')} <button className="secondary" onClick={exitClient}>{t('ov.exit')}</button></div>}
      {d && !clientId && (
        <>
          <RoleGuide role="admin"><SetupChecklist s={d.setup} /></RoleGuide>
          <LedgerHealth />
          <div className="stats" data-testid="ov-stats">
            <StatButton testId="ov-tile-clients" open={panel === 'clients'} onClick={() => open('clients')} value={String(d.clients.total)} label={t('ov.clients')}
              sub={t('ov.clients_sub', { a: d.clients.active, d: d.clients.dormant })} />
            <StatButton testId="ov-tile-crops" open={panel === 'crops'} onClick={() => open('crops')} value={String(d.crops.total)} label={t('ov.crops')}
              sub={t('ov.crops_sub', { n: d.crops.list.filter((c) => Number(c.scopes_active) > 0).length })} />
            <StatButton testId="ov-tile-scopes" open={panel === 'scopes'} onClick={() => open('scopes')} value={String(d.scopes.active)} label={t('ov.scopes')}
              sub={t('ov.scopes_sub', { s: d.scopes.setup, c: d.scopes.closed })} />
            <StatButton testId="ov-tile-attention" open={panel === 'attention'} onClick={() => open('attention')} value={String(attentionTotal(d.attention))} label={t('ov.attention')}
              sub={attentionTotal(d.attention) > 0 ? t('ov.attention_sub') : t('home.all_clear')} />
          </div>
          {panel === 'clients' && <ClientsPanel d={d} onOpen={openClient} />}
          {panel === 'crops' && <CropsPanel d={d} />}
          {panel === 'scopes' && <ScopesPanel />}
          {panel === 'attention' && <AttentionPanel d={d} />}

          <div className="ov-hd">
            <h2 className="section-title">{t('ov.by_state')}</h2>
            <label className="ov-state">
              <span className="small">{t('ov.state')}</span>
              <select value={stateId} onChange={(e) => setStateId(e.target.value)} data-testid="ov-state">
                <option value="">{t('ov.all_states')}</option>
                {d.states.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
              </select>
            </label>
          </div>
          {d.clients.list.length === 0 ? <Empty>{t('ov.no_clients')}</Empty> : clientsByState(d.clients.list, stateId).map((g) => (
            <div key={g.state}>
              <h3 className="ov-state-name">{g.state}</h3>
              <div className="scope-cards" data-testid="ov-clients">{g.clients.map((c) => <ClientCard key={c.id} c={c} onOpen={() => openClient(c.id)} />)}</div>
            </div>))}

          <h2 className="section-title">{t('ov.pipeline')}</h2>
          <Pipeline rows={d.pipeline} />
          <div className="ov-volumes">
            <Volume title={t('ov.vol_state')} rows={(stateId ? d.volume_by_state.filter((v) => v.id === stateId) : d.volume_by_state)} testId="ov-vol-state" />
            <Volume title={t('ov.vol_crop')} rows={d.volume_by_crop} testId="ov-vol-crop" />
          </div>
        </>)}
    </>
  );
}

function SetupChecklist({ s }: { s: Overview['setup'] }) {
  const { t } = useI18n();
  const items = [
    { done: Number(s.states) > 0, text: t('ov.setup_state'), to: '/states' },
    { done: !!s.hr_admin, text: t('ov.setup_hr'), to: '/system/seats' },
    { done: Number(s.state_managers) > 0, text: t('ov.setup_sm'), to: '/people' },
  ];
  return (
    <div className="setup" data-testid="setup-checklist">
      <div className="small"><strong>{t('ov.setup_title')}</strong> {t('ov.setup_n', { n: items.filter((i) => i.done).length, m: items.length })}</div>
      <ol>{items.map((i) => (
        <li key={i.to} className={i.done ? 'done' : ''} data-testid="setup-item" data-done={i.done ? 'yes' : 'no'}>
          <span aria-hidden="true">{i.done ? '✓' : '○'} </span>{i.done ? i.text : <Link to={i.to}>{i.text}</Link>}
          <span className="visually-hidden"> {i.done ? t('ov.done') : t('ov.to_do')}</span>
        </li>))}</ol>
    </div>
  );
}

function ClientCard({ c, onOpen }: { c: OverviewClient; onOpen: () => void }) {
  const { t } = useI18n();
  return (
    <div className={`card scope-card ${Number(c.scopes_active) > 0 ? 'active' : ''}`} data-testid="ov-client" data-client={c.code}>
      <div className="row" style={{ justifyContent: 'space-between' }}><strong>{c.name}</strong><span className="mono small">{c.code}</span></div>
      <div className="muted small">{humanise(c.type)}</div>
      <dl className="ov-facts">
        <div><dt>{t('ov.f_scopes')}</dt><dd>{t('ov.of', { a: c.scopes_active, b: c.scopes_total })}</dd></div>
        <div><dt>{t('ov.f_volume')}</dt><dd>{kg(c.kg)}</dd></div>
        <div><dt>{t('ov.f_qr')}</dt><dd>{num(c.qr, 0)}</dd></div>
        <div><dt>{t('ov.f_people')}</dt><dd>{num(c.people, 0)}</dd></div>
      </dl>
      {Number(c.unstaffed) > 0 && <p className="small"><Badge value="open" label={t('ov.unstaffed_n', { n: c.unstaffed })} /></p>}
      {!c.has_manager && <p className="small"><Badge value="pending" label={t('ov.no_manager')} /></p>}
      <button type="button" className="secondary" onClick={onOpen} data-testid="ov-open-client">{t('ov.open_client')}</button>
    </div>
  );
}

/** One client, read-only: its figures, its scopes (each opens the scope screen, also read-only), its open stages. */
function ClientView({ c, d, onExit }: { c: OverviewClient; d: Overview; onExit: () => void }) {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const { choose } = useScope();
  const scopes = (ctx?.scopes ?? []).filter((s) => s.client_id === c.id);
  const gaps = d.attention.unstaffed_list.filter((g) => g.client_id === c.id);
  return (
    <>
      <ReadOnlyBanner text={t('ov.viewing', { name: c.name })} onExit={onExit} />
      <div className="stats" data-testid="client-stats">
        <div className="stat"><div className="stat-val">{t('ov.of', { a: c.scopes_active, b: c.scopes_total })}</div><div className="stat-label">{t('ov.f_scopes')}</div></div>
        <div className="stat"><div className="stat-val">{kg(c.kg)}</div><div className="stat-label">{t('ov.f_volume')}</div></div>
        <div className="stat"><div className="stat-val">{num(c.qr, 0)}</div><div className="stat-label">{t('ov.f_qr')}</div></div>
        <div className="stat"><div className="stat-val">{num(c.people, 0)}</div><div className="stat-label">{t('ov.f_people')}</div></div>
      </div>
      <p className="small muted">{c.state_name ?? '—'} · {humanise(c.type)} · <span className="mono">{c.code}</span>{!c.has_manager && <> · <Badge value="pending" label={t('ov.no_manager')} /></>}</p>
      <h2 className="section-title">{t('ov.client_scopes')}</h2>
      {scopes.length === 0 ? <Empty /> : (
        <div className="scope-cards">{scopes.map((s) => (
          <div className={`card scope-card ${s.status}`} key={s.scope_id}>
            <div className="row" style={{ justifyContent: 'space-between' }}><strong>{s.crop_name} · {s.season_code} · {s.geography}</strong><Badge value={s.status} /></div>
            <div className="muted small">{t('home.n_stages', { n: s.chain.length })}</div>
            <div className="row" style={{ marginTop: 8 }}>
              <button className="secondary" onClick={() => choose(s.scope_id)} data-testid="ov-open-scope">{t('ov.open_scope')}</button>
              {s.status !== 'draft' && <Link to={`/dashboard/${s.scope_id}`}>{t('dash.open')}</Link>}
            </div>
          </div>))}</div>)}
      {gaps.length > 0 && (
        <>
          <h2 className="section-title">{t('ov.unstaffed_title')}</h2>
          <ul className="ov-list">{gaps.map((g) => <li key={`${g.scope_id}-${g.stage_type}`}>{g.scope}: <strong>{t(`stage.${g.stage_type}`, undefined, g.stage)}</strong> · <Link to={`/scopes/${g.scope_id}/roster`}>{t('home.view')}</Link></li>)}</ul>
        </>)}
    </>
  );
}

export function ReadOnlyBanner({ text, onExit }: { text: string; onExit: () => void }) {
  const { t } = useI18n();
  return (
    <div className="alert info readonly-banner" role="status" data-testid="readonly-banner">
      <span><span aria-hidden="true">👁 </span>{text}</span>
      <button type="button" className="secondary" onClick={onExit} data-testid="readonly-exit">{t('ov.exit')}</button>
    </div>
  );
}

function ClientsPanel({ d, onOpen }: { d: Overview; onOpen: (id: string) => void }) {
  const { t } = useI18n();
  return (
    <div className="card ov-panel" data-testid="ov-panel-clients">
      <h2>{t('ov.clients')}</h2>
      <p className="small muted">{t('ov.clients_detail', { a: d.clients.active, d: d.clients.dormant, m: d.clients.without_manager })}</p>
      {d.clients.list.length === 0 ? <Empty /> : (
        <div className="table-wrap"><table className="wide">
          <thead><tr><th>{t('ov.c_client')}</th><th>{t('ov.state')}</th><th className="num">{t('ov.f_scopes')}</th><th className="num">{t('ov.f_volume')}</th><th>{t('ov.c_manager')}</th></tr></thead>
          <tbody>{d.clients.list.map((c) => (
            <tr key={c.id}><td><button type="button" className="linkish" onClick={() => onOpen(c.id)}>{c.name}</button></td><td>{c.state_name ?? '—'}</td>
              <td className="num">{t('ov.of', { a: c.scopes_active, b: c.scopes_total })}</td><td className="num">{kg(c.kg)}</td>
              <td>{c.has_manager ? t('common.yes') : <Badge value="pending" label={t('ov.no_manager')} />}</td></tr>))}</tbody>
        </table></div>)}
    </div>
  );
}

function CropsPanel({ d }: { d: Overview }) {
  const { t } = useI18n();
  return (
    <div className="card ov-panel" data-testid="ov-panel-crops">
      <h2>{t('ov.crops')}</h2>
      {d.crops.list.length === 0 ? <Empty /> : (
        <div className="table-wrap"><table>
          <thead><tr><th>{t('ov.c_crop')}</th><th className="num">{t('ov.f_scopes')}</th></tr></thead>
          <tbody>{d.crops.list.map((c) => <tr key={c.id}><td>{c.name} <span className="mono small muted">{c.code}</span></td><td className="num">{t('ov.of', { a: c.scopes_active, b: c.scopes_total })}</td></tr>)}</tbody>
        </table></div>)}
      <p className="small"><Link to="/crops">{t('ov.to_crops')}</Link></p>
    </div>
  );
}

function ScopesPanel() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const { choose } = useScope();
  const scopes = ctx?.scopes ?? [];
  return (
    <div className="card ov-panel" data-testid="ov-panel-scopes">
      <h2>{t('ov.all_scopes')}</h2>
      {scopes.length === 0 ? <Empty /> : (
        <ul className="ov-list">{scopes.map((s) => (
          <li key={s.scope_id}><button type="button" className="linkish" onClick={() => choose(s.scope_id)}>{s.crop_name} · {s.season_code} · {s.geography}</button>
            <span className="small muted"> · {s.client_name}</span> <Badge value={s.status} /></li>))}</ul>)}
    </div>
  );
}

function AttentionPanel({ d }: { d: Overview }) {
  const { t } = useI18n();
  const a = d.attention;
  return (
    <div className="card ov-panel" data-testid="ov-panel-attention">
      <h2>{t('ov.attention')}</h2>
      <ul className="ov-list">
        <li data-testid="att-flags">{t('ov.att_flags', { n: a.open_flags })}</li>
        {a.flags_list.map((f) => <li key={f.id} className="sub-item"><Link to={`/records/${f.footprint_id}`} className="mono">{f.record}</Link> · {f.client} · {f.text} <span className="small muted">({date(f.created_at)})</span></li>)}
        <li data-testid="att-step1">{t('ov.att_step1', { n: a.farmers_step1 })}{Number(a.farmers_step1) > 0 && <> · <Link to="/farmers">{t('home.view')}</Link></>}</li>
        <li data-testid="att-step2">{t('ov.att_step2', { n: a.farmers_step2 })}{Number(a.farmers_step2) > 0 && <> · <Link to="/farmers">{t('home.view')}</Link></>}</li>
        <li data-testid="att-unstaffed">{t('ov.att_unstaffed', { n: a.unstaffed })}</li>
        {a.unstaffed_list.map((g) => <li key={`${g.scope_id}-${g.stage_type}`} className="sub-item">{g.client} · {g.scope}: <strong>{t(`stage.${g.stage_type}`, undefined, g.stage)}</strong> · <Link to={`/scopes/${g.scope_id}/roster`}>{t('home.view')}</Link></li>)}
      </ul>
      <p className="small muted">{t('ov.attention_note')}</p>
    </div>
  );
}

/** Stage by stage over all active scopes: records waiting for the next person, and done. One hue; the table is the chart. */
function Pipeline({ rows }: { rows: Overview['pipeline'] }) {
  const { t } = useI18n();
  if (rows.length === 0) return <Empty>{t('ov.no_pipeline')}</Empty>;
  const max = Math.max(1, ...rows.map((r) => Number(r.pending) + Number(r.done)));
  return (
    <div className="table-wrap" data-testid="ov-pipeline"><table className="wide ov-bars">
      <thead><tr><th>{t('home.col_stage')}</th><th>{t('ov.p_bar')}</th><th className="num">{t('ov.p_pending')}</th><th className="num">{t('ov.p_done')}</th><th className="num">{t('ov.p_kg')}</th><th>{t('ov.p_oldest')}</th></tr></thead>
      <tbody>{rows.map((r) => {
        const p = Number(r.pending), dn = Number(r.done);
        return (
          <tr key={r.stage_type}>
            <td>{t(`stage.${r.stage_type}`, undefined, r.label)}</td>
            <td><div className="bar" title={t('ov.p_title', { p, d: dn })}>
              <span className="seg done" style={{ width: `${(dn / max) * 100}%` }} /><span className="seg pending" style={{ width: `${(p / max) * 100}%` }} /></div></td>
            <td className="num">{p}</td><td className="num">{dn}</td><td className="num">{p > 0 ? kg(r.kg_pending) : '—'}</td>
            <td>{r.oldest_pending ? date(r.oldest_pending) : '—'}</td>
          </tr>);
      })}</tbody>
    </table>
    <p className="small muted legend"><span className="key done" aria-hidden="true" /> {t('ov.p_done')} <span className="key pending" aria-hidden="true" /> {t('ov.p_pending')}</p></div>
  );
}

function Volume({ title, rows, testId }: { title: string; rows: { id: string; name: string; kg: number; lots: number; qr: number }[]; testId: string }) {
  const { t } = useI18n();
  const max = Math.max(1, ...rows.map((r) => Number(r.kg)));
  return (
    <div className="card ov-panel" data-testid={testId}>
      <h2>{title}</h2>
      {rows.length === 0 ? <Empty /> : (
        <div className="table-wrap" style={{ border: 'none' }}><table className="ov-bars">
          <thead><tr><th>{t('ov.c_name')}</th><th>{t('ov.f_volume')}</th><th className="num">{t('ov.c_lots')}</th><th className="num">{t('ov.f_qr')}</th></tr></thead>
          <tbody>{rows.map((r) => (
            <tr key={r.id}><td>{r.name}</td>
              <td><div className="bar" title={kg(r.kg)}><span className="seg done" style={{ width: `${(Number(r.kg) / max) * 100}%` }} /></div><span className="small">{kg(r.kg)}</span></td>
              <td className="num">{num(r.lots, 0)}</td><td className="num">{num(r.qr, 0)}</td></tr>))}</tbody>
        </table></div>)}
    </div>
  );
}
