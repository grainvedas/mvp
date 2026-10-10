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
import { date } from '../../lib/format';
import { NO_RIGHTS, type EmployeeStatus, type Lens, type OpRole, type StageType, type SystemRole } from '../../lib/types';
import { filterPeople, lensTone, stagesAfter, type AssignmentInfo, type DirectoryFilter, type DirectoryPerson, type Profile,
  type Roster, type StateOverviewData, type Warning } from '../../lib/people';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { oversees } from '../../lib/rights';
import { AccessBadges, Confirm, OrgLine, StatusBadge, TempPassword, WarningList, useStageName } from './shared';

interface Named { id: string; name: string }
const useClients = () => useAsync(() => q(supabase.from('clients').select('id,name').order('name')) as Promise<Named[]>, []);
const useStates = () => useAsync(() => q(supabase.from('states').select('id,name').order('name')) as Promise<Named[]>, []);

// ── directory ────────────────────────────────────────────────────────────────────────────────────────────────────
export function Directory() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const can = ctx?.user?.can ?? NO_RIGHTS;
  const list = useAsync(() => rpc<DirectoryPerson[]>('people_directory'), []);
  const clients = useClients();
  const states = useStates();
  const [f, setF] = useState<DirectoryFilter>({ text: '', client: '', state: '', status: '', unassigned: false, kind: 'employees' });
  const rows = useMemo(() => filterPeople(list.data ?? [], f), [list.data, f]);
  const all = list.data ?? [];
  // the lenses offered are the ones the reader's own assignments can show something through
  const seenClients = new Set(all.flatMap((p) => p.assignments.map((a) => a.client_id)));
  const seenStates = new Set(all.flatMap((p) => p.assignments.map((a) => a.state_id)));
  return (
    <div>
      <div className="page-hd"><h1><span aria-hidden="true">👥 </span>{t('people.title')}</h1><div className="sub">{t('people.sub')}</div></div>
      <div className="tabs" role="tablist">
        {(['employees', 'client_logins'] as const).map((k) => (
          <button key={k} type="button" role="tab" aria-selected={f.kind === k} className={f.kind === k ? 'active' : ''} onClick={() => setF({ ...f, kind: k })}>
            {t(`people.kind_${k}`)} ({all.filter((p) => (k === 'client_logins') === p.external).length})</button>))}
      </div>
      {f.kind === 'employees' && (
        <div className="filters" data-testid="people-filters">
          <Field label={t('people.search')} htmlFor="pf-text"><input id="pf-text" type="search" value={f.text} onChange={(e) => setF({ ...f, text: e.target.value })} placeholder={t('people.search_hint')} /></Field>
          <Field label={t('people.client_lens')} htmlFor="pf-client"><select id="pf-client" value={f.client} onChange={(e) => setF({ ...f, client: e.target.value })}>
            <option value="">{t('people.any_client')}</option>{(clients.data ?? []).filter((c) => seenClients.has(c.id)).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
          <Field label={t('people.state_lens')} htmlFor="pf-state"><select id="pf-state" value={f.state} onChange={(e) => setF({ ...f, state: e.target.value })}>
            <option value="">{t('people.any_state')}</option>{(states.data ?? []).filter((s) => seenStates.has(s.id)).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
          <Field label={t('common.status')} htmlFor="pf-status"><select id="pf-status" value={f.status} onChange={(e) => setF({ ...f, status: e.target.value as DirectoryFilter['status'] })}>
            <option value="">{t('people.any_status')}</option>{(['invited', 'onboarding', 'active', 'suspended', 'offboarded'] as EmployeeStatus[]).map((s) => <option key={s} value={s}>{t(`pstatus.${s}`)}</option>)}</select></Field>
          <label className="check"><input type="checkbox" checked={f.unassigned} onChange={(e) => setF({ ...f, unassigned: e.target.checked })} />{t('people.only_unassigned')}</label>
        </div>)}
      <p className="small muted">{t('people.legend')} <span className="badge lens-scope">{t('lens.scope')}</span> <span className="badge lens-client">{t('lens.client')}</span> <span className="badge lens-state">{t('lens.state')}</span> <span className="badge sys">{t('people.system_role')}</span></p>
      {list.loading ? <Loading /> : <ErrorBox error={list.error} onRetry={() => void list.reload()} />}
      {list.data && rows.length === 0 && <Empty>{t('people.none')}</Empty>}
      {rows.length > 0 && (
        <div className="card table-wrap"><table data-testid="people">
          <thead><tr><th>{t('people.col_person')}</th><th>{t('common.status')}</th><th>{t('people.col_access')}</th><th /></tr></thead>
          <tbody>{rows.map((p) => (
            <tr key={p.id} data-testid="person-row">
              <td><Link to={`/people/${p.id}`}><strong>{p.name}</strong></Link><OrgLine org={p.org} /><div className="small muted">{p.email ?? p.phone ?? ''}</div></td>
              <td><StatusBadge status={p.status} />{!p.has_login && <> <Badge value="draft" label={t('people.no_login')} /></>}</td>
              <td><AccessBadges systemRole={p.system_role} assignments={p.assignments} elsewhere={p.elsewhere} unassigned={p.unassigned && !p.external} /></td>
              <td>{can.assign && !p.external && p.system_role !== 'admin' && ['invited', 'onboarding', 'active'].includes(p.status) && p.id !== ctx?.user?.id &&
                <Link className="btn secondary" to={`/people/${p.id}/assign`} aria-label={`${t('assign.title')}: ${p.name}`}>{t('assign.title')}</Link>}</td>
            </tr>))}</tbody>
        </table></div>)}
      {f.kind === 'client_logins' && can.assign && !oversees(ctx) && <NewClientLogin clients={clients.data ?? []} done={() => void list.reload()} />}
      {can.hr && <p className="small muted">{t('people.hr_hint')} <Link to="/hr/joiners/new">{t('hr.add_joiner')}</Link></p>}
      {!can.hr && <p className="small muted">{t('people.missing_hint')}</p>}
    </div>
  );
}

/** A client's own read-only login. Not an employee: made here by whoever manages the client, never by HR. */
function NewClientLogin({ clients, done }: { clients: Named[]; done: () => void }) {
  const { t } = useI18n();
  const [f, setF] = useState({ client_id: '', display_name: '', email: '' });
  const [made, setMade] = useState<{ who: string; pw: string } | null>(null);
  const act = useAction();
  useEffect(() => { if (!f.client_id && clients.length === 1) setF((s) => ({ ...s, client_id: clients[0].id })); }, [clients, f.client_id]);
  const submit = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    const r = await callFunction<{ sign_in: string; temporary_password: string }>('create-user', { kind: 'viewer', ...f });
    setMade({ who: r.sign_in, pw: r.temporary_password }); setF({ ...f, display_name: '', email: '' }); done();
  }); };
  return (
    <form className="card" onSubmit={submit} aria-label={t('people.new_client_login')}>
      <h2 style={{ marginTop: 0 }}>{t('people.new_client_login')}</h2>
      <p className="muted small">{t('people.client_login_note')}</p>
      {made && <TempPassword who={made.who} password={made.pw} />}
      <div className="form-grid">
        <Field label={t('lens.client')} htmlFor="cl-client"><select id="cl-client" value={f.client_id} onChange={(e) => setF({ ...f, client_id: e.target.value })} required>
          <option value="">—</option>{clients.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
        <Field label={t('hr.f_name')} htmlFor="cl-name"><input id="cl-name" value={f.display_name} onChange={(e) => setF({ ...f, display_name: e.target.value })} required /></Field>
        <Field label={t('hr.f_email')} htmlFor="cl-email"><input id="cl-email" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} required /></Field>
      </div>
      <ErrorBox error={act.error} /><button type="submit" disabled={act.busy}>{t('common.create')}</button>
    </form>
  );
}

