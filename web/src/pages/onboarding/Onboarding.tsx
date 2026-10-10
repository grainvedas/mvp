// The new hire's own screens (identity layer), made for a phone: the pre-boarding checklist, one task at a time, the
// first-day page, the 30-60-90 goals, and the calm screen for an employee nobody has assigned yet.
// Identity and bank numbers are checked here for the person's sake, then sent once to the id-numbers server function,
// which keeps a check code (HMAC) and the last four characters only (migration 37); nothing here keeps them.
import { Fragment, useState, type FormEvent, type ReactNode } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { rpc } from '../../lib/api';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { date } from '../../lib/format';
import { countdown, joinWords, joinerTrack, masked, progress, taskState, validAadhaar, validAccount, validIfsc, validPan, waitsFor,
  type Contact, type IdKind, type MyOnboarding, type Task } from '../../lib/people';
import { sendIdNumber } from '../../lib/idNumbers';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { FileBox, uploadHrFile, useStageName } from '../people/shared';
import { Owner, TaskTitle } from '../hr/Hr';
import { RoleGuide } from '../../shell/RoleGuide';

const useMine = () => useAsync(() => rpc<MyOnboarding>('my_onboarding'), []);

function Join({ o }: { o: MyOnboarding }) {
  const { t } = useI18n();
  const c = countdown(o.days_to_join);
  // B3: until HR marks the person as joined, the date itself, never "you joined … days ago"
  const key = joinWords(o.status, o.days_to_join);
  return <span data-testid="join-countdown">{t(`mine.${key}`, { n: c.n, d: date(o.join_date) })}</span>;
}

// ── the checklist ────────────────────────────────────────────────────────────────────────────────────────────────
export function Checklist() {
  const { t } = useI18n();
  const o = useMine();
  if (o.loading && !o.data) return <Loading />;
  if (!o.data) return <ErrorBox error={o.error} onRetry={() => void o.reload()} />;
  const x = o.data, p = progress(x.tasks);
  return (
    <div style={{ maxWidth: 640 }}>
      <div className="band" data-testid="onboarding-band">
        <div><h1>{t('mine.welcome', { name: x.name.split(' ')[0] })}</h1><div className="sub"><Join o={x} /></div></div>
        <div className="side">{[x.org.job_title, x.org.department].filter(Boolean).join(' · ')}</div>
      </div>
      <div className="card">
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <strong data-testid="checklist-progress">{t('mine.progress', { done: p.done, total: p.total })}</strong><span className="muted small">{p.pct} %</span>
        </div>
        <div className="bar" role="img" aria-label={`${p.pct} %`} style={{ marginTop: 6 }}><span style={{ width: `${p.pct}%` }} /></div>
        {p.total === 0 ? <Empty>{t('mine.no_tasks')}</Empty> : (
          <ol className="checklist" data-testid="checklist">{x.tasks.map((k) => {
            const st = taskState(x.tasks, k);
            return (
              <li key={k.id} className={st} data-testid={`row-${k.code}`} data-state={st}>
                <span className="n" aria-hidden="true">{st === 'done' ? '✓' : st === 'locked' ? '🔒' : k.seq}</span>
                <div><div className="t-title"><TaskTitle task={k} /></div>
                  <div className="t-sub">{st === 'done' ? t('mine.done') : st === 'ours' ? <><Owner owner={k.owner} /> {t('mine.we_are_on_it')}</>
                    : st === 'locked' ? t('mine.locked_after', { steps: waitsFor(x.tasks, k).map((w) => w.title).join(', ') }) : t('mine.due', { d: date(k.due_on) })}</div></div>
                {st === 'open' && <Link className="btn" to={`/onboarding/task/${k.id}`} data-testid="start-task">{t('mine.start')}</Link>}
              </li>);
          })}</ol>)}
      </div>
      <p className="row">
        {(x.status === 'active' || (x.days_to_join !== null && x.days_to_join <= 0)) && <Link className="btn secondary" to="/welcome">{t('mine.first_day')}</Link>}
        <Link className="btn secondary" to="/goals">{t('goals.title')}</Link>
      </p>
      <p className="small muted">{t('mine.privacy')}</p>
    </div>
  );
}

