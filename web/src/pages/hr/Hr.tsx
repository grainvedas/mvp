// HR (identity layer, migrations 31–33): the joiner pipeline, add a joiner, one joiner's page, the checklist templates.
// HR creates a person ONCE, as an identity. Nothing on these screens gives anyone a scope, a client or a state:
// that is a manager's act, on the People screens.
import { useEffect, useMemo, useState, type FormEvent } from 'react';
import { Link, Navigate, useNavigate, useParams } from 'react-router-dom';
import { callFunction, functionState, q, rpc } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { oversees } from '../../lib/rights';
import { date, dateTime } from '../../lib/format';
import { NO_RIGHTS, type EmploymentType, type SystemRole } from '../../lib/types';
import { DESIGNATION_BANDS, EMPLOYMENT_TYPES, FILE_KINDS, activationNeed, countdown, joinWords, masked, onThem, onUs, skipsStatutory, taskCode, waitingOn,
  type CheckState, type HrFile, type JoinerDetail as Detail, type PersonalDetails, type PipelineRow, type Task, type TaskKind, type TaskOwner } from '../../lib/people';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { FileBox, OrgLine, StatusBadge, TempPassword, uploadHrFile, useStageName } from '../people/shared';
import { HIRE_ROLES, sendInvites, type HireRole, type OpeningsSummary } from '../../lib/scale';
import { HrLinks, InviteResults, RoleLabel, useHrPeople } from './Scale';
import { BuddySelect, DepartmentSelect, DepartmentsCard, ReportsToSelect, useOrgChoices } from './OrgChoices';
import { BaseLocation, stateChoices, useAllStates, useHrScope } from './Geo';
import type { StageType } from '../../lib/types';

interface Template { id: string; name: string; is_default: boolean; active: boolean; role?: HireRole | null; first_day_time?: string | null; first_day_place?: string | null; first_day_ask_for?: string | null; first_day_bring?: string | null }

function Countdown({ days, status, on }: { days: number | null | undefined; status?: string; on?: string | null }) {
  const { t } = useI18n();
  const c = countdown(days);
  // H1 (migration 38): while someone is joining, never "joined N days ago": their joining date
  if (status && joinWords(status as never, days) === 'join.date') return <>{t('jl.joining_date', { d: date(on) })}</>;
  return <>{t(c.key, { n: c.n })}</>;
}
export function Owner({ owner }: { owner: TaskOwner }) {
  const { t } = useI18n();
  return <span className={`owner ${owner}`}>{t(`owner.${owner}`)}</span>;
}

// ── the pipeline ────────────────────────────────────────────────────────────────────────────────────────────────
export function HrPipeline() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const can = ctx?.user?.can ?? NO_RIGHTS;
  const list = useAsync(() => rpc<PipelineRow[]>('hr_pipeline'), []);
  const [show, setShow] = useState<'all' | 'us' | 'them'>('all');
  const rows = (list.data ?? []).filter((r) => show === 'all' || (show === 'us' ? onUs(r) : onThem(r)));
  const all = list.data ?? [];
  const n = (f: (r: PipelineRow) => boolean) => String(all.filter(f).length);
  return (
    <div>
      <div className="page-hd"><h1><span aria-hidden="true">🧑‍💼 </span>{t('hr.pipeline_title')}</h1><div className="sub">{t('hr.pipeline_sub')}</div></div>
      <p className="row">
        <Link className="btn" to="/hr/joiners/new" data-testid="add-joiner">{t('hr.add_joiner')}</Link>
        <Link className="btn secondary" to="/hr/templates">{t('hr.templates')}</Link>
        {(can.assign || can.hr) && <Link className="btn secondary" to="/people">{t('nav.people')}</Link>}
      </p>
      {list.loading ? <Loading /> : <ErrorBox error={list.error} onRetry={() => void list.reload()} />}
      {list.data && (
        <>
          <div className="stats" data-testid="hr-stats">
            <div className="stat"><div className="stat-val">{n((r) => r.status !== 'active')}</div><div className="stat-label">{t('hr.kpi_joining')}</div><div className="stat-sub">{t('hr.kpi_joining_sub')}</div></div>
            <div className="stat"><div className="stat-val">{n(onUs)}</div><div className="stat-label">{t('hr.kpi_on_us')}</div><div className="stat-sub">{t('hr.kpi_on_us_sub')}</div></div>
            <div className="stat"><div className="stat-val">{n(onThem)}</div><div className="stat-label">{t('hr.kpi_on_them')}</div><div className="stat-sub">{t('hr.kpi_on_them_sub')}</div></div>
            <div className="stat"><div className="stat-val">{n((r) => r.overdue > 0)}</div><div className="stat-label">{t('hr.kpi_overdue')}</div><div className="stat-sub">{t('hr.kpi_overdue_sub')}</div></div>
          </div>
          <div className="tabs" role="tablist">
            {(['all', 'us', 'them'] as const).map((k) => (
              <button key={k} type="button" role="tab" aria-selected={show === k} className={show === k ? 'active' : ''} onClick={() => setShow(k)}>{t(`hr.show_${k}`)}</button>))}
          </div>
          {rows.length === 0 ? <Empty>{t('hr.pipeline_empty')}</Empty> : (
            <div className="card table-wrap"><table className="wide" data-testid="pipeline">
              <thead><tr><th>{t('hr.col_joiner')}</th><th>{t('hr.col_joins')}</th><th>{t('hr.col_progress')}</th><th>{t('hr.col_waiting')}</th><th>{t('common.status')}</th></tr></thead>
              <tbody>{rows.map((r) => (
                <tr key={r.id} data-testid="pipeline-row">
                  <td><Link to={`/hr/joiners/${r.id}`}><strong>{r.name}</strong></Link>
                    <OrgLine org={{ job_title: r.job_title, department: r.department, designation_band: null, employment_type: r.employment_type }} /></td>
                  <td>{date(r.join_date)}<div className="small muted"><Countdown days={r.days_to_join} status={r.status} on={r.join_date} /></div></td>
                  <td><div className="bar" role="img" aria-label={`${r.pct} %`}><span style={{ width: `${r.pct}%` }} /></div>
                    <div className="small muted" data-testid="pipeline-pct">{t('hr.done_of', { done: r.done, total: r.total, pct: r.pct })}</div></td>
                  <td data-testid="pipeline-waiting">{r.blocked_by ? <>{waitingOn(r).map((o) => <span key={o}><Owner owner={o} /> </span>)}<span className="small">{t(`task.${taskKey(r.next_task)}`, undefined, r.next_task ?? '')}</span>
                    <div className={`small ${r.overdue > 0 ? 'gap' : 'muted'}`}>{t('hr.due', { d: date(r.next_due) })}{r.overdue > 0 ? ` · ${t('hr.overdue_n', { n: r.overdue })}` : ''}</div></>
                    : <span className="muted">{t('hr.nothing_open')}</span>}</td>
                  <td><StatusBadge status={r.status} />{r.status === 'invited' && <div className="small muted">{t('hr.awaiting_first')}</div>}</td>
                </tr>))}</tbody>
            </table></div>)}
        </>)}
    </div>
  );
}
/** Standard tasks are translated by their title's code; a task HR typed itself is shown as typed. */
const STANDARD: Record<string, string> = { 'Sign offer letter & NDA': 'offer_nda', 'Upload identity (PAN / Aadhaar)': 'identity', 'Add bank details': 'bank',
  'Countersign contract & NDA': 'countersign', 'PF & gratuity nomination (Form 2 / F)': 'pf_gratuity', 'Provision laptop & accounts': 'it_setup',
  'Assign & introduce buddy': 'buddy', 'Set 30-60-90 goals': 'goals', 'Personal details': 'personal' };
export const taskKey = (title: string | null | undefined) => STANDARD[title ?? ''] ?? '_';
export function TaskTitle({ task }: { task: { code: string; title: string } }) {
  const { t } = useI18n();
  // the standard titles have a Hindi wording; an edited or added one is the template's own text
  return <>{STANDARD[task.title] === task.code ? t(`task.${task.code}`, undefined, task.title) : task.title}</>;
}

// ── add a joiner ───────────────────────────────────────────────────────────────────────────────────────────────────────
const blankJoiner = { full_name: '', join_date: '', personal_email: '', phone: '', employment_type: 'full_time' as EmploymentType, designation_band: '',
  department: '', job_title: '', reports_to: '', buddy: '', template_id: '', system_role: 'operational' as SystemRole,
  opening_id: '', intended_role: '' as HireRole | '', intended_stage: '' as StageType | '', hr_owner: '', base_state_id: '', base_district: '' };

