// Onboarding at scale (migration 38, Veda's brief of 11 Oct 2026; decisions "as recommended"):
//   Openings       a state's planned positions per role, and how far each has got (open, joining, joined, assigned, vacant)
//   Joiners        HR's list, filtered and paged on the server, with "Mine" and bulk acts
//   Import         an Excel file of joiners: preview, then the valid rows in one go; invites right after
//   Invites        one-time links (copy, QR), emailed when a mail sender is set up
//   AssignMany     several people on one assignment in one act; "ready to assign" first
// Who may do what is the database's: each control is shown when the server says the reader may use it.
import { useEffect, useMemo, useState, type FormEvent, type ReactNode } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import readXlsxFile from 'read-excel-file';
import writeXlsxFile from 'write-excel-file';
import { callFunction, q, rpc } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { date } from '../../lib/format';
import { NO_RIGHTS, type Lens, type OpRole, type StageType } from '../../lib/types';
import { joinWords, waitingOn } from '../../lib/people';
import { HIRE_ROLES, IMPORT_COLUMNS, NO_FILTER, NUMBER_KEYS, filterArgs, joinerRows, linksText, bulkError, pageCount, sendInvites,
  type HireRole, type ImportResult, type InviteResult, type JoinerFilter, type JoinersPage, type Opening, type OpeningsSummary } from '../../lib/scale';
import { STAGE_ICON } from '../../engine/icons';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { RoleGuide } from '../../shell/RoleGuide';
import { StatusBadge, useStageName } from '../people/shared';
import { Owner, TaskTitle, taskKey } from './Hr';
import { HrScopeNote, stateChoices, useHrScope } from './Geo';

const STAGES = Object.keys(STAGE_ICON) as StageType[];
const PAGE = 50;
interface Named { id: string; name: string }
const useAllStates = () => useAsync(() => q(supabase.from('states').select('id,name').order('name')) as Promise<Named[]>, []);
/** The states this reader works with: every state, or an HR resource's own (migration 39). */
const useStates = () => { const all = useAllStates(); const sc = useHrScope(); return { ...all, data: all.data ? stateChoices(all.data, sc.data) : all.data }; };
export const useHrPeople = () => useAsync(async () => ((await q(supabase.from('app_users').select('id,display_name,system_role')
  .in('system_role', ['hr_admin', 'hr_resource']).eq('status', 'active').order('display_name'))) as { id: string; display_name: string }[])
  .map((p) => ({ id: p.id, name: p.display_name })), []);

/** HR's pages, one row of links. */
export function HrLinks({ here }: { here: 'joiners' | 'openings' | 'import' | 'templates' | 'team' }) {
  const { t } = useI18n();
  const items: [typeof here, string, string][] = [['joiners', '/hr', 'hr.pipeline_title'], ['openings', '/hr/openings', 'open.title'],
    ['import', '/hr/import', 'imp.title'], ['templates', '/hr/templates', 'hr.templates'], ['team', '/hr/team', 'geo.team']];
  return <p className="row hr-links" data-testid="hr-links">{items.map(([k, to, key]) => k === here
    ? <strong key={k} className="btn secondary active" aria-current="page">{t(key)}</strong>
    : <Link key={k} className="btn secondary" to={to}>{t(key)}</Link>)}</p>;
}

export function RoleLabel({ role, stage }: { role: HireRole | null | undefined; stage?: StageType | null }) {
  const { t } = useI18n();
  const st = useStageName();
  if (!role) return <span className="muted">{t('role.none')}</span>;
  return <>{t(`role.${role}`)}{stage ? ` · ${st(stage)}` : ''}</>;
}

