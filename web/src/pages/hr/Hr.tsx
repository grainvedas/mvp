// HR (identity layer, migrations 31–33): the joiner pipeline, add a joiner, one joiner's page, the checklist templates.
// HR creates a person ONCE, as an identity. Nothing on these screens gives anyone a scope, a client or a state:
// that is a manager's act, on the People screens.
import { useEffect, useMemo, useState, type FormEvent } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { callFunction, functionState, q, rpc } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { oversees } from '../../lib/rights';
import { date, dateTime } from '../../lib/format';
import { NO_RIGHTS, type EmploymentType, type SystemRole } from '../../lib/types';
import { DESIGNATION_BANDS, EMPLOYMENT_TYPES, FILE_KINDS, countdown, masked, onThem, onUs, skipsStatutory, taskCode, waitingOn,
  type CheckState, type HrFile, type JoinerDetail as Detail, type PersonalDetails, type PipelineRow, type Task, type TaskKind, type TaskOwner } from '../../lib/people';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { FileBox, OrgLine, StatusBadge, TempPassword, uploadHrFile } from '../people/shared';

interface Person { id: string; display_name: string; status: string; external: boolean }
const usePeople = () => useAsync(() => q(supabase.from('app_users').select('id,display_name,status,external').eq('external', false)
  .in('status', ['invited', 'onboarding', 'active']).order('display_name')) as Promise<Person[]>, []);
interface Template { id: string; name: string; is_default: boolean; active: boolean; first_day_time?: string | null; first_day_place?: string | null; first_day_ask_for?: string | null; first_day_bring?: string | null }

