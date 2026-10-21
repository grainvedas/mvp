// Migration 63 (Phase 1, release 5, Part D4): the scope dashboard's "Season report" card. The Client Manager requests the
// close with an answer for every blocker the closing check lists; the State Manager confirms (or declines) and may reopen
// with a reason; either makes an interim report while the season runs. Every issued version is listed with its files,
// in both copies for those who may read the internal one, and its "Verify this document" page. Every rule is the
// database's; the buttons only show what app.scope_close_state says this person may do.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { date, dateTime, humanise, kg } from '../../lib/format';
import { Badge, Empty, ErrorBox, Loading } from '../../shell/ui';
import {
  closeChecklist, closeState, confirmClose, decideClose, expectedFiles, fileKey, generateInterim, openReportFile, reopenScope, requestClose,
  scopeReports, withdrawReport, type Answers, type CheckGroup, type CheckItem, type Checklist, type ReportHead, type Lang, type Format,
} from '../../lib/reports';
import type { Copy } from '../../lib/exports';

type AnswerKind = 'flags' | 'kg' | 'pod' | 'packs' | 'balance';
const keyOf = (g: string, i: CheckItem) => (g === 'packs' ? i.batch_code! : g === 'balance' ? i.stage! : i.id!);

/** Pure: the answers typed on the screen as the server takes them (one reason per blocker, 10 to 250 characters). */
export function answersOf(typed: Record<string, string>): Answers {
  const out: Answers = {};
  for (const [k, reason] of Object.entries(typed)) {
    const [g, id] = k.split('|') as [AnswerKind, string];
    const r = reason.trim();
    if (!r) continue;
    const item = g === 'packs' ? { batch_code: id, reason: r } : g === 'balance' ? { stage: id, reason: r } : { id, reason: r };
    (out[g] ??= []).push(item);
  }
  return out;
}

function ItemLine({ g, i }: { g: string; i: CheckItem }) {
  const { t } = useI18n();
  const stage = (s?: string) => (s ? t(`stage.${s}`, undefined, humanise(s)) : '');
  if (g === 'pending') return <span><span className="mono">{i.code}</span> · {stage(i.stage)} · {t('srep.since', { at: dateTime(i.since) })}</span>;
  if (g === 'lab_hold') return <span><span className="mono">{i.code}</span> · {t('srep.lot', { lot: i.lot ?? '—' })} · {date(i.drawn_on)}</span>;
  if (g === 'flags') return <span><span className="mono">{i.code}</span> · {i.text}</span>;
  if (g === 'kg') return <span><span className="mono">{i.code}</span> · {stage(i.stage)} · <strong>{kg(i.kg)}</strong> {t('srep.left')}</span>;
  if (g === 'pod') return <span><span className="mono">{i.code}</span> · {kg(i.kg)} · {t('srep.no_delivery')}</span>;
  if (g === 'packs') return <span><span className="mono">{i.batch_code}</span> · {t('srep.packs_line', { released: i.released ?? 0, old: i.old_data ?? 0, held: i.held ?? 0, void: i.void ?? 0 })}</span>;
  return <span>{stage(i.stage)} · <strong className="text-danger">{t('dash.balance_diff', { kg: kg(i.difference_kg) })}</strong></span>;
}

