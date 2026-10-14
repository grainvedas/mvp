// HR's requirements list (migration 46, Veda 14 Oct 2026, "GrainVeda MVP — HR requirements list and staffing a
// scope", section B): what the Client Managers and State Managers need, raised once by them (or by itself from a
// scope's empty stages), grouped state → client → scope. HR publishes a requirement's lines in one act (one opening,
// a line per stage, "Requested by …"), correcting the number or date first (logged); or returns a line with a question,
// declines or holds it with a reason. HR sees her states; the HR Admin all. Every rule is the database's
// (tests/40_requirements.sql); this page shows and asks.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { rpc } from '../../lib/api';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { date } from '../../lib/format';
import { groupQueue, LINE_ROLES, publishable, shownBadge, type HrAction, type HrCounts, type HrQueue, type RequirementLine } from '../../lib/requirements';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { useStageName } from '../people/shared';
import { HrLinks } from './Scale';
import { HrScopeNote } from './Geo';

/** "N new requirements · oldest X days": HR's figure, a link to the list. */
export function RequirementsFigure() {
  const { t } = useI18n();
  const c = useAsync(() => rpc<HrCounts>('hr_requirement_counts').catch(() => null), []);
  if (!c.data) return null;
  return (
    <p data-testid="req-figure"><Link className={`btn ${c.data.new > 0 ? '' : 'secondary'}`} to="/hr/requirements">
      📝 {c.data.new > 0 ? t('req.figure', { n: c.data.new, d: c.data.oldest_days }) : t('req.figure_none')}</Link></p>);
}

export function LineWhat({ l }: { l: Pick<RequirementLine, 'role' | 'stage' | 'positions'> }) {
  const { t } = useI18n();
  const stage = useStageName();
  return <><strong>{l.positions}</strong> × {t(`role.${l.role}`)}{l.stage ? ` · ${stage(l.stage)}` : ''}</>;
}

/** A line's status as people read it: Requested, Returned (with the question), Published (opening), Joining, Ready to assign … */
export function LineStatusText({ l }: { l: RequirementLine }) {
  const { t } = useI18n();
  return (
    <span data-testid="req-status" data-status={l.shown}>
      <Badge value={shownBadge(l.shown)} label={t(`req.st_${l.shown}`)} />
      {l.opening && <span className="small"> · {l.opening.code}</span>}
      {l.shown === 'joining' && <span className="small"> · {l.joining.map((p) => p.joins_on ? t('req.joins_on', { name: p.name, d: date(p.joins_on) }) : p.name).join(', ')}</span>}
      {l.shown === 'ready' && <span className="small"> · {l.ready.map((p) => p.name).join(', ')}</span>}
      {l.reason && ['returned', 'held', 'declined', 'withdrawn', 'filled'].includes(l.status) && <div className="small muted" style={{ overflowWrap: 'anywhere' }}>{t(l.status === 'returned' ? 'req.question' : 'req.reason', { r: l.reason })}{l.status_by ? ` · ${l.status_by}` : ''}</div>}
      {l.overdue && <span className="small gap"> · {t('req.overdue')}</span>}
    </span>);
}