// ── Openings ─────────────────────────────────────────────────────────────────────────────────────────────────────────
export function Openings() {
  const { t } = useI18n();
  const states = useStates();
  const [state, setState] = useState('');
  const s = useAsync(() => rpc<OpeningsSummary>('openings_summary', { p_state: state || null }), [state]);
  const [edit, setEdit] = useState<Opening | 'new' | null>(null);
  const act = useAction();
  const x = s.data;
  const status = (o: Opening, to: string) => act.run(async () => { await rpc('set_opening_status', { p_opening: o.id, p_status: to }); await s.reload(); });
  const byState = useMemo(() => {
    const m = new Map<string, Opening[]>();
    for (const o of x?.openings ?? []) m.set(o.state_name, [...(m.get(o.state_name) ?? []), o]);
    return [...m.entries()];
  }, [x]);
  const nums = (n: Record<string, number>, testid?: string) => NUMBER_KEYS.map((k) => <td key={k} className="num" data-testid={testid ? `${testid}-${k}` : undefined}>{n[k]}</td>);
  return (
    <div>
      <div className="page-hd"><h1><span aria-hidden="true">📋 </span>{t('open.title')}</h1><div className="sub">{t('open.sub')}</div></div>
      {x?.can_plan && <HrLinks here="openings" />}
      <HrScopeNote />
      <div className="filters">
        <Field label={t('lens.state')} htmlFor="op-state"><select id="op-state" value={state} onChange={(e) => setState(e.target.value)}>
          <option value="">{t('people.any_state')}</option>{(states.data ?? []).map((st) => <option key={st.id} value={st.id}>{st.name}</option>)}</select></Field>
      </div>
      {s.loading && !x ? <Loading /> : <ErrorBox error={s.error} onRetry={() => void s.reload()} />}
      {x && <>
        <div className="stats" data-testid="openings-stats">{(['positions', 'joining', 'joined', 'assigned', 'vacant', 'waiting_wave'] as const).map((k) => (
          <div className="stat" key={k}><div className="stat-val" data-testid={`total-${k}`}>{x.total[k] ?? 0}</div><div className="stat-label">{t(`open.n_${k}`)}</div></div>))}</div>
        {x.not_linked > 0 && x.can_plan && <p className="small muted" data-testid="not-linked">{t('open.not_linked', { n: x.not_linked })}</p>}
        {x.can_plan && !edit && <p><button type="button" onClick={() => setEdit('new')} data-testid="new-opening">{t('open.new')}</button></p>}
        {edit && <OpeningForm opening={edit === 'new' ? null : edit} done={() => { setEdit(null); void s.reload(); }} />}
        {x.openings.length === 0 ? <Empty>{t('open.none')}</Empty> : byState.map(([name, list]) => {
          const tot = x.states.find((st) => st.state_name === name)!;
          return (
            <div className="card table-wrap" key={name} data-testid="openings-state">
              <h2 style={{ marginTop: 0 }}>{name}</h2>
              <table className="wide" data-testid="openings">
                <thead><tr><th>{t('open.col_opening')}</th><th>{t('open.col_place')}</th>{NUMBER_KEYS.map((k) => <th key={k} className="num">{t(`open.n_${k}`)}</th>)}<th>{t('common.status')}</th><th /></tr></thead>
                <tbody>{list.map((o) => (
                  <tr key={o.id} data-testid="opening-row" data-code={o.code}>
                    <td><strong>{o.code}</strong><div className="small"><RoleLabel role={o.role} stage={o.stage} /></div>
                      {o.target_join && <div className="small muted">{t('open.target', { d: date(o.target_join) })}</div>}</td>
                    <td className="small">{[o.client_name, o.scope_name].filter(Boolean).join(' · ') || '—'}
                      {!o.ready_target && <div className="muted">{t(o.role === 'client_manager' ? 'open.no_client_yet' : 'open.scope_not_active')}</div>}</td>
                    {nums(o as unknown as Record<string, number>, `n-${o.code}`)}
                    <td><Badge value={o.status === 'open' ? 'active' : o.status === 'closed' ? 'closed' : 'draft'} label={t(`open.status_${o.status}`)} /></td>
                    <td className="row">
                      {x.can_plan && <Link className="btn secondary small-btn" to={`/hr?opening=${o.id}`}>{t('open.people')}</Link>}
                      {x.can_plan && <button type="button" className="secondary small-btn" onClick={() => setEdit(o)} disabled={act.busy}>{t('common.edit')}</button>}
                      {x.can_plan && o.status === 'open' && <button type="button" className="secondary small-btn" onClick={() => void status(o, 'on_hold')} disabled={act.busy}>{t('open.hold')}</button>}
                      {x.can_plan && o.status !== 'open' && <button type="button" className="secondary small-btn" onClick={() => void status(o, 'open')} disabled={act.busy}>{t('open.reopen')}</button>}
                      {x.can_plan && o.status !== 'closed' && <button type="button" className="secondary small-btn" onClick={() => void status(o, 'closed')} disabled={act.busy}>{t('open.close')}</button>}
                    </td>
                  </tr>))}
                  <tr className="total-row" data-testid="state-total"><td colSpan={2}><strong>{t('open.state_total')}</strong></td>{nums(tot as unknown as Record<string, number>)}<td colSpan={2} /></tr>
                </tbody>
              </table>
              {x.can_seat && list.some((o) => o.role === 'state_manager' && o.ready > 0) && <SeatReady stateId={list[0].state_id} onDone={() => void s.reload()} />}
            </div>);
        })}
        {x.openings.length > 0 && <div className="card table-wrap"><table className="wide" data-testid="openings-overall"><tbody>
          <tr className="total-row"><td><strong>{t('open.overall')}</strong></td>{NUMBER_KEYS.map((k) => <td key={k} className="num"><span className="small muted">{t(`open.n_${k}`)} </span><span data-testid={`overall-${k}`}>{x.total[k]}</span></td>)}</tr>
        </tbody></table></div>}
        <ErrorBox error={act.error} />
        <p className="small muted">{t('open.how')}</p>
      </>}
    </div>
  );
}

