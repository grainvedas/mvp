// Production safeguards (migration 45, Veda 14 Oct 2026: "when in production … can such thing happen and not
// recorded?"). For the admin, and for the HR Admin as the second person who decides a correction:
//   · the change log: intact or not, and how the changes of the last 30 days came (app, server function, correction,
//     declared, direct);
//   · the changes made behind the app (direct, declared, corrections): when, which table, which database account,
//     which columns: never a value;
//   · corrections of live data: the admin asks with a reason, a second person approves or refuses, the database owner
//     runs it inside the door (a ledger block in the asker's name);
//   · the ledger's fingerprint that the daily GitHub job copies outside the database.
// Every rule is the database's (tests/39_production_safeguards.sql); this page only shows and asks.
import { useState } from 'react';
import { rpc } from '../../lib/api';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { dateTime, humanise } from '../../lib/format';
import { Badge, Empty, ErrorBox, Loading } from '../../shell/ui';

export type ChangePath = 'app' | 'service' | 'correction' | 'declared' | 'direct';
export interface BehindApp { seq: number; at: string; table: string; op: 'INSERT' | 'UPDATE' | 'DELETE'; db_role: string; path: ChangePath;
  note: string | null; columns: string[]; correction_id: string | null }
export interface Correction { id: string; reason: string; detail: string | null; status: 'requested' | 'approved' | 'refused' | 'open' | 'done';
  requested_by: string | null; requested_at: string; mine: boolean; decided_by: string | null; decided_at: string | null;
  refused_why: string | null; rows_changed: number | null; closed_at: string | null }
export interface SafeguardsReport {
  change_log: { lines: number; intact: boolean; first_bad: number | null; problem: string | null };
  days: number; by_path: Partial<Record<ChangePath, number>>; behind_app: BehindApp[]; direct_count: number; declared_count: number;
  two_person: boolean; corrections: Correction[]; can_request: boolean; can_decide: boolean;
  head: { environment: string; ledger: { seq: number; hash: string } | null; change_log: { seq: number; hash: string } | null; at: string };
}

const FIRST = 10;
export const PATHS: ChangePath[] = ['app', 'service', 'correction', 'declared', 'direct'];
/** A fingerprint as people can compare it by eye: the first and last six characters. */
export const shortHash = (h: string | null | undefined) => (h && h.length > 14 ? `${h.slice(0, 6)}…${h.slice(-6)}` : h ?? '—');
/** What a second person may still do with a correction: decide it while it is requested, and never their own. */
export const mayDecide = (c: Pick<Correction, 'status' | 'mine'>, canDecide: boolean) => canDecide && c.status === 'requested' && !c.mine;

export function Safeguards() {
  const { t } = useI18n();
  const rep = useAsync(() => rpc<SafeguardsReport>('safeguards_report', { p_days: 30 }), []);
  const [allBehind, setAllBehind] = useState(false);              // ten at first: the corrections stay in sight on a phone
  const d = rep.data;
  return (
    <div data-testid="safeguards">
      <h1><span aria-hidden="true">🛡 </span>{t('sg.title')}</h1>
      <p className="small muted">{t('sg.sub')}</p>
      {rep.loading && !d ? <Loading /> : <ErrorBox error={rep.error} onRetry={() => void rep.reload()} />}
      {d && (
        <>
          <div className="card">
            <h2>{t('sg.log')}</h2>
            {d.change_log.intact
              ? <div className="alert ok" data-testid="sg-log">{t('sg.log_ok', { n: d.change_log.lines })}</div>
              : <div className="alert error" role="alert" data-testid="sg-log">{t('sg.log_bad', { seq: d.change_log.first_bad ?? '?', problem: d.change_log.problem ?? '' })}</div>}
            <p className="small" data-testid="sg-paths">{t('sg.paths', { d: d.days })}{' '}
              {PATHS.map((p) => `${t(`sg.path_${p}`)} ${d.by_path[p] ?? 0}`).join(' · ')}</p>
            <p className="small muted">{t('sg.log_note')}</p>
          </div>

          <Corrections d={d} onChanged={() => void rep.reload()} />

          <div className="card">
            <h2>{t('sg.behind')}</h2>
            <p className="small muted">{t('sg.behind_note')}</p>
            {d.direct_count > 0 && <div className="alert warn small" data-testid="sg-direct">{t('sg.direct_count', { n: d.direct_count, d: d.days })}</div>}
            {d.behind_app.length === 0 ? <Empty>{t('sg.behind_none', { d: d.days })}</Empty> : (
              <ul className="stack" style={{ listStyle: 'none', padding: 0, margin: 0 }} data-testid="sg-behind">
                {d.behind_app.slice(0, allBehind ? undefined : FIRST).map((c) => (
                  <li key={c.seq} className="small" data-testid="sg-change" style={{ borderBottom: '1px solid var(--line, #ddd)', paddingBottom: 6 }}>
                    <div><Badge value={c.path === 'direct' ? 'fail' : c.path === 'correction' ? 'verified' : 'pending'} label={t(`sg.path_${c.path}`)} />{' '}
                      <strong>{t(`sg.op_${c.op}`)}</strong> · {humanise(c.table)} · #{c.seq}</div>
                    <div className="muted">{dateTime(c.at)} · {t('sg.account', { role: c.db_role })}{c.note ? ` · ${c.note}` : ''}</div>
                    {c.columns.length > 0 && <div className="muted" style={{ overflowWrap: 'anywhere' }}>{t('sg.columns', { cols: c.columns.join(', ') })}</div>}
                  </li>))}
              </ul>)}
            {!allBehind && d.behind_app.length > FIRST && (
              <button className="secondary small-btn" style={{ marginTop: 8 }} onClick={() => setAllBehind(true)} data-testid="sg-more">
                {t('sg.more', { n: d.behind_app.length - FIRST })}</button>)}
          </div>


          <div className="card">
            <h2>{t('sg.copy')}</h2>
            <p className="small muted">{t('sg.copy_note')}</p>
            <dl className="kv" data-testid="sg-head">
              <dt>{t('sg.head_ledger')}</dt><dd className="mono">{d.head.ledger ? `#${d.head.ledger.seq} · ${shortHash(d.head.ledger.hash)}` : '—'}</dd>
              <dt>{t('sg.head_log')}</dt><dd className="mono">{d.head.change_log ? `#${d.head.change_log.seq} · ${shortHash(d.head.change_log.hash)}` : '—'}</dd>
            </dl>
          </div>
        </>)}
    </div>
  );
}

