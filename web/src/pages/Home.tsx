// The first screen after sign-in (decision G8 = B: the prototype's dashboards, from the data this system already reads).
//   operator                      "Hi {name}" and one "My stage" card per stage held: what is waiting, own recent records
//   manager / viewer, one scope   number cards, action queue, season flow stage by stage, team table
//   manager / viewer, several     overall: number cards over all scopes and a card per scope; choosing one opens the above
// Every figure comes from app.pipeline_summary (verified quantities per stage), the open flags and the stage
// assignments. Nothing here is written, and nothing is kept on the phone: with no network the cards show no figures.
import { Link, useNavigate } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { useI18n } from '../lib/i18n';
import { rpc, q } from '../lib/api';
import { supabase } from '../lib/supabase';
import { useAsync } from '../lib/useAsync';
import { isManager, type Slot, type StageType } from '../lib/types';
import { Empty, Badge } from '../shell/ui';
import { useScope, useWide, type ScopeChoice } from '../shell/scope';
import { stageIcon } from '../engine/icons';
import { kg, humanise, dateTime, num } from '../lib/format';

export interface PipeRow { stage: string; chain_pos: number; records: number; pending: number; verified: number; kg_out: number; kg_available: number }

/** The numbers on a scope's first screen, from its pipeline rows. Pure, so the arithmetic is tested without a screen. */
export function scopeFigures(rows: PipeRow[]) {
  const sorted = [...rows].sort((a, b) => a.chain_pos - b.chain_pos);
  const first = sorted[0];
  const qr = sorted.find((r) => r.stage === 'qr_activation');
  const work = sorted.filter((r) => r.stage !== 'qr_activation');
  const last = work[work.length - 1];
  const procured = Number(first?.kg_out ?? 0);
  const output = work.length > 1 ? Number(last?.kg_out ?? 0) : 0;
  const pending = work.reduce((n, r) => n + Number(r.pending), 0);
  const bottleneck = work.reduce<PipeRow | null>((b, r) => (Number(r.pending) > Number(b?.pending ?? 0) ? r : b), null);
  return {
    procured, output, pending,
    yieldPct: procured > 0 && output > 0 ? Math.round((output / procured) * 100) : null,
    completed: Number(qr?.records ?? 0),
    records: work.reduce((n, r) => n + Number(r.records), 0),
    bottleneck: bottleneck && Number(bottleneck.pending) > 0 ? bottleneck : null,
  };
}

/** Stages of a chain that nobody holds (the gate stage counts: someone must seal). */
export const unassigned = (chain: StageType[], held: StageType[]) => chain.filter((s) => !held.includes(s));

export function Home() {
  const { ctx } = useAuth();
  const { scopes, current } = useScope();
  const wide = useWide();
  const me = ctx!.user!;
  return (
    <div>
      {!wide && scopes.length > 1 && <ScopePicker />}
      {me.role === 'operator' ? <OperatorHome /> : current ? <ScopeHome scope={current} /> : <OverallHome />}
    </div>
  );
}