// ── one task ─────────────────────────────────────────────────────────────────────────────────────────────────────
const blankTask = { ack: false, pan: '', aadhaar: '', bank_name: '', ifsc: '', account: '', nominee: '', relation: '', uan: '', note: '',
  dob: '', relative_kind: 'father', relative_name: '', present: '', permanent: '', same: false, em_name: '', em_relation: '', em_phone: '' };

export function TaskPage() {
  const { id = '' } = useParams();
  const { t } = useI18n();
  const { ctx, refresh } = useAuth();
  const nav = useNavigate();
  const o = useMine();
  const act = useAction();
  const me = ctx!.user!.id;
  const [f, setF] = useState(blankTask);
  const [file, setFile] = useState<File | null>(null);
  if (o.loading && !o.data) return <Loading />;
  if (!o.data) return <ErrorBox error={o.error} onRetry={() => void o.reload()} />;
  const task = o.data.tasks.find((k) => k.id === id);
  if (!task) return <Empty>{t('mine.task_gone')}</Empty>;
  const state = taskState(o.data.tasks, task);
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const checked = o.data.checked ?? { pan: false, aadhaar: false, uan: false, bank: false };
  const idOnFile = checked.pan || checked.aadhaar;

  // what is wrong with what was typed, in the reader's words; null = may be sent
  const problem = ((): string | null => {
    switch (task.kind) {
      case 'sign': return f.ack ? null : t('mine.need_ack');
      case 'identity':
        if (!f.pan && !f.aadhaar && !idOnFile) return t('mine.need_id');
        if (f.pan && !validPan(f.pan)) return t('mine.bad_pan');
        if (f.aadhaar && !validAadhaar(f.aadhaar)) return t('mine.bad_aadhaar');
        return null;
      case 'personal': return personalProblem(f, t);
      case 'bank':
        if (!f.bank_name.trim()) return t('mine.need_bank');
        if (!validIfsc(f.ifsc)) return t('mine.bad_ifsc');
        return validAccount(f.account) || (checked.bank && !f.account) ? null : t('mine.bad_account');
      case 'nomination':
        if (!f.nominee.trim() || !f.relation.trim()) return t('mine.need_nominee');
        return f.uan && !/^[0-9]{12}$/.test(f.uan.replace(/\s/g, '')) ? t('mine.bad_uan') : null;
      default: return null;
    }
  })();

  const submit = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    // The numbers go to the id-numbers function, one request each, and are cleared from this page at once (A1).
    const numbers: [IdKind, string, string?][] = [];
    if (task.kind === 'identity') { if (f.pan) numbers.push(['pan', f.pan]); if (f.aadhaar) numbers.push(['aadhaar', f.aadhaar]); }
    if (task.kind === 'bank' && f.account) numbers.push(['bank', f.account, f.ifsc]);
    if (task.kind === 'nomination' && f.uan) numbers.push(['uan', f.uan]);
    setF((x) => ({ ...x, pan: '', aadhaar: '', account: '', uan: '' }));
    for (const [kind, n, ifsc] of numbers) await sendIdNumber(task.id, kind, n, ifsc);
    const kind = { sign: 'offer_letter', identity: 'aadhaar_masked', bank: 'bank_proof', nomination: 'pf_form' }[task.kind as string] ?? 'other';
    if (file) await uploadHrFile(me, kind, file, task.id);
    const data: Record<string, unknown> = { note: f.note };
    if (task.kind === 'sign') data.acknowledged = true;
    if (task.kind === 'bank') data.bank_name = f.bank_name.trim();
    if (task.kind === 'nomination') { data.gratuity_nominee = f.nominee.trim(); data.nominee_relation = f.relation.trim(); }
    if (task.kind === 'personal') Object.assign(data, {
      date_of_birth: f.dob, relative_kind: f.relative_kind, relative_name: f.relative_name.trim(), present_address: f.present.trim(),
      permanent_address: (f.same ? f.present : f.permanent).trim(), emergency_name: f.em_name.trim(), emergency_relation: f.em_relation.trim(),
      emergency_phone: f.em_phone.trim() });
    await rpc('complete_task', { p_task: task.id, p_data: data });
    await refresh();                                   // the last task makes the joiner active: the menu changes with it
    nav('/onboarding', { replace: true });
  }); };

  const waits = waitsFor(o.data.tasks, task);
  const numberBox = (k: 'pan' | 'aadhaar' | 'uan' | 'account', label: string, hint: string | undefined, props: Record<string, unknown>) => (
    <Field label={label} hint={hint} htmlFor={`t-${k}`}>
      <input id={`t-${k}`} value={f[k]} onChange={(e) => setF({ ...f, [k]: k === 'pan' ? e.target.value.toUpperCase() : e.target.value })}
        autoComplete="off" spellCheck={false} data-private="number" {...props} /></Field>);
  return (
    <div style={{ maxWidth: 560 }}>
      <p className="small"><Link to="/onboarding">{t('mine.back')}</Link></p>
      <h1><TaskTitle task={task} /></h1>
      <p className="muted small">{t('mine.due', { d: date(task.due_on) })}{task.statutory ? ` · ${t('hr.statutory')}` : ''}</p>
      {task.note && state === 'open' && <div className="alert warn" data-testid="task-note">{task.note}</div>}
      {state === 'done' && <div className="alert ok">{t('mine.done')}</div>}
      {state === 'locked' && <div className="alert info" data-testid="task-locked">{t('mine.locked_after', { steps: waits.map((w) => w.title).join(', ') })}</div>}
      {state === 'ours' && <div className="alert info">{t('mine.we_are_on_it')}</div>}
      {state === 'open' && (
        <form className="card" onSubmit={submit} aria-label={task.title}>
          {task.kind === 'sign' && <>
            <p>{t('mine.sign_body')}</p>
            <FileBox id="t-file" label={t('mine.signed_copy')} hint={t('common.optional')} onPick={setFile} />
            <label className="check"><input type="checkbox" checked={f.ack} onChange={(e) => setF({ ...f, ack: e.target.checked })} />{t('mine.ack')}</label>
          </>}
          {task.kind === 'identity' && <>
            <p>{t('mine.identity_body2')}</p>
            {idOnFile && <p className="small" data-testid="id-on-file">{[checked.pan && `PAN ${masked(o.data.docs.pan_last4)}`, checked.aadhaar && `Aadhaar ${masked(o.data.docs.aadhaar_last4)}`]
              .filter(Boolean).join(' · ')} · {t('mine.id_on_file')}</p>}
            {numberBox('pan', 'PAN', 'ABCDE1234F', { maxLength: 10, autoCapitalize: 'characters' })}
            {numberBox('aadhaar', 'Aadhaar', t('mine.aadhaar_hint'), { inputMode: 'numeric', maxLength: 14 })}
            <FileBox id="t-file" label={t('mine.masked_aadhaar')} hint={t('common.optional')} onPick={setFile} />
            <p className="small muted" data-testid="masked-howto">{t('mine.masked_howto')}</p>
            <div className="alert info">{t('mine.number_note')}</div>
          </>}
          {task.kind === 'personal' && <PersonalForm f={f} setF={setF} />}
          {task.kind === 'bank' && <>
            <Field label={t('mine.bank_name')} htmlFor="t-bank"><input id="t-bank" value={f.bank_name} onChange={set('bank_name')} /></Field>
            <Field label="IFSC" hint="HDFC0001234" htmlFor="t-ifsc"><input id="t-ifsc" value={f.ifsc} onChange={(e) => setF({ ...f, ifsc: e.target.value.toUpperCase() })} maxLength={11} autoComplete="off" autoCapitalize="characters" /></Field>
            {numberBox('account', t('mine.account'), checked.bank ? `${t('mine.id_on_file')} ${masked(o.data.docs.bank_last4)}` : undefined, { inputMode: 'numeric', maxLength: 22 })}
            <FileBox id="t-file" label={t('mine.bank_proof')} hint={t('common.optional')} onPick={setFile} />
            <div className="alert info">{t('mine.number_note')}</div>
          </>}
          {task.kind === 'nomination' && <>
            <p>{t('mine.nomination_body')}</p>
            <Field label={t('mine.nominee')} htmlFor="t-nominee"><input id="t-nominee" value={f.nominee} onChange={set('nominee')} /></Field>
            <Field label={t('mine.relation')} htmlFor="t-relation"><input id="t-relation" value={f.relation} onChange={set('relation')} /></Field>
            {numberBox('uan', 'UAN', t('mine.uan_hint'), { inputMode: 'numeric', maxLength: 12 })}
            <FileBox id="t-file" label={t('mine.signed_form')} hint={t('common.optional')} onPick={setFile} />
          </>}
          {!['sign', 'identity', 'personal', 'bank', 'nomination'].includes(task.kind) && (
            <Field label={t('hr.note')} hint={t('common.optional')} htmlFor="t-note"><input id="t-note" value={f.note} onChange={set('note')} /></Field>)}
          {problem && <p className="hint" data-testid="task-problem">{problem}</p>}
          <ErrorBox error={act.error} />
          <button type="submit" disabled={act.busy || problem !== null} data-testid="task-done">{t('mine.submit')}</button>
        </form>)}
    </div>
  );
}