export function Requirements() {
  const { t } = useI18n();
  const [f, setF] = useState({ state_id: '', status: '', role: '', overdue: false });
  const q = useAsync(() => rpc<HrQueue>('hr_requirements', { p: f }), [JSON.stringify(f)]);
  const x = q.data;
  const states = x ? [...new Map(x.groups.map((g) => [g.state_id, g.state_name])).entries()] : [];
  return (
    <div data-testid="requirements">
      <div className="page-hd"><h1><span aria-hidden="true">📝 </span>{t('req.title')}</h1><div className="sub">{t('req.sub')}</div></div>
      <HrLinks here="requirements" />
      <HrScopeNote />
      {x && <div className="stats" data-testid="req-stats">
        <div className="stat"><div className="stat-val" data-testid="req-new">{x.counts.new}</div><div className="stat-label">{t('req.kpi_new')}</div>
          <div className="stat-sub">{t('req.kpi_oldest', { d: x.counts.oldest_days })}</div></div>
        <button type="button" className="stat" onClick={() => setF({ ...f, overdue: true })}><div className="stat-val">{x.counts.overdue}</div><div className="stat-label">{t('req.kpi_overdue')}</div></button>
      </div>}
      <div className="filters" data-testid="req-filters">
        <Field label={t('lens.state')} htmlFor="rq-state"><select id="rq-state" value={f.state_id} onChange={(e) => setF({ ...f, state_id: e.target.value })}>
          <option value="">{t('people.any_state')}</option>{states.map(([id, name]) => <option key={id} value={id}>{name}</option>)}</select></Field>
        <Field label={t('common.status')} htmlFor="rq-status"><select id="rq-status" value={f.status} onChange={(e) => setF({ ...f, status: e.target.value })} data-testid="rq-status">
          <option value="">{t('req.f_open')}</option>{(['requested', 'returned', 'held', 'published', 'filled', 'declined', 'withdrawn', 'all'] as const).map((s) =>
            <option key={s} value={s}>{t(s === 'all' ? 'req.f_all' : `req.st_${s}`)}</option>)}</select></Field>
        <Field label={t('open.role')} htmlFor="rq-role"><select id="rq-role" value={f.role} onChange={(e) => setF({ ...f, role: e.target.value })}>
          <option value="">{t('jl.any_role')}</option>{LINE_ROLES.map((r) => <option key={r} value={r}>{t(`role.${r}`)}</option>)}</select></Field>
        <label className="check"><input type="checkbox" checked={f.overdue} onChange={(e) => setF({ ...f, overdue: e.target.checked })} />{t('req.overdue_only')}</label>
      </div>
      {q.loading && !x ? <Loading /> : <ErrorBox error={q.error} onRetry={() => void q.reload()} />}
      {x && (x.groups.length === 0 ? <Empty>{t('req.none')}</Empty> : groupQueue(x.groups).map((s) => (
        <section key={s.state} data-testid="req-state">
          <h2>{s.state}</h2>
          {s.clients.map((c) => (
            <div key={c.client ?? '-'} data-testid="req-client">
              <h3>{c.client ?? t('req.whole_state')}</h3>
              {c.reqs.map((r) => <RequirementCard key={r.id} r={r} canAct={x.can_act} onDone={() => void q.reload()} />)}
            </div>))}
        </section>)))}
      <p className="small muted">{t('req.how')}</p>
    </div>
  );
}