function ChecklistView({ c, typed, setTyped, answering }: { c: Checklist; typed: Record<string, string>; setTyped: (f: (x: Record<string, string>) => Record<string, string>) => void; answering: boolean }) {
  const { t } = useI18n();
  return (
    <ul className="checklist" data-testid="close-checklist">
      {c.groups.map((g: CheckGroup) => (
        <li key={g.key} data-testid="close-group" data-key={g.key} data-ok={g.ok ? 'yes' : 'no'}>
          <div className="row"><strong>{t(`srep.g.${g.key}`)}</strong>
            {g.ok ? <Badge value="verified" label={g.items.length ? t('srep.answered') : t('srep.clear')} /> : <Badge value="fail" label={t('srep.blocks_n', { n: g.items.filter((i) => !i.reason).length })} />}</div>
          {g.items.length > 0 && <ul className="small">
            {g.items.map((i) => {
              const k = `${g.key}|${keyOf(g.key, i)}`;
              return (
                <li key={k} data-testid="close-item">
                  <ItemLine g={g.key} i={i} />
                  {g.answerable && answering && (
                    <label className="stack small">{t(`srep.why.${g.key}`)}
                      <textarea rows={2} maxLength={250} value={typed[k] ?? i.reason ?? ''} data-testid="close-reason" data-item={k}
                        onChange={(e) => setTyped((x) => ({ ...x, [k]: e.target.value }))} /></label>)}
                  {g.answerable && !answering && i.reason && <div className="muted">{t('srep.reason', { r: i.reason })}</div>}
                </li>);
            })}
          </ul>}
          {!g.answerable && g.items.length > 0 && <p className="small muted">{t(`srep.clear_first.${g.key}`)}</p>}
        </li>
      ))}
    </ul>
  );
}

function Reason({ label, onDone, busy, testid }: { label: string; onDone: (r: string) => void; busy: boolean; testid: string }) {
  const { t } = useI18n();
  const [r, setR] = useState('');
  return (
    <div className="stack" data-testid={testid}>
      <label className="stack small">{t('srep.why')}<textarea rows={2} maxLength={250} value={r} onChange={(e) => setR(e.target.value)} data-testid={`${testid}-why`} /></label>
      <button className="secondary" disabled={busy || r.trim().length < 10} onClick={() => onDone(r.trim())} data-testid={`${testid}-go`}>{label}</button>
    </div>
  );
}

const FILE_ORDER: { copy: Copy; format: Format; lang: Lang }[] = expectedFiles(true);

function ReportRow({ r, internal, mayStore, sm, onMake, onWithdraw, busy }: { r: ReportHead; internal: boolean; mayStore: boolean; sm: boolean;
  onMake: (r: ReportHead) => void; onWithdraw: (r: ReportHead, why: string) => void; busy: boolean }) {
  const { t } = useI18n();
  const dl = useAction();
  const [wd, setWd] = useState(false);
  const files = r.files ?? {};
  const want = expectedFiles(internal);
  const missing = want.filter((f) => !(fileKey(f.copy, f.lang, f.format) in files));
  return (
    <li data-testid="report-row" data-ref={r.ref} data-status={r.status}>
      <div className="row"><strong>{r.final ? t('rep.final_v', { n: r.version }) : t('rep.interim_n', { n: r.version })}</strong>
        <span className="mono small">{r.ref}</span>
        <Badge value={r.status === 'valid' ? 'verified' : r.status === 'withdrawn' ? 'fail' : 'closed'} label={t(`srep.st.${r.status}`)} /></div>
      <div className="small muted">{dateTime(r.issued_at)}{r.issued_by ? ` · ${r.issued_by}` : ''}
        {r.superseded_by && <> · {t('srep.superseded_by', { ref: r.superseded_by })}</>}
        {r.withdrawn_reason && <> · {t('srep.withdrawn_why', { r: r.withdrawn_reason })}</>}</div>
      <div className="stack small" data-testid="report-files">
        {(['shareable', 'internal'] as Copy[]).map((copy) => {
          const have = FILE_ORDER.filter((f) => f.copy === copy && fileKey(f.copy, f.lang, f.format) in files);
          return have.length === 0 ? null : (
            <div key={copy} className="report-files"><span className="muted">{t(`exp.copy_${copy}`)}:</span>
              {have.map((f) => (
                <button key={fileKey(f.copy, f.lang, f.format)} type="button" className="linkish" disabled={dl.busy}
                  data-testid={`file-${fileKey(f.copy, f.lang, f.format)}`} onClick={() => dl.run(() => openReportFile(r.id, r.ref, f.copy, f.lang, f.format))}>
                  {t(`srep.file.${f.format}`)} {f.lang === 'hi' ? 'हिन्दी' : 'English'}</button>))}
            </div>);
        })}
        <Link to={`/d/${r.ref}`} data-testid="report-verify">{t('srep.verify_page')}</Link>
      </div>
      {missing.length > 0 && r.status !== 'withdrawn' && (mayStore
        ? <button className="small" disabled={busy} onClick={() => onMake(r)} data-testid="report-make">{t('srep.make_files', { n: missing.length })}</button>
        : <p className="small muted">{t('srep.files_pending', { n: missing.length })}</p>)}
      {sm && r.status === 'valid' && (wd
        ? <Reason label={t('srep.withdraw_go')} busy={busy} testid="report-withdraw" onDone={(why) => onWithdraw(r, why)} />
        : <button className="secondary small" onClick={() => setWd(true)} data-testid="report-withdraw-open">{t('srep.withdraw')}</button>)}
      <ErrorBox error={dl.error} />
    </li>
  );
}