type TaskForm = typeof blankTask;
/** Pure: what is missing from the Personal details step, in the reader's words; null = may be sent. */
export function personalProblem(f: Pick<TaskForm, 'dob' | 'relative_name' | 'present' | 'permanent' | 'same' | 'em_name' | 'em_relation' | 'em_phone'>,
  t: (k: string) => string): string | null {
  if (!f.dob) return t('mine.need_dob');
  if (!f.relative_name.trim()) return t('mine.need_relative');
  if (!f.present.trim() || (!f.same && !f.permanent.trim())) return t('mine.need_address');
  if (!f.em_name.trim() || !f.em_relation.trim()) return t('mine.need_emergency');
  return /^(\+?91)?[6-9][0-9]{9}$/.test(f.em_phone.replace(/[\s-]/g, '')) ? null : t('mine.bad_em_phone');
}

function PersonalForm({ f, setF }: { f: TaskForm; setF: (x: TaskForm) => void }) {
  const { t } = useI18n();
  const set = (k: keyof TaskForm) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  return (
    <div data-testid="personal-form">
      <p>{t('mine.personal_body')}</p>
      <Field label={t('mine.dob')} htmlFor="p-dob"><input id="p-dob" type="date" value={f.dob} onChange={set('dob')} /></Field>
      <Field label={t('mine.relative_kind')} htmlFor="p-rk"><select id="p-rk" value={f.relative_kind} onChange={set('relative_kind')}>
        <option value="father">{t('mine.rk_father')}</option><option value="spouse">{t('mine.rk_spouse')}</option></select></Field>
      <Field label={t(f.relative_kind === 'spouse' ? 'mine.spouse_name' : 'mine.father_name')} htmlFor="p-rn"><input id="p-rn" value={f.relative_name} onChange={set('relative_name')} /></Field>
      <Field label={t('mine.present_address')} htmlFor="p-pa"><textarea id="p-pa" rows={3} value={f.present} onChange={set('present')} /></Field>
      <label className="check"><input type="checkbox" checked={f.same} onChange={(e) => setF({ ...f, same: e.target.checked })} data-testid="same-address" />{t('mine.same_address')}</label>
      {!f.same && <Field label={t('mine.permanent_address')} htmlFor="p-pm"><textarea id="p-pm" rows={3} value={f.permanent} onChange={set('permanent')} /></Field>}
      <div className="section-title">{t('mine.emergency')}</div>
      <Field label={t('mine.em_name')} htmlFor="p-en"><input id="p-en" value={f.em_name} onChange={set('em_name')} /></Field>
      <Field label={t('mine.relation')} htmlFor="p-er"><input id="p-er" value={f.em_relation} onChange={set('em_relation')} /></Field>
      <Field label={t('mine.em_phone')} htmlFor="p-ep"><input id="p-ep" type="tel" inputMode="tel" value={f.em_phone} onChange={set('em_phone')} /></Field>
    </div>
  );
}