/** On a phone the scope selector sits at the top of the first screen (on a laptop it is in the top bar). */
function ScopePicker() {
  const { t } = useI18n();
  const { scopes, current, choose } = useScope();
  return (
    <div className="field">
      <label htmlFor="scope-pick">{t('scope.label')}</label>
      <select id="scope-pick" value={current?.id ?? ''} onChange={(e) => choose(e.target.value === '' ? null : e.target.value)} data-testid="scope-switcher">
        <option value="">{t('scope.overall')}</option>
        {scopes.map((s) => <option key={s.id} value={s.id}>{s.label}{s.status === 'draft' ? ` ${t('scope.setup')}` : ''}</option>)}
      </select>
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Operator
function OperatorHome() {
  const { ctx } = useAuth();
  const { t } = useI18n();
  const { current } = useScope();
  const me = ctx!.user!;
  const slots = current ? ctx!.slots.filter((s) => s.scope_id === current.id) : ctx!.slots;
  const wide = useWide();
  const compact = !wide && slots.length > 2;              // a phone with many stages: the cards without their lists, so they fit a screen or two
  return (
    <>
      <div className="band">
        <div><h1>{t('home.hello', { name: me.display_name })}</h1>
          <div className="sub">{t(`role.${me.role}`)}{current ? ` · ${current.label}` : ''}</div></div>
      </div>
      {slots.length > 0 && <h2 className="section-title">{t('home.your_stages')}</h2>}
      <div className="stage-cards">{slots.map((s) => <StageCard key={`${s.scope_id}-${s.stage_type}`} slot={s} userId={me.id} compact={compact} />)}</div>
      {ctx!.slots.length === 0 && <Empty>{t('home.no_slots')}</Empty>}
    </>
  );
}

interface OwnRow { id: string; footprint_code: string; qty_out: number; status: string; created_at: string }
function StageCard({ slot, userId, compact }: { slot: Slot; userId: string; compact: boolean }) {
  const { t } = useI18n();
  const first = slot.chain[0] === slot.stage_type;
  const gate = slot.stage_type === 'qr_activation';
  const label = t(`stage.${slot.stage_type}`, undefined, slot.stage_label);
  const to = `/work/${slot.scope_id}/${slot.stage_type}`;
  const inc = useAsync(() => first ? Promise.resolve([]) : rpc<unknown[]>('incoming_records', { p_scope: slot.scope_id, p_stage: slot.stage_type }),
    [slot.scope_id, slot.stage_type]);
  const own = useAsync(() => compact ? Promise.resolve(null) : q(supabase.from('footprints').select('id,footprint_code,qty_out,status,created_at')
    .eq('scope_id', slot.scope_id).eq('stage_type', slot.stage_type).eq('created_by', userId)
    .order('created_at', { ascending: false }).limit(200)) as Promise<OwnRow[] | null>, [slot.scope_id, slot.stage_type, userId, compact]);
  const waiting = inc.data?.length ?? 0;
  const mine = (own.data ?? []).filter((r) => r.status !== 'superseded');
  const total = mine.reduce((n, r) => n + Number(r.qty_out), 0);
  return (
    <div className="card stage-card">
      <Link className="stage-hd" to={to} data-testid={`slot-${slot.stage_type}`} data-scope={slot.scope_id}>
        <strong><span aria-hidden="true">{stageIcon(slot.stage_type)} </span>{t('home.my_stage', { stage: label })}</strong>
        <div className="sub">{slot.scope_label} · {slot.client_name}</div>
      </Link>
      <div className="stage-body">
        <div className={`inbox${waiting > 0 ? ' waiting' : ''}`}>
          {first ? <strong>{t('home.first_stage')}</strong>
            : inc.data ? <strong data-testid="incoming-count">{waiting > 0 ? t('home.waiting_n', { n: waiting }) : t('home.nothing_waiting')}</strong>
              : <strong className="muted">{t('home.waiting_unknown')}</strong>}
          <Link className="btn secondary" to={to}>{t(gate ? 'home.go_seal' : waiting > 0 && !first ? 'home.go_waiting' : 'home.go_stage', { stage: label })}</Link>
        </div>
        {!gate && own.data && (
          <>
            <div className="section-title">{t('home.recent')}</div>
            {mine.length === 0 ? <p className="muted">{t('home.no_runs')}</p> : (
              <ul className="runs">{mine.slice(0, 4).map((r) => (
                <li key={r.id}><Link className="mono" to={`/records/${r.id}`}>{r.footprint_code}</Link>
                  <span>{kg(r.qty_out)} <Badge value={r.status} /></span></li>))}</ul>)}
            {mine.length > 0 && <p className="small muted">{t('home.season_total', { kg: kg(total), n: mine.length })}</p>}
          </>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Managers and viewers: all scopes
function OverallHome() {
  const { ctx } = useAuth();
  const { t } = useI18n();
  const { choose } = useScope();
  const me = ctx!.user!;
  const scopes = ctx!.scopes;
  const live = scopes.filter((s) => s.status !== 'draft' && s.status !== 'closed');
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const pipes = useAsync(() => Promise.all(live.map((s) => rpc<PipeRow[]>('pipeline_summary', { p_scope: s.scope_id }).then((rows) => [s.scope_id, rows] as const))), [live.map((s) => s.scope_id).join(',')]);
  const flags = useAsync(() => q(supabase.from('flags').select('id').eq('status', 'open')) as Promise<{ id: string }[]>, []);
  const byScope = new Map(pipes.data ?? []);
  const figures = [...byScope.values()].map(scopeFigures);
  const sum = (f: (x: ReturnType<typeof scopeFigures>) => number) => figures.reduce((n, x) => n + f(x), 0);
  const needs = sum((x) => x.pending) + (flags.data?.length ?? 0);
  const crops = new Set(scopes.map((s) => s.crop_name)).size;
  return (
    <>
      <div className="band">
        <div><h1>{me.client_name ?? t('home.platform')}</h1>
          <div className="sub">{t('home.scopes_crops', { n: scopes.length, m: crops })}</div></div>
        <div className="side">{me.display_name}<br />{t(`role.${me.role}`)}</div>
      </div>
      {isManager(me.role) && <LedgerHealth />}
      <div className="stats" data-testid="stats">
        <Stat value={String(live.length)} label={t('home.kpi_active')} sub={t('home.kpi_setup', { n: scopes.filter((s) => s.status === 'draft').length })} />
        <Stat value={pipes.data ? kg(sum((x) => x.procured)) : '…'} label={t('home.kpi_volume')} sub={t('home.kpi_volume_sub')} />
        <Stat value={pipes.data ? String(needs) : '…'} label={t('home.kpi_needs')} sub={needs > 0 ? t('home.kpi_needs_sub') : t('home.all_clear')} />
        <Stat value={pipes.data ? String(sum((x) => x.completed)) : '…'} label={t('home.kpi_qr')} sub={t('home.kpi_qr_sub')} />
      </div>
      <h2 className="section-title">{t('home.scopes')}</h2>
      {scopes.length === 0 ? <Empty /> : (
        <div className="scope-cards">{scopes.map((s) => {
          const f = byScope.has(s.scope_id) ? scopeFigures(byScope.get(s.scope_id)!) : null;
          return (
            <div className={`card scope-card ${s.status}`} key={s.scope_id}>
              <div className="row" style={{ justifyContent: 'space-between' }}><strong>{s.crop_name} · {s.season_code} · {s.geography}</strong><Badge value={s.status} /></div>
              <div className="muted small">{s.client_name} · {t('home.n_stages', { n: s.chain.length })}</div>
              <p className="small" style={{ margin: '8px 0' }}>{f === null ? (s.status === 'draft' ? t('home.in_setup') : '…')
                : f.records === 0 ? t('home.no_activity')
                  : t('home.scope_line', { kg: kg(f.procured), pending: f.pending, qr: f.completed })}</p>
              <div className="row">
                {s.status === 'draft' ? <Link className="btn secondary" to={`/scopes/${s.scope_id}`}>{t('home.set_up')}</Link>
                  : <button className="secondary" onClick={() => choose(s.scope_id)}>{t('home.work_in_scope')}</button>}
                {s.status !== 'draft' && <Link to={`/dashboard/${s.scope_id}`} data-testid="dashboard-link">{t('dash.open')}</Link>}
              </div>
            </div>);
        })}</div>)}
    </>
  );
}

function Stat({ value, label, sub }: { value: string; label: string; sub?: string }) {
  return <div className="stat"><div className="stat-val">{value}</div><div className="stat-label">{label}</div>{sub && <div className="stat-sub">{sub}</div>}</div>;
}

// ---------------------------------------------------------------------------------------------------------------
// Managers and viewers: one scope
interface SlotRow { id: string; user_id: string; stage_type: StageType }
function ScopeHome({ scope }: { scope: ScopeChoice }) {
  const { ctx } = useAuth();
  const { t } = useI18n();
  const { scopes, choose } = useScope();
  const navigate = useNavigate();
  const me = ctx!.user!;
  const manager = isManager(me.role);
  const draft = scope.status === 'draft';
  const pipe = useAsync(() => draft ? Promise.resolve([] as PipeRow[]) : rpc<PipeRow[]>('pipeline_summary', { p_scope: scope.id }), [scope.id, draft]);
  const flags = useAsync(() => q(supabase.from('flags').select('id,footprints!inner(scope_id)').eq('status', 'open').eq('footprints.scope_id', scope.id)) as unknown as Promise<{ id: string }[]>, [scope.id]);
  const slots = useAsync(() => q(supabase.from('slot_assignments').select('id,user_id,stage_type').eq('scope_id', scope.id)) as Promise<SlotRow[]>, [scope.id]);
  const users = useAsync(() => scope.client_id ? q(supabase.from('app_users').select('id,display_name').eq('client_id', scope.client_id)) as Promise<{ id: string; display_name: string }[]>
    : Promise.resolve([]), [scope.client_id]);
  const label = (s: string) => t(`stage.${s}`, undefined, humanise(s));
  const rows = pipe.data ?? [];
  const f = scopeFigures(rows);
  const open = unassigned(scope.chain, (slots.data ?? []).map((s) => s.stage_type));
  const queue: { key: string; text: string; to: string; action: string }[] = [];
  if (f.pending > 0) queue.push({ key: 'pending', text: t('home.q_pending', { n: f.pending }), to: `/work/${scope.id}/${f.bottleneck!.stage}?tab=records`, action: t('home.q_review') });
  if (slots.data && open.length > 0 && !draft) queue.push({ key: 'slots', text: t('home.q_slots', { n: open.length, stages: open.slice(0, 3).map(label).join(', ') }),
    to: `/scopes/${scope.id}?step=people`, action: manager ? t('home.q_assign') : t('home.view') });
  if ((flags.data?.length ?? 0) > 0) queue.push({ key: 'flags', text: t('home.q_flags', { n: flags.data!.length }), to: manager ? '/flags' : `/dashboard/${scope.id}`, action: t('home.view') });
  const by = (stage: string) => rows.find((r) => r.stage === stage);
  const holder = (stage: StageType) => (slots.data ?? []).filter((s) => s.stage_type === stage).map((s) => users.data?.find((u) => u.id === s.user_id)?.display_name ?? '…');
  return (
    <>
      <div className="band">
        <div><h1>{scope.label}</h1><div className="sub">{scope.client_name} · {t('home.n_stages', { n: scope.chain.length })}</div></div>
        <div className="side">{me.display_name}<br />{t(`role.${me.role}`)}</div>
      </div>
      {scopes.length > 1 && <p><button className="secondary" onClick={() => choose(null)}>{t('home.back_overall')}</button></p>}
      {manager && <LedgerHealth />}
      {draft ? (
        <div className="card"><p>{t('home.in_setup')}</p><Link className="btn" to={`/scopes/${scope.id}`}>{t('home.set_up')}</Link></div>
      ) : (
        <>
          <div className="stats" data-testid="stats">
            <Stat value={pipe.data ? kg(f.procured) : '…'} label={t('home.kpi_procured')} sub={t('home.kpi_procured_sub')} />
            <Stat value={pipe.data && slots.data ? String(f.pending + open.length + (flags.data?.length ?? 0)) : '…'} label={t('home.kpi_queue')}
              sub={queue.length > 0 ? t('home.kpi_needs_sub') : t('home.all_clear')} />
            <Stat value={pipe.data ? (f.yieldPct === null ? '—' : `${f.yieldPct} %`) : '…'} label={t('home.kpi_yield')} sub={t('home.kpi_yield_sub')} />
            <Stat value={pipe.data ? String(f.completed) : '…'} label={t('home.kpi_completed')} sub={t('home.kpi_completed_sub')} />
          </div>
          {queue.length > 0 ? (
            <div className="card queue" data-testid="action-queue">
              <h2>{t('home.queue_title', { n: queue.length })}</h2>
              {queue.map((x) => <div className="queue-row" key={x.key}><span>{x.text}</span><Link className="btn secondary" to={x.to}>{x.action}</Link></div>)}
            </div>
          ) : pipe.data && <div className="alert ok" data-testid="action-queue">{t('home.caught_up')}</div>}
          {f.records > 0 && (
            <div className="headline">
              <div><strong>{kg(f.procured)}</strong><span>{t('home.h_procured')}</span></div>
              <div><strong>{num(f.pending, 0)}</strong><span>{t('home.h_progress')}</span></div>
              <div><strong>{num(f.completed, 0)}</strong><span>{t('home.h_qr')}</span></div>
            </div>)}
          <h2 className="section-title">{t('home.flow_title')}</h2>
          {f.bottleneck ? <div className="alert warn">{t('home.bottleneck', { n: f.bottleneck.pending, stage: label(f.bottleneck.stage) })}</div>
            : f.records > 0 && <div className="alert ok">{t('home.no_pileups')}</div>}
          <ol className="flow" data-testid="season-flow">{scope.chain.map((s) => {
            const r = by(s);
            return (
              <li key={s}><Link to={`/work/${scope.id}/${s}?tab=records`} className={r && Number(r.pending) > 0 ? 'has-pending' : ''}>
                <span className="flow-icon" aria-hidden="true">{stageIcon(s)}</span>
                <span className="flow-name">{label(s)}</span>
                {!r || Number(r.records) === 0 ? <span className="muted small">{t('home.no_records')}</span> : (
                  <span className="small">
                    {Number(r.verified) > 0 && <span className="flow-ok">✓ {r.verified} </span>}
                    {Number(r.pending) > 0 && <span className="flow-wait">● {t('home.n_pending', { n: r.pending })}</span>}
                  </span>)}
              </Link></li>);
          })}</ol>
          <h2 className="section-title">{t('home.quick')}</h2>
          <div className="row" style={{ marginBottom: 14 }}>
            <Link className="btn secondary" to={`/dashboard/${scope.id}`} data-testid="dashboard-link">{t('home.full_dashboard')}</Link>
            <Link className="btn secondary" to={`/scopes/${scope.id}`}>{t('home.manage_scope')}</Link>
            {me.role !== 'client_view' && <Link className="btn secondary" to="/farmers/new">{t('home.add_farmer')}</Link>}
            <button className="secondary" onClick={() => navigate('/farmers')}>{t('nav.farmers')}</button>
          </div>
          {slots.data && (
            <div className="card" style={{ padding: 0, overflow: 'hidden' }} data-testid="team-table">
              <div className="row" style={{ justifyContent: 'space-between', padding: '12px 16px' }}><strong>{t('home.team_title')}</strong><span className="muted small">{scope.label}</span></div>
              <div className="table-wrap" style={{ border: 'none', borderRadius: 0 }}><table>
                <thead><tr><th>{t('home.col_stage')}</th><th>{t('home.team_person')}</th><th>{t('home.team_verifies')}</th><th>{t('home.team_creates')}</th><th>{t('home.team_hands')}</th><th>{t('home.team_pending')}</th></tr></thead>
                <tbody>{scope.chain.map((s, i) => {
                  const prev = scope.chain[i - 1]; const next = scope.chain[i + 1];
                  const toVerify = prev ? Number(by(prev)?.pending ?? 0) : 0; const made = Number(by(s)?.pending ?? 0);
                  const names = holder(s);
                  return (
                    <tr key={s}>
                      <td><span aria-hidden="true">{stageIcon(s)} </span><strong>{label(s)}</strong></td>
                      <td>{names.length ? names.join(', ') : <Badge value="open" label={t('wizard.nobody')} />}</td>
                      <td>{prev ? t('home.team_verify', { stage: label(prev) }) : t('home.team_first')}</td>
                      <td>{s === 'qr_activation' ? t('home.team_seals') : t('home.team_create', { stage: label(s) })}</td>
                      <td>{next ? label(next) : t('home.team_end')}</td>
                      <td>{toVerify + made === 0 ? '—' : [toVerify > 0 && t('home.team_to_verify', { n: toVerify }), made > 0 && s !== 'qr_activation' && t('home.team_made', { n: made })].filter(Boolean).join(' · ')}</td>
                    </tr>);
                })}</tbody>
              </table></div>
            </div>)}
        </>
      )}
    </>
  );
}

interface LedgerCheck { checked_at: string; ok: boolean; blocks: number; first_bad_seq: number | null; problem: string | null; source: string }
/** Result of the nightly ledger check (migration 21). Silent while it is recent and clean. */
function LedgerHealth() {
  const { t } = useI18n();
  const last = useAsync(async () => ((await q(supabase.from('ledger_checks').select('*').order('checked_at', { ascending: false }).limit(1))) as LedgerCheck[])[0] ?? null, []);
  if (!last.data) return null;
  const c = last.data;
  const stale = Date.now() - new Date(c.checked_at).getTime() > 36 * 3600 * 1000;
  if (c.ok && !stale) return <p className="small muted banner" data-testid="ledger-health">{t('home.ledger_ok', { n: c.blocks, at: dateTime(c.checked_at) })}</p>;
  return <div className={`alert ${c.ok ? 'warn' : 'error'} banner`} role="alert" data-testid="ledger-health">
    {c.ok ? t('home.ledger_stale', { at: dateTime(c.checked_at) }) : t('home.ledger_bad', { seq: c.first_bad_seq ?? '?', problem: c.problem ?? '', at: dateTime(c.checked_at) })}</div>;
}
