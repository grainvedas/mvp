// The new hire's own screens (identity layer), made for a phone: the pre-boarding checklist, one task at a time, the
// first-day page, the 30-60-90 goals, and the calm screen for an employee nobody has assigned yet.
// Identity and bank numbers are checked in full here, on the device, and only their last four characters are sent.
import { useState, type FormEvent, type ReactNode } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { rpc } from '../../lib/api';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { date } from '../../lib/format';
import { countdown, last4, masked, progress, taskState, validAadhaar, validAccount, validIfsc, validPan,
  type Contact, type MyOnboarding, type Task } from '../../lib/people';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { FileBox, uploadHrFile, useStageName } from '../people/shared';
import { Owner, TaskTitle } from '../hr/Hr';

const useMine = () => useAsync(() => rpc<MyOnboarding>('my_onboarding'), []);

function Join({ o }: { o: MyOnboarding }) {
  const { t } = useI18n();
  const c = countdown(o.days_to_join);
  return <span data-testid="join-countdown">{t(`mine.${c.key}`, { n: c.n, d: date(o.join_date) })}</span>;
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
                    : st === 'locked' ? t('mine.locked') : t('mine.due', { d: date(k.due_on) })}</div></div>
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
export function TaskPage() {
  const { id = '' } = useParams();
  const { t } = useI18n();
  const { ctx, refresh } = useAuth();
  const nav = useNavigate();
  const o = useMine();
  const act = useAction();
  const me = ctx!.user!.id;
  const [f, setF] = useState({ ack: false, pan: '', aadhaar: '', bank_name: '', ifsc: '', account: '', nominee: '', relation: '', uan: '', note: '' });
  const [file, setFile] = useState<File | null>(null);
  if (o.loading && !o.data) return <Loading />;
  if (!o.data) return <ErrorBox error={o.error} onRetry={() => void o.reload()} />;
  const task = o.data.tasks.find((k) => k.id === id);
  if (!task) return <Empty>{t('mine.task_gone')}</Empty>;
  const state = taskState(o.data.tasks, task);
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const hasCard = o.data.files.some((x) => x.kind === 'pan' || x.kind === 'aadhaar');

  // what is wrong with what was typed, in the reader's words; null = may be sent
  const problem = ((): string | null => {
    switch (task.kind) {
      case 'sign': return f.ack ? null : t('mine.need_ack');
      case 'identity':
        if (!f.pan && !f.aadhaar) return t('mine.need_id');
        if (f.pan && !validPan(f.pan)) return t('mine.bad_pan');
        if (f.aadhaar && !validAadhaar(f.aadhaar)) return t('mine.bad_aadhaar');
        return file || hasCard ? null : t('mine.need_card');
      case 'bank':
        if (!f.bank_name.trim()) return t('mine.need_bank');
        if (!validIfsc(f.ifsc)) return t('mine.bad_ifsc');
        return validAccount(f.account) ? null : t('mine.bad_account');
      case 'nomination':
        if (!f.nominee.trim() || !f.relation.trim()) return t('mine.need_nominee');
        return f.uan && !/^[0-9]{12}$/.test(f.uan.replace(/\s/g, '')) ? t('mine.bad_uan') : null;
      default: return null;
    }
  })();

  const submit = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    const kind = { sign: 'offer_letter', identity: f.pan ? 'pan' : 'aadhaar', bank: 'bank_proof', nomination: 'pf_form' }[task.kind as string] ?? 'other';
    if (file) await uploadHrFile(me, kind, file, task.id);
    // Only the last four characters of a number leave this device.
    const data: Record<string, unknown> = { note: f.note };
    if (task.kind === 'sign') data.acknowledged = true;
    if (task.kind === 'identity') { if (f.pan) data.pan_last4 = last4(f.pan); if (f.aadhaar) data.aadhaar_last4 = last4(f.aadhaar); }
    if (task.kind === 'bank') { data.bank_name = f.bank_name.trim(); data.bank_ifsc = f.ifsc.trim().toUpperCase(); data.bank_last4 = last4(f.account); }
    if (task.kind === 'nomination') { data.gratuity_nominee = f.nominee.trim(); data.nominee_relation = f.relation.trim(); if (f.uan) data.pf_uan_last4 = last4(f.uan); }
    await rpc('complete_task', { p_task: task.id, p_data: data });
    await refresh();                                   // the last task makes the joiner active: the menu changes with it
    nav('/onboarding', { replace: true });
  }); };

  return (
    <div style={{ maxWidth: 560 }}>
      <p className="small"><Link to="/onboarding">{t('mine.back')}</Link></p>
      <h1><TaskTitle task={task} /></h1>
      <p className="muted small">{t('mine.due', { d: date(task.due_on) })}{task.statutory ? ` · ${t('hr.statutory')}` : ''}</p>
      {state === 'done' && <div className="alert ok">{t('mine.done')}</div>}
      {state === 'locked' && <div className="alert info">{t('mine.locked')}</div>}
      {state === 'ours' && <div className="alert info">{t('mine.we_are_on_it')}</div>}
      {state === 'open' && (
        <form className="card" onSubmit={submit} aria-label={task.title}>
          {task.kind === 'sign' && <>
            <p>{t('mine.sign_body')}</p>
            <FileBox id="t-file" label={t('mine.signed_copy')} hint={t('common.optional')} onPick={setFile} />
            <label className="check"><input type="checkbox" checked={f.ack} onChange={(e) => setF({ ...f, ack: e.target.checked })} />{t('mine.ack')}</label>
          </>}
          {task.kind === 'identity' && <>
            <p>{t('mine.identity_body')}</p>
            <Field label="PAN" hint="ABCDE1234F" htmlFor="t-pan"><input id="t-pan" value={f.pan} onChange={(e) => setF({ ...f, pan: e.target.value.toUpperCase() })} maxLength={10} autoComplete="off" autoCapitalize="characters" /></Field>
            <Field label="Aadhaar" hint={t('mine.aadhaar_hint')} htmlFor="t-aadhaar"><input id="t-aadhaar" value={f.aadhaar} onChange={set('aadhaar')} inputMode="numeric" maxLength={14} autoComplete="off" /></Field>
            <FileBox id="t-file" label={t('mine.card_photo')} hint={hasCard ? t('mine.card_already') : undefined} onPick={setFile} />
            <div className="alert info">{t('mine.last4_note')}</div>
          </>}
          {task.kind === 'bank' && <>
            <Field label={t('mine.bank_name')} htmlFor="t-bank"><input id="t-bank" value={f.bank_name} onChange={set('bank_name')} /></Field>
            <Field label="IFSC" hint="HDFC0001234" htmlFor="t-ifsc"><input id="t-ifsc" value={f.ifsc} onChange={(e) => setF({ ...f, ifsc: e.target.value.toUpperCase() })} maxLength={11} autoComplete="off" autoCapitalize="characters" /></Field>
            <Field label={t('mine.account')} htmlFor="t-account"><input id="t-account" value={f.account} onChange={set('account')} inputMode="numeric" autoComplete="off" /></Field>
            <FileBox id="t-file" label={t('mine.bank_proof')} hint={t('common.optional')} onPick={setFile} />
            <div className="alert info">{t('mine.last4_note')}</div>
          </>}
          {task.kind === 'nomination' && <>
            <p>{t('mine.nomination_body')}</p>
            <Field label={t('mine.nominee')} htmlFor="t-nominee"><input id="t-nominee" value={f.nominee} onChange={set('nominee')} /></Field>
            <Field label={t('mine.relation')} htmlFor="t-relation"><input id="t-relation" value={f.relation} onChange={set('relation')} /></Field>
            <Field label="UAN" hint={t('mine.uan_hint')} htmlFor="t-uan"><input id="t-uan" value={f.uan} onChange={set('uan')} inputMode="numeric" maxLength={12} autoComplete="off" /></Field>
            <FileBox id="t-file" label={t('mine.signed_form')} hint={t('common.optional')} onPick={setFile} />
          </>}
          {!['sign', 'identity', 'bank', 'nomination'].includes(task.kind) && (
            <Field label={t('hr.note')} hint={t('common.optional')} htmlFor="t-note"><input id="t-note" value={f.note} onChange={set('note')} /></Field>)}
          {problem && <p className="hint" data-testid="task-problem">{problem}</p>}
          <ErrorBox error={act.error} />
          <button type="submit" disabled={act.busy || problem !== null} data-testid="task-done">{t('mine.submit')}</button>
        </form>)}
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
      <div className="grid">
        <ContactCard title={t('day1.reports_to')} c={x.reports_to} empty={t('day1.not_set')} />
        <ContactCard title={t('day1.buddy')} c={x.buddy} empty={t('day1.buddy_soon')} />
      </div>
      <div className="card" data-testid="day1-work">
        <div className="section-title" style={{ marginTop: 0 }}>{t('day1.where')}</div>
        {mine.length === 0 ? <p className="muted">{t(x.status === 'active' ? 'hold.body' : 'day1.after_joining')}</p> : (
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
      <p className="small muted">{t('mine.no_access_yet')}</p>
      {x.docs.pan_last4 && <p className="small muted">PAN {masked(x.docs.pan_last4)}</p>}
    </div>
  );
}
