// People and access (identity layer, migrations 31–33).
//   Directory     the pool of employees, filtered through two independent lenses (client, state)
//   Profile       one person on four axes: identity, org facts (grey: grant nothing), system role, assignments
//   Assign        give ONE assignment: a scope (role, stages, posting), a client's account, or a state
//   Roster        a scope stage by stage: who holds it, and the stages nobody holds
//   State         every scope in a state, across clients
// Who may do what is decided by the database (app.assign, app.end_assignment, …). The screens show a control when
// the server says the reader may use it, and show the server's refusal when it says no.
import { useEffect, useMemo, useState, type FormEvent } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { callFunction, q, rpc } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { date, todayIST } from '../../lib/format';
import { NO_RIGHTS, type EmployeeStatus, type Lens, type OpRole, type StageType, type SystemRole } from '../../lib/types';
import { lensTone, stagesAfter, type AssignmentInfo, type DirectoryFilter, type DirectoryPerson, type Profile,
  type Roster, type StateOverviewData, type Warning } from '../../lib/people';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { buildsScope, givesAssignments, myStateIds, oversees, seatsStateManagers } from '../../lib/rights';
import { AccessBadges, Confirm, OrgLine, StatusBadge, TempPassword, WarningList, useStageName } from './shared';
import { ReadyToAssign } from '../hr/Scale';
import { NewClientAccount } from '../clients/ClientAccounts';
import { clientAccounts } from '../../lib/clientAccounts';
import { elsewhereLine, poolGroups, type Elsewhere } from '../../lib/setup';
import { ScopeRequirementCard } from '../scopes/ScopeRequirement';
import { BaseLocation, HrScopeNote, stateChoices, useHrScope } from '../hr/Geo';

interface Named { id: string; name: string }
const useClients = () => useAsync(() => q(supabase.from('clients').select('id,name,state_id').order('name')) as Promise<(Named & { state_id: string | null })[]>, []);
const useStates = () => useAsync(() => q(supabase.from('states').select('id,name').order('name')) as Promise<Named[]>, []);