// ── one assignment, as a card ───────────────────────────────────────────────────────────────────────────────────────
function AssignmentCard({ a, changed }: { a: AssignmentInfo; changed: () => Promise<unknown> }) {
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
        <div><span className={`badge ${lensTone[a.lens]}`}>{t(`lens.${a.lens}`)}</span> <strong>{a.label}</strong> <span className="muted small">{t(`oprole.${a.op_role}`)}</span></div>
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
  const [f, setF] = useState({ reason: '', exit_date: new Date().toISOString().slice(0, 10), settlement: '', form16: '', join_date: '' });
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
          {x.assignments.map((a) => <AssignmentCard key={a.id} a={a} changed={p.reload} />)}
          {x.elsewhere > 0 && <p className="small muted" data-testid="elsewhere">{t('people.elsewhere_long', { n: x.elsewhere })}</p>}
          {x.history.length > 0 && <><div className="section-title">{t('assign.history')}</div>{x.history.map((a) => <AssignmentCard key={a.id} a={a} changed={p.reload} />)}</>}
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
  // The admin seats State Managers and gives nothing else (migration 34); a State Manager gives a client's account.
  const watch = oversees(ctx);
  const [lens, setLens] = useState<Lens>(watch ? 'state' : 'scope');
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
  const lenses: Lens[] = watch ? ['state'] : ['scope', ...(can.state_lens ? ['client' as Lens] : [])];
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
interface Pool { id: string; name: string }
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
  const pool = useAsync(async () => canManage ? (await rpc<DirectoryPerson[]>('people_directory'))
    .filter((p) => !p.external && ['invited', 'onboarding', 'active'].includes(p.status)).map((p) => ({ id: p.id, name: p.name }) as Pool) : [], [canManage]);
  const act = useAction();
  const [note, setNote] = useState<string | null>(null);
  if (r.loading && !r.data) return <Loading />;
  if (!r.data) return <ErrorBox error={r.error} onRetry={() => void r.reload()} />;
  const x = r.data;
  const held = (person: string) => x.stages.filter((s) => s.holders.some((h) => h.employee_id === person));
  const after = async (gaps?: StageType[], lost?: StageType[]) => {
    const g = (gaps ?? []).filter((s) => !lost || lost.includes(s));
    setNote(g.length ? t('assign.left_unstaffed', { stages: g.map(stage).join(', ') }) : null);
    await r.reload(); onChanged?.();
  };
  const give = (s: StageType, person: string) => act.run(async () => {
    const mine = held(person);
    if (mine.length > 0) await rpc('set_stages', { p_assignment: mine[0].holders.find((h) => h.employee_id === person)!.assignment_id, p_stages: [...mine.map((m) => m.stage), s] });
    else await rpc('assign', { p_employee: person, p_lens: 'scope', p_target: scopeId, p_op_role: 'operator', p_stages: [s] });
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
      {x.gaps.length > 0 && x.scope.status !== 'closed' && <div className="alert warn" data-testid="roster-gaps">{t('roster.gaps', { n: x.gaps.length, stages: x.gaps.map(stage).join(', ') })}</div>}
      {x.gaps.length === 0 && <div className="alert ok" data-testid="roster-covered">{t('roster.covered')}</div>}
      {note && <div className="alert warn" data-testid="coverage-warning">{note}</div>}
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
            <select aria-label={`Assign ${stage(s.stage)}`} defaultValue="" disabled={act.busy} onChange={(e) => { const v = e.target.value; e.target.value = ''; if (v) void give(s.stage, v); }}>
              <option value="">{t('roster.assign_from_pool')}</option>
              {(pool.data ?? []).filter((p) => !s.holders.some((h) => h.employee_id === p.id)).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select></div>}
        </div>))}</div>
      {canManage && <p className="small muted">{t('roster.pool_note')}</p>}
      <ErrorBox error={act.error} />
    </div>
  );
}