function ContactCard({ title, c, empty }: { title: string; c: Contact | null; empty: string }) {
  return (
    <div className="card"><div className="section-title" style={{ marginTop: 0 }}>{title}</div>
      {c ? <><strong>{c.name}</strong><div className="small">{[c.phone && <a key="p" href={`tel:${c.phone}`}>{c.phone}</a>, c.email && <a key="e" href={`mailto:${c.email}`}>{c.email}</a>]
        .filter(Boolean).reduce<ReactNode[]>((a, x, i) => (i ? [...a, ' · ', x] : [x]), [])}</div></> : <span className="muted">{empty}</span>}
    </div>
  );
}

// ── the first day ────────────────────────────────────────────────────────────────────────────────────────────────
export function Welcome() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const stage = useStageName();
  const o = useMine();
  if (o.loading && !o.data) return <Loading />;
  if (!o.data) return <ErrorBox error={o.error} onRetry={() => void o.reload()} />;
  const x = o.data, p = progress(x.tasks), mine = ctx?.assignments ?? [];
  return (
    <div style={{ maxWidth: 640 }}>
      <div className="band"><div><h1>{t('day1.title', { name: x.name.split(' ')[0] })}</h1><div className="sub"><Join o={x} /></div></div></div>
      <div className="card">
        <dl className="kv">
          <dt>{t('hr.f_title')}</dt><dd>{x.org.job_title ?? '—'}</dd>
          <dt>{t('hr.f_dept')}</dt><dd>{x.org.department ?? '—'}</dd>
          <dt>{t('hr.f_type')}</dt><dd>{x.org.employment_type ? t(`emptype.${x.org.employment_type}`) : '—'}</dd>
        </dl>
      </div>
      <FirstDayCard o={x} />
      <div className="grid">
        <ContactCard title={t('day1.reports_to')} c={x.reports_to} empty={t('day1.not_set')} />
        <ContactCard title={t('day1.buddy')} c={x.buddy} empty={t('day1.buddy_soon')} />
      </div>
      <div className="card" data-testid="day1-work">
        <div className="section-title" style={{ marginTop: 0 }}>{t('day1.where')}</div>
        {mine.length === 0 ? <p className="muted" data-testid="day1-after">{t(joinerTrack(x.system_role) === 'hr' ? (x.status === 'active' ? 'day1.hr_active' : 'day1.after_joining_hr')
          : (x.status === 'active' ? 'hold.body' : 'day1.after_joining'))}</p> : (
          <ul>{mine.map((a) => <li key={a.id}><strong>{a.label}</strong>{a.stages.length > 0 && <> · {a.stages.map(stage).join(', ')}</>}{a.posting && <span className="muted"> · {a.posting}</span>}</li>)}</ul>)}
      </div>
      <p className="row">
        {p.done < p.total && <Link className="btn" to="/onboarding">{t('day1.left', { n: p.total - p.done })}</Link>}
        <Link className="btn secondary" to="/goals">{t('goals.title')}</Link>
        {mine.length > 0 && <Link className="btn secondary" to="/">{t('nav.home')}</Link>}
      </p>
    </div>
  );
}