function Countdown({ days }: { days: number | null | undefined }) {
  const { t } = useI18n();
  const c = countdown(days);
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
                  <td>{date(r.join_date)}<div className="small muted"><Countdown days={r.days_to_join} /></div></td>
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
const taskKey = (title: string | null | undefined) => STANDARD[title ?? ''] ?? '_';
export function TaskTitle({ task }: { task: { code: string; title: string } }) {
  const { t } = useI18n();
  // the standard titles have a Hindi wording; an edited or added one is the template's own text
  return <>{STANDARD[task.title] === task.code ? t(`task.${task.code}`, undefined, task.title) : task.title}</>;
}

// ── add a joiner ───────────────────────────────────────────────────────────────────────────────────────────────────────
const blankJoiner = { full_name: '', join_date: '', personal_email: '', phone: '', employment_type: 'full_time' as EmploymentType, designation_band: '',
  department: '', job_title: '', reports_to: '', buddy: '', template_id: '', system_role: 'operational' as SystemRole };

export function AddJoiner() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const can = ctx?.user?.can ?? NO_RIGHTS;
  const people = usePeople();
  const templates = useAsync(() => q(supabase.from('onboarding_templates').select('id,name,is_default,active').eq('active', true).order('name')) as Promise<Template[]>, []);
  const fn = useAsync(() => functionState('create-user'), []);
  const [f, setF] = useState(blankJoiner);
  const [made, setMade] = useState<{ id: string; name: string; sign_in: string; password: string; emailed: boolean; type: EmploymentType } | null>(null);
  const act = useAction();
  useEffect(() => { if (!f.template_id && templates.data?.length) setF((s) => ({ ...s, template_id: (templates.data!.find((x) => x.is_default) ?? templates.data![0]).id })); }, [templates.data, f.template_id]);
  const set = (k: keyof typeof blankJoiner) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const submit = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    const r = await callFunction<{ app_user_id: string; sign_in: string; temporary_password: string; invite_emailed: boolean }>('create-user', { kind: 'joiner', ...f });
    setMade({ id: r.app_user_id, name: f.full_name, sign_in: r.sign_in, password: r.temporary_password, emailed: r.invite_emailed, type: f.employment_type });
    setF({ ...blankJoiner, template_id: f.template_id });
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
          <p className="row"><Link className="btn" to={`/hr/joiners/${made.id}`}>{t('hr.open_joiner')}</Link>
            <button type="button" className="secondary" onClick={() => setMade(null)}>{t('hr.add_another')}</button></p>
        </div>)}
      {!made && (
        <form className="card" onSubmit={submit} aria-label={t('hr.add_joiner')}>
          <p className="muted small">{t('hr.add_note')}</p>
          <div className="form-grid">
            <Field label={t('hr.f_name')} htmlFor="j-name"><input id="j-name" value={f.full_name} onChange={set('full_name')} required autoComplete="off" /></Field>
            <Field label={t('hr.f_join')} htmlFor="j-join"><input id="j-join" type="date" value={f.join_date} onChange={set('join_date')} required /></Field>
            <Field label={t('hr.f_email')} hint={t('hr.f_email_hint')} htmlFor="j-email"><input id="j-email" type="email" value={f.personal_email} onChange={set('personal_email')} required autoComplete="off" /></Field>
            <Field label={t('hr.f_phone')} hint={t('hr.f_phone_hint')} htmlFor="j-phone"><input id="j-phone" type="tel" inputMode="tel" value={f.phone} onChange={set('phone')} required autoComplete="off" /></Field>
            <Field label={t('hr.f_type')} htmlFor="j-type"><select id="j-type" value={f.employment_type} onChange={set('employment_type')}>
              {EMPLOYMENT_TYPES.map((x) => <option key={x} value={x}>{t(`emptype.${x}`)}</option>)}</select></Field>
            <Field label={t('hr.f_band')} htmlFor="j-band"><select id="j-band" value={f.designation_band} onChange={set('designation_band')}>
              <option value="">—</option>{DESIGNATION_BANDS.map((x) => <option key={x} value={x}>{x}</option>)}</select></Field>
            <Field label={t('hr.f_dept')} htmlFor="j-dept"><input id="j-dept" value={f.department} onChange={set('department')} /></Field>
            <Field label={t('hr.f_title')} htmlFor="j-title"><input id="j-title" value={f.job_title} onChange={set('job_title')} /></Field>
            <Field label={t('hr.f_reports')} htmlFor="j-reports"><select id="j-reports" value={f.reports_to} onChange={set('reports_to')}>
              <option value="">—</option>{(people.data ?? []).map((p) => <option key={p.id} value={p.id}>{p.display_name}</option>)}</select></Field>
            <Field label={t('hr.f_buddy')} hint={t('common.optional')} htmlFor="j-buddy"><select id="j-buddy" value={f.buddy} onChange={set('buddy')}>
              <option value="">—</option>{(people.data ?? []).map((p) => <option key={p.id} value={p.id}>{p.display_name}</option>)}</select></Field>
            <Field label={t('hr.f_template')} htmlFor="j-template"><select id="j-template" value={f.template_id} onChange={set('template_id')} required>
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
  const people = usePeople();
  const act = useAction();
  const [temp, setTemp] = useState<{ who: string; pw: string } | null>(null);
  const [note, setNote] = useState('');
  const [edit, setEdit] = useState(false);
  const [doc, setDoc] = useState<{ kind: string; file: File | null }>({ kind: 'contract', file: null });
  if (d.loading && !d.data) return <Loading />;
  if (!d.data) return <ErrorBox error={d.error} onRetry={() => void d.reload()} />;
  const x = d.data, p = x.person;
  const ours = x.tasks.filter((k) => k.status === 'pending' && k.owner !== 'hire');
  const run = (fn: () => Promise<unknown>) => act.run(async () => { await fn(); await d.reload(); });
  // The admin marking the HR Admin as joined (migration 36) switches HR on: this page is HR's from then on, so he goes to
  // the Seats page, which says so (first: this page's own guard would send him home), and his menu loses HR · Joiners
  // once the server is asked again.
  const activate = () => act.run(async () => {
    await rpc('activate_joiner', { p_employee: p.id });
    if (p.system_role === 'hr_admin' && oversees(ctx)) { nav('/system/seats', { state: { joined: p.name } }); void refresh(); return; }
    await d.reload();
  });
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
        <div className="side">{date(p.join_date)}<br /><Countdown days={p.days_to_join} /></div>
      </div>
      <p className="row"><StatusBadge status={p.status} />
        {p.status === 'invited' && <span className="small muted">{t('hr.awaiting_first')}</span>}
        {!p.has_login && <Badge value="draft" label={t('people.no_login')} />}
        <Link className="btn secondary" to={`/people/${p.id}`}>{t('people.open_profile')}</Link>
        {mayActivate(x) && (
          <button type="button" onClick={() => void activate()} disabled={act.busy} data-testid="activate">{t('hr.mark_joined')}</button>)}
        {x.can_manage && p.has_login && <button type="button" className="secondary" onClick={() => void reset()} disabled={act.busy} data-testid="reset-password">{t('users.reset_password')}</button>}
      </p>
      {temp && <TempPassword who={temp.who} password={temp.pw} />}
      <ErrorBox error={act.error} />

      {ours.length > 0 && x.can_manage && (
        <div className="queue" data-testid="waiting-on-you">
          <h2>{t('hr.waiting_on_you', { n: ours.length })}</h2>
          {ours.map((k) => <OurTask key={k.id} task={k} person={p.id} people={people.data ?? []} current={x} busy={act.busy} done={(data) => run(() => rpc('complete_task', { p_task: k.id, p_data: data }))} />)}
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
              {x.can_manage && k.status === 'pending' && k.owner === 'hire' && (k.kind === 'sign' || k.kind === 'other') && (
                <button type="button" className="secondary small-btn" disabled={act.busy} onClick={() => void run(() => rpc('complete_task', { p_task: k.id, p_data: { note: t('hr.on_behalf_note') } }))}>{t('hr.on_behalf')}</button>)}</td>
          </tr>))}</tbody>
      </table></div>

      <div className="axes">
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
          <h2 style={{ marginTop: 0 }}>{t('hr.org_facts')} {x.can_manage && <button type="button" className="secondary small-btn" onClick={() => setEdit(!edit)}>{t(edit ? 'common.cancel' : 'common.edit')}</button>}</h2>
          {!edit ? (
            <dl className="kv">
              <dt>{t('account.sign_in')}</dt><dd>{p.email ?? '—'}</dd>
              <dt>{t('hr.f_phone')}</dt><dd>{p.phone ?? '—'}</dd>
              <dt>{t('hr.f_type')}</dt><dd>{x.org.employment_type ? t(`emptype.${x.org.employment_type}`) : '—'}</dd>
              <dt>{t('hr.f_band')}</dt><dd>{x.org.designation_band ?? '—'}</dd>
              <dt>{t('hr.f_dept')}</dt><dd>{x.org.department ?? '—'}</dd>
              <dt>{t('hr.f_title')}</dt><dd>{x.org.job_title ?? '—'}</dd>
              <dt>{t('hr.f_reports')}</dt><dd>{x.org.reports_to_name ?? '—'}</dd>
              <dt>{t('hr.f_buddy')}</dt><dd>{x.org.buddy_name ?? '—'}</dd>
              <dt>{t('hr.added_by')}</dt><dd>{p.created_by ?? '—'} · {date(p.created_at)}</dd>
            </dl>) : <OrgEditor detail={x} people={people.data ?? []} busy={act.busy} save={(patch) => run(async () => { await rpc('update_joiner', { p_employee: p.id, p: patch }); setEdit(false); })} />}
          <h2>{t('hr.notes')}</h2>
          {x.can_manage && <form className="row" onSubmit={(e) => { e.preventDefault(); if (note.trim()) void run(async () => { await rpc('add_hr_note', { p_employee: p.id, p_note: note }); setNote(''); }); }}>
            <input aria-label={t('hr.note_new')} placeholder={t('hr.note_new')} value={note} onChange={(e) => setNote(e.target.value)} style={{ flex: 1 }} />
            <button type="submit" className="secondary" disabled={act.busy || !note.trim()}>{t('common.add')}</button></form>}
          {x.notes.length === 0 ? <Empty>{t('hr.no_notes')}</Empty> : <ul data-testid="hr-notes">{x.notes.map((nn) => <li key={nn.id}>{nn.note} <span className="small muted">{nn.by} · {dateTime(nn.at)}</span></li>)}</ul>}
          {x.exits.length > 0 && <><h2>{t('hr.exits')}</h2><ul>{x.exits.map((e, i) => <li key={i}>{date(e.exit_date)} · {e.reason ?? '—'} · {e.final_settlement ?? '—'} · {e.form16_ref ?? '—'}</li>)}</ul></>}
        </div>
      </div>
      <div className="axes">
        <PersonalCard p={x.personal ?? null} />
        <FirstDayEditor x={x} busy={act.busy} save={(patch) => run(() => rpc('update_joiner', { p_employee: p.id, p: patch }))} />
      </div>
      <p className="small muted">{t('hr.assignments_n', { n: x.assignments })} <button type="button" className="secondary small-btn" onClick={() => nav(`/people/${p.id}`)}>{t('people.open_profile')}</button></p>
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
function OurTask({ task, person, people, current, busy, done }:
  { task: Task; person: string; people: Person[]; current: Detail; busy: boolean; done: (data: Record<string, unknown>) => Promise<unknown> }) {
  const { t } = useI18n();
  const [note, setNote] = useState('');
  const [buddy, setBuddy] = useState(current.org.buddy ?? '');
  const [goals, setGoals] = useState<Record<number, string>>({ 30: '', 60: '', 90: '' });
  const [file, setFile] = useState<File | null>(null);
  const kind: TaskKind = task.kind;
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
        {kind === 'buddy' && <Field label={t('hr.f_buddy')} htmlFor={`buddy-${task.id}`}><select id={`buddy-${task.id}`} value={buddy} onChange={(e) => setBuddy(e.target.value)}>
          <option value="">—</option>{people.filter((x) => x.id !== person).map((x) => <option key={x.id} value={x.id}>{x.display_name}</option>)}</select></Field>}
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

function OrgEditor({ detail, people, busy, save }: { detail: Detail; people: Person[]; busy: boolean; save: (p: Record<string, string>) => Promise<unknown> }) {
  const { t } = useI18n();
  const o = detail.org;
  const [f, setF] = useState({ join_date: detail.person.join_date ?? '', employment_type: o.employment_type ?? 'full_time', designation_band: o.designation_band ?? '',
    department: o.department ?? '', job_title: o.job_title ?? '', reports_to: o.reports_to ?? '', buddy: o.buddy ?? '' });
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  return (
    <form onSubmit={(e) => { e.preventDefault(); void save(f); }} aria-label={t('hr.org_facts')}>
      <Field label={t('hr.f_join')} hint={t('hr.join_moves')} htmlFor="o-join"><input id="o-join" type="date" value={f.join_date} onChange={set('join_date')} /></Field>
      <Field label={t('hr.f_type')} htmlFor="o-type"><select id="o-type" value={f.employment_type} onChange={set('employment_type')}>
        {EMPLOYMENT_TYPES.map((k) => <option key={k} value={k}>{t(`emptype.${k}`)}</option>)}</select></Field>
      <Field label={t('hr.f_band')} htmlFor="o-band"><select id="o-band" value={f.designation_band} onChange={set('designation_band')}>
        <option value="">—</option>{DESIGNATION_BANDS.map((k) => <option key={k} value={k}>{k}</option>)}</select></Field>
      <Field label={t('hr.f_dept')} htmlFor="o-dept"><input id="o-dept" value={f.department} onChange={set('department')} /></Field>
      <Field label={t('hr.f_title')} htmlFor="o-title"><input id="o-title" value={f.job_title} onChange={set('job_title')} /></Field>
      <Field label={t('hr.f_reports')} htmlFor="o-reports"><select id="o-reports" value={f.reports_to} onChange={set('reports_to')}>
        <option value="">—</option>{people.filter((k) => k.id !== detail.person.id).map((k) => <option key={k.id} value={k.id}>{k.display_name}</option>)}</select></Field>
      <Field label={t('hr.f_buddy')} htmlFor="o-buddy"><select id="o-buddy" value={f.buddy} onChange={set('buddy')}>
        <option value="">—</option>{people.filter((k) => k.id !== detail.person.id).map((k) => <option key={k.id} value={k.id}>{k.display_name}</option>)}</select></Field>
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
  const tpls = useAsync(() => q(supabase.from('onboarding_templates').select('id,name,is_default,active,first_day_time,first_day_place,first_day_ask_for,first_day_bring').order('name')) as Promise<Template[]>, []);
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
  return (
    <div>
      <p className="small"><Link to="/hr">{t('hr.pipeline_title')}</Link></p>
      <h1>{t('hr.templates')}</h1>
      <p className="muted small">{t('hr.templates_note')}</p>
      {tpls.loading ? <Loading /> : <ErrorBox error={tpls.error} />}
      <div className="row">
        <Field label={t('hr.template')} htmlFor="tpl"><select id="tpl" value={sel} onChange={(e) => setSel(e.target.value)}>
          {(tpls.data ?? []).map((x) => <option key={x.id} value={x.id}>{x.name}{x.is_default ? ` (${t('hr.default')})` : ''}</option>)}</select></Field>
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