export function RosterPage() {
  const { id = '' } = useParams();
  const { t } = useI18n();
  const r = useAsync(() => rpc<Roster>('scope_roster', { p_scope: id }), [id]);
  return (
    <div>
      <p className="small"><Link to={`/scopes/${id}`}>{t('scopes.title')}</Link></p>
      {r.loading && !r.data ? <Loading /> : <ErrorBox error={r.error} />}
      {r.data && <>
        <div className="page-hd"><h1><span aria-hidden="true">🗂 </span>{t('roster.title')}</h1>
          <div className="sub">{r.data.scope.client_name} · {r.data.scope.crop_name} · {r.data.scope.season_code} · {r.data.scope.geography} · {r.data.scope.state_name} <Badge value={r.data.scope.status} /></div></div>
        <div className="card"><RosterEditor scopeId={id} /></div>
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
          <div className="stat"><div className="stat-val">{x.clients}</div><div className="stat-label">{t('state.kpi_clients')}</div></div>
          <div className="stat"><div className="stat-val">{x.scopes.length}</div><div className="stat-label">{t('state.kpi_scopes')}</div></div>
          <div className="stat"><div className="stat-val">{x.people}</div><div className="stat-label">{t('state.kpi_people')}</div><div className="stat-sub">{t('state.kpi_unassigned', { n: x.unassigned })}</div></div>
          <div className="stat"><div className="stat-val">{x.scopes.reduce((n, s) => n + (s.status === 'closed' ? 0 : s.gaps.length), 0)}</div><div className="stat-label">{t('state.kpi_gaps')}</div><div className="stat-sub">{t('state.kpi_gaps_sub')}</div></div>
        </div>
        <p className="small muted">{t('state.supervisors')}: {x.supervisors.length ? x.supervisors.map((s) => s.name).join(', ') : '—'}</p>
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