/** B6: when and where, who to ask for, what to bring — as HR set it, else the template's defaults. */
function FirstDayCard({ o }: { o: MyOnboarding }) {
  const { t } = useI18n();
  const d = o.first_day;
  if (!d) return null;
  const rows: [string, string | null][] = [['day1.when', [d.date ? date(d.date) : null, d.time].filter(Boolean).join(' · ') || null],
    ['day1.place', d.place], ['day1.ask_for', d.ask_for], ['day1.bring', d.bring]];
  return (
    <div className="card" data-testid="first-day">
      <div className="section-title" style={{ marginTop: 0 }}>{t('day1.details')}</div>
      <dl className="kv">{rows.map(([k, v]) => <Fragment key={k}><dt>{t(k)}</dt><dd>{v ?? <span className="muted">{t('day1.hr_will_tell')}</span>}</dd></Fragment>)}</dl>
    </div>
  );
}

// ── 30-60-90 ─────────────────────────────────────────────────────────────────────────────────────────────────────
export function Goals() {
  const { t } = useI18n();
  const o = useMine();
  if (o.loading && !o.data) return <Loading />;
  if (!o.data) return <ErrorBox error={o.error} onRetry={() => void o.reload()} />;
  const goals = o.data.goals;
  return (
    <div>
      <h1>{t('goals.title')}</h1>
      <p className="muted">{t('goals.sub')}</p>
      {goals.length === 0 ? <div className="card hold"><div className="big-icon" aria-hidden="true">🎯</div><p>{t('goals.none')}</p></div> : (
        <div className="horizons" data-testid="goals">{([30, 60, 90] as const).map((h) => (
          <div className="card" key={h}><div className="section-title" style={{ marginTop: 0 }}>{t('goals.days', { n: h })}</div>
            {goals.filter((g) => g.horizon === h).length === 0 ? <span className="muted">—</span>
              : <ul>{goals.filter((g) => g.horizon === h).map((g) => <li key={g.id}>{g.goal}</li>)}</ul>}</div>))}</div>)}
      <p><Link to="/onboarding">{t('mine.back')}</Link></p>
    </div>
  );
}

