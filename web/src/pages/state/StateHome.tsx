// The State Manager's first screen (migration 41, Veda 13 Oct 2026): "<State> overview", modelled on the prototype's
// State Manager dashboard. He owns one state: its crops, its clients and their Client Managers, the farmers he verifies
// after the Client Manager, everything that happens in it. Everything here is read: app.state_home counts his state
// on the server, and every number says what it counts. Tapping a client opens its dashboard read-only (the admin's
// drill-in, with Exit); acting happens on the pages the buttons lead to.
import { useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { useAuth } from '../../auth/AuthProvider';
import { rpc } from '../../lib/api';
import { useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { date, kg, num } from '../../lib/format';
import { myStateIds } from '../../lib/rights';
import { Badge, Empty, ErrorBox, Loading } from '../../shell/ui';
import { RoleGuide } from '../../shell/RoleGuide';
import { StatButton } from '../dashboard/parts';
import { ClientView, PipelineShort, type OverviewClient, type Overview, type PipelineStage } from '../admin/Overview';
import { StateRequirements } from './StateRequirements';

export interface StateClient extends OverviewClient { scopes_setup: number; lots: number; waiting: number; managers: string | null }
export interface StateHomeData {
  state: { id: string; name: string; code: string };
  managers: string[];
  clients: { total: number; active: number; without_manager: number; list: StateClient[] };
  crops: { total: number; state_not_set: number; /** migration 42: crops of his state that are ready for a scope */ ready?: number;
    list: { id: string; name: string; code: string; scopes_active: number; scopes_total: number; ready?: boolean; missing?: string[] }[] };
  scopes: { active: number; setup: number; closed: number; qr_issued: number; list: { scope_id: string; client: string; crop: string; scope: string; status: string;
    /** migration 46: one person on two stages in a row */ same_person?: { verified_own: number; made_on_own: number } }[] };
  farmers: { total: number; active: number };
  attention: {
    no_manager: number; no_manager_list: { id: string; name: string; code: string }[];
    farmers_waiting: number; farmers_list: { id: string; name: string; village: string; client_id: string; client: string }[];
    unstaffed: number; unstaffed_list: Overview['attention']['unstaffed_list'];
    open_flags: number; flags_list: Overview['attention']['flags_list'];
    /** migration 43: possible duplicates (same phone), farmers without GI land; migration 44: changes after verification to
     *  accept, and farmers above their expected yield (a warning, not counted). `over_yield` came from a server of migration 43. */
    duplicates?: number; over_yield?: number; no_gi_land?: number; changes?: number; above_yield?: number;
  };
  pipeline: PipelineStage[];
}

/** Pure: "Needs my action" is the sum of the lines it opens, so the figure and the list never disagree. Farmers without GI
 *  land are shown but not counted: they wait for their Client Manager, and the State Manager meets them at step 2. Above
 *  the expected yield is a warning only (migration 44, Veda 14 Oct): shown, never counted. */
export const needsMyAction = (a: StateHomeData['attention']) =>
  Number(a.no_manager) + Number(a.farmers_waiting) + Number(a.unstaffed) + Number(a.open_flags)
  + Number(a.duplicates ?? 0) + Number(a.changes ?? 0) + (a.changes === undefined ? Number(a.over_yield ?? 0) : 0);

/** Pure: the set-up checklist of the role guide, ticked from the state's own numbers (Veda's five steps, in order). */
export function stateSetup(d: Pick<StateHomeData, 'crops' | 'clients' | 'scopes' | 'farmers' | 'attention'>): { key: string; done: boolean; to: string | null }[] {
  const clients = Number(d.clients.total);
  return [
    // a crop of his state counts once it is ready (migration 42); a server before that says nothing of readiness
    { key: 'sh.setup_crops', done: Number(d.crops.ready ?? d.crops.total) > 0, to: '/crops' },
    { key: 'sh.setup_clients', done: clients > 0, to: '/clients' },
    { key: 'sh.setup_managers', done: clients > 0 && Number(d.clients.without_manager) === 0, to: '/people' },
    { key: 'sh.setup_scopes', done: Number(d.scopes.active) + Number(d.scopes.setup) > 0 && Number(d.farmers.total) > 0, to: null },
    { key: 'sh.setup_verify', done: Number(d.farmers.active) > 0 && Number(d.attention.farmers_waiting) === 0, to: '/farmers' },
  ];
}

type Panel = 'clients' | 'scopes' | 'action' | 'qr' | null;

export function StateHome() {
  const { ctx } = useAuth();
  const { t } = useI18n();
  const me = ctx!.user!;
  const ids = myStateIds(ctx);
  const [stateId, setStateId] = useState(ids[0] ?? '');
  const [params, setParams] = useSearchParams();
  const [panel, setPanel] = useState<Panel>(null);
  const h = useAsync(() => (stateId ? rpc<StateHomeData>('state_home', { p_state: stateId }) : Promise.resolve(null)), [stateId]);
  const d = h.data;
  const clientId = params.get('client');
  const client = d && clientId ? d.clients.list.find((c) => c.id === clientId) ?? null : null;
  const exitClient = () => { const n = new URLSearchParams(params); n.delete('client'); setParams(n, { replace: true }); };
  const openClient = (id: string) => { const n = new URLSearchParams(params); n.set('client', id); setParams(n); };
  const open = (p: Panel) => setPanel((x) => (x === p ? null : p));
  if (!stateId) return <Empty>{t('sh.no_state')}</Empty>;
  return (
    <>
      <div className="band" data-testid="state-home">
        <div><h1 data-testid="state-home-title">{t('sh.title', { state: d?.state.name ?? '…', name: me.display_name })}</h1><div className="sub">{t('sh.sub')}</div></div>
        <div className="side">{me.display_name}<br />{t('role.state_manager')}</div>
      </div>
      {ids.length > 1 && (
        <label className="ov-state" style={{ marginBottom: 12 }}>
          <span className="small">{t('ov.state')}</span>
          <select value={stateId} onChange={(e) => setStateId(e.target.value)} data-testid="sh-state">
            {(ctx?.assignments ?? []).filter((a) => a.lens === 'state').map((a) => <option key={a.id} value={a.state_id ?? ''}>{a.state_name}</option>)}
          </select>
        </label>)}
      {h.loading && !d ? <Loading /> : <ErrorBox error={h.error} onRetry={() => void h.reload()} />}
      {d && client && <ClientView c={client} d={d} onExit={exitClient} />}
      {d && clientId && !client && <div className="alert warn">{t('ov.client_gone')} <button className="secondary" onClick={exitClient}>{t('ov.exit')}</button></div>}
      {d && !clientId && (
        <>
          <RoleGuide role="state_manager"><SetupChecklist d={d} /></RoleGuide>
          {Number(d.attention.no_manager) > 0 && <NoManagerWarning d={d} />}
          <div className="stats" data-testid="sh-stats">
            <StatButton testId="sh-tile-clients" open={panel === 'clients'} onClick={() => open('clients')} value={String(d.clients.total)} label={t('sh.clients')}
              sub={t('sh.clients_sub', { a: d.clients.active })} />
            <StatButton testId="sh-tile-scopes" open={panel === 'scopes'} onClick={() => open('scopes')} value={String(d.scopes.active)} label={t('sh.scopes')}
              sub={t('sh.scopes_sub', { s: d.scopes.setup })} />
            <StatButton testId="sh-tile-action" open={panel === 'action'} onClick={() => open('action')} value={String(needsMyAction(d.attention))} label={t('sh.action')}
              sub={needsMyAction(d.attention) > 0 ? t('sh.action_sub') : t('home.all_clear')} />
            <StatButton testId="sh-tile-qr" open={panel === 'qr'} onClick={() => open('qr')} value={String(d.scopes.qr_issued)} label={t('sh.qr')}
              sub={t('sh.qr_sub')} />
          </div>
          {panel === 'clients' && <ClientsPanel d={d} onOpen={openClient} />}
          {panel === 'scopes' && <ScopesPanel d={d} />}
          {panel === 'action' && <ActionPanel d={d} />}
          {panel === 'qr' && <QrPanel d={d} />}

          <p className="small" data-testid="sh-crops">{t('sh.crops_line', { n: d.crops.total, state: d.state.name })}
            {d.crops.ready !== undefined && Number(d.crops.total) > 0 && <> · <span data-testid="sh-crops-ready">{t('sh.crops_ready', { n: d.crops.ready, of: d.crops.total })}</span></>}
            {Number(d.crops.state_not_set) > 0 && <> · {t('sh.crops_unset', { n: d.crops.state_not_set })}</>} · <Link to="/crops">{t('sh.to_crops')}</Link></p>

          <div className="ov-hd">
            <h2 className="section-title">{t('sh.pipeline')}</h2>
            <Link to="/pipeline" data-testid="sh-to-pipeline">{t('ov.to_pipeline')}</Link>
          </div>
          <PipelineShort rows={d.pipeline} />

          <h2 className="section-title">{t('state.kpi_gaps')}</h2>
          {d.attention.unstaffed_list.length === 0 ? <Empty>{t('sh.no_gaps')}</Empty> : (
            <ul className="ov-list card" data-testid="sh-gaps">{d.attention.unstaffed_list.map((g) => (
              <li key={`${g.scope_id}-${g.stage_type}`}>{g.client} · {g.scope}: <strong>{t(`stage.${g.stage_type}`, undefined, g.stage)}</strong> · <Link to={`/scopes/${g.scope_id}/roster`}>{t('home.view')}</Link></li>))}</ul>)}

          <StateRequirements stateId={stateId} clients={d.clients.list.map((c) => ({ id: c.id, name: c.name }))} />
          <SamePerson d={d} />

          <h2 className="section-title">{t('sh.client_cards')}</h2>
          {d.clients.list.length === 0 ? <Empty>{t('sh.no_clients')}</Empty> : (
            <div className="scope-cards" data-testid="sh-clients">{d.clients.list.map((c) => <ClientCard key={c.id} c={c} onOpen={() => openClient(c.id)} />)}</div>)}
        </>)}
    </>
  );
}

function SetupChecklist({ d }: { d: StateHomeData }) {
  const { t } = useI18n();
  const items = stateSetup(d);
  return (
    <div className="setup" data-testid="setup-checklist">
      <div className="small"><strong>{t('ov.setup_title')}</strong> {t('ov.setup_n', { n: items.filter((i) => i.done).length, m: items.length })}</div>
      <ol>{items.map((i) => (
        <li key={i.key} className={i.done ? 'done' : ''} data-testid="setup-item" data-done={i.done ? 'yes' : 'no'}>
          <span aria-hidden="true">{i.done ? '✓' : '○'} </span>{i.done || !i.to ? t(i.key) : <Link to={i.to}>{t(i.key)}</Link>}
          <span className="visually-hidden"> {i.done ? t('ov.done') : t('ov.to_do')}</span>
        </li>))}</ol>
    </div>
  );
}

/** "N clients have no Client Manager yet", with a way to give each one (People & access, filtered to that client). */
function NoManagerWarning({ d }: { d: StateHomeData }) {
  const { t } = useI18n();
  const nav = useNavigate();
  return (
    <div className="alert warn" role="status" data-testid="sh-no-manager">
      <div>{t('sh.no_manager', { n: d.attention.no_manager })}</div>
      <div className="row" style={{ marginTop: 6 }}>{d.attention.no_manager_list.map((c) => (
        <button key={c.id} type="button" className="secondary small-btn" onClick={() => nav(`/people?client=${c.id}`)} data-testid="sh-give-manager">
          {t('sh.give_manager', { name: c.name })}</button>))}</div>
    </div>
  );
}

function ClientCard({ c, onOpen }: { c: StateClient; onOpen: () => void }) {
  const { t } = useI18n();
  return (
    <div className={`card scope-card ${Number(c.scopes_active) > 0 ? 'active' : ''}`} data-testid="sh-client" data-client={c.code}>
      <div className="row" style={{ justifyContent: 'space-between' }}><strong>{c.name}</strong><span className="mono small">{c.code}</span></div>
      <div className="small">{t('sh.cm')}: {c.managers ? <strong>{c.managers}</strong> : <Badge value="pending" label={t('sh.cm_none')} />}</div>
      <dl className="ov-facts">
        <div><dt>{t('sh.f_scopes')}</dt><dd>{t('sh.scopes_as', { a: c.scopes_active, s: c.scopes_setup })}</dd></div>
        <div><dt>{t('sh.batches')}</dt><dd>{num(c.lots, 0)}</dd></div>
        <div><dt>{t('ov.f_qr')}</dt><dd>{num(c.qr, 0)}</dd></div>
        <div><dt>{t('ov.f_people')}</dt><dd>{num(c.people, 0)}</dd></div>
        <div><dt>{t('sh.waiting')}</dt><dd data-testid="sh-client-waiting">{num(c.waiting, 0)}</dd></div>
      </dl>
      {Number(c.unstaffed) > 0 && <p className="small"><Badge value="open" label={t('ov.unstaffed_n', { n: c.unstaffed })} /></p>}
      <button type="button" className="secondary" onClick={onOpen} data-testid="sh-open-client">{t('ov.open_client')}</button>
    </div>
  );
}

function ClientsPanel({ d, onOpen }: { d: StateHomeData; onOpen: (id: string) => void }) {
  const { t } = useI18n();
  return (
    <div className="card ov-panel" data-testid="sh-panel-clients">
      <h2>{t('sh.clients')}</h2>
      <p className="small muted">{t('sh.clients_detail', { n: d.clients.total, a: d.clients.active, m: d.clients.without_manager })}</p>
      {d.clients.list.length === 0 ? <Empty /> : (
        <div className="table-wrap"><table className="wide">
          <thead><tr><th>{t('ov.c_client')}</th><th>{t('sh.cm')}</th><th className="num">{t('sh.f_scopes')}</th><th className="num">{t('ov.f_volume')}</th></tr></thead>
          <tbody>{d.clients.list.map((c) => (
            <tr key={c.id}><td><button type="button" className="linkish" onClick={() => onOpen(c.id)}>{c.name}</button></td>
              <td>{c.managers ?? <Badge value="pending" label={t('sh.cm_none')} />}</td>
              <td className="num">{t('sh.scopes_as', { a: c.scopes_active, s: c.scopes_setup })}</td><td className="num">{kg(c.kg)}</td></tr>))}</tbody>
        </table></div>)}
    </div>
  );
}

/** Migration 46 (Veda, 14 Oct): where one person recorded a step and checked it (two stages in a row), per scope. */
function SamePerson({ d }: { d: StateHomeData }) {
  const { t } = useI18n();
  const rows = d.scopes.list.filter((s) => (s.same_person?.verified_own ?? 0) + (s.same_person?.made_on_own ?? 0) > 0);
  if (rows.length === 0) return null;
  return (
    <div className="card" data-testid="sh-same-person">
      <h3 style={{ marginTop: 0 }}>{t('sp.title')}</h3>
      <ul className="ov-list">{rows.map((s) => <li key={s.scope_id}><Link to={`/scopes/${s.scope_id}/roster`}>{s.scope}</Link>
        <span className="small"> · {t('sp.count', { v: s.same_person!.verified_own, m: s.same_person!.made_on_own })}</span></li>)}</ul>
      <p className="small muted">{t('sp.note')}</p>
    </div>);
}

function ScopesPanel({ d }: { d: StateHomeData }) {
  const { t } = useI18n();
  return (
    <div className="card ov-panel" data-testid="sh-panel-scopes">
      <h2>{t('sh.scopes')}</h2>
      <p className="small muted">{t('sh.scopes_detail', { a: d.scopes.active, s: d.scopes.setup, c: d.scopes.closed })}</p>
      {d.scopes.list.length === 0 ? <Empty /> : (
        <ul className="ov-list">{d.scopes.list.map((s) => (
          <li key={s.scope_id}><Link to={`/scopes/${s.scope_id}`}>{s.scope}</Link><span className="small muted"> · {s.client}</span> <Badge value={s.status} />
            {(s.same_person?.verified_own ?? 0) > 0 && <> <span className="same-person">{t('sp.short', { n: s.same_person!.verified_own })}</span></>}</li>))}</ul>)}
      <p className="small muted">{t('sh.scopes_note')}</p>
    </div>
  );
}

function ActionPanel({ d }: { d: StateHomeData }) {
  const { t } = useI18n();
  const a = d.attention;
  return (
    <div className="card ov-panel" data-testid="sh-panel-action">
      <h2>{t('sh.action')}</h2>
      <ul className="ov-list">
        <li data-testid="act-no-manager">{t('sh.act_no_manager', { n: a.no_manager })}</li>
        {a.no_manager_list.map((c) => <li key={c.id} className="sub-item">{c.name} · <Link to={`/people?client=${c.id}`}>{t('sh.give_manager', { name: c.code })}</Link></li>)}
        <li data-testid="act-farmers">{t('sh.act_farmers', { n: a.farmers_waiting })}{Number(a.farmers_waiting) > 0 && <> · <Link to="/farmers">{t('home.view')}</Link></>}</li>
        {a.farmers_list.map((f) => <li key={f.id} className="sub-item">{f.name} · {f.village} · {f.client}</li>)}
        {a.duplicates !== undefined && <li data-testid="act-duplicates">{t('sh.act_duplicates', { n: a.duplicates })}{Number(a.duplicates) > 0 && <> · <Link to="/farmers/register?flag=duplicate">{t('home.view')}</Link></>}</li>}
        {a.changes !== undefined && <li data-testid="act-changes">{t('sh.act_changes', { n: a.changes })}{Number(a.changes) > 0 && <> · <Link to="/farmers/register?flag=changed">{t('home.view')}</Link></>}</li>}
        <li data-testid="act-unstaffed">{t('ov.att_unstaffed', { n: a.unstaffed })}</li>
        {a.unstaffed_list.map((g) => <li key={`${g.scope_id}-${g.stage_type}`} className="sub-item">{g.client} · {g.scope}: <strong>{t(`stage.${g.stage_type}`, undefined, g.stage)}</strong> · <Link to={`/scopes/${g.scope_id}/roster`}>{t('home.view')}</Link></li>)}
        <li data-testid="act-flags">{t('ov.att_flags', { n: a.open_flags })}</li>
        {a.flags_list.map((f) => <li key={f.id} className="sub-item"><Link to={`/records/${f.footprint_id}`} className="mono">{f.record}</Link> · {f.client} · {f.text} <span className="small muted">({date(f.created_at)})</span></li>)}
      </ul>
      {Number(a.above_yield ?? 0) > 0 && <p className="small muted" data-testid="act-above-yield">{t('sh.act_above_yield', { n: a.above_yield ?? 0 })} · <Link to="/farmers/register?flag=above_yield">{t('home.view')}</Link></p>}
      {Number(a.no_gi_land ?? 0) > 0 && <p className="small muted" data-testid="act-no-gi">{t('sh.act_no_gi', { n: a.no_gi_land ?? 0 })} · <Link to="/farmers/register?flag=no_gi_land">{t('home.view')}</Link></p>}
    </div>
  );
}

function QrPanel({ d }: { d: StateHomeData }) {
  const { t } = useI18n();
  const rows = d.clients.list.filter((c) => Number(c.qr) > 0);
  return (
    <div className="card ov-panel" data-testid="sh-panel-qr">
      <h2>{t('sh.qr')}</h2>
      {rows.length === 0 ? <Empty>{t('sh.no_qr')}</Empty> : (
        <ul className="ov-list">{rows.map((c) => <li key={c.id}>{c.name}: <strong>{num(c.qr, 0)}</strong></li>)}</ul>)}
    </div>
  );
}