// ── directory ────────────────────────────────────────────────────────────────────────────────────────────────────
export function Directory() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const can = ctx?.user?.can ?? NO_RIGHTS;
  const clients = useClients();
  const states = useStates();
  const scope = useHrScope();
  // a State Manager (migration 41): his state's clients and his state only; a client may come from his overview (?client=)
  const sm0 = ctx?.user?.can?.state_manager ? myStateIds(ctx) : null;
  // a Client Manager (migration 44, Veda 14 Oct): his clients and their state only
  const myClients = (ctx?.assignments ?? []).filter((a) => a.lens === 'client' && a.op_role === 'client_account').map((a) => a.client_id ?? '');
  const cm = !sm0 && !oversees(ctx) && !can.hr && myClients.length > 0
    ? [...new Set((clients.data ?? []).filter((c) => myClients.includes(c.id)).map((c) => c.state_id).filter((x): x is string => !!x))] : null;
  const sm = sm0 ?? cm;
  const [params] = useSearchParams();
  const [f, setF] = useState<DirectoryFilter>({ text: '', client: params.get('client') ?? '', state: '', status: '', unassigned: false, kind: 'employees' });
  const [qq, setQq] = useState('');
  const [page, setPage] = useState(0);
  useEffect(() => { const h = setTimeout(() => { setQq(f.text); setPage(0); }, 300); return () => clearTimeout(h); }, [f.text]);
  // filtered and paged on the server (migration 38): the pool grows to hundreds
  const list = useAsync(() => rpc<{ total: number; counts: { employees: number; client_logins: number }; rows: DirectoryPerson[] }>('people_page', { p: {
    kind: f.kind, q: qq || null, client: f.client || null, state: f.state || null, status: f.status || null, unassigned: f.unassigned, limit: 50, offset: page * 50 } }),
    [f.kind, qq, f.client, f.state, f.status, f.unassigned, page]);
  const set = (p: Partial<DirectoryFilter>) => { setF({ ...f, ...p }); setPage(0); };
  const rows = list.data?.rows ?? [];
  const pages = Math.max(1, Math.ceil((list.data?.total ?? 0) / 50));
  return (
    <div>
      <div className="page-hd"><h1><span aria-hidden="true">👥 </span>{t('people.title')}</h1><div className="sub">{t('people.sub')}</div></div>
      <HrScopeNote />
      <div className="tabs" role="tablist">
        {(['employees', 'client_logins'] as const).map((k) => (
          <button key={k} type="button" role="tab" aria-selected={f.kind === k} className={f.kind === k ? 'active' : ''} onClick={() => set({ kind: k })}>
            {t(`people.kind_${k}`)} ({list.data?.counts[k] ?? '…'})</button>))}
      </div>
      {f.kind === 'employees' && (
        <div className="filters" data-testid="people-filters">
          <Field label={t('people.search')} htmlFor="pf-text"><input id="pf-text" type="search" value={f.text} onChange={(e) => setF({ ...f, text: e.target.value })} placeholder={t('people.search_hint')} /></Field>
          <Field label={t('people.client_lens')} htmlFor="pf-client"><select id="pf-client" value={f.client} onChange={(e) => set({ client: e.target.value })}>
            <option value="">{t('people.any_client')}</option>{(clients.data ?? []).filter((c) => !sm || (!!c.state_id && sm.includes(c.state_id))).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
          <Field label={t('people.state_lens')} htmlFor="pf-state"><select id="pf-state" value={f.state} onChange={(e) => set({ state: e.target.value })}>
            <option value="">{t('people.any_state')}</option>{(sm ? (states.data ?? []).filter((s) => sm.includes(s.id)) : stateChoices(states.data ?? [], scope.data)).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
          <Field label={t('common.status')} htmlFor="pf-status"><select id="pf-status" value={f.status} onChange={(e) => set({ status: e.target.value as DirectoryFilter['status'] })}>
            <option value="">{t('people.any_status')}</option>{(['invited', 'onboarding', 'active', 'suspended', 'offboarded'] as EmployeeStatus[]).map((s) => <option key={s} value={s}>{t(`pstatus.${s}`)}</option>)}</select></Field>
          <label className="check"><input type="checkbox" checked={f.unassigned} onChange={(e) => set({ unassigned: e.target.checked })} />{t('people.only_unassigned')}</label>
        </div>)}
      <p className="small muted">{t('people.legend')} <span className="badge lens-scope">{t('lens.scope')}</span> <span className="badge lens-client">{t('lens.client')}</span> <span className="badge lens-state">{t('lens.state')}</span> <span className="badge sys">{t('people.system_role')}</span></p>
      {list.loading && !list.data ? <Loading /> : <ErrorBox error={list.error} onRetry={() => void list.reload()} />}
      {list.data && rows.length === 0 && <Empty>{t('people.none')}</Empty>}
      {rows.length > 0 && (
        <div className="card table-wrap"><table data-testid="people">
          <thead><tr><th>{t('people.col_person')}</th><th>{t('common.status')}</th><th>{t('people.col_access')}</th><th /></tr></thead>
          <tbody>{rows.map((p) => (
            <tr key={p.id} data-testid="person-row">
              <td><Link to={`/people/${p.id}`}><strong>{p.name}</strong></Link><OrgLine org={p.org} /><div className="small muted">{p.email ?? p.phone ?? ''}</div></td>
              <td><StatusBadge status={p.status} />{!p.has_login && <> <Badge value="draft" label={t('people.no_login')} /></>}</td>
              <td><AccessBadges systemRole={p.system_role} assignments={p.assignments} elsewhere={p.elsewhere} unassigned={p.unassigned && !p.external} clientAccount={p.client_account} /></td>
              <td>{(p.assignable ?? (givesAssignments(ctx) && !p.external && p.system_role !== 'admin' && ['invited', 'onboarding', 'active'].includes(p.status) && p.id !== ctx?.user?.id)) &&
                <Link className="btn secondary" to={`/people/${p.id}/assign`} aria-label={`${t('assign.title')}: ${p.name}`}>{t('assign.title')}</Link>}</td>
            </tr>))}</tbody>
        </table></div>)}
      {(list.data?.total ?? 0) > 50 && <p className="row pager" data-testid="people-pager">
        <button type="button" className="secondary" disabled={page === 0} onClick={() => setPage(page - 1)}>{t('jl.prev')}</button>
        <span className="small">{t('jl.page', { page: page + 1, pages, total: list.data?.total ?? 0 })}</span>
        <button type="button" className="secondary" disabled={page + 1 >= pages} onClick={() => setPage(page + 1)}>{t('jl.next')}</button></p>}
      {f.kind === 'client_logins' && can.assign && !oversees(ctx) && <NewClientLogin clients={clients.data ?? []} done={() => void list.reload()} />}
      {can.hr && <p className="small muted">{t('people.hr_hint')} <Link to="/hr/joiners/new">{t('hr.add_joiner')}</Link></p>}
      {!can.hr && <p className="small muted">{t('people.missing_hint')}</p>}
    </div>
  );
}

/** A client's own login (migration 67: a viewer of one state's scopes, or the client's own staff), made here by its Client
 *  Manager, never by HR. Not an employee. The owner is the admin's to make, on the client's page. */
function NewClientLogin({ clients, done }: { clients: Named[]; done: () => void }) {
  const { t } = useI18n();
  const [client, setClient] = useState('');
  useEffect(() => { if (!client && clients.length === 1) setClient(clients[0].id); }, [clients, client]);
  const info = useAsync(() => client ? clientAccounts(client).catch(() => null) : Promise.resolve(null), [client]);
  const pick = (
    <Field label={t('lens.client')} htmlFor="cl-client"><select id="cl-client" value={client} onChange={(e) => setClient(e.target.value)} required>
      <option value="">—</option>{clients.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>);
  if (client && info.data) return <NewClientAccount client={client} info={info.data} done={done} title={t('people.new_client_login')}
    label={t('people.new_client_login')} note={t('people.client_login_note')} before={pick} />;
  return (
    <form className="card" aria-label={t('people.new_client_login')} onSubmit={(e) => e.preventDefault()}>
      <h2 style={{ marginTop: 0 }}>{t('people.new_client_login')}</h2>
      <p className="muted small">{t('people.client_login_note')}</p>
      <div className="form-grid">{pick}</div>
      {info.loading && <Loading />}
    </form>
  );
}

// ── one assignment, as a card ───────────────────────────────────────────────────────────────────────────────────────
function AssignmentCard({ a, changed, clientKind }: { a: AssignmentInfo; changed: () => Promise<unknown>; /** migration 68 (item 65) */ clientKind?: string }) {
  const { t } = useI18n();
  const stage = useStageName();
  const { ctx } = useAuth();
  const act = useAction();
  const [mode, setMode] = useState<null | 'end' | 'move' | 'stages'>(null);
  const [gaps, setGaps] = useState<StageType[] | null>(null);
  const [reason, setReason] = useState('');
  const [target, setTarget] = useState('');
  const [stages, setStages] = useState<StageType[]>(a.stages);
  const [note, setNote] = useState<string | null>(null);
  const scopes = (ctx?.scopes ?? []).filter((s) => s.manage && s.status !== 'closed');
  const chain = scopes.find((s) => s.scope_id === (mode === 'move' ? target : a.scope_id))?.chain ?? [];
  const begin = (m: 'end' | 'move' | 'stages') => { setMode(m); setNote(null); setStages(m === 'move' ? [] : a.stages);
    if (m !== 'stages') void rpc<{ gaps: StageType[] }>('end_preview', { p_assignment: a.id }).then((r) => setGaps(r.gaps), () => setGaps(null)); };
  const said = (g: StageType[] | undefined) => setNote(g?.length ? t('assign.left_unstaffed', { stages: g.map(stage).join(', ') }) : t('assign.saved'));
  const end = () => act.run(async () => { const r = await rpc<{ gaps: StageType[] }>('end_assignment', { p_assignment: a.id, p_reason: reason }); setMode(null); said(r.gaps); await changed(); });
  const move = () => act.run(async () => {
    const r = await rpc<{ gaps: StageType[] }>('reassign', { p_assignment: a.id, p_target: target, p_stages: stages, p_posting: a.posting, p_reason: reason });
    setMode(null); said(r.gaps); await changed(); });
  const save = () => act.run(async () => { const r = await rpc<{ gaps: StageType[] }>('set_stages', { p_assignment: a.id, p_stages: stages }); setMode(null); said(r.gaps.filter((g) => a.stages.includes(g))); await changed(); });
  const toggles = (
    <div className="chips" role="group" aria-label={t('assign.stages')}>{chain.map((s) => (
      <label key={s} className="check" style={{ minHeight: 0, padding: '2px 8px 2px 0' }}><input type="checkbox" checked={stages.includes(s)}
        onChange={(e) => setStages(stagesAfter(stages, s, e.target.checked))} />{stage(s)}</label>))}</div>);
  return (
    <div className={`assignment${a.active ? '' : ' ended'}`} data-testid={a.active ? 'assignment' : 'assignment-ended'}>
      <div className="row">
        <div><span className={`badge ${lensTone[a.lens]}`}>{t(`lens.${a.lens}`)}</span> <strong>{a.label}</strong> <span className="muted small" data-testid="assignment-role">{a.op_role === 'client_viewer' && clientKind ? t(`ca.role.${clientKind}`) : t(`oprole.${a.op_role}`)}</span></div>
        {a.active && a.can_end && !mode && <div className="row">
          {a.lens === 'scope' && <button type="button" className="secondary small-btn" onClick={() => begin('stages')}>{t('assign.change_stages')}</button>}
          {a.lens === 'scope' && <button type="button" className="secondary small-btn" onClick={() => begin('move')}>{t('assign.move')}</button>}
          <button type="button" className="danger small-btn" onClick={() => begin('end')} aria-label={`${t('assign.end')}: ${a.label}`}>{t('assign.end')}</button></div>}
      </div>
      {a.stages.length > 0 && <div className="chips">{a.stages.map((s) => <span key={s} className="chip">{stage(s)}</span>)}</div>}
      <div className="small muted">
        {a.posting && <>{t('assign.posting')}: {a.posting} · </>}{a.season_code && <>{a.season_code} · </>}
        {t('assign.since', { d: date(a.created_at), by: a.created_by ?? '—' })}
        {a.ends_on && <> · {t(a.lapsed ? 'assign.lapsed_on' : 'assign.ends_on', { d: date(a.ends_on) })}</>}
        {!a.active && <> · {t('assign.ended', { d: date(a.ended_at), why: a.end_reason ?? '' })}</>}
      </div>
      {note && <div className="alert info" data-testid="assignment-note">{note}</div>}
      <Confirm open={mode === 'end'} title={t('assign.end_title', { what: a.label })} confirmLabel={t('assign.end')} busy={act.busy} onConfirm={() => void end()} onCancel={() => setMode(null)}>
        {gaps && gaps.length > 0 && <p className="gap" data-testid="coverage-warning">{t('assign.will_unstaff', { stages: gaps.map(stage).join(', ') })}</p>}
        <Field label={t('assign.reason')} hint={t('common.optional')} htmlFor={`why-${a.id}`}><input id={`why-${a.id}`} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        <p className="small">{t('assign.end_note')}</p>
      </Confirm>
      <Confirm open={mode === 'move'} title={t('assign.move_title', { what: a.label })} confirmLabel={t('assign.move')} busy={act.busy || !target || (a.op_role === 'operator' && stages.length === 0)}
        onConfirm={() => void move()} onCancel={() => setMode(null)} danger={false}>
        {gaps && gaps.length > 0 && <p className="gap" data-testid="coverage-warning">{t('assign.will_unstaff', { stages: gaps.map(stage).join(', ') })}</p>}
        <Field label={t('assign.move_to')} htmlFor={`to-${a.id}`}><select id={`to-${a.id}`} value={target} onChange={(e) => { setTarget(e.target.value); setStages([]); }}>
          <option value="">—</option>{scopes.filter((s) => s.scope_id !== a.scope_id).map((s) => <option key={s.scope_id} value={s.scope_id}>{s.client_name} · {s.crop_name} · {s.season_code} · {s.geography}</option>)}</select></Field>
        {target && toggles}
        <Field label={t('assign.reason')} hint={t('common.optional')} htmlFor={`mwhy-${a.id}`}><input id={`mwhy-${a.id}`} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        <p className="small">{t('assign.move_note')}</p>
      </Confirm>
      <Confirm open={mode === 'stages'} title={t('assign.change_stages')} confirmLabel={t('common.save')} busy={act.busy || (a.op_role === 'operator' && stages.length === 0)}
        onConfirm={() => void save()} onCancel={() => setMode(null)} danger={false}>{toggles}</Confirm>
      <ErrorBox error={act.error} />
    </div>
  );
}

// ── profile ──────────────────────────────────────────────────────────────────────────────────────────────────────
export function ProfilePage() {
  const { id = '' } = useParams();
  const { t } = useI18n();
  const { ctx } = useAuth();
  const p = useAsync(() => rpc<Profile>('employee_profile', { p_employee: id }), [id]);
  const act = useAction();
  const [mode, setMode] = useState<null | 'suspend' | 'offboard' | 'rehire'>(null);
  const [f, setF] = useState({ reason: '', exit_date: todayIST(), settlement: '', form16: '', join_date: '' });
  const [preview, setPreview] = useState<{ assignments: number; gaps: { scope: string; client: string; stage: StageType }[] } | null>(null);
  const [temp, setTemp] = useState<{ who: string; pw: string } | null>(null);
  const stage = useStageName();
  if (p.loading && !p.data) return <Loading />;
  if (!p.data) return <ErrorBox error={p.error} onRetry={() => void p.reload()} />;
  const x = p.data, me = x.identity, admin = (ctx?.user?.can ?? NO_RIGHTS).admin;
  const run = (fn: () => Promise<unknown>) => act.run(async () => { await fn(); setMode(null); await p.reload(); });
  const beginOffboard = () => { setMode('offboard'); setPreview(null); void rpc<typeof preview>('offboard_preview', { p_employee: me.id }).then(setPreview, () => setPreview(null)); };
  const reset = () => act.run(async () => {
    if (!window.confirm(t('users.reset_sure'))) return;
    const r = await callFunction<{ sign_in: string; temporary_password: string }>('reset-password', { app_user_id: me.id });
    setTemp({ who: r.sign_in, pw: r.temporary_password });
  });
  return (
    <div>
      <p className="small"><Link to="/people">{t('people.title')}</Link></p>
      <div className="band"><div><h1>{me.name}</h1><div className="sub">{x.org?.job_title ?? (me.external ? t('people.kind_client_logins') : t(`sysrole.${x.system_role}`))}</div></div>
        <div className="side"><StatusBadge status={me.status} /></div></div>
      <p className="row" data-testid="profile-actions">
        {x.can.assign && <Link className="btn" to={`/people/${me.id}/assign`} data-testid="give-assignment">{t('assign.title')}</Link>}
        {x.can.hr_record && <Link className="btn secondary" to={`/hr/joiners/${me.id}`}>{t('people.hr_record')}</Link>}
        {x.can.reset_login && me.has_login && <button type="button" className="secondary" onClick={() => void reset()} disabled={act.busy}>{t('users.reset_password')}</button>}
        {x.can.suspend && <button type="button" className="secondary" onClick={() => setMode('suspend')}>{t('life.suspend')}</button>}
        {x.can.reinstate && <button type="button" onClick={() => void run(() => rpc('reinstate_person', { p_employee: me.id }))} disabled={act.busy}>{t('life.reinstate')}</button>}
        {x.can.offboard && <button type="button" className="danger" onClick={beginOffboard}>{t('life.offboard')}</button>}
        {x.can.rehire && <button type="button" onClick={() => setMode('rehire')}>{t('life.rehire')}</button>}
      </p>
      {temp && <TempPassword who={temp.who} password={temp.pw} />}
      <ErrorBox error={act.error} />
      <Confirm open={mode === 'suspend'} title={t('life.suspend_title', { name: me.name })} confirmLabel={t('life.suspend')} busy={act.busy || !f.reason.trim()}
        onConfirm={() => void run(() => rpc('suspend_person', { p_employee: me.id, p_reason: f.reason }))} onCancel={() => setMode(null)}>
        <p>{t('life.suspend_note')}</p>
        <Field label={t('assign.reason')} htmlFor="s-reason"><input id="s-reason" value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>
      </Confirm>
      <Confirm open={mode === 'offboard'} title={t('life.offboard_title', { name: me.name })} confirmLabel={t('life.offboard')} busy={act.busy || !f.exit_date}
        onConfirm={() => void run(() => rpc('offboard_person', { p_employee: me.id, p_exit_date: f.exit_date, p_reason: f.reason, p_final_settlement: f.settlement, p_form16_ref: f.form16 }))} onCancel={() => setMode(null)}>
        <p>{t('life.offboard_note')}</p>
        {preview && <p data-testid="offboard-preview">{t('life.offboard_ends', { n: preview.assignments })}
          {preview.gaps.length > 0 && <span className="gap"> {t('life.offboard_gaps', { list: preview.gaps.map((g) => `${stage(g.stage)} (${g.scope})`).join('; ') })}</span>}</p>}
        <div className="form-grid">
          <Field label={t('life.exit_date')} htmlFor="o-date"><input id="o-date" type="date" value={f.exit_date} onChange={(e) => setF({ ...f, exit_date: e.target.value })} required /></Field>
          <Field label={t('assign.reason')} htmlFor="o-reason"><input id="o-reason" value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>
          {!me.external && <Field label={t('life.settlement')} htmlFor="o-settle"><input id="o-settle" value={f.settlement} onChange={(e) => setF({ ...f, settlement: e.target.value })} /></Field>}
          {!me.external && <Field label={t('life.form16')} htmlFor="o-f16"><input id="o-f16" value={f.form16} onChange={(e) => setF({ ...f, form16: e.target.value })} /></Field>}
        </div>
      </Confirm>
      <Confirm open={mode === 'rehire'} title={t('life.rehire_title', { name: me.name })} confirmLabel={t('life.rehire')} busy={act.busy || !f.join_date} danger={false}
        onConfirm={() => void run(() => rpc('rehire_person', { p_employee: me.id, p_join_date: f.join_date }))} onCancel={() => setMode(null)}>
        <p>{t('life.rehire_note')}</p>
        <Field label={t('hr.f_join')} htmlFor="r-join"><input id="r-join" type="date" value={f.join_date} onChange={(e) => setF({ ...f, join_date: e.target.value })} required /></Field>
      </Confirm>

      <div className="axes">
        <div className="card axis" data-testid="axis-identity">
          <h2>1 · {t('axis.identity')}</h2>
          <dl className="kv">
            <dt>{t('account.sign_in')}</dt><dd>{me.email ?? me.phone ?? '—'}</dd>
            <dt>{t('hr.f_phone')}</dt><dd>{me.phone ?? '—'}</dd>
            <dt>{t('people.login')}</dt><dd>{me.has_login ? t('people.login_linked') : t('people.no_login')}</dd>
            {me.join_date && <><dt>{t('hr.f_join')}</dt><dd>{date(me.join_date)}</dd></>}
            {x.exits.map((e, i) => <span key={i} style={{ display: 'contents' }}><dt>{t('life.exit_date')}</dt><dd>{date(e.exit_date)}{e.reason ? ` · ${e.reason}` : ''}</dd></span>)}
          </dl>
        </div>
        {!me.external && <div className="card axis" data-testid="axis-org">
          <h2>2 · {t('axis.org')} <span className="axis-note">{t('axis.org_note')}</span></h2>
          <dl className="kv org-line" style={{ fontSize: 'inherit' }}>
            <dt>{t('hr.f_title')}</dt><dd>{x.org?.job_title ?? '—'}</dd>
            <dt>{t('hr.f_band')}</dt><dd>{x.org?.designation_band ?? '—'}</dd>
            <dt>{t('hr.f_dept')}</dt><dd>{x.org?.department ?? '—'}</dd>
            <dt>{t('hr.f_type')}</dt><dd>{x.org?.employment_type ? t(`emptype.${x.org.employment_type}`) : '—'}</dd>
            <dt>{t('hr.f_reports')}</dt><dd>{x.org?.reports_to_name ?? '—'}</dd>
          </dl>
          <BaseLocation employeeId={me.id} onChanged={() => void p.reload()} />
        </div>}
        {!me.external && <div className="card axis grants" data-testid="axis-system-role">
          <h2>3 · {t('axis.system_role')} <span className="axis-note">{t('axis.grants')}</span></h2>
          <p><span className={`badge ${x.system_role === 'operational' ? 'draft' : 'sys'}`}>{t(`sysrole.${x.system_role}`)}</span></p>
          <p className="small muted">{t(`sysrole.${x.system_role}_note`)}</p>
          {x.can.set_role && (
            <div className="row"><label htmlFor="sysrole" className="small">{t('axis.change_role')}</label>
              <select id="sysrole" value={x.system_role} style={{ width: 'auto' }} disabled={act.busy}
                onChange={(e) => { const to = e.target.value as SystemRole; if (window.confirm(t('axis.change_role_sure', { name: me.name, role: t(`sysrole.${to}`) }))) void run(() => rpc('set_system_role', { p_employee: me.id, p_role: to })); }}>
                <option value="operational">{t('sysrole.operational')}</option><option value="hr_resource">{t('sysrole.hr_resource')}</option>
                {admin && <option value="admin">{t('sysrole.admin')}</option>}
              </select></div>)}
          {x.system_role === 'hr_admin' && admin && <p className="small"><Link to="/system/seats">{t('seats.title')}</Link></p>}
        </div>}
        <div className="card axis grants" data-testid="axis-assignments">
          <h2>{me.external ? '2' : '4'} · {t('axis.assignments')} <span className="axis-note">{t('axis.grants')}</span></h2>
          {x.assignments.length === 0 && x.elsewhere === 0 && <p className="muted" data-testid="no-assignments">{t('people.unassigned_long')}</p>}
          {x.assignments.map((a) => <AssignmentCard key={a.id} a={a} changed={p.reload} clientKind={me.client_account?.kind} />)}
          {x.elsewhere > 0 && <p className="small muted" data-testid="elsewhere">{t('people.elsewhere_long', { n: x.elsewhere })}</p>}
          {x.history.length > 0 && <><div className="section-title">{t('assign.history')}</div>{x.history.map((a) => <AssignmentCard key={a.id} a={a} changed={p.reload} clientKind={me.client_account?.kind} />)}</>}
        </div>
      </div>
    </div>
  );
}

// ── give an assignment ──────────────────────────────────────────────────────────────────────────────────────────────
export function AssignPage() {
  const { id = '' } = useParams();
  const [search] = useSearchParams();
  const { t } = useI18n();
  const { ctx } = useAuth();
  const nav = useNavigate();
  const stage = useStageName();
  const can = ctx?.user?.can ?? NO_RIGHTS;
  const person = useAsync(() => rpc<Profile>('employee_profile', { p_employee: id }), [id]);
  const clients = useClients();
  const states = useStates();
  const scopes = useMemo(() => (ctx?.scopes ?? []).filter((s) => s.manage && s.status !== 'closed'), [ctx]);
  // The HR Admin seats State Managers (a state, nothing else); a State Manager also gives a client's account; the admin
  // gives nothing (migration 35, Veda 10 Oct).
  const seatOnly = seatsStateManagers(ctx) && !can.assign;
  // migration 44 (Veda, 14 Oct): "A scope" only for whoever runs a scope (its Client Manager); the State Manager keeps "A client's account"
  const [lens, setLens] = useState<Lens>(seatOnly ? 'state' : scopes.length > 0 || !can.state_lens ? 'scope' : 'client');
  const [target, setTarget] = useState(search.get('scope') ?? '');
  const [role, setRole] = useState<OpRole>('operator');
  const [stages, setStages] = useState<StageType[]>(search.get('stage') ? [search.get('stage') as StageType] : []);
  const [posting, setPosting] = useState('');
  const [endsOn, setEndsOn] = useState('');
  const [warnings, setWarnings] = useState<Warning[]>([]);
  const act = useAction();
  const roster = useAsync(() => lens === 'scope' && target ? rpc<Roster>('scope_roster', { p_scope: target }) : Promise.resolve(null), [lens, target]);
  const opRole: OpRole = lens === 'scope' ? role : lens === 'client' ? 'client_account' : 'state_supervisor';
  useEffect(() => {
    if (!target) { setWarnings([]); return; }
    const h = setTimeout(() => { void rpc<Warning[]>('assignment_warnings', { p_employee: id, p_lens: lens, p_target: target, p_op_role: opRole, p_stages: stages })
      .then(setWarnings, () => setWarnings([])); }, 250);
    return () => clearTimeout(h);
  }, [id, lens, target, opRole, stages]);
  if (person.loading && !person.data) return <Loading />;
  if (!person.data) return <ErrorBox error={person.error} />;
  const who = person.data.identity;
  const sc = scopes.find((s) => s.scope_id === target);
  if (!givesAssignments(ctx)) return <div className="alert info" data-testid="assign-not-yours">{t('assign.not_yours')}</div>;
  const lenses: Lens[] = seatOnly ? ['state'] : [...(scopes.length > 0 || !can.state_lens ? ['scope' as Lens] : []), ...(can.state_lens ? ['client' as Lens] : []), ...(seatsStateManagers(ctx) ? ['state' as Lens] : [])];
  const ready = !!target && (lens !== 'scope' || role === 'export_manager' || stages.length > 0);
  const submit = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    await rpc('assign', { p_employee: id, p_lens: lens, p_target: target, p_op_role: opRole, p_stages: lens === 'scope' ? stages : [], p_posting: posting, p_ends_on: endsOn || null });
    nav(`/people/${id}`);
  }); };
  return (
    <div style={{ maxWidth: 760 }}>
      <p className="small"><Link to={`/people/${id}`}>{who.name}</Link></p>
      <h1>{t('assign.title_for', { name: who.name })}</h1>
      <p className="muted small">{t('assign.one_at_a_time')}</p>
      <form className="card" onSubmit={submit} aria-label={t('assign.title')}>
        {lenses.length > 1 && (
          <div className="tabs" role="tablist">{lenses.map((l) => (
            <button key={l} type="button" role="tab" aria-selected={lens === l} className={lens === l ? 'active' : ''}
              onClick={() => { setLens(l); setTarget(''); setStages([]); }}>{t(`assign.lens_${l}`)}</button>))}</div>)}
        {lens === 'scope' && <>
          <Field label={`1 · ${t('lens.scope')}`} htmlFor="a-scope"><select id="a-scope" value={target} onChange={(e) => { setTarget(e.target.value); setStages([]); }} required>
            <option value="">—</option>{scopes.map((s) => <option key={s.scope_id} value={s.scope_id}>{s.client_name} · {s.state_name ?? ''} · {s.crop_name} · {s.season_code} · {s.geography}</option>)}</select></Field>
          {scopes.length === 0 && <div className="alert info">{t('assign.no_scopes')}</div>}
          <Field label={`2 · ${t('assign.role')}`} htmlFor="a-role"><select id="a-role" value={role} onChange={(e) => setRole(e.target.value as OpRole)}>
            <option value="operator">{t('oprole.operator')}</option><option value="export_manager">{t('oprole.export_manager')}</option></select></Field>
          <p className="hint">{t(`oprole.${role}_note`)}</p>
          {sc && <fieldset className="field" style={{ border: 'none', padding: 0, margin: '0 0 14px' }}>
            <legend style={{ padding: 0, fontWeight: 600 }}>3 · {t('assign.stages')}</legend>
            {sc.chain.map((s) => {
              const holders = roster.data?.stages.find((x) => x.stage === s)?.holders ?? [];
              return (
                <label key={s} className="check"><input type="checkbox" checked={stages.includes(s)} onChange={(e) => setStages(stagesAfter(stages, s, e.target.checked))} />
                  <span>{stage(s)} <span className={`small ${holders.length ? 'muted' : 'gap'}`}>{holders.length ? t('assign.held_by', { names: holders.map((h) => h.name).join(', ') }) : t('wizard.nobody')}</span></span></label>);
            })}</fieldset>}
          <Field label={`4 · ${t('assign.posting')}`} hint={t('assign.posting_hint')} htmlFor="a-posting"><input id="a-posting" value={posting} onChange={(e) => setPosting(e.target.value)} /></Field>
          <Field label={t('assign.ends_on_label')} hint={t('assign.ends_hint')} htmlFor="a-ends"><input id="a-ends" type="date" value={endsOn} onChange={(e) => setEndsOn(e.target.value)} /></Field>
        </>}
        {lens === 'client' && <>
          <Field label={t('lens.client')} htmlFor="a-client"><select id="a-client" value={target} onChange={(e) => setTarget(e.target.value)} required>
            <option value="">—</option>{(clients.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
          <p className="hint">{t('oprole.client_account_note')}</p>
        </>}
        {lens === 'state' && <>
          <Field label={t('lens.state')} htmlFor="a-state"><select id="a-state" value={target} onChange={(e) => setTarget(e.target.value)} required>
            <option value="">—</option>{(states.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
          <p className="hint">{t('oprole.state_supervisor_note')}</p>
        </>}
        <WarningList warnings={warnings} />
        <ErrorBox error={act.error} />
        <div className="row"><Link className="btn secondary" to={`/people/${id}`}>{t('common.cancel')}</Link>
          <button type="submit" disabled={act.busy || !ready} data-testid="assign-save">{t('assign.give')}</button></div>
      </form>
    </div>
  );
}

// ── a scope's roster ──────────────────────────────────────────────────────────────────────────────────────────────
interface Pool { id: string; name: string; plain: string; elsewhere: Elsewhere[] }   // migration 51 (A15): work on other scopes
/** The pool in a stage's list: free people, then "Already on other scopes" with what each holds there (A15). */
function PoolOptions({ pool }: { pool: Pool[] }) {
  const { t } = useI18n();
  const g = poolGroups(pool);
  if (g.busy.length === 0) return <>{g.free.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</>;
  return (<>
    {g.free.length > 0 && <optgroup label={t('pool.free')}>{g.free.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</optgroup>}
    <optgroup label={t('pool.busy')} data-testid="pool-busy">{g.busy.map((p) => <option key={p.id} value={p.id}>{`${p.name} · ${p.elsewhere.slice(0, 2).map((e) => elsewhereLine(e, t)).join('; ')}${p.elsewhere.length > 2 ? ` ${t('pool.more', { n: p.elsewhere.length - 2 })}` : ''}`}</option>)}</optgroup>
  </>);
}
/**
 * Stage by stage: who holds it; the stages nobody holds are flagged. A manager of the scope gives a stage to someone
 * from the pool (their assignment is made, or grows by that stage) and takes one away (the assignment shrinks, or ends
 * with its last stage). Used on the roster page and as the People step of the scope wizard.
 */
export function RosterEditor({ scopeId, onChanged }: { scopeId: string; onChanged?: () => void }) {
  const { t } = useI18n();
  const stage = useStageName();
  const r = useAsync(() => rpc<Roster>('scope_roster', { p_scope: scopeId }), [scopeId]);
  const canManage = !!r.data?.can_manage;
  const [find, setFind] = useState('');
  const [findQ, setFindQ] = useState('');
  useEffect(() => { const h = setTimeout(() => setFindQ(find), 300); return () => clearTimeout(h); }, [find]);
  // the pool, from the server (migration 44, Veda 14 Oct): operational people based in the scope's state, and the
  // Client Manager himself; never the admin, HR or a State Manager. Searched by name; 200 at most.
  // migration 46: who HR got ready for this scope comes first, marked with the stage they are for
  const [rev, setRev] = useState(0);
  // migration 51 (A15, Veda 15 Oct): free people first, then those already on other scopes, each with the work held there
  const pool = useAsync(async () => canManage ? (await rpc<{ id: string; name: string; me: boolean; ready_for?: StageType | null; elsewhere?: Elsewhere[] }[]>('roster_pool', { p_scope: scopeId, p_q: findQ || null }))
    .map((p) => ({ id: p.id, plain: p.name, elsewhere: p.elsewhere ?? [], name: (p.me ? t('roster.me', { name: p.name }) : p.name) + (p.ready_for ? ` · ${t('req.ready_for', { stage: stage(p.ready_for) })}` : '') }) as Pool) : [], [canManage, findQ, scopeId, rev]);
  const [busyNote, setBusyNote] = useState<string | null>(null);
  const act = useAction();
  const [note, setNote] = useState<string | null>(null);
  const [warnings, setWarnings] = useState<Warning[] | null>(null);
  if (r.loading && !r.data) return <Loading />;
  if (!r.data) return <ErrorBox error={r.error} onRetry={() => void r.reload()} />;
  const x = r.data;
  const held = (person: string) => x.stages.filter((s) => s.holders.some((h) => h.employee_id === person));
  const after = async (gaps?: StageType[], lost?: StageType[]) => {
    const g = (gaps ?? []).filter((s) => !lost || lost.includes(s));
    setNote(g.length ? t('assign.left_unstaffed', { stages: g.map(stage).join(', ') }) : null);
    await r.reload(); setRev((n) => n + 1); onChanged?.();
  };
  const give = (s: StageType, person: string) => act.run(async () => {
    const p = pool.data?.find((x) => x.id === person);
    // the soft note (A15): he keeps his other work and gets a second queue; nothing is refused for it
    setBusyNote(p && p.elsewhere.length ? t('pool.soft_note', { name: p.plain, work: p.elsewhere.map((e) => elsewhereLine(e, t)).join('; ') }) : null);
    const mine = held(person);
    // migration 46 (Veda, 14 Oct): one person may hold several stages, also two in a row; what that means is said, not refused
    const res = mine.length > 0 ? await rpc<{ warnings?: Warning[] }>('set_stages', { p_assignment: mine[0].holders.find((h) => h.employee_id === person)!.assignment_id, p_stages: [...mine.map((m) => m.stage), s] })
      : await rpc<{ warnings?: Warning[] }>('assign', { p_employee: person, p_lens: 'scope', p_target: scopeId, p_op_role: 'operator', p_stages: [s] });
    setWarnings((res?.warnings ?? []).filter((w) => w.code === 'adjacent_stages' || w.code === 'several_stages'));
    await after();
  });
  const take = (s: StageType, h: Roster['stages'][number]['holders'][number]) => act.run(async () => {
    if (!window.confirm(t('wizard.remove_confirm', { name: h.name, stage: stage(s) }))) return;
    const left = held(h.employee_id).map((m) => m.stage).filter((k) => k !== s);
    const res = left.length > 0 ? await rpc<{ gaps: StageType[] }>('set_stages', { p_assignment: h.assignment_id, p_stages: left })
      : await rpc<{ gaps: StageType[] }>('end_assignment', { p_assignment: h.assignment_id, p_reason: 'stage removed on the roster' });
    await after(res.gaps, [s]);
  });
  return (
    <div>
      {canManage && x.scope.status !== 'closed' && <ReadyToAssign lens="scope" target={scopeId} opRole="operator" stages={x.stages.map((s) => s.stage)} onDone={() => void after()} />}
      {x.gaps.length > 0 && x.scope.status !== 'closed' && <div className="alert warn" data-testid="roster-gaps">{t('roster.gaps', { n: x.gaps.length, stages: x.gaps.map(stage).join(', ') })}</div>}
      {x.gaps.length === 0 && <div className="alert ok" data-testid="roster-covered">{t('roster.covered')}</div>}
      {note && <div className="alert warn" data-testid="coverage-warning">{note}</div>}
      {busyNote && <div className="alert info small" data-testid="pool-soft-note">{busyNote}</div>}
      <WarningList warnings={warnings} />
      {(x.same_person?.verified_own ?? 0) + (x.same_person?.made_on_own ?? 0) > 0 && (
        <p className="small" data-testid="same-person-count"><span className="same-person">{t('ledger.same_person')}</span> {t('sp.count', { v: x.same_person!.verified_own, m: x.same_person!.made_on_own })}</p>)}
      <div className="slots" role="table" aria-label={t('wizard.step4')} data-testid="slots">{x.stages.map((s) => (
        <div className="slot" role="row" key={s.stage}>
          <div role="cell"><strong>{stage(s.stage)}</strong></div>
          <div role="cell">{s.holders.length === 0 && <span className="gap" data-testid={`gap-${s.stage}`}>{t('wizard.nobody')}</span>}
            {s.holders.map((h) => (
              <div key={h.assignment_id} className="row" data-testid={`slot-holder-${s.stage}`}>
                <span><Link to={`/people/${h.employee_id}`}>{h.name}</Link>{h.status !== 'active' && <> <StatusBadge status={h.status} /></>}{h.lapsed && <> <Badge value="closed" label={t('assign.lapsed')} /></>}
                  {h.posting && <span className="muted small"> · {h.posting}</span>}</span>
                {canManage && <button type="button" className="secondary small-btn" aria-label={`${t('wizard.remove')}: ${h.name} · ${stage(s.stage)}`} disabled={act.busy} onClick={() => void take(s.stage, h)}>{t('wizard.remove')}</button>}
              </div>))}</div>
          {canManage && <div className="row slot-controls" role="cell">
            <select aria-label={`Assign ${stage(s.stage)}`} style={{ maxWidth: '100%', minWidth: 0 }} defaultValue="" disabled={act.busy} onChange={(e) => { const v = e.target.value; e.target.value = ''; if (v) void give(s.stage, v); }}>
              <option value="">{t('roster.assign_from_pool')}</option>
              <PoolOptions pool={(pool.data ?? []).filter((p) => !s.holders.some((h) => h.employee_id === p.id))} />
            </select></div>}
        </div>))}</div>
      {canManage && <Field label={t('roster.find')} hint={t('roster.find_hint')} htmlFor={`find-${scopeId}`}><input id={`find-${scopeId}`} type="search" value={find} onChange={(e) => setFind(e.target.value)} data-testid="roster-find" /></Field>}
      {canManage && (pool.data?.length ?? 0) >= 200 && !findQ && <p className="small" data-testid="roster-pool-more">{t('roster.pool_more')}</p>}
      {canManage && <p className="small muted">{t('roster.pool_note')}</p>}
      <ErrorBox error={act.error} />
      {x.scope.status !== 'closed' && <ScopeRequirementCard scopeId={scopeId} chain={x.stages.map((s) => s.stage)} gaps={x.gaps}
        reloadKey={`${rev}-${x.gaps.join(',')}`} onChanged={() => setRev((n) => n + 1)} />}
    </div>
  );
}

export function RosterPage() {
  const { id = '' } = useParams();
  const { t } = useI18n();
  const r = useAsync(() => rpc<Roster>('scope_roster', { p_scope: id }), [id]);
  const { ctx } = useAuth();
  const stage = useStageName();
  // a draft: whether it can be activated, and the way to do it (14 Oct 2026, brief F: the Roster had no Activate)
  const missing = useAsync(() => rpc<{ crop: string[]; retired: boolean; stages: StageType[] }>('activation_missing', { p_scope: id }).catch(() => null), [id]);
  const builds = buildsScope(ctx, id);
  const lacks = missing.data ? [...missing.data.crop.map((k) => t('wizard.lack_crop', { what: t(`crops.missing_${k}`, undefined, k) })),
    ...missing.data.stages.map((x) => t('wizard.lack_stage', { stage: stage(x) }))] : null;
  return (
    <div>
      <p className="small"><Link to={`/scopes/${id}`}>{t('scopes.title')}</Link></p>
      {r.loading && !r.data ? <Loading /> : <ErrorBox error={r.error} />}
      {r.data && <>
        <div className="page-hd"><h1><span aria-hidden="true">🗂 </span>{t('roster.title')}</h1>
          <div className="sub">{r.data.scope.client_name} · {r.data.scope.crop_name} · {r.data.scope.season_code} · {r.data.scope.geography} · {r.data.scope.state_name} <Badge value={r.data.scope.status} /></div></div>
        {r.data.scope.status === 'draft' && builds && lacks && (
          <div className="card" data-testid="roster-activation">
            {lacks.length === 0
              ? <><div className="alert ok">{t('roster.covered')}</div>
                  <Link className="btn gold" to={`/scopes/${id}?step=people`} data-testid="roster-activate">{t('wizard.activate')}</Link></>
              : <div className="alert warn">{t('wizard.cannot_activate')}<ul>{lacks.map((x, i) => { const st = missing.data?.stages[i - (lacks.length - (missing.data?.stages.length ?? 0))];   // migration 46: a stage links to its request
                return <li key={x}>{st ? <a href={`#req-${st}`} data-testid="lack-link">{x}</a> : x}</li>; })}</ul></div>}
          </div>)}
        <div className="card"><RosterEditor scopeId={id} onChanged={() => void missing.reload()} /></div>
        <div className="card"><h2 style={{ marginTop: 0 }}>{t('roster.managers')}</h2>
          {r.data.managers.length === 0 ? <Empty /> : <ul data-testid="roster-managers">{r.data.managers.map((m) => (
            <li key={`${m.employee_id}-${m.op_role}`}><Link to={`/people/${m.employee_id}`}>{m.name}</Link> <span className="muted small">{t(`oprole.${m.op_role}`)}</span></li>))}</ul>}
          <p className="small muted">{t('roster.managers_note')}</p></div>
      </>}
    </div>
  );
}

// ── a state at a glance ─────────────────────────────────────────────────────────────────────────────────────────────
export function StateOverview() {
  const { id } = useParams();
  const { t } = useI18n();
  const { ctx } = useAuth();
  const nav = useNavigate();
  const stage = useStageName();
  const states = useStates();
  const admin = (ctx?.user?.can ?? NO_RIGHTS).admin;
  const mine = (states.data ?? []).filter((s) => admin || (ctx?.assignments ?? []).some((a) => a.lens === 'state' && a.state_id === s.id));
  const sel = id ?? mine[0]?.id ?? '';
  const d = useAsync(() => sel ? rpc<StateOverviewData>('state_overview', { p_state: sel }) : Promise.resolve(null), [sel]);
  const x = d.data;
  return (
    <div>
      <div className="page-hd"><h1><span aria-hidden="true">🗺 </span>{t('state.title')}{x?.state ? `: ${x.state.name}` : ''}</h1><div className="sub">{t('state.sub')}</div></div>
      {mine.length > 1 && <Field label={t('lens.state')} htmlFor="st-pick"><select id="st-pick" value={sel} onChange={(e) => nav(`/state/${e.target.value}`)} style={{ maxWidth: 320 }}>
        {mine.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>}
      {states.data && mine.length === 0 && <Empty>{t('state.none')}</Empty>}
      {d.loading && sel ? <Loading /> : <ErrorBox error={d.error} onRetry={() => void d.reload()} />}
      {x && <>
        <div className="stats" data-testid="state-stats">
          <div className="stat"><div className="stat-val">{x.clients}</div><div className="stat-label">{t('state.kpi_clients')}</div><div className="stat-sub" data-testid="state-clients-active">{t('state.kpi_clients_sub', { a: x.clients_active ?? 0 })}</div></div>
          <div className="stat"><div className="stat-val">{x.scopes.length}</div><div className="stat-label">{t('state.kpi_scopes')}</div></div>
          <div className="stat"><div className="stat-val">{x.people}</div><div className="stat-label">{t('state.kpi_people')}</div><div className="stat-sub">{t('state.kpi_unassigned', { n: x.unassigned })}</div></div>
          <div className="stat"><div className="stat-val">{x.scopes.reduce((n, s) => n + (s.status === 'closed' ? 0 : s.gaps.length), 0)}</div><div className="stat-label">{t('state.kpi_gaps')}</div><div className="stat-sub">{t('state.kpi_gaps_sub')}</div></div>
        </div>
        <p className="small muted">{t('state.supervisors')}: {x.supervisors.length ? x.supervisors.map((s) => s.name).join(', ') : '—'}</p>
        {[...new Set(x.scopes.map((s) => s.client_id))].map((c) => <ReadyToAssign key={c} lens="client" target={c} opRole="client_account"
          title={t('ready.client_title', { client: x.scopes.find((s) => s.client_id === c)?.client_name ?? '' })} onDone={() => void d.reload()} />)}
        {x.scopes.length === 0 ? <Empty /> : (
          <div className="card table-wrap"><table data-testid="state-scopes">
            <thead><tr><th>{t('lens.client')}</th><th>{t('lens.scope')}</th><th>{t('common.status')}</th><th>{t('state.col_people')}</th><th>{t('state.col_coverage')}</th><th /></tr></thead>
            <tbody>{x.scopes.map((s) => (
              <tr key={s.scope_id} className={s.gaps.length && s.status !== 'closed' ? 'gap-row' : ''} data-testid="state-scope-row">
                <td>{s.client_name}</td><td>{s.crop_name} · {s.season_code} · {s.geography}</td><td><Badge value={s.status} /></td><td>{s.people}</td>
                <td>{s.status === 'closed' ? '—' : s.gaps.length === 0 ? <span className="ok-text">{t('roster.covered_short', { n: s.stages })}</span>
                  : <span className="gap">{t('roster.gaps_short', { n: s.gaps.length, stages: s.gaps.map(stage).join(', ') })}</span>}</td>
                <td><Link className="btn secondary" to={`/scopes/${s.scope_id}/roster`}>{t('roster.title')}</Link></td>
              </tr>))}</tbody>
          </table></div>)}
      </>}
    </div>
  );
}