// ── nobody has assigned me yet ───────────────────────────────────────────────────────────────────────────────────
/** An active employee with no assignment. A valid state, not an error: say so calmly, and say who to ask. */
export function NoAssignment() {
  const { t } = useI18n();
  const { ctx, refresh } = useAuth();
  const o = useMine();
  const act = useAction();
  const open = ctx?.onboarding?.open ?? 0;
  return (
    <div style={{ maxWidth: 560 }}>
      <div className="card hold" data-testid="no-assignment">
        <div className="big-icon" aria-hidden="true">🌱</div>
        <h1>{t('hold.title', { name: (ctx?.user?.display_name ?? '').split(' ')[0] })}</h1>
        <p>{t('hold.body')}</p>
        {o.data?.reports_to && <p className="muted">{t('hold.ask', { name: o.data.reports_to.name })}{o.data.reports_to.phone ? <> · <a href={`tel:${o.data.reports_to.phone}`}>{o.data.reports_to.phone}</a></> : null}</p>}
        <p className="row" style={{ justifyContent: 'center' }}>
          <button type="button" className="secondary" disabled={act.busy} onClick={() => void act.run(() => refresh())} data-testid="check-again">{t('hold.check')}</button>
          {open > 0 && <Link className="btn" to="/onboarding">{t('day1.left', { n: open })}</Link>}
          <Link className="btn secondary" to="/welcome">{t('mine.first_day')}</Link>
        </p>
      </div>
    </div>
  );
}

/** What a joiner's first screen is until they are active: their checklist, in short. */
export function JoinerHome() {
  const { t } = useI18n();
  const o = useMine();
  if (o.loading && !o.data) return <Loading />;
  if (!o.data) return <ErrorBox error={o.error} onRetry={() => void o.reload()} />;
  const x = o.data, p = progress(x.tasks);
  const next = x.tasks.find((k: Task) => taskState(x.tasks, k) === 'open');
  return (
    <div style={{ maxWidth: 640 }}>
      <div className="band" data-testid="joiner-home"><div><h1>{t('mine.welcome', { name: x.name.split(' ')[0] })}</h1><div className="sub"><Join o={x} /></div></div></div>
      <div className="card">
        <strong>{t('mine.progress', { done: p.done, total: p.total })}</strong>
        <div className="bar" role="img" aria-label={`${p.pct} %`} style={{ margin: '6px 0 12px' }}><span style={{ width: `${p.pct}%` }} /></div>
        {next ? <p>{t('mine.next')}: <strong><TaskTitle task={next} /></strong> <Badge value="pending" label={t('mine.due', { d: date(next.due_on) })} /></p>
          : <p className="muted">{t(p.done === p.total ? 'mine.all_done' : 'mine.waiting_on_us')}</p>}
        <p className="row"><Link className="btn" to="/onboarding">{t('mine.open_checklist')}</Link></p>
      </div>
      <RoleGuide role="joiner" />
      <p className="small muted" data-testid="no-access-yet">{t(joinerTrack(x.system_role) === 'hr' ? 'mine.no_access_yet_hr' : 'mine.no_access_yet')}</p>
      <p className="small"><Link to="/help" data-testid="joiner-help">{t('menu.help')}</Link></p>
      {x.docs.pan_last4 && <p className="small muted">PAN {masked(x.docs.pan_last4)}</p>}
    </div>
  );
}