function RequirementCard({ r, canAct, onDone }: { r: HrQueue['groups'][number]; canAct: boolean; onDone: () => void }) {
  const { t } = useI18n();
  const act = useAction();
  const [changes, setChanges] = useState<Record<string, { positions?: string; needed_by?: string }>>({});
  const [asking, setAsking] = useState<{ line: string; action: Exclude<HrAction, 'publish'> } | null>(null);
  const [why, setWhy] = useState('');
  const [made, setMade] = useState<string[] | null>(null);
  const can = publishable(r.lines);
  const decide = (ids: string[], action: HrAction, reason?: string) => act.run(async () => {
    const p_changes = Object.fromEntries(ids.filter((id) => changes[id]).map((id) => [id, {
      ...(changes[id].positions ? { positions: Number(changes[id].positions) } : {}), ...(changes[id].needed_by ? { needed_by: changes[id].needed_by } : {}) }]));
    const res = await rpc<{ lines: RequirementLine[] }>('decide_lines', { p_lines: ids, p_action: action, p_reason: reason ?? null, p_changes });
    if (action === 'publish') setMade(res.lines.map((l) => l.opening?.code).filter(Boolean) as string[]);
    setAsking(null); setWhy(''); setChanges({}); onDone();
  });
  const title = r.kind === 'scope' ? r.scope_name : r.kind === 'client' ? t('req.for_client', { c: r.client_name ?? '' }) : t('req.state_need');
  return (
    <div className="card" data-testid="req-card" data-kind={r.kind}>
      <div className="row" style={{ justifyContent: 'space-between' }}><strong style={{ overflowWrap: 'anywhere' }}>{title}</strong>
        {r.scope_id && <Link className="small" to={`/scopes/${r.scope_id}/roster`}>{t('roster.title')}</Link>}</div>
      <div className="small muted">{t('req.raised', { who: r.raised_by ?? t('req.by_system'), d: date(r.raised_at) })}</div>
      <ul className="stack" style={{ listStyle: 'none', padding: 0, margin: '8px 0' }}>
        {r.lines.map((l) => (
          <li key={l.id} data-testid="req-line" data-stage={l.stage ?? ''} data-status={l.status} style={{ borderBottom: '1px solid var(--line, #ddd)', paddingBottom: 6 }}>
            <div><LineWhat l={l} />{l.auto && <span className="small muted"> · {t('req.auto')}</span>}</div>
            <div className="small">{t('req.needed_by', { d: date(l.needed_by) })}{l.posting ? ` · ${l.posting}` : ''}{l.note ? ` · ${l.note}` : ''}</div>
            <LineStatusText l={l} />
            {canAct && (l.status === 'requested' || l.status === 'held') && (
              <div className="row" style={{ marginTop: 4 }}>
                <label className="small">{t('req.people')} <input type="number" min={1} max={500} style={{ width: 70 }} aria-label={`${t('req.people')}: ${l.stage ?? l.role}`}
                  value={changes[l.id]?.positions ?? String(l.positions)} onChange={(e) => setChanges({ ...changes, [l.id]: { ...changes[l.id], positions: e.target.value } })} data-testid="req-positions" /></label>
                <label className="small">{t('req.by')} <input type="date" aria-label={`${t('req.by')}: ${l.stage ?? l.role}`} value={changes[l.id]?.needed_by ?? l.needed_by}
                  onChange={(e) => setChanges({ ...changes, [l.id]: { ...changes[l.id], needed_by: e.target.value } })} /></label>
                <button type="button" className="small-btn" disabled={act.busy} onClick={() => void decide([l.id], 'publish')} data-testid="req-publish">{t('req.publish')}</button>
                {(['return', 'decline', 'hold'] as const).filter((a) => !(a === 'hold' && l.status === 'held')).map((a) => (
                  <button key={a} type="button" className="secondary small-btn" disabled={act.busy} onClick={() => { setAsking({ line: l.id, action: a }); setWhy(''); }} data-testid={`req-${a}`}>{t(`req.${a}`)}</button>))}
              </div>)}
            {asking?.line === l.id && (
              <div className="row" style={{ marginTop: 4 }}>
                <input aria-label={t(asking.action === 'return' ? 'req.question_label' : 'req.why_label')} placeholder={t(asking.action === 'return' ? 'req.question_label' : 'req.why_label')}
                  value={why} maxLength={500} onChange={(e) => setWhy(e.target.value)} data-testid="req-why" />
                <button type="button" className={asking.action === 'decline' ? 'danger small-btn' : 'small-btn'} disabled={act.busy || why.trim().length < 3}
                  onClick={() => void decide([l.id], asking.action, why.trim())} data-testid="req-confirm">{t(`req.${asking.action}`)}</button>
                <button type="button" className="secondary small-btn" onClick={() => setAsking(null)}>{t('common.cancel')}</button>
              </div>)}
          </li>))}
      </ul>
      {canAct && can.length > 1 && (
        <button type="button" disabled={act.busy} onClick={() => void decide(can.map((l) => l.id), 'publish')} data-testid="req-publish-all">
          {t(r.kind === 'scope' ? 'req.publish_scope' : 'req.publish_all', { n: can.length })}</button>)}
      {made && made.length > 0 && <div className="alert ok small" data-testid="req-made">{t('req.made', { codes: made.join(', ') })} · <Link to="/hr/openings">{t('open.title')}</Link></div>}
      <ErrorBox error={act.error} />
    </div>
  );
}