const blankOpening = { state_id: '', role: 'operator' as HireRole, stage: '' as StageType | '', client_id: '', scope_id: '', positions: '10', target_join: '', title: '' };
function OpeningForm({ opening, done }: { opening: Opening | null; done: () => void }) {
  const { t } = useI18n();
  const stage = useStageName();
  const states = useStates();
  const [f, setF] = useState(opening ? { state_id: opening.state_id, role: opening.role, stage: opening.stage ?? '', client_id: opening.client_id ?? '',
    scope_id: opening.scope_id ?? '', positions: String(opening.positions), target_join: opening.target_join ?? '', title: opening.title ?? '' } : blankOpening);
  // HR reads no clients or scopes; the database gives the form their names (migration 38, app.opening_targets)
  const targets = useAsync(() => f.state_id ? rpc<{ clients: Named[]; scopes: { id: string; season_code: string; geography: string; status: string; client_id: string; chain: StageType[] }[] }>(
    'opening_targets', { p_state: f.state_id }) : Promise.resolve({ clients: [], scopes: [] }), [f.state_id]);
  const clients = { data: targets.data?.clients };
  const scopes = { data: targets.data?.scopes };
  const act = useAction();
  // G3 (Veda, 14 Oct): one State Manager per state, so a State Manager opening has 1 position
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value, ...(k === 'role' && e.target.value === 'state_manager' ? { positions: '1' } : {}) });
  const sc = (scopes.data ?? []).find((x) => x.id === f.scope_id);
  const stageChoices = sc ? sc.chain : STAGES;
  const needsClient = f.role === 'client_manager' || f.role === 'operator' || f.role === 'export_manager';
  const needsScope = f.role === 'operator' || f.role === 'export_manager';
  const save = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    await rpc('save_opening', { p: { ...f, id: opening?.id, positions: Number(f.positions) } }); done();
  }); };
  return (
    <form className="card" onSubmit={save} aria-label={t(opening ? 'open.edit' : 'open.new')} data-testid="opening-form">
      <h2 style={{ marginTop: 0 }}>{opening ? `${t('open.edit')}: ${opening.code}` : t('open.new')}</h2>
      <div className="form-grid">
        <Field label={t('lens.state')} htmlFor="of-state"><select id="of-state" value={f.state_id} onChange={(e) => setF({ ...f, state_id: e.target.value, client_id: '', scope_id: '' })} required>
          <option value="">—</option>{(states.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
        <Field label={t('open.role')} htmlFor="of-role"><select id="of-role" value={f.role} onChange={set('role')}>
          {HIRE_ROLES.map((r) => <option key={r} value={r}>{t(`role.${r}`)}</option>)}</select></Field>
        <Field label={t('open.positions')} htmlFor="of-pos"><input id="of-pos" type="number" min={1} max={f.role === 'state_manager' ? 1 : 5000} value={f.positions} onChange={set('positions')} required data-testid="of-positions" /></Field>
        {needsClient && <Field label={t('lens.client')} hint={t('common.optional')} htmlFor="of-client"><select id="of-client" value={f.client_id} onChange={(e) => setF({ ...f, client_id: e.target.value, scope_id: '' })}>
          <option value="">{t('open.any_client')}</option>{(clients.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>}
        {needsScope && <Field label={t('lens.scope')} hint={t('common.optional')} htmlFor="of-scope"><select id="of-scope" value={f.scope_id} onChange={set('scope_id')}>
          <option value="">{t('open.any_scope')}</option>{(scopes.data ?? []).filter((x) => !f.client_id || x.client_id === f.client_id).map((x) => (
            <option key={x.id} value={x.id}>{x.season_code} · {x.geography}{x.status === 'draft' ? ` (${t('open.draft')})` : ''}</option>))}</select></Field>}
        {f.role === 'operator' && <Field label={t('open.stage')} htmlFor="of-stage"><select id="of-stage" value={f.stage} onChange={set('stage')} required>
          <option value="">—</option>{stageChoices.map((s) => <option key={s} value={s}>{stage(s)}</option>)}</select></Field>}
        <Field label={t('open.target_join')} hint={t('common.optional')} htmlFor="of-join"><input id="of-join" type="date" value={f.target_join} onChange={set('target_join')} /></Field>
        <Field label={t('open.title_f')} hint={t('common.optional')} htmlFor="of-title"><input id="of-title" value={f.title} onChange={set('title')} maxLength={120} /></Field>
      </div>
      <ErrorBox error={act.error} />
      <p className="row"><button type="submit" disabled={act.busy} data-testid="save-opening">{t('common.save')}</button>
        <button type="button" className="secondary" onClick={done}>{t('common.cancel')}</button></p>
    </form>
  );
}

/** The HR Admin (or the Deputy) seats the State Managers who have joined for this state. */
function SeatReady({ stateId, onDone }: { stateId: string; onDone: () => void }) {
  const { t } = useI18n();
  return <ReadyToAssign lens="state" target={stateId} opRole="state_supervisor" title={t('ready.seat_title')} onDone={onDone} />;
}

export function DeputyCard() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const isHrAdmin = ctx?.user?.system_role === 'hr_admin';
  const d = useAsync(() => rpc<{ id: string; name: string } | null>('sm_deputy'), []);
  const hr = useHrPeople();
  const [pick, setPick] = useState('');
  const act = useAction();
  const save = (id: string | null) => act.run(async () => { await rpc('set_sm_deputy', { p_employee: id }); setPick(''); await d.reload(); });
  return (
    <div className="card" data-testid="deputy-card">
      <h2 style={{ marginTop: 0 }}>{t('deputy.title')}</h2>
      <p className="small muted">{t('deputy.note')}</p>
      <p data-testid="deputy-now">{d.data ? <><strong>{d.data.name}</strong> {isHrAdmin && <button type="button" className="secondary small-btn" disabled={act.busy} onClick={() => void save(null)} data-testid="deputy-clear">{t('deputy.clear')}</button>}</> : <span className="muted">{t('deputy.none')}</span>}</p>
      {isHrAdmin && <div className="row">
        <select aria-label={t('deputy.title')} value={pick} onChange={(e) => setPick(e.target.value)} data-testid="deputy-pick">
          <option value="">—</option>{(hr.data ?? []).filter((p) => p.id !== ctx?.user?.id).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select>
        <button type="button" disabled={!pick || act.busy} onClick={() => void save(pick)} data-testid="deputy-set">{t('deputy.set')}</button></div>}
      <ErrorBox error={act.error} />
    </div>
  );
}

// ── "ready to assign", and several people on one assignment ─────────────────────────────────────────────────────────
interface Ready { employee_id: string; name: string; phone: string | null; role: HireRole; stage: StageType | null; opening_code: string; op_role: OpRole }
interface ManyResult { done: number; results: { id: string; ok: boolean; error?: string }[] }
/** People who joined for this state, client or scope and have not been given it; tick and give it to all in one act. */
export function ReadyToAssign({ lens, target, opRole, title, stages, onDone }:
  { lens: Lens; target: string; opRole: OpRole; title?: string; stages?: StageType[]; onDone?: () => void }) {
  const { t } = useI18n();
  const stage = useStageName();
  const r = useAsync(() => rpc<Ready[]>('ready_to_assign', { p_lens: lens, p_target: target }), [lens, target]);
  const [pick, setPick] = useState<Set<string>>(new Set());
  const [st, setSt] = useState<StageType | ''>('');
  const [res, setRes] = useState<ManyResult | null>(null);
  const act = useAction();
  const list = (r.data ?? []).filter((p) => lens !== 'scope' || !st || p.stage === st || p.stage === null);
  useEffect(() => { if (!st && stages?.length && r.data?.length) setSt((r.data.find((p) => p.stage)?.stage ?? stages[0]) as StageType); }, [r.data, stages, st]);
  if (r.loading && !r.data) return <Loading />;
  if (r.error) return null;                                          // not the reader's to assign: nothing to show
  if (!r.data?.length && !res) return null;
  const give = () => act.run(async () => {
    const ids = list.filter((p) => pick.has(p.employee_id)).map((p) => p.employee_id);
    const role = lens === 'scope' ? (list.find((p) => pick.has(p.employee_id))?.op_role ?? 'operator') : opRole;
    setRes(await rpc<ManyResult>('assign_many', { p_employees: ids, p_lens: lens, p_target: target, p_op_role: role,
      p_stages: lens === 'scope' && role === 'operator' ? [st] : [] }));
    setPick(new Set()); await r.reload(); onDone?.();
  });
  const allOn = list.length > 0 && list.every((p) => pick.has(p.employee_id));
  return (
    <div className="card" data-testid="ready-to-assign" data-lens={lens}>
      <h2 style={{ marginTop: 0 }}>{title ?? t('ready.title')} <span className="muted small">({r.data?.length ?? 0})</span></h2>
      <p className="small muted">{t('ready.note')}</p>
      {lens === 'scope' && stages && <Field label={t('open.stage')} htmlFor={`rta-stage-${target}`}><select id={`rta-stage-${target}`} value={st} onChange={(e) => { setSt(e.target.value as StageType); setPick(new Set()); }} data-testid="ready-stage">
        {stages.map((s) => <option key={s} value={s}>{stage(s)} ({(r.data ?? []).filter((p) => p.stage === s).length})</option>)}</select></Field>}
      {list.length > 0 && <label className="check"><input type="checkbox" checked={allOn} onChange={(e) => setPick(e.target.checked ? new Set(list.map((p) => p.employee_id)) : new Set())} data-testid="ready-all" />{t('ready.all', { n: list.length })}</label>}
      <ul className="ready-list">{list.map((p) => (
        <li key={p.employee_id}><label className="check"><input type="checkbox" checked={pick.has(p.employee_id)} data-testid="ready-person"
          onChange={(e) => { const n = new Set(pick); if (e.target.checked) n.add(p.employee_id); else n.delete(p.employee_id); setPick(n); }} />
          {p.name} <span className="small muted">{p.opening_code}{p.stage ? ` · ${stage(p.stage)}` : ''}</span></label></li>))}</ul>
      <button type="button" disabled={act.busy || pick.size === 0 || (lens === 'scope' && !st)} onClick={() => void give()} data-testid="ready-assign">
        {lens === 'scope' ? t('ready.assign_stage', { n: pick.size, stage: st ? stage(st) : '' }) : t('ready.assign', { n: pick.size })}</button>
      {res && <ManyOutcome res={res} names={Object.fromEntries((r.data ?? []).map((p) => [p.employee_id, p.name]))} />}
      <ErrorBox error={act.error} />
    </div>
  );
}

export function ManyOutcome({ res, names }: { res: ManyResult; names?: Record<string, string> }) {
  const { t } = useI18n();
  const bad = res.results.filter((x) => !x.ok);
  return (
    <div className={`alert ${bad.length ? 'warn' : 'ok'}`} role="status" data-testid="bulk-outcome">
      {t('bulk.done', { n: res.done, of: res.results.length })}
      {bad.length > 0 && <ul className="small">{bad.slice(0, 20).map((x) => <li key={x.id}>{names?.[x.id] ?? x.id}: {bulkError(x.error) ? t(bulkError(x.error)!, undefined, x.error ?? '') : x.error}</li>)}</ul>}
    </div>
  );
}

// ── invites: the links, to copy or show as a QR code ────────────────────────────────────────────────────────────────
export function InviteResults({ results, skipped, mail }: { results: InviteResult[]; skipped?: { id: string; name: string | null; reason: string }[]; mail: boolean }) {
  const { t } = useI18n();
  const [qr, setQr] = useState<Record<string, string>>({});
  const [copied, setCopied] = useState('');
  const copy = async (text: string, what: string) => { try { await navigator.clipboard.writeText(text); setCopied(what); } catch { setCopied(''); } };
  const show = async (r: InviteResult) => {
    if (!r.link) return;
    const QR = (await import('qrcode')).default;
    setQr({ ...qr, [r.id]: await QR.toDataURL(r.link, { margin: 1, width: 220 }) });
  };
  const emailed = results.filter((r) => r.sent === 'email').length;
  return (
    <div className="card" data-testid="invite-results">
      <h2 style={{ marginTop: 0 }}>{t('inv.made', { n: results.length })}</h2>
      <p className="small">{mail ? t('inv.emailed', { n: emailed }) : t('inv.no_sender')}</p>
      <p className="small muted">{t('inv.once')}</p>
      {results.length > 1 && <p><button type="button" className="secondary" onClick={() => void copy(linksText(results), 'all')} data-testid="copy-all">{t('inv.copy_all')}</button>
        {copied === 'all' && <span className="small ok-text"> {t('inv.copied')}</span>}</p>}
      <ul className="invite-list">{results.map((r) => (
        <li key={r.id} data-testid="invite-row" data-sent={r.sent}>
          <strong>{r.name}</strong> <Badge value={r.sent === 'email' ? 'verified' : r.sent === 'failed' ? 'closed' : 'draft'} label={t(`inv.sent_${r.sent}`)} />
          {r.link && <div className="row">
            <input readOnly value={r.link} aria-label={`${t('inv.link')}: ${r.name}`} className="link-box" data-testid="invite-link" onFocus={(e) => e.target.select()} />
            <button type="button" className="secondary small-btn" onClick={() => void copy(r.link!, r.id)}>{t('inv.copy')}</button>
            <button type="button" className="secondary small-btn" onClick={() => void show(r)}>{t('inv.qr')}</button>
            {copied === r.id && <span className="small ok-text">{t('inv.copied')}</span>}</div>}
          {qr[r.id] && <img src={qr[r.id]} alt={`${t('inv.qr')}: ${r.name}`} width={220} height={220} />}
        </li>))}</ul>
      {skipped && skipped.length > 0 && <p className="small muted" data-testid="invite-skipped">{t('inv.skipped', { n: skipped.length })}: {skipped.map((s) => `${s.name ?? '—'} (${t(`inv.why_${s.reason}`, undefined, s.reason)})`).join(', ')}</p>}
    </div>
  );
}

// ── the import ───────────────────────────────────────────────────────────────────────────────────────────────────────
export function ImportJoiners() {
  const { t } = useI18n();
  const stage = useStageName();
  const open = useAsync(() => rpc<OpeningsSummary>('openings_summary', {}), []);
  const [rows, setRows] = useState<Record<string, string>[] | null>(null);
  const [file, setFile] = useState('');
  const [res, setRes] = useState<ImportResult | null>(null);
  const [inv, setInv] = useState<Awaited<ReturnType<typeof sendInvites>> | null>(null);
  const [show, setShow] = useState<'all' | 'problems'>('problems');
  const act = useAction();
  const template = () => {
    const openings = (open.data?.openings ?? []).filter((o) => o.status === 'open' && o.vacant > 0);   // G4: no full opening
    return writeXlsxFile([
      [IMPORT_COLUMNS.map((c) => ({ value: c, fontWeight: 'bold' as const })),
        ['Ram Kumar', 'ram.kumar@example.com', '9876543210', '2026-11-01', 'full_time', 'B1', 'Field operations', 'Field Operator', '', openings[0]?.code ?? 'UP-OPR-001',
          openings[0]?.state_name ?? 'Uttar Pradesh', 'Basti'].map((v) => ({ value: v }))],
      [[{ value: 'code', fontWeight: 'bold' as const }, { value: 'state', fontWeight: 'bold' as const }, { value: 'role', fontWeight: 'bold' as const },
        { value: 'stage', fontWeight: 'bold' as const }, { value: 'vacant', fontWeight: 'bold' as const }],
        ...openings.map((o) => [{ value: o.code }, { value: o.state_name }, { value: t(`role.${o.role}`) }, { value: o.stage ? stage(o.stage) : '' }, { value: o.vacant }])],
    ], { sheets: ['joiners', 'openings'], fileName: 'grainveda_joiners_template.xlsx' });
  };
  const choose = (f: File | undefined) => act.run(async () => {
    setRes(null); setRows(null); setInv(null);
    if (!f) return;
    setFile(f.name);
    const r = joinerRows((await readXlsxFile(f)) as unknown[][]);
    setRows(r);
    setRes(await rpc<ImportResult>('import_joiners', { p_rows: r, p_dry_run: true }));
  });
  const commit = () => act.run(async () => {
    setRes(await rpc<ImportResult>('import_joiners', { p_rows: rows, p_dry_run: false, p_batch: file.slice(0, 40) }));
    setRows(null);
  });
  const invite = () => act.run(async () => { setInv(await sendInvites((res?.rows ?? []).filter((r) => r.created && r.id).map((r) => r.id!))); });
  const shown = (res?.rows ?? []).filter((r) => show === 'all' || r.status !== 'ready');
  const c = res?.counts;
  return (
    <div style={{ maxWidth: 980 }}>
      <div className="page-hd"><h1><span aria-hidden="true">📥 </span>{t('imp.title')}</h1><div className="sub">{t('imp.sub')}</div></div>
      <HrLinks here="import" />
      <HrScopeNote />
      <div className="card">
        <ol className="steps-list">
          <li><button type="button" className="secondary" onClick={() => void template()} data-testid="imp-template">{t('imp.template')}</button> <span className="small muted">{t('imp.template_note')}</span></li>
          <li><Field label={t('imp.file')} htmlFor="imp-file"><input id="imp-file" type="file" accept=".xlsx" onChange={(e) => void choose(e.target.files?.[0])} /></Field></li>
          <li className="small muted">{t('imp.rules')}</li>
        </ol>
      </div>
      {act.busy && <Loading />}
      <ErrorBox error={act.error} />
      {res && c && <div className="card" data-testid="imp-result" data-dry={String(res.dry_run)}>
        <h2 style={{ marginTop: 0 }}>{res.dry_run ? t('imp.preview', { file }) : t('imp.done', { n: c.created })}</h2>
        <div className="stats">{(['ready', 'warning', 'error', 'skipped'] as const).map((k) => (
          <div className="stat" key={k}><div className="stat-val" data-testid={`imp-n-${k}`}>{c[k]}</div><div className="stat-label">{t(`imp.s_${k}`)}</div></div>))}
          {!res.dry_run && <div className="stat"><div className="stat-val" data-testid="imp-n-created">{c.created}</div><div className="stat-label">{t('imp.s_created')}</div></div>}</div>
        <div className="tabs" role="tablist">{(['problems', 'all'] as const).map((k) => (
          <button key={k} type="button" role="tab" aria-selected={show === k} className={show === k ? 'active' : ''} onClick={() => setShow(k)}>{t(`imp.show_${k}`)}</button>))}</div>
        {shown.length === 0 ? <p className="small muted">{t('imp.no_problems')}</p> : <div className="table-wrap"><table className="wide" data-testid="imp-rows">
          <thead><tr><th>{t('imp.col_row')}</th><th>{t('hr.col_joiner')}</th><th>{t('open.col_opening')}</th><th>{t('common.status')}</th><th>{t('imp.col_why')}</th></tr></thead>
          <tbody>{shown.slice(0, 500).map((r) => (
            <tr key={r.row} data-testid="imp-row" data-status={r.status}>
              <td className="num">{r.row + 1}</td><td>{r.name || '—'}<div className="small muted">{r.email ?? ''}</div></td>
              <td className="small">{r.opening ?? '—'}{r.role ? <div className="muted"><RoleLabel role={r.role} stage={r.stage} /></div> : null}
                {r.state && <div className="muted" data-testid="imp-row-state">{r.state}</div>}</td>
              <td><Badge value={r.status === 'ready' ? 'verified' : r.status === 'warning' ? 'pending' : r.status === 'skipped' ? 'draft' : 'closed'} label={t(`imp.s_${r.status}`)} /></td>
              <td className="small">{r.reasons.map((k) => t(k, undefined, k)).join(' · ')}</td>
            </tr>))}</tbody>
        </table></div>}
        {res.dry_run && rows && (c.ready + c.warning > 0) && <p><button type="button" disabled={act.busy} onClick={() => void commit()} data-testid="imp-commit">{t('imp.commit', { n: c.ready + c.warning })}</button>
          <span className="small muted"> {t('imp.commit_note')}</span></p>}
        {!res.dry_run && c.created > 0 && !inv && <p><button type="button" disabled={act.busy} onClick={() => void invite()} data-testid="imp-invite">{t('imp.invite', { n: c.created })}</button>
          <Link className="btn secondary" to={`/hr?status=joining`}>{t('imp.to_list')}</Link></p>}
      </div>}
      {inv && <InviteResults {...inv} />}
    </div>
  );
}

// ── the joiners list ─────────────────────────────────────────────────────────────────────────────────────────────────
const HR_CODES = ['countersign', 'it_setup', 'buddy', 'goals'];
export function JoinersList() {
  const { t } = useI18n();
  const stage = useStageName();
  const { ctx } = useAuth();
  const can = ctx?.user?.can ?? NO_RIGHTS;
  const [params, setParams] = useSearchParams();
  const [f, setF] = useState<JoinerFilter>({ ...NO_FILTER, opening: params.get('opening') ?? '', status: (params.get('status') as JoinerFilter['status']) ?? '' });
  const [text, setText] = useState('');
  const [page, setPage] = useState(0);
  const states = useStates();
  const open = useAsync(() => rpc<OpeningsSummary>('openings_summary', {}).catch(() => null), []);
  const list = useAsync(() => rpc<JoinersPage>('joiners_page', { p: filterArgs(f, PAGE, page * PAGE) }), [JSON.stringify(f), page]);
  const reminders = useAsync(async () => { await callFunction('invite', { action: 'reminders' }).catch(() => null); return rpc<{ queued: number } | null>('reminder_state'); }, []);
  const [sel, setSel] = useState<Set<string>>(new Set());
  useEffect(() => { const h = setTimeout(() => { setF((x) => x.q === text ? x : { ...x, q: text }); setPage(0); }, 300); return () => clearTimeout(h); }, [text]);
  const setFilter = (p: Partial<JoinerFilter>) => { setF({ ...f, ...p }); setPage(0); setSel(new Set());
    if ('opening' in p) { const n = new URLSearchParams(params); if (p.opening) n.set('opening', p.opening); else n.delete('opening'); setParams(n, { replace: true }); } };
  const x = list.data;
  const rows = x?.rows ?? [];
  const pages = pageCount(x?.total ?? 0, PAGE);
  const allOn = rows.length > 0 && rows.every((r) => sel.has(r.id));
  return (
    <div>
      <div className="page-hd"><h1><span aria-hidden="true">🧑‍💼 </span>{t('hr.pipeline_title')}</h1><div className="sub">{t('hr.pipeline_sub')}</div></div>
      <RoleGuide role={ctx?.user?.system_role === 'hr_admin' ? 'hr_admin' : 'hr_resource'} />
      <HrScopeNote />
      <p className="row">
        <Link className="btn" to="/hr/joiners/new" data-testid="add-joiner">{t('hr.add_joiner')}</Link>
        <Link className="btn secondary" to="/hr/import" data-testid="to-import">{t('imp.title')}</Link>
        <Link className="btn secondary" to="/hr/openings">{t('open.title')}</Link>
        <Link className="btn secondary" to="/hr/templates">{t('hr.templates')}</Link>
        {(can.assign || can.hr) && <Link className="btn secondary" to="/people">{t('nav.people')}</Link>}
      </p>
      {x && <div className="stats" data-testid="hr-stats">
        <button type="button" className="stat" onClick={() => setFilter({ status: 'joining' })}><div className="stat-val">{x.stats.joining}</div><div className="stat-label">{t('hr.kpi_joining')}</div><div className="stat-sub">{t('hr.kpi_joining_sub')}</div></button>
        <button type="button" className="stat" onClick={() => setFilter({ waiting: 'us' })}><div className="stat-val">{x.stats.on_us}</div><div className="stat-label">{t('hr.kpi_on_us')}</div><div className="stat-sub">{t('hr.kpi_on_us_sub')}</div></button>
        <button type="button" className="stat" onClick={() => setFilter({ waiting: 'joiner' })}><div className="stat-val">{x.stats.on_them}</div><div className="stat-label">{t('hr.kpi_on_them')}</div><div className="stat-sub">{t('hr.kpi_on_them_sub')}</div></button>
        <button type="button" className="stat" onClick={() => setFilter({ overdue: true })}><div className="stat-val">{x.stats.overdue}</div><div className="stat-label">{t('hr.kpi_overdue')}</div><div className="stat-sub">{t('hr.kpi_overdue_sub')}</div></button>
        <button type="button" className="stat" onClick={() => setFilter({ owner: 'mine' })} data-testid="kpi-mine"><div className="stat-val">{x.stats.mine}</div><div className="stat-label">{t('jl.mine')}</div><div className="stat-sub">{t('jl.mine_sub')}</div></button>
      </div>}
      {reminders.data && reminders.data.queued > 0 && <p className="small muted" data-testid="reminders-waiting">{t('jl.reminders_waiting', { n: reminders.data.queued })}</p>}
      <div className="filters" data-testid="joiner-filters">
        <Field label={t('people.search')} htmlFor="jf-q"><input id="jf-q" type="search" value={text} onChange={(e) => setText(e.target.value)} placeholder={t('jl.search_hint')} /></Field>
        <Field label={t('jl.owner')} htmlFor="jf-owner"><select id="jf-owner" value={f.owner} onChange={(e) => setFilter({ owner: e.target.value as JoinerFilter['owner'] })}>
          <option value="">{t('jl.owner_all')}</option><option value="mine">{t('jl.mine')}</option><option value="none">{t('jl.owner_none')}</option></select></Field>
        <Field label={t('lens.state')} htmlFor="jf-state"><select id="jf-state" value={f.state} onChange={(e) => setFilter({ state: e.target.value })}>
          <option value="">{t('people.any_state')}</option>{(states.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
        <Field label={t('open.role')} htmlFor="jf-role"><select id="jf-role" value={f.role} onChange={(e) => setFilter({ role: e.target.value })}>
          <option value="">{t('jl.any_role')}</option>{HIRE_ROLES.map((r) => <option key={r} value={r}>{t(`role.${r}`)}</option>)}</select></Field>
        <Field label={t('open.col_opening')} htmlFor="jf-open"><select id="jf-open" value={f.opening} onChange={(e) => setFilter({ opening: e.target.value })}>
          <option value="">{t('jl.any_opening')}</option>{(open.data?.openings ?? []).map((o) => <option key={o.id} value={o.id}>{o.code} · {t(`role.${o.role}`)}{o.stage ? ` · ${stage(o.stage)}` : ''}</option>)}</select></Field>
        <Field label={t('common.status')} htmlFor="jf-status"><select id="jf-status" value={f.status} onChange={(e) => setFilter({ status: e.target.value as JoinerFilter['status'] })}>
          <option value="">{t('people.any_status')}</option>{(['joining', 'invited', 'onboarding', 'active'] as const).map((s) => <option key={s} value={s}>{t(`jl.status_${s}`)}</option>)}</select></Field>
        <Field label={t('jl.waiting')} htmlFor="jf-wait"><select id="jf-wait" value={f.waiting} onChange={(e) => setFilter({ waiting: e.target.value as JoinerFilter['waiting'] })}>
          <option value="">—</option>{(['us', 'joiner', 'it'] as const).map((w) => <option key={w} value={w}>{t(`jl.waiting_${w}`)}</option>)}</select></Field>
        <label className="check"><input type="checkbox" checked={f.overdue} onChange={(e) => setFilter({ overdue: e.target.checked })} data-testid="jf-overdue" />{t('jl.overdue_only')}</label>
        {JSON.stringify(f) !== JSON.stringify(NO_FILTER) && <button type="button" className="secondary small-btn" onClick={() => { setText(''); setFilter({ ...NO_FILTER }); }}>{t('jl.clear')}</button>}
      </div>
      {sel.size > 0 && <BulkBar ids={[...sel]} rows={rows} done={() => void list.reload()} clear={() => setSel(new Set())} />}
      {list.loading && !x ? <Loading /> : <ErrorBox error={list.error} onRetry={() => void list.reload()} />}
      {x && (rows.length === 0 ? <Empty>{t('hr.pipeline_empty')}</Empty> : (
        <div className="card table-wrap"><table className="wide" data-testid="pipeline">
          <thead><tr><th><input type="checkbox" aria-label={t('jl.select_page')} checked={allOn} onChange={(e) => setSel(e.target.checked ? new Set(rows.map((r) => r.id)) : new Set())} data-testid="select-page" /></th>
            <th>{t('hr.col_joiner')}</th><th>{t('jl.col_role')}</th><th>{t('hr.col_joins')}</th><th>{t('hr.col_progress')}</th><th>{t('hr.col_waiting')}</th><th>{t('common.status')}</th></tr></thead>
          <tbody>{rows.map((r) => {
            const jw = joinWords(r.status, r.days_to_join);
            return (
              <tr key={r.id} data-testid="pipeline-row">
                <td><input type="checkbox" aria-label={`${t('jl.select')}: ${r.name}`} checked={sel.has(r.id)} data-testid="select-row"
                  onChange={(e) => { const n = new Set(sel); if (e.target.checked) n.add(r.id); else n.delete(r.id); setSel(n); }} /></td>
                <td><Link to={`/hr/joiners/${r.id}`}><strong>{r.name}</strong></Link>
                  <div className="small muted">{[r.job_title, r.hr_owner_name && t('jl.owner_is', { name: r.hr_owner_name })].filter(Boolean).join(' · ')}</div></td>
                <td className="small" data-testid="pipeline-role"><RoleLabel role={r.role} stage={r.stage} />{r.opening_code && <div className="muted">{r.opening_code}{r.state_name ? ` · ${r.state_name}` : ''}</div>}</td>
                <td>{date(r.join_date)}<div className="small muted" data-testid="pipeline-when">{t(jw === 'join.date' ? 'jl.joining_date' : jw, { n: Math.abs(r.days_to_join ?? 0), d: date(r.join_date) })}</div></td>
                <td><div className="bar" role="img" aria-label={`${r.pct} %`}><span style={{ width: `${r.pct}%` }} /></div>
                  <div className="small muted" data-testid="pipeline-pct">{t('hr.done_of', { done: r.done, total: r.total, pct: r.pct })}</div></td>
                <td data-testid="pipeline-waiting">{r.blocked_by ? <>{waitingOn(r).map((o) => <span key={o}><Owner owner={o} /> </span>)}<span className="small"><TaskTitle task={{ code: taskKey(r.next_task), title: r.next_task ?? '' }} /></span>
                  <div className={`small ${r.overdue > 0 ? 'gap' : 'muted'}`}>{t('hr.due', { d: date(r.next_due) })}{r.overdue > 0 ? ` · ${t('hr.overdue_n', { n: r.overdue })}` : ''}</div></>
                  : <span className="muted">{t('hr.nothing_open')}</span>}</td>
                <td><StatusBadge status={r.status} />{r.invite ? <div className="small muted" data-testid="pipeline-invite">{t(`inv.state_${r.invite.state}`)}</div>
                  : r.status === 'invited' && <div className="small muted">{t(r.has_login ? 'hr.awaiting_first' : 'jl.no_invite')}</div>}</td>
              </tr>);
          })}</tbody>
        </table></div>))}
      {x && x.total > PAGE && <p className="row pager" data-testid="pager">
        <button type="button" className="secondary" disabled={page === 0} onClick={() => setPage(page - 1)}>{t('jl.prev')}</button>
        <span className="small" data-testid="pager-text">{t('jl.page', { page: page + 1, pages, total: x.total })}</span>
        <button type="button" className="secondary" disabled={page + 1 >= pages} onClick={() => setPage(page + 1)}>{t('jl.next')}</button></p>}
      {x && x.total <= PAGE && rows.length > 0 && <p className="small muted" data-testid="pager-text">{t('jl.count', { n: x.total })}</p>}
    </div>
  );
}

/** What HR does for the chosen joiners at once; each person is done on their own and logged on their own. */
// The outcome stays on screen with the choice still made (the list reloads under it); "Clear" ends it.
function BulkBar({ ids, rows, done, clear }: { ids: string[]; rows: JoinersPage['rows']; done: () => void; clear: () => void }) {
  const { t } = useI18n();
  const hr = useHrPeople();
  const [mode, setMode] = useState<'' | 'invite' | 'task' | 'first_day' | 'owner' | 'join'>('');
  const [code, setCode] = useState('countersign');
  const [owner, setOwner] = useState('');
  const [why, setWhy] = useState('');
  const [fd, setFd] = useState({ first_day_date: '', first_day_time: '', first_day_place: '', first_day_ask_for: '', first_day_bring: '' });
  const [res, setRes] = useState<ManyResult | null>(null);
  const [inv, setInv] = useState<Awaited<ReturnType<typeof sendInvites>> | null>(null);
  const act = useAction();
  const names = Object.fromEntries(rows.map((r) => [r.id, r.name]));
  const run = (fn: () => Promise<ManyResult>) => act.run(async () => { setRes(await fn()); setInv(null); done(); });
  const forms: Record<string, ReactNode> = {
    task: <div className="row"><select aria-label={t('bulk.which_step')} value={code} onChange={(e) => setCode(e.target.value)} data-testid="bulk-step">
      {HR_CODES.map((c) => <option key={c} value={c}>{t(`task.${c}`)}</option>)}</select>
      <button type="button" disabled={act.busy} onClick={() => void run(() => rpc<ManyResult>('complete_task_many', { p_employees: ids, p_code: code, p_data: {} }))} data-testid="bulk-go">{t('bulk.mark_done', { n: ids.length })}</button></div>,
    owner: <div className="row"><select aria-label={t('jl.owner')} value={owner} onChange={(e) => setOwner(e.target.value)} data-testid="bulk-owner">
      <option value="">{t('jl.owner_none')}</option>{(hr.data ?? []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select>
      <button type="button" disabled={act.busy} onClick={() => void run(() => rpc<ManyResult>('set_hr_owner', { p_employees: ids, p_owner: owner || null }))} data-testid="bulk-go">{t('bulk.set_owner', { n: ids.length })}</button></div>,
    first_day: <div className="form-grid">
      <Field label={t('day1.date')} htmlFor="bf-date"><input id="bf-date" type="date" value={fd.first_day_date} onChange={(e) => setFd({ ...fd, first_day_date: e.target.value })} /></Field>
      <Field label={t('day1.time')} htmlFor="bf-time"><input id="bf-time" value={fd.first_day_time} onChange={(e) => setFd({ ...fd, first_day_time: e.target.value })} maxLength={40} /></Field>
      <Field label={t('day1.place')} htmlFor="bf-place"><input id="bf-place" value={fd.first_day_place} onChange={(e) => setFd({ ...fd, first_day_place: e.target.value })} /></Field>
      <Field label={t('day1.ask_for')} htmlFor="bf-ask"><input id="bf-ask" value={fd.first_day_ask_for} onChange={(e) => setFd({ ...fd, first_day_ask_for: e.target.value })} /></Field>
      <Field label={t('day1.bring')} htmlFor="bf-bring"><input id="bf-bring" value={fd.first_day_bring} onChange={(e) => setFd({ ...fd, first_day_bring: e.target.value })} /></Field>
      <button type="button" disabled={act.busy} onClick={() => void run(() => rpc<ManyResult>('update_joiner_many', { p_employees: ids,
        p: Object.fromEntries(Object.entries(fd).filter(([, v]) => v.trim() !== '')) }))} data-testid="bulk-go">{t('bulk.set_first_day', { n: ids.length })}</button></div>,
    join: <div><p className="small muted">{t('bulk.join_note')}</p><div className="row">
      <input aria-label={t('gate.reason')} placeholder={t('gate.reason')} value={why} onChange={(e) => setWhy(e.target.value)} style={{ flex: 1, minWidth: 0 }} data-testid="bulk-reason" />
      <button type="button" disabled={act.busy} onClick={() => void run(() => rpc<ManyResult>('activate_many', { p_employees: ids, p_reason: why.trim() || null }))} data-testid="bulk-go">{t('bulk.mark_joined', { n: ids.length })}</button></div></div>,
  };
  return (
    <div className="card bulk-bar" data-testid="bulk-bar">
      <div className="row"><strong>{t('bulk.chosen', { n: ids.length })}</strong>
        {(['invite', 'task', 'first_day', 'owner', 'join'] as const).map((m) => (
          <button key={m} type="button" className={mode === m ? '' : 'secondary'} onClick={() => { setMode(m); setRes(null);
            if (m === 'invite') void act.run(async () => { setInv(await sendInvites(ids)); done(); }); }} data-testid={`bulk-${m}`}>{t(`bulk.${m}`)}</button>))}
        <button type="button" className="secondary" onClick={clear} data-testid="bulk-clear">{t('jl.clear')}</button></div>
      {mode && mode !== 'invite' && forms[mode]}
      <ErrorBox error={act.error} />
      {res && <ManyOutcome res={res} names={names} />}
      {inv && <InviteResults {...inv} />}
    </div>
  );
}