export function AddJoiner() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const can = ctx?.user?.can ?? NO_RIGHTS;
  const templates = useAsync(() => q(supabase.from('onboarding_templates').select('id,name,is_default,active').eq('active', true).order('name')) as Promise<Template[]>, []);
  const fn = useAsync(() => functionState('create-user'), []);
  const openings = useAsync(() => rpc<OpeningsSummary>('openings_summary', {}).catch(() => null), []);
  const hrPeople = useHrPeople();
  const scope = useHrScope();
  const allStates = useAllStates();
  const stage = useStageName();
  const [invite, setInvite] = useState<Awaited<ReturnType<typeof sendInvites>> | null>(null);
  const [f, setF] = useState(blankJoiner);
  const [made, setMade] = useState<{ id: string; name: string; sign_in: string; password: string; emailed: boolean; type: EmploymentType } | null>(null);
  const act = useAction();
  useEffect(() => { if (!f.hr_owner && ctx?.user?.id && (ctx.user.system_role === 'hr_admin' || ctx.user.system_role === 'hr_resource')) setF((s) => ({ ...s, hr_owner: ctx.user!.id })); }, [ctx, f.hr_owner]);
  const chosen = (openings.data?.openings ?? []).find((o) => o.id === f.opening_id);
  const set = (k: keyof typeof blankJoiner) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  // migration 58: the choices are those of the state the person is based in (as the server decides it)
  const baseState = f.base_state_id || (scope.data && !scope.data.full && scope.data.states.length === 1 ? scope.data.states[0].id : '') || chosen?.state_id || '';
  const org = useOrgChoices(baseState || null);
  useEffect(() => {
    if (!org) return;
    setF((s) => ({ ...s, reports_to: org.managers.some((m) => m.id === s.reports_to) ? s.reports_to : '',
                          buddy: org.buddies.some((m) => m.id === s.buddy) ? s.buddy : '' }));
  }, [org]);
  const submit = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    const r = await callFunction<{ app_user_id: string; sign_in: string; temporary_password: string; invite_emailed: boolean }>('create-user', {
      kind: 'joiner', ...f, intended_role: f.opening_id ? '' : f.intended_role, intended_stage: !f.opening_id && f.intended_role === 'operator' ? f.intended_stage : '',
      system_role: f.opening_id && chosen?.role === 'hr' && f.system_role === 'operational' ? 'hr_resource' : f.system_role });
    setMade({ id: r.app_user_id, name: f.full_name, sign_in: r.sign_in, password: r.temporary_password, emailed: r.invite_emailed, type: f.employment_type });
    setInvite(null);
    setF({ ...blankJoiner, opening_id: f.opening_id, template_id: f.template_id, hr_owner: f.hr_owner, base_state_id: f.base_state_id, base_district: f.base_district });
  }); };
  return (
    <div style={{ maxWidth: 820 }}>
      <p className="small"><Link to="/hr">{t('hr.pipeline_title')}</Link></p>
      <h1>{t('hr.add_joiner')}</h1>
      {fn.data && fn.data !== 'ok' && fn.data !== 'unknown' && (
        <div className="alert warn" role="status" data-testid="functions-warning">{t('users.fn_warning', { what: t(fn.data === 'missing' ? 'users.fn_none' : 'users.fn_old', { name: 'create-user' }) })}</div>)}
      {made && (
        <div className="card" data-testid="joiner-made">
          <h2 style={{ marginTop: 0 }}>{t('hr.invite_sent', { name: made.name })}</h2>
          <p><Badge value="draft" label={t('hr.awaiting_first')} /></p>
          <TempPassword who={made.sign_in} password={made.password} />
          <p className="small muted">{t(made.emailed ? 'hr.invite_emailed' : 'hr.invite_by_hand')}</p>
          {skipsStatutory(made.type) && <p className="small muted">{t('hr.statutory_skipped')}</p>}
          <p className="small">{t('inv.instead')} <button type="button" className="secondary small-btn" disabled={act.busy} data-testid="made-invite"
            onClick={() => void act.run(async () => setInvite(await sendInvites([made.id])))}>{t('inv.send_one')}</button></p>
          {invite && <InviteResults {...invite} />}
          <p className="row"><Link className="btn" to={`/hr/joiners/${made.id}`}>{t('hr.open_joiner')}</Link>
            <button type="button" className="secondary" onClick={() => setMade(null)}>{t('hr.add_another')}</button></p>
        </div>)}
      {!made && (
        <form className="card" onSubmit={submit} aria-label={t('hr.add_joiner')}>
          <p className="muted small">{t('hr.add_note')}</p>
          <div className="form-grid" data-testid="joiner-role">
            <Field label={t('open.col_opening')} hint={t('aj.opening_hint')} htmlFor="j-opening"><select id="j-opening" value={f.opening_id}
              onChange={(e) => { const o = (openings.data?.openings ?? []).find((x) => x.id === e.target.value); setF({ ...f, opening_id: e.target.value, base_state_id: o?.state_id ?? f.base_state_id }); }}>
              <option value="">{t('aj.no_opening')}</option>
              {(openings.data?.openings ?? []).filter((o) => o.status === 'open' && o.vacant > 0).map((o) => (   // G4 (Veda, 14 Oct): no full or closed opening
                <option key={o.id} value={o.id}>{o.code} · {t(`role.${o.role}`)}{o.stage ? ` · ${stage(o.stage)}` : ''} · {t('aj.vacant', { n: o.vacant })}</option>))}</select></Field>
            {!f.opening_id && <Field label={t('open.role')} hint={t('common.optional')} htmlFor="j-role"><select id="j-role" value={f.intended_role} onChange={set('intended_role')}>
              <option value="">—</option>{HIRE_ROLES.map((r) => <option key={r} value={r}>{t(`role.${r}`)}</option>)}</select></Field>}
            {!f.opening_id && f.intended_role === 'operator' && <Field label={t('open.stage')} hint={t('common.optional')} htmlFor="j-stage"><select id="j-stage" value={f.intended_stage} onChange={set('intended_stage')}>
              <option value="">—</option>{(['procurement', 'lot_inward', 'village_batch', 'warehouse', 'milling', 'sorting', 'grading', 'drying', 'popping', 'cleaning', 'blanching', 'cold_storage', 'packing', 'qc', 'commercial', 'shipment', 'qr_activation'] as StageType[]).map((x) => <option key={x} value={x}>{stage(x)}</option>)}</select></Field>}
            {chosen && <p className="small" data-testid="opening-role"><RoleLabel role={chosen.role} stage={chosen.stage} /> · {chosen.state_name}</p>}
            <Field label={t('jl.owner')} htmlFor="j-owner"><select id="j-owner" value={f.hr_owner} onChange={set('hr_owner')}>
              <option value="">{t('jl.owner_none')}</option>{(hrPeople.data ?? []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></Field>
            {/* G9 (Veda, 14 Oct): an HR resource of one state saw that state twice; now it is the one choice, chosen */}
            <Field label={t('geo.based_in')} hint={t('geo.based_hint')} htmlFor="j-base"><select id="j-base"
              value={f.base_state_id || (scope.data && !scope.data.full && scope.data.states.length === 1 ? scope.data.states[0].id : '')} onChange={set('base_state_id')}
              required={!!scope.data && !(!scope.data.full && scope.data.states.length === 1)}>
              {!(scope.data && !scope.data.full && scope.data.states.length === 1) && <option value="">—</option>}
              {stateChoices(allStates.data ?? [], scope.data).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
            <Field label={t('geo.district')} hint={t('common.optional')} htmlFor="j-district"><input id="j-district" value={f.base_district} onChange={set('base_district')} maxLength={60} /></Field>
          </div>
          <div className="form-grid">
            <Field label={t('hr.f_name')} htmlFor="j-name"><input id="j-name" value={f.full_name} onChange={set('full_name')} required autoComplete="off" /></Field>
            <Field label={t('hr.f_join')} htmlFor="j-join"><input id="j-join" type="date" value={f.join_date} onChange={set('join_date')} required /></Field>
            <Field label={t('hr.f_email')} hint={t('hr.f_email_hint')} htmlFor="j-email"><input id="j-email" type="email" value={f.personal_email} onChange={set('personal_email')} required autoComplete="off" /></Field>
            <Field label={t('hr.f_phone')} hint={t('hr.f_phone_hint')} htmlFor="j-phone"><input id="j-phone" type="tel" inputMode="tel" value={f.phone} onChange={set('phone')} required autoComplete="off" /></Field>
            <Field label={t('hr.f_type')} htmlFor="j-type"><select id="j-type" value={f.employment_type} onChange={set('employment_type')}>
              {EMPLOYMENT_TYPES.map((x) => <option key={x} value={x}>{t(`emptype.${x}`)}</option>)}</select></Field>
            <Field label={t('hr.f_band')} htmlFor="j-band"><select id="j-band" value={f.designation_band} onChange={set('designation_band')}>
              <option value="">—</option>{DESIGNATION_BANDS.map((x) => <option key={x} value={x}>{x}</option>)}</select></Field>
            <Field label={t('hr.f_dept')} hint={t('org.dept_hint')} htmlFor="j-dept"><DepartmentSelect id="j-dept" value={f.department} onChange={(v) => setF({ ...f, department: v })} choices={org} /></Field>
            <Field label={t('hr.f_title')} htmlFor="j-title"><input id="j-title" value={f.job_title} onChange={set('job_title')} /></Field>
            <Field label={t('hr.f_reports')} hint={t('org.reports_hint')} htmlFor="j-reports"><ReportsToSelect id="j-reports" value={f.reports_to} onChange={(v) => setF({ ...f, reports_to: v })} choices={org} /></Field>
            <Field label={t('hr.f_buddy')} hint={t('org.buddy_hint')} htmlFor="j-buddy"><BuddySelect id="j-buddy" value={f.buddy} onChange={(v) => setF({ ...f, buddy: v })} choices={org} /></Field>
            <Field label={t('hr.f_template')} htmlFor="j-template"><select id="j-template" value={f.template_id} onChange={set('template_id')}>
              <option value="">{t('aj.template_auto')}</option>
              {(templates.data ?? []).map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}</select></Field>
            <Field label={t('hr.f_sysrole')} hint={t('hr.f_sysrole_hint')} htmlFor="j-sysrole"><select id="j-sysrole" value={f.system_role} onChange={set('system_role')}>
              <option value="operational">{t('sysrole.operational')}</option><option value="hr_resource">{t('sysrole.hr_resource')}</option>
              {can.admin && <option value="admin">{t('sysrole.admin')}</option>}</select></Field>
          </div>
          {skipsStatutory(f.employment_type) && <div className="alert info" data-testid="statutory-hint">{t('hr.statutory_hint')}</div>}
          {f.system_role === 'hr_resource' && <div className="alert info">{t('hr.hr_resource_hint')}</div>}
          <ErrorBox error={act.error} />
          <button type="submit" disabled={act.busy}>{t('hr.save_invite')}</button>
        </form>)}
    </div>
  );
}

/** Pure: "Mark as joined" is shown exactly when the server would accept it (migration 36: for the admin, only on the
 *  HR Admin seat holder's page). An older server that does not say falls back to the HR rule as before. */
export const mayActivate = (x: { can_manage: boolean; can_activate?: boolean; person: { status: string } }) =>
  x.can_activate ?? (x.can_manage && (x.person.status === 'invited' || x.person.status === 'onboarding'));

// ── one joiner ───────────────────────────────────────────────────────────────────────────────────────────────────────────
export function JoinerPage() {
  const { id = '' } = useParams();
  const { t } = useI18n();
  const nav = useNavigate();
  const d = useAsync(() => rpc<Detail>('joiner_detail', { p_employee: id }), [id]);
  const { ctx, refresh } = useAuth();
  const act = useAction();
  const [temp, setTemp] = useState<{ who: string; pw: string } | null>(null);
  const [note, setNote] = useState('');
  const [edit, setEdit] = useState(false);
  const [doc, setDoc] = useState<{ kind: string; file: File | null }>({ kind: 'contract', file: null });
  const [why, setWhy] = useState('');
  const [joined, setJoined] = useState(false);
  if (d.loading && !d.data) return <Loading />;
  // the admin may open one joiner's page: the HR Admin's (H2); any other address sends him home, as before migration 38
  if (!d.data && d.error && !ctx?.user?.can?.hr) return <Navigate to="/" replace />;
  if (!d.data) return <ErrorBox error={d.error} onRetry={() => void d.reload()} />;
  const x = d.data, p = x.person;
  const ours = x.tasks.filter((k) => k.status === 'pending' && k.owner !== 'hire');
  const run = (fn: () => Promise<unknown>) => act.run(async () => { await fn(); await d.reload(); });
  // The admin marking the HR Admin as joined (migration 36) switches HR on: this page is HR's from then on, so he goes to
  // the Seats page, which says so (first: this page's own guard would send him home), and his menu loses HR · Joiners
  // once the server is asked again.
  const need = activationNeed(x.activation);
  const activate = () => act.run(async () => {
    await rpc('activate_joiner', { p_employee: p.id, p_reason: why.trim() || null });
    if (p.system_role === 'hr_admin' && oversees(ctx)) { nav('/system/seats', { state: { joined: p.name } }); void refresh(); return; }
    // G2 (migration 38): the page shows "Active" at once, and the button goes, before the server is asked again
    d.setData({ ...x, person: { ...p, status: 'active' }, can_activate: false });
    setWhy(''); setJoined(true);
    await d.reload();
  });
  const onPaper = (taskId: string) => {
    const n = window.prompt(t('gate.on_paper_note'));
    if (n === null) return;
    void run(() => rpc('record_on_paper', { p_task: taskId, p_note: n }));
  };
  const full = x.docs !== undefined;                  // the admin on the HR Admin's page sees her steps, not her HR file
  const mayDo = x.can_do_steps ?? x.can_manage;
  const open = (path: string) => act.run(async () => {
    const { data, error } = await supabase.storage.from('hr-docs').createSignedUrl(path, 120);
    if (error || !data?.signedUrl) throw new Error(t('hr.file_not_opened'));
    window.open(data.signedUrl, '_blank', 'noopener');
  });
  const reset = () => act.run(async () => {
    if (!window.confirm(t('users.reset_sure'))) return;
    const r = await callFunction<{ sign_in: string; temporary_password: string }>('reset-password', { app_user_id: p.id });
    setTemp({ who: r.sign_in, pw: r.temporary_password });
  });
  return (
    <div>
      <p className="small"><Link to="/hr">{t('hr.pipeline_title')}</Link></p>
      <div className="band">
        <div><h1>{p.name}</h1><div className="sub">{[x.org.job_title, x.org.department].filter(Boolean).join(' · ') || t(`sysrole.${p.system_role}`)}</div></div>
        <div className="side">{date(p.join_date)}<br /><Countdown days={p.days_to_join} status={p.status} on={p.join_date} /></div>
      </div>
      <p className="row"><StatusBadge status={p.status} />
        {p.status === 'invited' && <span className="small muted">{t('hr.awaiting_first')}</span>}
        {!p.has_login && <Badge value="draft" label={t('people.no_login')} />}
        <Link className="btn secondary" to={`/people/${p.id}`}>{t('people.open_profile')}</Link>
        {mayActivate(x) && need !== 'reason' && (
          <button type="button" onClick={() => void activate()} disabled={act.busy || need === 'statutory'} data-testid="activate">{t('hr.mark_joined')}</button>)}
        {x.can_manage && p.has_login && <button type="button" className="secondary" onClick={() => void reset()} disabled={act.busy} data-testid="reset-password">{t('users.reset_password')}</button>}
      </p>
      {joined && <div className="alert ok" role="status" data-testid="joined-now">{t('gate.joined_now', { name: p.name })}</div>}
      {mayActivate(x) && need === 'statutory' && <div className="alert warn" data-testid="gate-statutory">{t('gate.statutory', { steps: x.activation!.statutory_open.join(', ') })}</div>}
      {mayActivate(x) && need === 'reason' && (
        <form className="card gate" onSubmit={(e) => { e.preventDefault(); void activate(); }} aria-label={t('hr.mark_joined')} data-testid="gate-reason">
          <p className="small">{t('gate.open_steps', { n: x.activation!.open })}</p>
          <div className="row"><input aria-label={t('gate.reason')} placeholder={t('gate.reason')} value={why} onChange={(e) => setWhy(e.target.value)} style={{ flex: 1, minWidth: 0 }} data-testid="gate-why" />
            <button type="submit" disabled={act.busy || why.trim().length < 5} data-testid="activate">{t('hr.mark_joined')}</button></div>
        </form>)}
      <div className="axes">
        <RoleCard x={x} onSaved={() => void d.reload()} />
        {full && <div className="card"><BaseLocation employeeId={p.id} /></div>}
        {x.can_invite !== undefined && (x.can_invite || x.invite) && <InviteCard x={x} onTemp={(who, pw) => setTemp({ who, pw })} onChanged={() => void d.reload()} />}
      </div>
      {temp && <TempPassword who={temp.who} password={temp.pw} />}
      <ErrorBox error={act.error} />

      {ours.length > 0 && mayDo && (
        <div className="queue" data-testid="waiting-on-you">
          <h2>{t('hr.waiting_on_you', { n: ours.length })}</h2>
          {ours.map((k) => <OurTask key={k.id} task={k} person={p.id} current={x} busy={act.busy} done={(data) => run(() => rpc('complete_task', { p_task: k.id, p_data: data }))} />)}
        </div>)}

      <h2 className="section-title">{t('hr.checklist')}</h2>
      <div className="card table-wrap"><table className="wide" data-testid="joiner-tasks">
        <thead><tr><th>#</th><th>{t('hr.col_task')}</th><th>{t('hr.col_owner')}</th><th>{t('hr.col_due')}</th><th>{t('common.status')}</th><th /></tr></thead>
        <tbody>{x.tasks.map((k) => (
          <tr key={k.id} data-testid={`task-${k.code}`}>
            <td>{k.seq}</td>
            <td><TaskTitle task={k} />{k.statutory && <> <Badge value="pending" label={t('hr.statutory')} /></>}{k.note && <div className="small muted">{k.note}</div>}</td>
            <td><Owner owner={k.owner} /></td>
            <td className={k.overdue ? 'gap' : ''}>{date(k.due_on)}{k.overdue ? ` · ${t('hr.overdue')}` : ''}</td>
            <td>{k.status === 'done' ? <><Badge value="verified" label={t('hr.done')} /><div className="small muted">{k.done_by} · {dateTime(k.done_at)}</div></> : <Badge value="pending" label={t('hr.open')} />}</td>
            <td>{x.can_manage && k.status === 'done' && <button type="button" className="secondary small-btn" disabled={act.busy} onClick={() => {
              const why = window.prompt(t('hr.reopen_why')); if (why) void run(() => rpc('reopen_task', { p_task: k.id, p_reason: why })); }}>{t('hr.reopen')}</button>}
              {mayDo && k.status === 'pending' && k.statutory && (
                <button type="button" className="secondary small-btn" disabled={act.busy} onClick={() => onPaper(k.id)} data-testid={`on-paper-${k.code}`}>{t('gate.on_paper')}</button>)}
              {x.can_manage && k.status === 'pending' && k.owner === 'hire' && (k.kind === 'sign' || k.kind === 'other') && (
                <button type="button" className="secondary small-btn" disabled={act.busy} onClick={() => void run(() => rpc('complete_task', { p_task: k.id, p_data: { note: t('hr.on_behalf_note') } }))}>{t('hr.on_behalf')}</button>)}</td>
          </tr>))}</tbody>
      </table></div>

      {full && <div className="axes">
        <div className="card">
          <h2 style={{ marginTop: 0 }}>{t('hr.vault')}</h2>
          <p className="small muted">{t('hr.vault_note')}</p>
          <dl className="kv" data-testid="masked-docs">
            <dt>PAN</dt><dd>{masked(x.docs.pan_last4)} <Checked s={x.checked?.pan} id="pan" /></dd>
            <dt>Aadhaar</dt><dd>{masked(x.docs.aadhaar_last4)} <Checked s={x.checked?.aadhaar} id="aadhaar" /></dd>
            <dt>{t('hr.bank')}</dt><dd>{x.docs.bank_name || x.docs.bank_last4 ? `${x.docs.bank_name ?? ''} · ${x.docs.bank_ifsc ?? ''} · ${masked(x.docs.bank_last4)}` : '—'} <Checked s={x.checked?.bank} id="bank" /></dd>
            <dt>UAN</dt><dd>{masked(x.docs.pf_uan_last4)} <Checked s={x.checked?.uan} id="uan" /></dd>
            <dt>{t('hr.pan_card')}</dt><dd data-testid="pan-card-seen">{x.docs.pan_card_seen_at ? t('hr.pan_seen_by', { name: x.docs.pan_card_seen_by ?? '—', d: date(x.docs.pan_card_seen_at) })
              : <>{'—'} {x.can_manage && <button type="button" className="secondary small-btn" disabled={act.busy} data-testid="record-pan-seen"
                onClick={() => void run(() => rpc('record_card_seen', { p_employee: p.id }))}>{t('hr.pan_seen_btn')}</button>}</>}</dd>
            <dt>{t('hr.nominee')}</dt><dd>{x.docs.gratuity_nominee ? `${x.docs.gratuity_nominee} (${x.docs.nominee_relation ?? ''})` : '—'}</dd>
            {x.docs.form16_ref && <><dt>Form 16</dt><dd>{x.docs.form16_ref}</dd></>}
          </dl>
          <IdMatches x={x} busy={act.busy} run={run} />
          {x.files.length === 0 ? <Empty>{t('hr.no_files')}</Empty> : (
            <ul data-testid="hr-files">{x.files.map((file) => (
              <li key={file.id} className="row" data-testid="hr-file" data-kind={file.kind}><span>{t(`filekind.${file.kind}`, undefined, file.kind)} · {file.file_name ?? ''} <span className="small muted">{file.uploaded_by} · {dateTime(file.created_at)}</span>
                {file.removed_at && <> <Badge value="closed" label={t('hr.file_removed', { d: date(file.removed_at) })} /></>}
                {!file.removed_at && file.masked === 'yes' && <> <Badge value="verified" label={t('hr.masked_yes_by', { name: file.masked_by ?? '—' })} /></>}</span>
                {!file.removed_at && <button type="button" className="secondary small-btn" onClick={() => void open(file.storage_path!)}>{t('hr.open_file')}</button>}
                {x.can_manage && !file.removed_at && maskCheck(file) && <MaskedButtons file={file} busy={act.busy} run={run} />}</li>))}</ul>)}
          {x.can_manage && (
            <div className="row" style={{ alignItems: 'flex-end' }}>
              <Field label={t('hr.file_kind')} htmlFor="doc-kind"><select id="doc-kind" value={doc.kind} onChange={(e) => setDoc({ ...doc, kind: e.target.value })}>
                {FILE_KINDS.map((k) => <option key={k} value={k}>{t(`filekind.${k}`)}</option>)}</select></Field>
              <FileBox id="doc-file" label={t('hr.add_file')} onPick={(file) => setDoc({ ...doc, file })} />
              <button type="button" className="secondary" disabled={!doc.file || act.busy} onClick={() => void run(() => uploadHrFile(p.id, doc.kind, doc.file!))}>{t('hr.upload')}</button>
            </div>)}
        </div>
        <div className="card">
          <h2 style={{ marginTop: 0 }}>{t('hr.org_facts')} {x.can_manage && <button type="button" className="secondary small-btn" onClick={() => setEdit(!edit)} data-testid="edit-org">{t(edit ? 'common.cancel' : 'common.edit')}</button>}</h2>
          {!edit ? (
            <dl className="kv" data-testid="org-facts">
              <dt>{t('account.sign_in')}</dt><dd>{p.email ?? '—'}</dd>
              <dt>{t('hr.f_phone')}</dt><dd>{p.phone ?? '—'}</dd>
              <dt>{t('hr.f_type')}</dt><dd>{x.org.employment_type ? t(`emptype.${x.org.employment_type}`) : '—'}</dd>
              <dt>{t('hr.f_band')}</dt><dd>{x.org.designation_band ?? '—'}</dd>
              <dt>{t('hr.f_dept')}</dt><dd>{x.org.department ?? '—'}</dd>
              <dt>{t('hr.f_title')}</dt><dd>{x.org.job_title ?? '—'}</dd>
              <dt>{t('hr.f_reports')}</dt><dd>{x.org.reports_to_name ?? '—'}</dd>
              <dt>{t('hr.f_buddy')}</dt><dd>{x.org.buddy_name ?? '—'}</dd>
              <dt>{t('hr.added_by')}</dt><dd>{p.created_by ?? '—'} · {date(p.created_at)}</dd>
            </dl>) : <OrgEditor detail={x} busy={act.busy} save={(patch) => run(async () => { await rpc('update_joiner', { p_employee: p.id, p: patch }); setEdit(false); })} />}
          <h2>{t('hr.notes')}</h2>
          {x.can_manage && <form className="row" onSubmit={(e) => { e.preventDefault(); if (note.trim()) void run(async () => { await rpc('add_hr_note', { p_employee: p.id, p_note: note }); setNote(''); }); }}>
            <input aria-label={t('hr.note_new')} placeholder={t('hr.note_new')} value={note} onChange={(e) => setNote(e.target.value)} style={{ flex: 1 }} />
            <button type="submit" className="secondary" disabled={act.busy || !note.trim()}>{t('common.add')}</button></form>}
          {x.notes.length === 0 ? <Empty>{t('hr.no_notes')}</Empty> : <ul data-testid="hr-notes">{x.notes.map((nn) => <li key={nn.id}>{nn.note} <span className="small muted">{nn.by} · {dateTime(nn.at)}</span></li>)}</ul>}
          {x.exits.length > 0 && <><h2>{t('hr.exits')}</h2><ul>{x.exits.map((e, i) => <li key={i}>{date(e.exit_date)} · {e.reason ?? '—'} · {e.final_settlement ?? '—'} · {e.form16_ref ?? '—'}</li>)}</ul></>}
        </div>
      </div>}
      <div className="axes">
        {full && <PersonalCard p={x.personal ?? null} />}
        <FirstDayEditor x={x} busy={act.busy} save={(patch) => run(() => rpc('update_joiner', { p_employee: p.id, p: patch }))} />
      </div>
      <p className="small muted">{t('hr.assignments_n', { n: x.assignments })} <button type="button" className="secondary small-btn" onClick={() => nav(`/people/${p.id}`)}>{t('people.open_profile')}</button></p>
    </div>
  );
}

/** The person's intended role and opening, and their HR owner (migration 38); HR changes them here. */
function RoleCard({ x, onSaved }: { x: Detail; onSaved: () => void }) {
  const { t } = useI18n();
  const stage = useStageName();
  const hr = useHrPeople();
  const [edit, setEdit] = useState(false);
  const openings = useAsync(() => edit ? rpc<OpeningsSummary>('openings_summary', {}) : Promise.resolve(null), [edit]);
  const [f, setF] = useState({ opening: '', role: x.role?.role ?? '', stage: x.role?.stage ?? '', owner: x.hr_owner?.id ?? '' });
  const act = useAction();
  if (!x.role) return null;
  const save = () => act.run(async () => {
    if (f.opening && f.opening !== x.role?.opening_id) await rpc('link_to_opening', { p_employees: [x.person.id], p_opening: f.opening });
    else if (!x.role?.opening_id && (f.role !== (x.role?.role ?? '') || f.stage !== (x.role?.stage ?? '')))
      await rpc('set_intended_role', { p_employee: x.person.id, p_role: f.role || null, p_stage: f.role === 'operator' ? f.stage || null : null });
    if (f.owner !== (x.hr_owner?.id ?? '')) await rpc('set_hr_owner', { p_employees: [x.person.id], p_owner: f.owner || null });
    setEdit(false); onSaved();
  });
  return (
    <div className="card" data-testid="role-card">
      <h2 style={{ marginTop: 0 }}>{t('jp.role_title')} {x.can_manage && <button type="button" className="secondary small-btn" onClick={() => setEdit(!edit)} data-testid="edit-role">{t(edit ? 'common.cancel' : 'common.edit')}</button>}</h2>
      {!edit ? <dl className="kv">
        <dt>{t('open.role')}</dt><dd data-testid="jp-role"><RoleLabel role={x.role.role as HireRole | null} stage={x.role.stage} /></dd>
        <dt>{t('open.col_opening')}</dt><dd>{x.role.opening_code ? `${x.role.opening_code}${x.role.state_name ? ` · ${x.role.state_name}` : ''}` : '—'}</dd>
        <dt>{t('jl.owner')}</dt><dd data-testid="jp-owner">{x.hr_owner?.name ?? '—'}</dd>
      </dl> : <div className="form-grid">
        <Field label={t('open.col_opening')} htmlFor="rc-open"><select id="rc-open" value={f.opening || x.role.opening_id || ''} onChange={(e) => setF({ ...f, opening: e.target.value })}>
          <option value="">{t('aj.no_opening')}</option>{(openings.data?.openings ?? []).filter((o) => o.status !== 'closed').map((o) => <option key={o.id} value={o.id}>{o.code} · {t(`role.${o.role}`)}{o.stage ? ` · ${stage(o.stage)}` : ''}</option>)}</select></Field>
        {!x.role.opening_id && !f.opening && <Field label={t('open.role')} htmlFor="rc-role"><select id="rc-role" value={f.role} onChange={(e) => setF({ ...f, role: e.target.value })}>
          <option value="">—</option>{HIRE_ROLES.map((r) => <option key={r} value={r}>{t(`role.${r}`)}</option>)}</select></Field>}
        <Field label={t('jl.owner')} htmlFor="rc-owner"><select id="rc-owner" value={f.owner} onChange={(e) => setF({ ...f, owner: e.target.value })}>
          <option value="">{t('jl.owner_none')}</option>{(hr.data ?? []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></Field>
        <button type="button" disabled={act.busy} onClick={() => void save()} data-testid="save-role">{t('common.save')}</button>
      </div>}
      <ErrorBox error={act.error} />
    </div>
  );
}

/** C · the invite: its state; a new link (copy, QR, emailed with a sender); a temporary password as the fallback. */
function InviteCard({ x, onTemp, onChanged }: { x: Detail; onTemp: (who: string, pw: string) => void; onChanged: () => void }) {
  const { t } = useI18n();
  const [inv, setInv] = useState<Awaited<ReturnType<typeof sendInvites>> | null>(null);
  const act = useAction();
  const p = x.person;
  const temp = () => act.run(async () => {
    if (!window.confirm(t('inv.temp_sure'))) return;
    const r = await callFunction<{ sign_in: string; temporary_password: string }>('reset-password', { app_user_id: p.id });
    onTemp(r.sign_in, r.temporary_password); onChanged();
  });
  return (
    <div className="card" data-testid="invite-card">
      <h2 style={{ marginTop: 0 }}>{t('inv.title')}</h2>
      <p className="small" data-testid="invite-state">{x.invite ? t(`inv.state_${x.invite.state}`) + (x.invite.state === 'not_sent' || x.invite.state === 'sent' ? ` · ${t('inv.until', { d: dateTime(x.invite.expires_at) })}` : '')
        : t('jl.no_invite')}{!p.has_login && <> · {t('inv.no_sign_in_yet')}</>}</p>
      {x.can_invite && <p className="row">
        <button type="button" disabled={act.busy} onClick={() => void act.run(async () => { setInv(await sendInvites([p.id])); onChanged(); })} data-testid="send-invite">{t(x.invite ? 'inv.send_again' : 'inv.send_one')}</button>
        {!p.has_login && <button type="button" className="secondary" disabled={act.busy} onClick={() => void temp()} data-testid="temp-instead">{t('inv.temp_instead')}</button>}</p>}
      <ErrorBox error={act.error} />
      {inv && <InviteResults {...inv} />}
    </div>
  );
}

/** Pure: a file HR is asked about: a masked Aadhaar not yet checked, or one found not masked whose image is still to go. */
export const maskCheck = (f: HrFile) => f.kind === 'aadhaar_masked' && !f.removed_at && (f.masked == null || f.masked === 'no');

/** A number's duplicate check (A1): checked, or entered before the check existed. */
function Checked({ s, id }: { s: CheckState | undefined; id: string }) {
  const { t } = useI18n();
  if (!s) return null;
  return <span data-testid={`checked-${id}`}><Badge value={s === 'checked' ? 'verified' : 'draft'} label={t(s === 'checked' ? 'hr.dup_checked' : 'hr.dup_not_checked')} /></span>;
}

/** Numbers that matched another person's (A1): refused ones, and bank warnings HR may accept with a reason. */
function IdMatches({ x, busy, run }: { x: Detail; busy: boolean; run: (fn: () => Promise<unknown>) => Promise<unknown> }) {
  const { t } = useI18n();
  const [why, setWhy] = useState<Record<string, string>>({});
  const list = x.matches ?? [];
  if (list.length === 0) return null;
  return (
    <div data-testid="id-matches">{list.map((m) => (
      <div key={m.id} className={`alert ${m.outcome === 'refused' ? 'error' : m.accepted_at ? 'ok' : 'warn'}`} data-testid={`match-${m.kind}`} data-outcome={m.outcome}>
        {m.outcome === 'refused'
          ? t('hr.match_refused', { kind: t(`idkind.${m.kind}`), last4: m.last4 ?? '', name: m.matched_name, d: dateTime(m.at) })
          : t('hr.match_bank', { name: m.matched_name })}{' '}
        <Link to={`/people/${m.matched_id}`}>{t('people.open_profile')}</Link>
        {m.outcome === 'warned' && (m.accepted_at
          ? <div className="small">{t('hr.match_accepted', { name: m.accepted_by ?? '—', d: date(m.accepted_at), why: m.accept_reason ?? '' })}</div>
          : x.can_manage && <form className="row" style={{ marginTop: 6 }} onSubmit={(e) => { e.preventDefault(); void run(() => rpc('accept_shared_bank', { p_match: m.id, p_reason: why[m.id] ?? '' })); }}>
            <input aria-label={t('hr.accept_reason')} placeholder={t('hr.accept_reason')} value={why[m.id] ?? ''} onChange={(e) => setWhy({ ...why, [m.id]: e.target.value })} style={{ flex: 1, minWidth: 0 }} data-testid="accept-reason" />
            <button type="submit" className="secondary" disabled={busy || !(why[m.id] ?? '').trim()} data-testid="accept-bank">{t('hr.accept_bank')}</button></form>)}
      </div>))}</div>
  );
}

/** HR, having opened a masked-Aadhaar image: masked, yes or no. "No" deletes the image and asks the joiner again (A2). */
function MaskedButtons({ file, busy, run }: { file: HrFile; busy: boolean; run: (fn: () => Promise<unknown>) => Promise<unknown> }) {
  const { t } = useI18n();
  const removeImage = async () => {
    const { error } = await supabase.storage.from('hr-docs').remove([file.storage_path!]);
    if (error) throw new Error(t('hr.file_not_removed'));
    await rpc('note_file_removed', { p_file: file.id });
  };
  if (file.masked === 'no') return <button type="button" className="danger small-btn" disabled={busy} onClick={() => void run(removeImage)} data-testid="remove-image">{t('hr.remove_image')}</button>;
  return (
    <span className="row" data-testid="masked-question"><span className="small">{t('hr.masked_q')}</span>
      <button type="button" className="secondary small-btn" disabled={busy} onClick={() => void run(() => rpc('confirm_masked', { p_file: file.id, p_masked: true }))} data-testid="masked-yes">{t('common.yes')}</button>
      <button type="button" className="danger small-btn" disabled={busy} onClick={() => { if (window.confirm(t('hr.masked_no_sure'))) void run(async () => {
        await rpc('confirm_masked', { p_file: file.id, p_masked: false }); await removeImage(); }); }} data-testid="masked-no">{t('common.no')}</button></span>
  );
}

/** A3: what the joiner gave on the Personal details step. */
function PersonalCard({ p }: { p: PersonalDetails | null }) {
  const { t } = useI18n();
  return (
    <div className="card" data-testid="personal-card">
      <h2 style={{ marginTop: 0 }}>{t('hr.personal')}</h2>
      {!p ? <Empty>{t('hr.personal_none')}</Empty> : (
        <dl className="kv">
          <dt>{t('mine.dob')}</dt><dd>{date(p.date_of_birth)}</dd>
          <dt>{t(p.relative_kind === 'spouse' ? 'mine.spouse_name' : 'mine.father_name')}</dt><dd>{p.relative_name ?? '—'}</dd>
          <dt>{t('mine.present_address')}</dt><dd style={{ whiteSpace: 'pre-line' }}>{p.present_address ?? '—'}</dd>
          <dt>{t('mine.permanent_address')}</dt><dd style={{ whiteSpace: 'pre-line' }}>{p.permanent_address ?? '—'}</dd>
          <dt>{t('mine.emergency')}</dt><dd>{[p.emergency_name, p.emergency_relation && `(${p.emergency_relation})`, p.emergency_phone].filter(Boolean).join(' ')}</dd>
        </dl>)}
    </div>
  );
}

/** B6: the joiner's first day, as HR sets it; empty fields fall back to the template's defaults (shown as placeholders). */
function FirstDayEditor({ x, busy, save }: { x: Detail; busy: boolean; save: (p: Record<string, string>) => Promise<unknown> }) {
  const { t } = useI18n();
  const d = x.first_day;
  const [edit, setEdit] = useState(false);
  const [f, setF] = useState({ first_day_date: d?.date ?? '', first_day_time: d?.time ?? '', first_day_place: d?.place ?? '', first_day_ask_for: d?.ask_for ?? '', first_day_bring: d?.bring ?? '' });
  if (!d) return null;
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const shown = (v: string | null, def: string | null) => v ?? (def ? <span className="muted">{def} · {t('hr.from_template')}</span> : '—');
  return (
    <div className="card" data-testid="first-day-hr">
      <h2 style={{ marginTop: 0 }}>{t('day1.details')} {x.can_manage && <button type="button" className="secondary small-btn" onClick={() => setEdit(!edit)} data-testid="edit-first-day">{t(edit ? 'common.cancel' : 'common.edit')}</button>}</h2>
      {!edit ? (
        <dl className="kv">
          <dt>{t('day1.date')}</dt><dd>{d.date ? date(d.date) : <span className="muted">{date(d.default_date)} · {t('hr.join_date_default')}</span>}</dd>
          <dt>{t('day1.time')}</dt><dd>{shown(d.time, d.default_time)}</dd>
          <dt>{t('day1.place')}</dt><dd>{shown(d.place, d.default_place)}</dd>
          <dt>{t('day1.ask_for')}</dt><dd>{shown(d.ask_for, d.default_ask_for)}</dd>
          <dt>{t('day1.bring')}</dt><dd>{shown(d.bring, d.default_bring)}</dd>
        </dl>) : (
        <form onSubmit={(e) => { e.preventDefault(); void save(f).then(() => setEdit(false)); }} aria-label={t('day1.details')}>
          <Field label={t('day1.date')} htmlFor="fd-date"><input id="fd-date" type="date" value={f.first_day_date} onChange={set('first_day_date')} /></Field>
          <Field label={t('day1.time')} htmlFor="fd-time"><input id="fd-time" value={f.first_day_time} onChange={set('first_day_time')} placeholder={d.default_time ?? '09:30'} maxLength={40} /></Field>
          <Field label={t('day1.place')} htmlFor="fd-place"><textarea id="fd-place" rows={2} value={f.first_day_place} onChange={set('first_day_place')} placeholder={d.default_place ?? ''} /></Field>
          <Field label={t('day1.ask_for')} htmlFor="fd-ask"><input id="fd-ask" value={f.first_day_ask_for} onChange={set('first_day_ask_for')} placeholder={d.default_ask_for ?? ''} /></Field>
          <Field label={t('day1.bring')} htmlFor="fd-bring"><textarea id="fd-bring" rows={2} value={f.first_day_bring} onChange={set('first_day_bring')} placeholder={d.default_bring ?? ''} /></Field>
          <button type="submit" disabled={busy} data-testid="save-first-day">{t('common.save')}</button>
        </form>)}
    </div>
  );
}

/** A task that is HR's or IT's, with what that kind of task needs. */
function OurTask({ task, person, current, busy, done }:
  { task: Task; person: string; current: Detail; busy: boolean; done: (data: Record<string, unknown>) => Promise<unknown> }) {
  const { t } = useI18n();
  const [note, setNote] = useState('');
  const [buddy, setBuddy] = useState(current.org.buddy ?? '');
  const [goals, setGoals] = useState<Record<number, string>>({ 30: '', 60: '', 90: '' });
  const [file, setFile] = useState<File | null>(null);
  const kind: TaskKind = task.kind;
  const org = useOrgChoices(kind === 'buddy' ? current.org.base_state_id ?? null : undefined);
  const ready = kind === 'buddy' ? !!buddy : kind === 'goals' ? [30, 60, 90].every((h) => goals[h].trim() || current.goals.some((g) => g.horizon === h)) : true;
  const submit = async () => {
    if (kind === 'countersign' && file) await uploadHrFile(person, 'contract', file, task.id);
    await done({ note, ...(kind === 'buddy' ? { buddy } : {}),
      ...(kind === 'goals' ? { goals: [30, 60, 90].filter((h) => goals[h].trim()).map((h) => ({ horizon: h, goal: goals[h].trim() })) } : {}) });
  };
  return (
    <div className="queue-row" data-testid={`our-${task.code}`}>
      <div style={{ flex: '1 1 260px', minWidth: 0 }}>
        <strong><TaskTitle task={task} /></strong> <Owner owner={task.owner} />
        <div className={`small ${task.overdue ? 'gap' : 'muted'}`}>{t('hr.due', { d: date(task.due_on) })}</div>
        {kind === 'buddy' && <Field label={t('hr.f_buddy')} hint={t('org.buddy_hint')} htmlFor={`buddy-${task.id}`}>
          <BuddySelect id={`buddy-${task.id}`} value={buddy} onChange={setBuddy} choices={org} exclude={person} before={current.org.buddy_name} /></Field>}
        {kind === 'goals' && [30, 60, 90].map((h) => (
          <Field key={h} label={t('goals.days', { n: h })} htmlFor={`goal-${h}-${task.id}`}><input id={`goal-${h}-${task.id}`} value={goals[h]} onChange={(e) => setGoals({ ...goals, [h]: e.target.value })}
            placeholder={current.goals.find((g) => g.horizon === h)?.goal ?? ''} /></Field>))}
        {kind === 'countersign' && <FileBox id={`cs-${task.id}`} label={t('hr.countersigned_copy')} hint={t('common.optional')} onPick={setFile} />}
        {(kind === 'it' || kind === 'countersign' || kind === 'other') && <Field label={t('hr.note')} hint={t('common.optional')} htmlFor={`note-${task.id}`}>
          <input id={`note-${task.id}`} value={note} onChange={(e) => setNote(e.target.value)} /></Field>}
      </div>
      <button type="button" disabled={busy || !ready} onClick={() => void submit()} data-testid={`do-${task.code}`}>{t('hr.mark_done')}</button>
    </div>
  );
}

function OrgEditor({ detail, busy, save }: { detail: Detail; busy: boolean; save: (p: Record<string, string>) => Promise<unknown> }) {
  const { t } = useI18n();
  const o = detail.org;
  const [f, setF] = useState({ join_date: detail.person.join_date ?? '', employment_type: o.employment_type ?? 'full_time', designation_band: o.designation_band ?? '',
    department: o.department ?? '', job_title: o.job_title ?? '', reports_to: o.reports_to ?? '', buddy: o.buddy ?? '' });
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const org = useOrgChoices(o.base_state_id ?? null);
  // a choice made before that is no longer offered stays as it is (the database checks only what changes)
  return (
    <form onSubmit={(e) => { e.preventDefault(); void save(f); }} aria-label={t('hr.org_facts')}>
      <Field label={t('hr.f_join')} hint={t('hr.join_moves')} htmlFor="o-join"><input id="o-join" type="date" value={f.join_date} onChange={set('join_date')} /></Field>
      <Field label={t('hr.f_type')} htmlFor="o-type"><select id="o-type" value={f.employment_type} onChange={set('employment_type')}>
        {EMPLOYMENT_TYPES.map((k) => <option key={k} value={k}>{t(`emptype.${k}`)}</option>)}</select></Field>
      <Field label={t('hr.f_band')} htmlFor="o-band"><select id="o-band" value={f.designation_band} onChange={set('designation_band')}>
        <option value="">—</option>{DESIGNATION_BANDS.map((k) => <option key={k} value={k}>{k}</option>)}</select></Field>
      <Field label={t('hr.f_dept')} hint={t('org.dept_hint')} htmlFor="o-dept"><DepartmentSelect id="o-dept" value={f.department} onChange={(v) => setF({ ...f, department: v })} choices={org} /></Field>
      <Field label={t('hr.f_title')} htmlFor="o-title"><input id="o-title" value={f.job_title} onChange={set('job_title')} /></Field>
      <Field label={t('hr.f_reports')} hint={t('org.reports_hint')} htmlFor="o-reports"><ReportsToSelect id="o-reports" value={f.reports_to} onChange={(v) => setF({ ...f, reports_to: v })}
        choices={org} exclude={detail.person.id} before={o.reports_to_name} /></Field>
      <Field label={t('hr.f_buddy')} hint={t('org.buddy_hint')} htmlFor="o-buddy"><BuddySelect id="o-buddy" value={f.buddy} onChange={(v) => setF({ ...f, buddy: v })}
        choices={org} exclude={detail.person.id} before={o.buddy_name} /></Field>
      <button type="submit" disabled={busy}>{t('common.save')}</button>
    </form>
  );
}

/** B2: which steps a step waits for (codes of steps of the same template; a step added and not yet saved has no code). */
function DependsOn({ row, rows, disabled, onChange }: { row: TplTask; rows: TplTask[]; disabled: boolean; onChange: (d: string[]) => void }) {
  const { t } = useI18n();
  const others = rows.filter((x) => x.code && x.code !== row.code);
  const on = row.depends_on ?? [];
  return (
    <details className="depends" data-testid={`depends-${row.code || row.seq}`}>
      <summary className="small">{on.length === 0 ? t('hr.depends_none') : others.filter((x) => on.includes(x.code)).map((x) => x.seq).join(', ')}</summary>
      {others.map((x) => (
        <label key={x.code} className="check small"><input type="checkbox" disabled={disabled} checked={on.includes(x.code)}
          onChange={(e) => onChange(e.target.checked ? [...on, x.code] : on.filter((c) => c !== x.code))} />{x.seq}. {x.title}</label>))}
    </details>
  );
}

/** B6: a template's defaults for the first day (each joiner's own values, set on the joiner page, come first). */
function TemplateFirstDay({ tpl, canWrite, saved }: { tpl: Template; canWrite: boolean; saved: () => void }) {
  const { t } = useI18n();
  const act = useAction();
  const [f, setF] = useState({ first_day_time: tpl.first_day_time ?? '', first_day_place: tpl.first_day_place ?? '', first_day_ask_for: tpl.first_day_ask_for ?? '', first_day_bring: tpl.first_day_bring ?? '' });
  useEffect(() => { setF({ first_day_time: tpl.first_day_time ?? '', first_day_place: tpl.first_day_place ?? '', first_day_ask_for: tpl.first_day_ask_for ?? '', first_day_bring: tpl.first_day_bring ?? '' }); }, [tpl]);
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const save = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    await q(supabase.from('onboarding_templates').update(Object.fromEntries(Object.entries(f).map(([k, v]) => [k, v.trim() || null]))).eq('id', tpl.id).select());
    saved();
  }); };
  return (
    <form className="card" onSubmit={save} aria-label={t('hr.tpl_first_day')} data-testid="template-first-day">
      <h2 style={{ marginTop: 0 }}>{t('hr.tpl_first_day')}</h2>
      <p className="small muted">{t('hr.tpl_first_day_note')}</p>
      <div className="form-grid">
        <Field label={t('day1.time')} htmlFor="tf-time"><input id="tf-time" value={f.first_day_time} onChange={set('first_day_time')} disabled={!canWrite} maxLength={40} placeholder="09:30" /></Field>
        <Field label={t('day1.ask_for')} htmlFor="tf-ask"><input id="tf-ask" value={f.first_day_ask_for} onChange={set('first_day_ask_for')} disabled={!canWrite} /></Field>
        <Field label={t('day1.place')} htmlFor="tf-place"><textarea id="tf-place" rows={2} value={f.first_day_place} onChange={set('first_day_place')} disabled={!canWrite} /></Field>
        <Field label={t('day1.bring')} htmlFor="tf-bring"><textarea id="tf-bring" rows={2} value={f.first_day_bring} onChange={set('first_day_bring')} disabled={!canWrite} /></Field>
      </div>
      <ErrorBox error={act.error} />
      {canWrite && <button type="submit" className="secondary" disabled={act.busy} data-testid="save-template-first-day">{t('common.save')}</button>}
    </form>
  );
}

// ── checklist templates ─────────────────────────────────────────────────────────────────────────────────────────────────
interface TplTask { id: string; template_id: string; seq: number; code: string; title: string; owner: TaskOwner; due_offset_days: number; statutory: boolean; kind: TaskKind; depends_on: string[] }
const KINDS: TaskKind[] = ['sign', 'identity', 'personal', 'bank', 'countersign', 'nomination', 'it', 'buddy', 'goals', 'other'];

export function Templates() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const canWrite = (ctx?.user?.can ?? NO_RIGHTS).hr_admin;
  const tpls = useAsync(() => q(supabase.from('onboarding_templates').select('id,name,is_default,active,role,first_day_time,first_day_place,first_day_ask_for,first_day_bring').order('name')) as Promise<Template[]>, []);
  const [sel, setSel] = useState('');
  const tasks = useAsync(() => sel ? q(supabase.from('template_tasks').select('*').eq('template_id', sel).order('seq')) as Promise<TplTask[]> : Promise.resolve([] as TplTask[]), [sel]);
  const [rows, setRows] = useState<TplTask[]>([]);
  const [gone, setGone] = useState<string[]>([]);
  const [name, setName] = useState('');
  const act = useAction();
  useEffect(() => { if (!sel && tpls.data?.length) setSel((tpls.data.find((x) => x.is_default) ?? tpls.data[0]).id); }, [tpls.data, sel]);
  useEffect(() => { setRows(tasks.data ?? []); setGone([]); }, [tasks.data]);
  const dirty = useMemo(() => JSON.stringify(rows) !== JSON.stringify(tasks.data ?? []) || gone.length > 0, [rows, tasks.data, gone]);
  const patch = (i: number, p: Partial<TplTask>) => setRows(rows.map((r, j) => (j === i ? { ...r, ...p } : r)));
  const add = () => setRows([...rows, { id: '', template_id: sel, seq: (rows.reduce((m, r) => Math.max(m, r.seq), 0) || 0) + 1, code: '', title: '', owner: 'hr', due_offset_days: 0, statutory: false, kind: 'other', depends_on: [] }]);
  const save = () => act.run(async () => {
    if (gone.length) await q(supabase.from('template_tasks').delete().in('id', gone).select());
    const taken = rows.filter((r) => r.id).map((r) => r.code);
    for (const r of rows) {
      const { id, ...row } = r;
      if (id) { const was = tasks.data?.find((x) => x.id === id); if (JSON.stringify(was) !== JSON.stringify(r)) await q(supabase.from('template_tasks').update(row).eq('id', id).select()); }
      else { const code = taskCode(r.title, taken); taken.push(code); await q(supabase.from('template_tasks').insert({ ...row, code }).select()); }
    }
    await tasks.reload();
  });
  const create = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    const made = await q(supabase.from('onboarding_templates').insert({ name: name.trim() }).select().single()) as Template;
    setName(''); await tpls.reload(); setSel(made.id);
  }); };
  const makeDefault = () => act.run(async () => {
    await q(supabase.from('onboarding_templates').update({ is_default: false }).eq('is_default', true).select());
    await q(supabase.from('onboarding_templates').update({ is_default: true }).eq('id', sel).select());
    await tpls.reload();
  });
  const cur = tpls.data?.find((x) => x.id === sel);
  // D (migration 38): one template per role, picked automatically for a joiner of that role
  const setRole = (role: string) => act.run(async () => {
    if (role) await q(supabase.from('onboarding_templates').update({ role: null }).eq('role', role).neq('id', sel).select());
    await q(supabase.from('onboarding_templates').update({ role: role || null }).eq('id', sel).select());
    await tpls.reload();
  });
  return (
    <div>
      <h1>{t('hr.templates')}</h1>
      <HrLinks here="templates" />
      <p className="muted small">{t('hr.templates_note')}</p>
      <DepartmentsCard canEdit={canWrite} />
      {tpls.loading ? <Loading /> : <ErrorBox error={tpls.error} />}
      <div className="row">
        <Field label={t('hr.template')} htmlFor="tpl"><select id="tpl" value={sel} onChange={(e) => setSel(e.target.value)}>
          {(tpls.data ?? []).map((x) => <option key={x.id} value={x.id}>{x.name}{x.is_default ? ` (${t('hr.default')})` : ''}{x.role ? ` · ${t(`role.${x.role}`)}` : ''}</option>)}</select></Field>
        {cur && <Field label={t('tpl.for_role')} hint={t('tpl.for_role_hint')} htmlFor="tpl-role"><select id="tpl-role" value={cur.role ?? ''} disabled={!canWrite || act.busy} onChange={(e) => void setRole(e.target.value)} data-testid="template-role">
          <option value="">{t('tpl.no_role')}</option>{HIRE_ROLES.map((r) => <option key={r} value={r}>{t(`role.${r}`)}</option>)}</select></Field>}
        {canWrite && cur && !cur.is_default && <button type="button" className="secondary" disabled={act.busy} onClick={() => void makeDefault()}>{t('hr.make_default')}</button>}
      </div>
      {!canWrite && <div className="alert info">{t('hr.templates_readonly')}</div>}
      <div className="card table-wrap"><table data-testid="template-tasks">
        <thead><tr><th>#</th><th>{t('hr.col_task')}</th><th>{t('hr.col_owner')}</th><th>{t('hr.col_offset')}</th><th>{t('hr.col_kind')}</th><th>{t('hr.col_depends')}</th><th>{t('hr.statutory')}</th><th /></tr></thead>
        <tbody>{rows.map((r, i) => (
          <tr key={r.id || `new-${i}`}>
            <td>{r.seq}</td>
            <td><input aria-label={`${t('hr.col_task')} ${r.seq}`} value={r.title} disabled={!canWrite} onChange={(e) => patch(i, { title: e.target.value })} /></td>
            <td><select aria-label={`${t('hr.col_owner')} ${r.seq}`} value={r.owner} disabled={!canWrite} onChange={(e) => patch(i, { owner: e.target.value as TaskOwner })}>
              {(['hire', 'hr', 'it'] as TaskOwner[]).map((o) => <option key={o} value={o}>{t(`owner.${o}`)}</option>)}</select></td>
            <td><input aria-label={`${t('hr.col_offset')} ${r.seq}`} type="number" min={-90} max={365} value={r.due_offset_days} disabled={!canWrite} style={{ width: 90 }}
              onChange={(e) => patch(i, { due_offset_days: Number(e.target.value) })} />
              <div className="small muted">{r.due_offset_days < 0 ? t('hr.offset_before', { n: -r.due_offset_days }) : r.due_offset_days === 0 ? t('hr.offset_day1') : t('hr.offset_after', { n: r.due_offset_days })}</div></td>
            <td><select aria-label={`${t('hr.col_kind')} ${r.seq}`} value={r.kind} disabled={!canWrite} onChange={(e) => patch(i, { kind: e.target.value as TaskKind })}>
              {KINDS.map((k) => <option key={k} value={k}>{t(`taskkind.${k}`)}</option>)}</select></td>
            <td><DependsOn row={r} rows={rows} disabled={!canWrite} onChange={(d) => patch(i, { depends_on: d })} /></td>
            <td><input type="checkbox" aria-label={`${t('hr.statutory')} ${r.seq}`} checked={r.statutory} disabled={!canWrite} onChange={(e) => patch(i, { statutory: e.target.checked })} /></td>
            <td>{canWrite && <button type="button" className="secondary small-btn" aria-label={`${t('wizard.remove')} ${r.seq}`} onClick={() => { if (r.id) setGone([...gone, r.id]); setRows(rows.filter((_, j) => j !== i)); }}>✕</button>}</td>
          </tr>))}</tbody>
      </table></div>
      <p className="small muted">{t('hr.statutory_note')} {t('hr.depends_note')}</p>
      {cur && <TemplateFirstDay tpl={cur} canWrite={canWrite} saved={() => void tpls.reload()} />}
      <ErrorBox error={act.error} />
      {canWrite && (
        <>
          <div className="row"><button type="button" className="secondary" onClick={add}>{t('hr.add_task')}</button>
            <button type="button" disabled={act.busy || !dirty || rows.some((r) => !r.title.trim())} onClick={() => void save()} data-testid="save-template">{t('common.save')}</button></div>
          <form className="card row" onSubmit={create} style={{ marginTop: 16 }}>
            <input aria-label={t('hr.new_template')} placeholder={t('hr.new_template')} value={name} onChange={(e) => setName(e.target.value)} required style={{ flex: 1 }} />
            <button type="submit" className="secondary" disabled={act.busy}>{t('common.create')}</button>
          </form>
        </>)}
    </div>
  );
}
