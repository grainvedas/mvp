// The State Manager's open requirements (migration 46, Veda 14 Oct 2026, section C): by client, each line and its
// status, the scopes' and his own; he asks for people for his state ("Request people"), answers HR's question,
// withdraws a line. A client with no Client Manager has its line by itself, in his name.
import { useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { rpc } from '../../lib/api';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { todayIST } from '../../lib/format';
import { LINE_ROLES, type Requirement, type RequirementLine } from '../../lib/requirements';
import { STAGE_ICON } from '../../engine/icons';
import type { StageType } from '../../lib/types';
import { Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { useStageName } from '../people/shared';
import { LineStatusText, LineWhat } from '../hr/Requirements';

type StateReq = Requirement & { lines: RequirementLine[] | null };
const STAGES = Object.keys(STAGE_ICON) as StageType[];
const in14 = () => { const d = new Date(`${todayIST()}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + 14); return d.toISOString().slice(0, 10); };

export function StateRequirements({ stateId, clients }: { stateId: string; clients: { id: string; name: string }[] }) {
  const { t } = useI18n();
  const r = useAsync(() => rpc<StateReq[]>('state_requirements', { p_state: stateId }).catch(() => null), [stateId]);
  const act = useAction();
  const [asking, setAsking] = useState(false);
  const [answering, setAnswering] = useState<string | null>(null);
  const [answer, setAnswer] = useState('');
  if (r.loading && !r.data) return <Loading />;
  if (!r.data) return null;                                   // a server before migration 46
  const byClient = new Map<string, StateReq[]>();
  for (const q of r.data) byClient.set(q.client_name ?? '', [...(byClient.get(q.client_name ?? '') ?? []), q]);
  const reply = (l: RequirementLine) => act.run(async () => {
    await rpc('requester_act', { p_line: l.id, p_action: 'answer', p: { answer: answer.trim() } }); setAnswering(null); setAnswer(''); await r.reload();
  });
  const withdraw = (l: RequirementLine) => act.run(async () => {
    if (!window.confirm(t('req.withdraw_confirm'))) return;
    await rpc('requester_act', { p_line: l.id, p_action: 'withdraw', p: {} }); await r.reload();
  });
  return (
    <div data-testid="sh-requirements">
      <div className="ov-hd"><h2 className="section-title">{t('req.state_title')}</h2>
        {!asking && <button type="button" className="secondary small-btn" onClick={() => setAsking(true)} data-testid="sh-request">{t('req.request')}</button>}</div>
      {asking && <StateRequestForm stateId={stateId} clients={clients} done={async () => { setAsking(false); await r.reload(); }} cancel={() => setAsking(false)} />}
      {r.data.length === 0 ? <Empty>{t('req.state_none')}</Empty> : (
        <div className="card">{[...byClient.entries()].map(([client, reqs]) => (
          <div key={client} data-testid="sh-req-client">
            <h3 style={{ margin: '6px 0' }}>{client || t('req.whole_state')}</h3>
            {reqs.map((q) => (
              <div key={q.id} data-testid="sh-req">
                {q.scope_id && <div className="small"><Link to={`/scopes/${q.scope_id}/roster`}>{q.scope_name}</Link></div>}
                <ul className="req-lines">{(q.lines ?? []).map((l) => (
                  <li key={l.id} data-testid="sh-req-line" data-status={l.shown}><LineWhat l={l} />{l.note && <span className="small muted"> · {l.note}</span>} · <LineStatusText l={l} />
                    {q.mine && l.status === 'returned' && answering !== l.id && <> <button type="button" className="small-btn" onClick={() => { setAnswering(l.id); setAnswer(''); }}>{t('req.answer')}</button></>}
                    {answering === l.id && <div className="row" style={{ marginTop: 4 }}>
                      <input aria-label={t('req.answer')} value={answer} maxLength={300} onChange={(e) => setAnswer(e.target.value)} />
                      <button type="button" className="small-btn" disabled={act.busy || answer.trim().length < 2} onClick={() => void reply(l)}>{t('req.send')}</button></div>}
                    {q.mine && q.kind !== 'scope' && ['requested', 'returned', 'held'].includes(l.status) && <> <button type="button" className="secondary small-btn" disabled={act.busy} onClick={() => void withdraw(l)}>{t('req.withdraw')}</button></>}
                  </li>))}</ul>
              </div>))}
          </div>))}</div>)}
      <ErrorBox error={act.error} />
    </div>
  );
}

function StateRequestForm({ stateId, clients, done, cancel }: { stateId: string; clients: { id: string; name: string }[]; done: () => Promise<void>; cancel: () => void }) {
  const { t } = useI18n();
  const stage = useStageName();
  const act = useAction();
  const [f, setF] = useState({ role: 'client_manager', stage: '', client_id: '', positions: '1', posting: '', needed_by: in14(), note: '' });
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });
  const send = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    await rpc('request_people', { p: { state_id: stateId, client_id: f.client_id || null,
      lines: [{ role: f.role, stage: f.role === 'operator' ? f.stage : null, positions: Number(f.positions), posting: f.posting, needed_by: f.needed_by, note: f.note }] } });
    await done();
  }); };
  return (
    <form className="card" onSubmit={send} aria-label={t('req.request')} data-testid="sh-request-form">
      <div className="form-grid">
        <Field label={t('open.role')} htmlFor="sr-role"><select id="sr-role" value={f.role} onChange={set('role')}>
          {LINE_ROLES.map((r) => <option key={r} value={r}>{t(`role.${r}`)}</option>)}</select></Field>
        {f.role === 'operator' && <Field label={t('open.stage')} htmlFor="sr-stage"><select id="sr-stage" value={f.stage} onChange={set('stage')} required>
          <option value="">—</option>{STAGES.map((s) => <option key={s} value={s}>{stage(s)}</option>)}</select></Field>}
        <Field label={t('lens.client')} hint={t('common.optional')} htmlFor="sr-client"><select id="sr-client" value={f.client_id} onChange={set('client_id')}>
          <option value="">{t('req.whole_state')}</option>{clients.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
        <Field label={t('req.people')} htmlFor="sr-pos"><input id="sr-pos" type="number" min={1} max={500} value={f.positions} onChange={set('positions')} required /></Field>
        <Field label={t('req.needed_by_label')} htmlFor="sr-by"><input id="sr-by" type="date" value={f.needed_by} onChange={set('needed_by')} required /></Field>
        <Field label={t('req.posting')} hint={t('common.optional')} htmlFor="sr-post"><input id="sr-post" value={f.posting} maxLength={120} onChange={set('posting')} /></Field>
        <Field label={t('req.note')} hint={t('common.optional')} htmlFor="sr-note"><input id="sr-note" value={f.note} maxLength={300} onChange={set('note')} /></Field>
      </div>
      <ErrorBox error={act.error} />
      <p className="row"><button type="submit" disabled={act.busy} data-testid="sr-send">{t('req.send_request')}</button>
        <button type="button" className="secondary" onClick={cancel}>{t('common.cancel')}</button></p>
    </form>
  );
}