// onChanged: the dashboard's other cards (the mass balance shows a write-off, flags carried over) read again after a close or a reopen.
export function SeasonReport({ scopeId, onChanged }: { scopeId: string; onChanged?: () => void }) {
  const { t } = useI18n();
  const state = useAsync(() => closeState(scopeId), [scopeId]);
  const reports = useAsync(() => scopeReports(scopeId), [scopeId]);
  const act = useAction();
  const [panel, setPanel] = useState<'none' | 'check' | 'decline' | 'withdraw' | 'reopen'>('none');
  const [check, setCheck] = useState<Checklist | null>(null);
  const [typed, setTyped] = useState<Record<string, string>>({});
  const [note, setNote] = useState('');
  const [progress, setProgress] = useState<string | null>(null);
  const s = state.data;
  const reload = () => { state.reload(); reports.reload(); onChanged?.(); };

  const make = async (id: string, have: Record<string, unknown>) => {
    const { makeReportFiles } = await import('../../lib/reportFiles');
    const n = expectedFiles(!!s?.may.internal).length - Object.keys(have).length;
    let done = 0;
    setProgress(t('srep.making', { n: done, m: n }));
    try {
      await makeReportFiles(id, !!s?.may.internal, have, (st) => { if (st.done) { done += 1; setProgress(t('srep.making', { n: done, m: n })); } });
    } finally { setProgress(null); reports.reload(); }
  };
  const runCheck = (answers: Answers = answersOf(typed)) => act.run(async () => setCheck(await closeChecklist(scopeId, answers)));

  if (state.loading && !s) return <Loading />;
  if (!s) return <ErrorBox error={state.error} onRetry={state.reload} />;
  const req = s.request;
  return (
    <div data-testid="season-report" data-status={s.status}>
      <p className="small muted">{t('srep.intro')}</p>
      {s.status === 'closed' && <div className="alert info" data-testid="scope-closed">{t('srep.closed_note')}</div>}
      {req && (
        <div className="alert warn" data-testid="close-requested">
          {t('srep.requested', { by: req.requested_by, at: dateTime(req.requested_at) })}{req.note && <> · {req.note}</>}
          <div className="row wrap">
            {s.may.confirm && <button disabled={act.busy || !!progress} data-testid="close-confirm" onClick={() => act.run(async () => {
              const r = await confirmClose(req.id); reload(); await make(r.report.id, {}); })}>{t('srep.confirm')}</button>}
            {s.may.decline && <button className="secondary" onClick={() => setPanel('decline')} data-testid="close-decline-open">{t('srep.decline')}</button>}
            {s.may.withdraw && <button className="secondary" onClick={() => setPanel('withdraw')} data-testid="close-withdraw-open">{t('srep.withdraw_request')}</button>}
            <button className="secondary" onClick={() => { setPanel('check'); runCheck(req.answers); }} data-testid="close-view">{t('srep.view_check')}</button>
          </div>
          {!s.may.confirm && s.may.decline && req.mine && <p className="small">{t('srep.two_people')}</p>}
        </div>)}
      {(panel === 'decline' || panel === 'withdraw') && req && (
        <Reason label={t(panel === 'decline' ? 'srep.decline_go' : 'srep.withdraw_request_go')} busy={act.busy} testid={`close-${panel}`}
          onDone={(why) => act.run(async () => { await decideClose(req.id, why); setPanel('none'); reload(); })} />)}

      <div className="row wrap no-print">
        {s.may.request && <button data-testid="close-open" onClick={() => { setPanel('check'); setTyped({}); runCheck({}); }}>{t('srep.close_scope')}</button>}
        {s.may.interim && <button className="secondary" disabled={act.busy || !!progress} data-testid="interim-go"
          onClick={() => act.run(async () => { const r = await generateInterim(scopeId); reload(); await make(r.id, {}); })}>{t('srep.interim')}</button>}
        {s.may.reopen && <button className="secondary" onClick={() => setPanel('reopen')} data-testid="reopen-open">{t('srep.reopen')}</button>}
      </div>
      {panel === 'reopen' && <Reason label={t('srep.reopen_go')} busy={act.busy} testid="reopen"
        onDone={(why) => act.run(async () => { await reopenScope(scopeId, why); setPanel('none'); reload(); })} />}

      {panel === 'check' && (
        <div className="stack" data-testid="close-panel">
          <h3>{t('srep.check_title')}</h3>
          {!check ? <Loading /> : <>
            {check.clear ? <div className="alert ok" data-testid="close-clear">{t('srep.check_clear')}</div>
              : <div className="alert warn" data-testid="close-blocked">{t('srep.check_blocked')}</div>}
            <ChecklistView c={check} typed={typed} setTyped={setTyped} answering={s.may.request} />
            {s.may.request && <>
              <label className="stack small">{t('srep.note')}<input value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} data-testid="close-note" /></label>
              <div className="row wrap">
                <button className="secondary" disabled={act.busy} onClick={() => runCheck()} data-testid="close-recheck">{t('srep.recheck')}</button>
                <button disabled={act.busy || !check.clear} data-testid="close-request"
                  onClick={() => act.run(async () => { await requestClose(scopeId, answersOf(typed), note); setPanel('none'); setCheck(null); reload(); })}>{t('srep.request')}</button>
              </div>
              {!check.clear && <p className="small muted">{t('srep.request_hint')}</p>}
            </>}
          </>}
        </div>)}
      {progress && <p className="small" role="status" data-testid="report-progress">{progress}</p>}
      <ErrorBox error={act.error} />

      <h3>{t('srep.versions')}</h3>
      {reports.loading && !reports.data ? <Loading /> : <ErrorBox error={reports.error} onRetry={reports.reload} />}
      {reports.data?.length === 0 && <Empty>{t('srep.no_reports')}</Empty>}
      {!!reports.data?.length && <ul className="reports" data-testid="report-list">
        {reports.data.map((r) => <ReportRow key={r.id} r={r} internal={s.may.internal} mayStore={s.may.store_files} sm={s.may.withdraw_report}
          busy={act.busy || !!progress} onMake={(x) => act.run(() => make(x.id, x.files ?? {}))}
          onWithdraw={(x, why) => act.run(async () => { await withdrawReport(x.id, why); reports.reload(); })} />)}
      </ul>}
      {s.closures.length > 0 && <details className="small" data-testid="close-history"><summary>{t('srep.history')}</summary>
        <ul>{s.closures.map((c) => <li key={c.id}>{t(`srep.h.${c.status}`, { v: c.version ?? '', by: c.decided_by ?? '—', at: dateTime(c.decided_at), req: c.requested_by })}
          {c.decided_reason && <> · {c.decided_reason}</>}
          {c.reopened_at && <> · {t('srep.h.reopened', { by: c.reopened_by ?? '—', at: dateTime(c.reopened_at), r: c.reopen_reason ?? '' })}</>}</li>)}</ul>
      </details>}
    </div>
  );
}
