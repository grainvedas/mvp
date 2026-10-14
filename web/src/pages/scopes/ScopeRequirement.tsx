// What the Client Manager sees of his scope's requirement (migration 46, Veda 14 Oct 2026, section C): on the People
// step and the Roster, each empty stage with its line's status (Requested, Returned with HR's question, Published,
// Joining, Ready to assign, Filled …); "Save People step" raises the lines for the empty stages; "Request people" asks
// for more (a number at a stage, an export manager); he answers HR's question, or withdraws a line. The State Manager,
// HR and the admin read it. Every rule is the database's (tests/40_requirements.sql).
import { useState, type FormEvent } from 'react';
import { rpc } from '../../lib/api';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { todayIST } from '../../lib/format';
import { lineForStage, OPEN, type RequirementLine, type ScopeRequirement as SR } from '../../lib/requirements';
import type { StageType } from '../../lib/types';
import { ErrorBox, Field, Loading } from '../../shell/ui';
import { useStageName } from '../people/shared';
import { LineStatusText, LineWhat } from '../hr/Requirements';

const in14 = () => { const d = new Date(`${todayIST()}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + 14); return d.toISOString().slice(0, 10); };

/** The scope's requirement under its roster. `gaps`: the stages with nobody; `chain`: for "Request people". */
export function ScopeRequirementCard({ scopeId, chain, gaps, reloadKey, onChanged }:
  { scopeId: string; chain: StageType[]; gaps: StageType[]; reloadKey?: unknown; onChanged?: () => void }) {
  const { t } = useI18n();
  const stage = useStageName();
  const r = useAsync(() => rpc<SR>('scope_requirement', { p_scope: scopeId }).catch(() => null), [scopeId, String(reloadKey ?? '')]);
  const act = useAction();
  const [asking, setAsking] = useState(false);
  const [answering, setAnswering] = useState<string | null>(null);
  const [answer, setAnswer] = useState('');
  if (r.loading && !r.data) return <Loading />;
  if (!r.data) return null;                                  // a server before migration 46, or not his to read
  const x = r.data;
  const done = async () => { await r.reload(); onChanged?.(); };
  const save = () => act.run(async () => { await rpc('save_people_step', { p_scope: scopeId }); await done(); });
  const withdraw = (l: RequirementLine) => act.run(async () => {
    if (!window.confirm(t('req.withdraw_confirm'))) return;
    await rpc('requester_act', { p_line: l.id, p_action: 'withdraw', p: {} }); await done();
  });
  const reply = (l: RequirementLine) => act.run(async () => {
    await rpc('requester_act', { p_line: l.id, p_action: 'answer', p: { answer: answer.trim() } }); setAnswering(null); setAnswer(''); await done();
  });
  const empty = gaps.map((s) => ({ s, l: lineForStage(x.lines, s) }));
  const others = x.lines.filter((l) => !(l.stage && gaps.includes(l.stage) && lineForStage(x.lines, l.stage)?.id === l.id) && OPEN.includes(l.status));
  const row = (l: RequirementLine) => (
    <>
      <LineStatusText l={l} />
      {x.can_request && l.status === 'returned' && answering !== l.id && <button type="button" className="small-btn" onClick={() => { setAnswering(l.id); setAnswer(''); }} data-testid="req-answer">{t('req.answer')}</button>}
      {answering === l.id && <div className="row" style={{ marginTop: 4 }}>
        <input aria-label={t('req.answer')} value={answer} maxLength={300} onChange={(e) => setAnswer(e.target.value)} data-testid="req-answer-text" />
        <button type="button" className="small-btn" disabled={act.busy || answer.trim().length < 2} onClick={() => void reply(l)} data-testid="req-answer-send">{t('req.send')}</button>
        <button type="button" className="secondary small-btn" onClick={() => setAnswering(null)}>{t('common.cancel')}</button></div>}
      {x.can_request && ['requested', 'returned', 'held'].includes(l.status) && <> <button type="button" className="secondary small-btn" disabled={act.busy} onClick={() => void withdraw(l)} data-testid="req-withdraw">{t('req.withdraw')}</button></>}
    </>);
  return (
    <div className="card" data-testid="scope-req">
      <h3 style={{ marginTop: 0 }}>{t('req.scope_title')}</h3>
      {empty.length === 0 && others.length === 0 && <p className="small muted">{t('req.scope_none')}</p>}
      {empty.length > 0 && <ul className="req-lines">{empty.map(({ s, l }) => (
        <li key={s} id={`req-${s}`} data-testid="req-stage" data-stage={s} data-status={l?.shown ?? 'none'}>
          <strong>{stage(s)}</strong>: {l ? row(l) : <span className="muted small" data-testid="req-status" data-status="none">{t('req.not_asked')}</span>}
        </li>))}</ul>}
      {others.length > 0 && <><div className="small muted">{t('req.more_asked')}</div>
        <ul className="req-lines">{others.map((l) => <li key={l.id} data-testid="req-other"><LineWhat l={l} />{l.note && <span className="small muted"> · {l.note}</span>} · {row(l)}</li>)}</ul></>}
      {x.can_request && <div className="row">
        {gaps.some((s) => !lineForStage(x.lines, s) || !OPEN.includes(lineForStage(x.lines, s)!.status)) &&   // a stage not yet asked for
          <button type="button" disabled={act.busy} onClick={() => void save()} data-testid="save-people">{t('req.save_people')}</button>}
        {!asking && <button type="button" className="secondary" onClick={() => setAsking(true)} data-testid="request-people">{t('req.request')}</button>}
      </div>}
      {x.can_request && gaps.some((s) => !lineForStage(x.lines, s) || !OPEN.includes(lineForStage(x.lines, s)!.status)) && <p className="small muted">{t('req.save_note')}</p>}
      {asking && <RequestForm scopeId={scopeId} chain={chain} done={async () => { setAsking(false); await done(); }} cancel={() => setAsking(false)} />}
      <ErrorBox error={act.error} />
    </div>
  );
}

function RequestForm({ scopeId, chain, done, cancel }: { scopeId: string; chain: StageType[]; done: () => Promise<void>; cancel: () => void }) {
  const { t } = useI18n();
  const stage = useStageName();
  const act = useAction();
  const [f, setF] = useState({ role: 'operator', stage: '', positions: '1', posting: '', needed_by: in14(), note: '' });
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const send = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    await rpc('request_people', { p: { scope_id: scopeId, lines: [{ ...f, positions: Number(f.positions), stage: f.role === 'operator' ? f.stage : null }] } });
    await done();
  }); };
  return (
    <form onSubmit={send} className="stack" aria-label={t('req.request')} data-testid="request-form">
      <div className="form-grid">
        <Field label={t('open.role')} htmlFor="rp-role"><select id="rp-role" value={f.role} onChange={set('role')}>
          {(['operator', 'export_manager'] as const).map((r) => <option key={r} value={r}>{t(`role.${r}`)}</option>)}</select></Field>
        {f.role === 'operator' && <Field label={t('open.stage')} htmlFor="rp-stage"><select id="rp-stage" value={f.stage} onChange={set('stage')} required data-testid="rp-stage">
          <option value="">—</option>{chain.map((s) => <option key={s} value={s}>{stage(s)}</option>)}</select></Field>}
        <Field label={t('req.people')} htmlFor="rp-pos"><input id="rp-pos" type="number" min={1} max={500} value={f.positions} onChange={set('positions')} required data-testid="rp-positions" /></Field>
        <Field label={t('req.needed_by_label')} htmlFor="rp-by"><input id="rp-by" type="date" value={f.needed_by} onChange={set('needed_by')} required /></Field>
        <Field label={t('req.posting')} hint={t('common.optional')} htmlFor="rp-post"><input id="rp-post" value={f.posting} maxLength={120} onChange={set('posting')} /></Field>
        <Field label={t('req.note')} hint={t('common.optional')} htmlFor="rp-note"><input id="rp-note" value={f.note} maxLength={300} onChange={set('note')} /></Field>
      </div>
      <ErrorBox error={act.error} />
      <p className="row"><button type="submit" disabled={act.busy} data-testid="rp-send">{t('req.send_request')}</button>
        <button type="button" className="secondary" onClick={cancel}>{t('common.cancel')}</button></p>
    </form>
  );
}