function Corrections({ d, onChanged }: { d: SafeguardsReport; onChanged: () => void }) {
  const { t } = useI18n();
  const act = useAction();
  const [reason, setReason] = useState('');
  const [detail, setDetail] = useState('');
  const [refusing, setRefusing] = useState<string | null>(null);
  const [why, setWhy] = useState('');
  const ask = () => act.run(async () => {
    await rpc('request_correction', { p_reason: reason.trim(), p_detail: detail.trim() || null });
    setReason(''); setDetail(''); onChanged();
  });
  const decide = (id: string, approve: boolean) => act.run(async () => {
    await rpc('decide_correction', { p_id: id, p_approve: approve, p_why: approve ? null : why.trim() });
    setRefusing(null); setWhy(''); onChanged();
  });
  return (
    <div className="card" data-testid="sg-corrections">
      <h2>{t('sg.corr')}</h2>
      <p className="small muted">{t('sg.corr_note')}</p>
      <p className="small" data-testid="sg-two-person">{t(d.two_person ? 'sg.two_on' : 'sg.two_off')}</p>
      {d.can_request && (
        <div className="stack" style={{ marginBottom: 12 }}>
          <label className="small" htmlFor="sg-reason"><strong>{t('sg.reason')}</strong></label>
          <textarea id="sg-reason" rows={2} maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="sg-reason" />
          <label className="small" htmlFor="sg-detail">{t('sg.detail')}</label>
          <input id="sg-detail" maxLength={300} value={detail} onChange={(e) => setDetail(e.target.value)} data-testid="sg-detail" />
          <div><button disabled={act.busy || reason.trim().length < 5} onClick={ask} data-testid="sg-request">{t('sg.request')}</button></div>
        </div>)}
      <ErrorBox error={act.error} />
      {d.corrections.length === 0 ? <Empty>{t('sg.corr_none')}</Empty> : (
        <ul className="stack" style={{ listStyle: 'none', padding: 0, margin: 0 }}>
          {d.corrections.map((c) => (
            <li key={c.id} className="small" data-testid="sg-correction" style={{ borderBottom: '1px solid var(--line, #ddd)', paddingBottom: 6 }}>
              <div><Badge value={c.status === 'done' ? 'verified' : c.status === 'refused' ? 'fail' : 'pending'} label={t(`sg.st_${c.status}`)} />{' '}
                <span style={{ overflowWrap: 'anywhere' }}>{c.reason}</span></div>
              {c.detail && <div className="muted" style={{ overflowWrap: 'anywhere' }}>{c.detail}</div>}
              <div className="muted">{t('sg.asked', { who: c.requested_by ?? '—', at: dateTime(c.requested_at) })}
                {c.decided_by && <> · {t(c.status === 'refused' ? 'sg.refused_by' : 'sg.approved_by', { who: c.decided_by, at: dateTime(c.decided_at ?? '') })}</>}
                {c.refused_why && <> · {t('sg.why', { why: c.refused_why })}</>}
                {c.status === 'done' && <> · {t('sg.done', { n: c.rows_changed ?? 0, at: dateTime(c.closed_at ?? '') })}</>}</div>
              {mayDecide(c, d.can_decide) && refusing !== c.id && (
                <div className="row" style={{ marginTop: 4 }}>
                  <button className="small-btn" disabled={act.busy} onClick={() => decide(c.id, true)} data-testid="sg-approve">{t('sg.approve')}</button>
                  <button className="secondary small-btn" disabled={act.busy} onClick={() => { setRefusing(c.id); setWhy(''); }} data-testid="sg-refuse">{t('sg.refuse')}</button>
                </div>)}
              {refusing === c.id && (
                <div className="row" style={{ marginTop: 4 }}>
                  <input aria-label={t('sg.refuse_why')} placeholder={t('sg.refuse_why')} value={why} maxLength={200} onChange={(e) => setWhy(e.target.value)} data-testid="sg-refuse-why" />
                  <button className="danger small-btn" disabled={act.busy || why.trim().length < 3} onClick={() => decide(c.id, false)} data-testid="sg-refuse-confirm">{t('sg.refuse')}</button>
                  <button className="secondary small-btn" onClick={() => setRefusing(null)}>{t('reg.cancel')}</button>
                </div>)}
            </li>))}
        </ul>)}
    </div>
  );
}
