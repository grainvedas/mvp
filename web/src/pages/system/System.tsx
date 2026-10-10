// System (identity layer): the two seats everything starts from, the once-a-day sign-in code switch, the audit log.
import { useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { rpc } from '../../lib/api';
import { SUPABASE_ANON_KEY, SUPABASE_URL } from '../../lib/supabase';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { dateTime, humanise } from '../../lib/format';
import type { AuditLine, Seat, Seats as SeatsData } from '../../lib/people';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { StatusBadge, useStageName } from '../people/shared';

function SeatRow({ s }: { s: Seat }) {
  const { t } = useI18n();
  return <li><Link to={`/people/${s.id}`}><strong>{s.name}</strong></Link> <span className="small muted">{s.email ?? ''}</span> <StatusBadge status={s.status} />
    {s.has_login === false && <> <Badge value="draft" label={t('people.no_login')} /></>}</li>;
}

/** Is a sender set up for the sign-in code? Asked of the server function itself (it knows; the database cannot). */
async function senderState(): Promise<'yes' | 'no' | 'unknown'> {
  try {
    const r = await fetch(`${SUPABASE_URL}/functions/v1/daily-code`, { headers: { apikey: SUPABASE_ANON_KEY, authorization: `Bearer ${SUPABASE_ANON_KEY}` }, signal: AbortSignal.timeout(8000) });
    const d = (await r.json().catch(() => null)) as { sender?: boolean } | null;
    return typeof d?.sender === 'boolean' ? (d.sender ? 'yes' : 'no') : 'unknown';
  } catch { return 'unknown'; }
}

export function Seats() {
  const { t } = useI18n();
  const d = useAsync(() => rpc<SeatsData>('bootstrap_seats'), []);
  const joined = (useLocation().state as { joined?: string } | null)?.joined;   // the admin has just marked the HR Admin as joined
  const sender = useAsync(senderState, []);
  const act = useAction();
  const [pick, setPick] = useState('');
  const [refused, setRefused] = useState<{ without_email: number; names: string[] } | null>(null);
  if (d.loading && !d.data) return <Loading />;
  if (!d.data) return <ErrorBox error={d.error} onRetry={() => void d.reload()} />;
  const x = d.data;
  const appoint = () => act.run(async () => {
    if (!window.confirm(t('seats.appoint_sure', { name: x.candidates.find((c) => c.id === pick)?.name ?? '' }))) return;
    await rpc('appoint_hr_admin', { p_employee: pick }); setPick(''); await d.reload();
  });
  const flip = (on: boolean) => act.run(async () => {
    if (on && !window.confirm(t('seats.code_on_sure'))) return;
    const r = await rpc<{ ok: boolean; without_email?: number; names?: string[] }>('set_daily_code', { p_on: on });
    setRefused(r.ok ? null : { without_email: r.without_email ?? 0, names: r.names ?? [] });
    await d.reload();
  });
  return (
    <div style={{ maxWidth: 860 }}>
      <div className="page-hd"><h1><span aria-hidden="true">🪑 </span>{t('seats.title')}</h1><div className="sub">{t('seats.sub')}</div></div>
      <ErrorBox error={act.error} />
      <div className="card seat" data-testid="seat-admin">
        <h2 style={{ marginTop: 0 }}>{t('seats.admin')}</h2>
        <p className="small muted">{t('seats.admin_note')}</p>
        <ul>{x.admins.map((s) => <SeatRow key={s.id} s={s} />)}</ul>
        <div className="alert info" data-testid="break-glass"><strong>{t('seats.break_glass')}</strong> {t('seats.break_glass_note')}</div>
      </div>
      <div className={`card seat${x.hr_admin ? '' : ' vacant'}`} data-testid="seat-hr-admin">
        <h2 style={{ marginTop: 0 }}>{t('seats.hr_admin')}</h2>
        <p className="small muted">{t('seats.hr_admin_note')}</p>
        {joined && <div className="alert ok" role="status" data-testid="hr-admin-joined">{t('seats.hr_admin_joined', { name: joined })}</div>}
        {x.hr_admin ? <ul><SeatRow s={x.hr_admin} /></ul> : <p className="gap" data-testid="seat-vacant">{t('seats.vacant')}</p>}
        {x.hr_admin && (x.hr_admin.status === 'invited' || x.hr_admin.status === 'onboarding') && (
          <div className="alert warn" data-testid="hr-admin-not-joined">{t('seats.hr_admin_not_joined', { name: x.hr_admin.name })}{' '}
            <Link to={`/hr/joiners/${x.hr_admin.id}`} data-testid="hr-admin-joiner-page">{t('seats.open_joiner_page')}</Link></div>)}
        <div className="row" style={{ alignItems: 'flex-end' }}>
          <Field label={t(x.hr_admin ? 'seats.move_to' : 'seats.appoint')} htmlFor="seat-pick"><select id="seat-pick" value={pick} onChange={(e) => setPick(e.target.value)}>
            <option value="">—</option>{x.candidates.filter((c) => c.id !== x.hr_admin?.id).map((c) => <option key={c.id} value={c.id}>{c.name}{c.system_role === 'hr_resource' ? ` (${t('sysrole.hr_resource')})` : ''}</option>)}</select></Field>
          <button type="button" disabled={!pick || act.busy} onClick={() => void appoint()} data-testid="appoint">{t('seats.appoint_btn')}</button>
        </div>
        <h3>{t('seats.hr_resources')} ({x.hr_resources.length})</h3>
        {x.hr_resources.length === 0 ? <Empty /> : <ul>{x.hr_resources.map((s) => <SeatRow key={s.id} s={s} />)}</ul>}
        <p className="small muted">{t('seats.hr_resources_note')}</p>
      </div>
      <div className="card" data-testid="daily-code-card">
        <h2 style={{ marginTop: 0 }}>{t('seats.code_title')} <Badge value={x.daily_code.on ? 'verified' : 'draft'} label={t(x.daily_code.on ? 'seats.code_on' : 'seats.code_off')} /></h2>
        <p className="small muted">{t('seats.code_note')}</p>
        <dl className="kv">
          <dt>{t('seats.code_sender')}</dt><dd data-testid="code-sender">{t(`seats.sender_${sender.data ?? 'unknown'}`)}</dd>
          <dt>{t('seats.code_no_email')}</dt><dd data-testid="code-no-email">{x.daily_code.without_email}</dd>
        </dl>
        {refused && <div className="alert error" data-testid="code-refused">{t('seats.code_refused', { n: refused.without_email })} {refused.names.slice(0, 20).join(', ')}{refused.names.length > 20 ? '…' : ''}</div>}
        {x.daily_code.on
          ? <button type="button" className="secondary" disabled={act.busy} onClick={() => void flip(false)} data-testid="code-switch-off">{t('seats.code_switch_off')}</button>
          : <button type="button" className="secondary" disabled={act.busy || sender.data !== 'yes'} onClick={() => void flip(true)} data-testid="code-switch-on">{t('seats.code_switch_on')}</button>}
        {!x.daily_code.on && sender.data !== 'yes' && <p className="hint">{t('seats.code_needs_sender')}</p>}
      </div>
    </div>
  );
}

/** What an audit line says, in a sentence. Unknown actions fall back to their name. */
function Detail({ l }: { l: AuditLine }) {
  const { t } = useI18n();
  const stage = useStageName();
  const d = l.detail as Record<string, unknown>;
  const stages = Array.isArray(d.stages) ? (d.stages as string[]).map(stage).join(', ') : '';
  const bits = [
    d.lens ? t(`lens.${String(d.lens)}`, undefined, String(d.lens)) : '', d.op_role ? t(`oprole.${String(d.op_role)}`, undefined, String(d.op_role)) : '', stages,
    d.reason ? `“${String(d.reason)}”` : '', d.from && d.to ? `${humanise(String(d.from))} → ${humanise(String(d.to))}` : '',
    typeof d.assignments_ended === 'number' ? t('audit.ended_n', { n: d.assignments_ended }) : '', d.exit_date ? String(d.exit_date) : '',
    d.previous ? t('audit.previous', { name: String(d.previous) }) : '', typeof d.on === 'boolean' ? (d.on ? t('seats.code_on') : t('seats.code_off')) : '',
  ].filter(Boolean);
  return <>{bits.join(' · ')}</>;
}

export function AuditLog() {
  const { t } = useI18n();
  const [flagged, setFlagged] = useState(false);
  const list = useAsync(() => rpc<AuditLine[]>('audit_feed', { p_limit: 300, p_flagged: flagged }), [flagged]);
  return (
    <div style={{ maxWidth: 900 }}>
      <div className="page-hd"><h1><span aria-hidden="true">📜 </span>{t('audit.title')}</h1><div className="sub">{t('audit.sub')}</div></div>
      <label className="check"><input type="checkbox" checked={flagged} onChange={(e) => setFlagged(e.target.checked)} data-testid="flagged-only" />{t('audit.flagged_only')}</label>
      {list.loading ? <Loading /> : <ErrorBox error={list.error} onRetry={() => void list.reload()} />}
      {list.data?.length === 0 && <Empty />}
      {!!list.data?.length && (
        <div className="card" style={{ padding: 0 }}><ul className="feed" data-testid="audit-feed">{list.data.map((l) => (
          <li key={l.id} className={l.flagged ? 'flagged' : ''} data-testid={l.flagged ? 'audit-flagged' : 'audit-line'} data-action={l.action}>
            <div><strong>{l.actor_name}</strong>{l.actor_role && l.actor_role !== 'operational' ? <span className="muted small"> ({t(`sysrole.${l.actor_role}`)})</span> : null}
              {' '}{t(`audit.${l.action}`, undefined, humanise(l.action))}{' '}
              {l.target ? <Link to={`/people/${l.target}`}>{l.target_name ?? '—'}</Link> : null}
              {l.flagged && <> <Badge value="open" label={t(`audit.flag_${l.action}`, undefined, t('audit.flag'))} /></>}</div>
            <div className="small"><Detail l={l} /></div>
            <div className="when">{dateTime(l.at)}</div>
          </li>))}</ul></div>)}
    </div>
  );
}
