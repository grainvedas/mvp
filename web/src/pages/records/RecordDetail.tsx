// S17 record detail · S16 QC override · S18 flags · S20 entry to "correct a pending record"
import { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import QRCode from 'qrcode';
import { rpc, q, sha256Hex } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { kg, date, dateTime, humanise, num, shortHash, todayIST } from '../../lib/format';
import { oversees, managesScope, isStateManager } from '../../lib/rights';
import { type Footprint, type FootprintDetail, type QualityParam, type StageForm, type Withdrawal } from '../../lib/types';
import { Badge, ErrorBox, Loading, Field, plainText } from '../../shell/ui';
import { uploadEvidence } from '../../engine/evidence';
import { EVIDENCE_ACCEPT } from '../../engine/widgets';
import { ComputedRows, EnteredRows, capturedAt, paramName } from '../../engine/values';
import { localiseForm } from '../../engine/localise';
import { cached } from '../../offline/cache';

export function RecordDetail() {
  const { id = '' } = useParams();
  const d = useAsync(() => rpc<FootprintDetail>('footprint_detail', { p_fp: id }), [id]);
  // Keep the page on screen while it refreshes after an action (a flag raised, a file attached): only the first load
  // of a record shows "Loading", so the panel just used keeps its message and the page does not jump.
  if (d.data?.footprint.id !== id) return d.loading ? <Loading /> : <ErrorBox error={d.error} onRetry={d.reload} />;
  if (d.error) return <ErrorBox error={d.error} onRetry={d.reload} />;
  return <RecordView r={d.data} reload={d.reload} />;
}

function RecordView({ r, reload }: { r: FootprintDetail; reload: () => void }) {
  const { t, lang } = useI18n();
  const { ctx } = useAuth();
  const me = ctx!.user!;
  const f = r.footprint;
  // The stage's form gives the names of the fields and of the lab parameters (the copy the stage page keeps). Without
  // it (no network and nothing kept) the values are still listed, under plainer names.
  const sf = useAsync(() => cached(`stage_form:${f.scope_id}:${f.stage_type}`,
    () => rpc<StageForm>('stage_form', { p_scope: f.scope_id, p_stage: f.stage_type })), [f.scope_id, f.stage_type]);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const form = useMemo(() => (sf.data ? localiseForm(sf.data, t) : null), [sf.data, lang]);
  const when = capturedAt(f);
  // A lot that has not reached the lab has no result yet: say nothing rather than "pending · pending".
  const noLabYet = !r.qc && !r.market_verdict.overridden && r.market_verdict.domestic === 'pending' && r.market_verdict.export === 'pending';
  // Who manages THIS record's scope (withdraw, verdict override, resolve a flag): the server's answer per scope. The admin
  // oversees: reads the record, raises a flag, does nothing else to it (migration 34).
  const watch = oversees(ctx);
  const boss = managesScope(ctx, f.scope_id);
  const mine = f.status === 'pending' && !watch && (f.created_by === me.id || boss);
  // Records whose save derived something elsewhere (a verdict, a batch, grade lots) are not edited in place (migration 22)
  const frozen = f.stage_type === 'qc' || f.stage_type === 'village_batch' || f.is_grade_lot || f.split_into_grades;
  const canCorrect = mine && !frozen;
  // migration 48 (A1): returned to its sender — he corrects it, or withdraws it to record it again
  const openReturn = (r.returns ?? []).find((x) => x.status === 'open') ?? null;
  const senderReturned = !!openReturn && f.created_by === me.id && !watch;
  return (
    <div>
      <p className="muted small"><Link to={`/work/${f.scope_id}/${f.stage_type}`}>{t(`stage.${f.stage_type}`, undefined, r.stage_label)}</Link></p>
      <h1 className="mono">{t('record.title', { code: f.footprint_code })}</h1>
      <div className="card">
        <div className="row"><Badge value={f.status} />{f.lot_closed && <Badge value="closed" label={t('record.lot_closed')} />}{f.grade && <Badge value="verified" label={t('record.grade', { grade: f.grade })} />}</div>
        <dl className="kv" style={{ marginTop: 12 }}>
          <dt>{t('record.stage')}</dt><dd>{t(`stage.${f.stage_type}`, undefined, r.stage_label)}</dd>
          {r.farmer && <><dt>{t('record.farmer')}</dt><dd>{r.farmer.name} <span className="mono">{r.farmer.farmer_code}</span>{r.farmer.state_farmer_code && <> · <span className="mono" data-testid="record-state-farmer">{r.farmer.state_farmer_code}</span></>} · {r.farmer.village}</dd></>}
          {r.prev && <><dt>{t('record.came_from')}</dt><dd><Link className="mono" to={`/records/${r.prev.id}`}>{r.prev.footprint_code}</Link> ({t(`stage.${r.prev.stage_type}`, undefined, humanise(r.prev.stage_type))})</dd></>}
          <dt>{t('record.qty_in')}</dt><dd>{kg(f.qty_in)}</dd>
          <dt>{t('record.qty_out')}</dt><dd className="big">{kg(f.qty_out)}</dd>
          <dt>{t('record.available')}</dt><dd>{kg(r.available_kg)}</dd>
          <ComputedRows computed={f.computed} t={t} />
          {f.happened_on && <><dt>{t('on.label')}</dt><dd data-testid="record-on">{date(f.happened_on)}</dd></>}
          {f.manager_reason && <><dt>{t('mgr.recorded_by_manager')}</dt><dd data-testid="record-manager-reason">“{f.manager_reason}”</dd></>}
          <dt>{t('record.recorded')}</dt><dd>{dateTime(when.at)} · {r.created_by_name ?? '—'}
            {when.sentLater && <span className="muted small" data-testid="sent-later"> · {t('record.sent_later', { at: dateTime(f.created_at) })}</span>}</dd>
          <dt>{t('record.verified')}</dt><dd>{f.verified_at ? `${dateTime(f.verified_at)} · ${r.verified_by_name ?? '—'}` : '—'}</dd>
          {!noLabYet && <><dt>{t('record.market_verdict')}</dt><dd>{t('record.market_domestic')} <Badge value={r.market_verdict.domestic} /> · {t('record.market_export')} <Badge value={r.market_verdict.export} />{r.market_verdict.overridden && <> <Badge value="pending" label={t('record.overridden')} /></>}</dd></>}
        </dl>
        {f.warnings?.length > 0 && <div className="alert warn">{f.warnings.map((w) => plainText(w, t)).join(' · ')}</div>}
        <details><summary>{t('record.entered')}</summary>
          <dl className="kv" data-testid="entered-values">
            <EnteredRows payload={f.payload} fields={form?.stage.form_schema ?? []} stage={f.stage_type} params={form?.quality_params} t={t} />
          </dl>
        </details>
        <div className="row">
          {canCorrect && <Link className="btn secondary" to={`/work/${f.scope_id}/${f.stage_type}?edit=${f.id}`}>{t('record.edit_pending')}</Link>}
          {me.role !== 'operator' && <Link className="btn secondary" to={`/trace/${f.id}`} data-testid="trace-link">{t('record.trace')}</Link>}
        </div>
        {mine && frozen && <p className="hint">{t('record.fix_by_withdraw')}</p>}
      </div>
      <LotFacts r={r} />
      <WithdrawalInfo f={f} canRecord={me.role !== 'client_view' && !watch} />
      <ReturnsPanel r={r} senderReturned={senderReturned} canCorrect={canCorrect} onDone={reload} />
      {(boss || senderReturned) && (f.status === 'pending' || f.status === 'verified') && !r.seal && <WithdrawPanel f={f} onDone={reload} />}
      {r.qc && <QcPanel detail={r} onChange={reload} canOverride={boss} params={form?.quality_params ?? []} />}
      {r.seal && <SealPanel code={r.seal.qr_code} hash={r.seal.ledger_hash} batch={r.seal.batch_codes} />}
      {r.seal && r.release && <ReleasePanel r={r} mayChange={!watch && (boss || isStateManager(ctx))} onDone={reload} />}
      {r.packs && <PacksPanel r={r} mayAct={me.role !== 'client_view' && !watch} onDone={reload} />}
      {f.stage_type === 'shipment' && <DeliveryPanel r={r} mayAct={me.role !== 'client_view' && !watch} onDone={reload} />}
      {f.stage_type === 'qr_activation' && f.status === 'pending' && !r.seal && me.role !== 'client_view' && !watch && <FinishSeal f={f} onDone={reload} />}
      {r.attachments.length > 0 && <Attachments detail={r} />}
      {me.role !== 'client_view' && !watch && f.status !== 'superseded' && <AddEvidence f={f} onDone={reload} />}
      <Flags detail={r} onChange={reload} canResolve={boss} canRaise />
      <div className="card">
        <h2>{t('record.ledger')}</h2>
        <div className="table-wrap"><table>
          <thead><tr><th>#</th><th>{t('record.ledger_event')}</th><th>{t('record.ledger_by')}</th><th>{t('record.ledger_when')}</th><th>{t('record.ledger_hash')}</th></tr></thead>
          <tbody>{r.ledger.map((l) => (
            <tr key={l.seq}><td className="num">{l.seq}</td><td>{t(`event.${l.event}`, undefined, humanise(l.event))}</td><td>{l.actor_name ?? '—'}</td><td>{dateTime(l.created_at)}</td>
              <td className="mono small" title={l.hash}>{shortHash(l.hash)}</td></tr>
          ))}</tbody>
        </table></div>
      </div>
    </div>
  );
}

/** Migration 49: where the lot comes from (with the kilograms taken), its farmers in documented proportions, its GI
 *  status, and what the system checks about it. All from the server (app.footprint_detail). */
function LotFacts({ r }: { r: FootprintDetail }) {
  const { t } = useI18n();
  const farmers = r.farmers ?? [], sources = r.sources ?? [], sys = r.system_checks ?? [];
  if (!r.gi_status && farmers.length === 0 && sources.length === 0 && sys.length === 0) return null;
  return (
    <div className="card" data-testid="lot-facts">
      {r.gi_status && <p data-testid="lot-gi">{t('gi.status')}: <Badge value={r.gi_status === 'gi' ? 'verified' : r.gi_status === 'non_gi' ? 'closed' : 'pending'} label={t(`gi.${r.gi_status}`)} /></p>}
      {sources.length > 0 && <>
        <h3>{t('rec.sources')}</h3>
        <ul className="small" data-testid="lot-sources">{sources.map((x) => (
          <li key={x.id}><Link className="mono" to={`/records/${x.id}`}>{x.code}</Link> ({t(`stage.${x.stage}`, undefined, humanise(x.stage))}): {t('rec.taken', { kg: kg(x.kg) })}
            {x.from_older && <span className="muted"> · {t('rec.from_older')}</span>}</li>))}</ul></>}
      {farmers.length > 0 && <>
        <h3>{t('rec.farmers', { n: farmers.length })}</h3>
        <ul className="small" data-testid="lot-farmers">{farmers.map((x) => (
          <li key={x.farmer_id}>{x.name}{x.village ? `, ${x.village}` : ''}: {num(x.share_pct, 1)} % · {kg(x.kg)}</li>))}</ul>
        <p className="muted small">{t('rec.proportions')}</p></>}
      {sys.length > 0 && <>
        <h3>{t('sys.title')}</h3>
        <ul className="sys-checks small">{sys.map((c) => <li key={c.key} data-ok={c.ok} className={c.ok ? 'ok' : 'not'}><span aria-hidden="true">{c.ok ? '✓' : '✗'}</span> {t(`chk.${c.key}`, c.vars, c.key)}</li>)}</ul></>}
    </div>
  );
}

/** Migration 48 (A1): the times this record was returned to its sender; its sender's way forward; the next stage's
 *  "Return to sender" (the server says whether the reader may). */
function ReturnsPanel({ r, senderReturned, canCorrect, onDone }: { r: FootprintDetail; senderReturned: boolean; canCorrect: boolean; onDone: () => void }) {
  const { t } = useI18n();
  const f = r.footprint;
  const [open, setOpen] = useState(false);
  const [why, setWhy] = useState('');
  const act = useAction();
  const send = () => act.run(async () => { await rpc('return_footprint', { p_fp: f.id, p_reason: why.trim() }); setOpen(false); setWhy(''); onDone(); });
  const list = r.returns ?? [];
  if (list.length === 0 && !r.can_return) return null;
  return (
    <div className="card" data-testid="returns-panel">
      <h2>{t('ret.title')}</h2>
      {list.map((x) => (
        <div key={x.id} className={`alert ${x.status === 'open' ? 'warn' : 'info'} small`} data-testid="return-item" data-status={x.status}>
          {t('ret.line', { by: x.returned_by_name ?? '—', at: dateTime(x.returned_at), reason: x.reason })}
          {x.status !== 'open' && <div>{t(`ret.done_${x.status}`, { by: x.resolved_by_name ?? '—', at: dateTime(x.resolved_at) })}</div>}
        </div>))}
      {senderReturned && (
        <p data-testid="return-next">{canCorrect
          ? <Link className="btn" to={`/work/${f.scope_id}/${f.stage_type}?edit=${f.id}`} data-testid="return-correct">{t('ret.correct')}</Link>
          : t('ret.withdraw_hint')}</p>)}
      {r.can_return && !open && <button className="secondary" onClick={() => setOpen(true)} data-testid="return-open">{t('ret.button')}</button>}
      {r.can_return && open && (
        <div className="stack">
          <Field label={t('ret.why')} htmlFor="rd-why" hint={t('mgr.min10')}><textarea id="rd-why" rows={2} value={why} maxLength={500} onChange={(e) => setWhy(e.target.value)} data-testid="return-why" /></Field>
          <ErrorBox error={act.error} />
          <div className="row">
            <button className="danger" disabled={act.busy || why.trim().length < 10} onClick={send} data-testid="return-send">{t('ret.send')}</button>
            <button className="secondary" onClick={() => setOpen(false)}>{t('common.cancel')}</button>
          </div>
        </div>)}
    </div>
  );
}

/** A withdrawn record shows why, and what replaced it; a replacement shows what it replaces. */
function WithdrawalInfo({ f, canRecord }: { f: Footprint; canRecord: boolean }) {
  const { t } = useI18n();
  const info = useAsync(async () => {
    const w = f.status === 'superseded'
      ? await q(supabase.from('withdrawals').select('*').eq('footprint_id', f.id).maybeSingle()) as unknown as Withdrawal | null : null;
    const by = f.status === 'superseded'
      ? await q(supabase.from('footprints').select('id,footprint_code,status').eq('supersedes_id', f.id).neq('status', 'superseded')) as unknown as { id: string; footprint_code: string }[] : [];
    const old = f.supersedes_id
      ? await q(supabase.from('footprints').select('id,footprint_code').eq('id', f.supersedes_id).maybeSingle()) as unknown as { id: string; footprint_code: string } | null : null;
    return { w, by, old };
  }, [f.id, f.status, f.supersedes_id]);
  if (!info.data || (f.status !== 'superseded' && !info.data.old)) return null;
  const { w, by, old } = info.data;
  return (
    <div className="card" data-testid="withdrawal-info">
      {f.status === 'superseded' && (
        <div className="alert warn">
          <strong>{t('record.withdrawn')}</strong>{w && <> · {dateTime(w.withdrawn_at)} · “{w.reason}”</>}
          {by.length > 0
            ? <div>{t('record.replaced_by')} <Link className="mono" to={`/records/${by[0].id}`}>{by[0].footprint_code}</Link></div>
            : canRecord && <div><Link className="btn secondary" to={`/work/${f.scope_id}/${f.stage_type}?replaces=${f.id}`} data-testid="record-replacement">{t('record.record_replacement')}</Link></div>}
        </div>
      )}
      {old && <p>{t('record.replaces')} <Link className="mono" to={`/records/${old.id}`}>{old.footprint_code}</Link></p>}
    </div>
  );
}

/** Managers only (the database decides): withdraw a wrong record with a reason. Nothing is deleted. */
function WithdrawPanel({ f, onDone }: { f: Footprint; onDone: () => void }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const act = useAction();
  const go = () => act.run(async () => { await rpc('withdraw_footprint', { p_fp: f.id, p_reason: reason }); setOpen(false); onDone(); });
  return (
    <div className="card">
      <h2>{t('record.withdraw_title')}</h2>
      <p className="muted small">{t('record.withdraw_hint')}</p>
      {!open ? <button className="secondary" onClick={() => setOpen(true)} data-testid="withdraw-open">{t('record.withdraw')}</button> : (
        <div className="stack">
          <Field label={t('record.withdraw_reason')} htmlFor="wd-reason"><textarea id="wd-reason" value={reason} onChange={(e) => setReason(e.target.value)} rows={2} /></Field>
          <ErrorBox error={act.error} />
          <div className="row">
            <button className="danger" disabled={!reason.trim() || act.busy} onClick={go}>{t('record.withdraw_confirm')}</button>
            <button className="secondary" onClick={() => setOpen(false)}>{t('common.cancel')}</button>
          </div>
        </div>
      )}
    </div>
  );
}

function QcPanel({ detail, onChange, canOverride, params }: { detail: FootprintDetail; onChange: () => void; canOverride: boolean; params: QualityParam[] }) {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const qc = detail.qc!;
  const unit = (p: string) => { const q = params.find((x) => x.param === p); return { label: q?.label, unit: q?.unit }; };
  const [reason, setReason] = useState('');
  // migration 50: the client's written acceptance is attached before an export release
  const hasAcceptance = detail.attachments.some((a) => a.label === 'acceptance');
  const [acceptance, setAcceptance] = useState<File | null>(null);
  const act = useAction();
  const override = () => act.run(async () => {
    if (!hasAcceptance && acceptance) await uploadEvidence(detail.footprint, acceptance, 'acceptance');
    await q(supabase.from('qc_verdicts').update({ override: { market: 'export', reason, authoriser: ctx!.user!.id } })
      .eq('footprint_id', detail.footprint.id).select());
    onChange();
  });
  return (
    <div className="card">
      <h2>{t('record.qc_title')}</h2>
      <p>{t('record.domestic')} <Badge value={qc.domestic_verdict} /> · {t('record.export')} <Badge value={qc.export_verdict} /> <span className="muted small">{t('record.derived')}</span></p>
      <div className="table-wrap"><table>
        <thead><tr><th>{t('record.param')}</th><th>{t('record.reading')}</th><th>{t('record.domestic')}</th><th>{t('record.export')}</th></tr></thead>
        <tbody>{qc.judged.map((j) => <tr key={j.param}><td>{t(`qp.${j.param}`, undefined, unit(j.param).label ?? paramName(j.param))}</td><td className="num">{typeof j.value === 'boolean' ? t(j.value ? 'common.yes' : 'common.no') : typeof j.value === 'string' ? j.value : <>{num(j.value)}{j.value !== null && unit(j.param).unit ? ` ${unit(j.param).unit}` : ''}</>}</td>
          <td><Badge value={j.domestic} /></td><td><Badge value={j.export} /></td></tr>)}</tbody>
      </table></div>
      {qc.override && <div className="alert warn">{t('record.override_done', { market: t(`opt.${String(qc.override.market)}`, undefined, String(qc.override.market)), reason: String(qc.override.reason), at: dateTime(String(qc.override.at)) })}</div>}
      {canOverride && !qc.override && qc.export_verdict === 'fail' && (
        <div className="stack">
          <h3>{t('record.override')}</h3>
          <Field label={t('record.override_reason')} htmlFor="ov-reason"><textarea id="ov-reason" value={reason} onChange={(e) => setReason(e.target.value)} rows={2} /></Field>
          {hasAcceptance ? <p className="small" data-testid="acceptance-on-file">{t('ov.acceptance_on_file')}</p>
            : <Field label={`${t('ov.acceptance')} *`} htmlFor="ov-acc" hint={t('ov.acceptance_hint')}>
                <input id="ov-acc" type="file" accept={EVIDENCE_ACCEPT} onChange={(e) => setAcceptance(e.target.files?.[0] ?? null)} data-testid="acceptance-file" /></Field>}
          <ErrorBox error={act.error} />
          <button className="danger" disabled={!reason.trim() || act.busy || (!hasAcceptance && !acceptance)} onClick={override}>{t('record.override')}</button>
        </div>
      )}
    </div>
  );
}

/** Migration 50 (G10, C9): the release's status. The client's Client Manager or the state's State Manager puts it under
 *  investigation or recalls it, with a reason; a recall stays, and shows on every pack (the server decides who may). */
function ReleasePanel({ r, mayChange, onDone }: { r: FootprintDetail; mayChange: boolean; onDone: () => void }) {
  const { t } = useI18n();
  const rel = r.release!;
  const [to, setTo] = useState<'' | 'active' | 'under_investigation' | 'recalled'>('');
  const [why, setWhy] = useState('');
  const act = useAction();
  const go = () => act.run(async () => { await rpc('set_release_status', { p_seal: r.footprint.id, p_status: to, p_reason: why.trim() }); setTo(''); setWhy(''); onDone(); });
  const next = (['active', 'under_investigation', 'recalled'] as const).filter((s) => s !== rel.status);
  return (
    <div className="card" data-testid="release-panel" data-status={rel.status}>
      <h2>{t('rel.title')}</h2>
      <p><Badge value={rel.status === 'active' ? 'verified' : rel.status === 'recalled' ? 'fail' : 'pending'} label={t(`rel.st_${rel.status}`)} />
        {rel.reason && <> “{rel.reason}”</>}{rel.at && <span className="muted small"> · {dateTime(rel.at)}{rel.by ? ` · ${rel.by}` : ''}</span>}</p>
      {rel.status === 'recalled' && <div className="alert warn">{t('rel.recalled_note')}</div>}
      {mayChange && rel.status !== 'recalled' && (
        <div className="stack">
          <Field label={t('rel.change')} htmlFor="rel-to">
            <select id="rel-to" value={to} onChange={(e) => setTo(e.target.value as typeof to)} data-testid="release-to">
              <option value="">—</option>{next.map((s) => <option key={s} value={s}>{t(`rel.st_${s}`)}</option>)}</select></Field>
          {to && <Field label={`${t('rel.why')} *`} htmlFor="rel-why" hint={t('mgr.min10')}>
            <textarea id="rel-why" rows={2} maxLength={500} value={why} onChange={(e) => setWhy(e.target.value)} data-testid="release-why" /></Field>}
          {to === 'recalled' && <p className="hint">{t('rel.recall_warn')}</p>}
          <ErrorBox error={act.error} />
          {to && <button className={to === 'recalled' ? 'danger' : ''} disabled={act.busy || why.trim().length < 10} onClick={go} data-testid="release-go">{t('rel.confirm', { status: t(`rel.st_${to}`) })}</button>}
        </div>)}
    </div>
  );
}

/** Migration 50 (G1, G8): a packing record's batch code (the system's), its packs and labels; a pack voided with a reason. */
function PacksPanel({ r, mayAct, onDone }: { r: FootprintDetail; mayAct: boolean; onDone: () => void }) {
  const { t } = useI18n();
  const p = r.packs!;
  const [serial, setSerial] = useState('');
  const [why, setWhy] = useState('');
  const [done, setDone] = useState('');
  const act = useAction();
  const voidIt = () => act.run(async () => { await rpc('void_pack', { p_serial: serial.trim(), p_reason: why.trim() }); setDone(serial.trim()); setSerial(''); setWhy(''); onDone(); });
  return (
    <div className="card" data-testid="packs-panel">
      <h2>{t('pk.title')}</h2>
      <dl className="kv">
        <dt>{t('pk.batch')}</dt><dd className="mono" data-testid="batch-code">{p.batch_code ?? '—'}</dd>
        <dt>{t('pk.packs')}</dt><dd data-testid="packs-count">{t('pk.counts', { packed: p.packed, void: p.void })}</dd>
        {p.best_before && <><dt>{t('pk.best_before_label')}</dt><dd>{date(p.best_before)}</dd></>}
        <dt>{t('pk.prints')}</dt><dd>{p.prints}</dd>
      </dl>
      {mayAct && p.packed > 0 && <p><Link className="btn" to={`/records/${r.footprint.id}/labels`} data-testid="print-labels">{t(p.prints > 0 ? 'pk.reprint' : 'pk.print')}</Link></p>}
      {mayAct && p.packed > 0 && (
        <details><summary>{t('pk.void_title')}</summary>
          <div className="stack">
            <Field label={t('pk.serial')} htmlFor="pk-serial"><input id="pk-serial" className="mono" value={serial} onChange={(e) => setSerial(e.target.value)} placeholder={`${p.batch_code ?? ''}-0001`} data-testid="void-serial" /></Field>
            <Field label={`${t('pk.void_why')} *`} htmlFor="pk-vwhy" hint={t('mgr.min10')}><input id="pk-vwhy" value={why} maxLength={300} onChange={(e) => setWhy(e.target.value)} data-testid="void-why" /></Field>
            <ErrorBox error={act.error} />
            <button className="danger" disabled={act.busy || !serial.trim() || why.trim().length < 10} onClick={voidIt} data-testid="void-go">{t('pk.void')}</button>
            {done && <div className="alert ok" data-testid="voided">{t('pk.voided', { serial: done })}</div>}
          </div>
        </details>)}
    </div>
  );
}

/** Migration 50 (G12): what arrived, recorded at delivery (the transit loss is worked out by the server). For export the
 *  proof of delivery is attached first. */
function DeliveryPanel({ r, mayAct, onDone }: { r: FootprintDetail; mayAct: boolean; onDone: () => void }) {
  const { t } = useI18n();
  const f = r.footprint, d = r.delivery;
  const [got, setGot] = useState(String(f.qty_in ?? ''));
  const [on, setOn] = useState(todayIST());
  const [note, setNote] = useState('');
  const [pod, setPod] = useState<File | null>(null);
  const hasPod = r.attachments.some((a) => a.label === 'pod');
  const act = useAction();
  const confirm = () => act.run(async () => {
    if (pod && !hasPod) await uploadEvidence(f, pod, 'pod');
    await rpc('confirm_delivery', { p_shipment: f.id, p_received_kg: Number(got), p_received_on: on, p_note: note.trim() || null });
    onDone();
  });
  if (d) return (
    <div className="card" data-testid="delivery-panel" data-done="true">
      <h2>{t('dl.title')}</h2>
      <dl className="kv">
        <dt>{t('dl.received')}</dt><dd>{kg(d.received_kg)} · {date(d.received_on)}</dd>
        <dt>{t('dl.loss')}</dt><dd data-testid="transit-loss">{kg(d.transit_loss_kg)}</dd>
        {d.note && <><dt>{t('dl.note')}</dt><dd>“{d.note}”</dd></>}
        <dt>{t('dl.by')}</dt><dd>{d.confirmed_by_name ?? '—'}</dd>
      </dl>
    </div>);
  if (!mayAct || (f.status !== 'pending' && f.status !== 'verified')) return null;
  const n = Number(got);
  return (
    <div className="card stack" data-testid="delivery-panel">
      <h2>{t('dl.title')}</h2>
      <p className="muted small">{t('dl.hint', { kg: kg(f.qty_in) })}</p>
      <div className="form-grid">
        <Field label={`${t('dl.received_kg')} *`} htmlFor="dl-kg"><input id="dl-kg" inputMode="decimal" value={got} onChange={(e) => setGot(e.target.value.replace(',', '.'))} data-testid="delivery-kg" /></Field>
        <Field label={`${t('dl.on')} *`} htmlFor="dl-on"><input id="dl-on" type="date" value={on} max={todayIST()} onChange={(e) => setOn(e.target.value)} data-testid="delivery-on" /></Field>
        <Field label={t('dl.note')} htmlFor="dl-note"><input id="dl-note" value={note} maxLength={300} onChange={(e) => setNote(e.target.value)} /></Field>
        {!hasPod && <Field label={t('dl.pod')} htmlFor="dl-pod" hint={t('dl.pod_hint')}><input id="dl-pod" type="file" accept={EVIDENCE_ACCEPT} onChange={(e) => setPod(e.target.files?.[0] ?? null)} data-testid="delivery-pod" /></Field>}
      </div>
      {got !== '' && Number.isFinite(n) && n <= Number(f.qty_in) && <p data-testid="delivery-loss-preview">{t('dl.loss_preview', { kg: kg(Math.max(Number(f.qty_in) - n, 0)) })}</p>}
      <ErrorBox error={act.error} />
      <button disabled={act.busy || got === '' || !Number.isFinite(n) || !on} onClick={confirm} data-testid="delivery-confirm">{t('dl.confirm')}</button>
    </div>
  );
}

/** A QR record whose seal was refused at the gate (saved by the two-step path used before migration 24). */
function FinishSeal({ f, onDone }: { f: Footprint; onDone: () => void }) {
  const { t } = useI18n();
  const act = useAction();
  return (
    <div className="card" data-testid="finish-seal">
      <p>{t('record.finish_seal_hint')}</p>
      <ErrorBox error={act.error} />
      <button className="gold" disabled={act.busy} onClick={() => void act.run(async () => { await rpc('seal_lot', { p_qr_fp: f.id }); onDone(); })}>{t('engine.seal_button')}</button>
    </div>
  );
}

function SealPanel({ code, hash, batch }: { code: string; hash: string; batch: string[] }) {
  const { t } = useI18n();
  const [img, setImg] = useState('');
  useEffect(() => { void QRCode.toDataURL(`${window.location.origin}/verify/${code}`, { margin: 1, width: 360 }).then(setImg); }, [code]);
  return (
    <div className="card">
      <h2>{t('record.sealed')}</h2>
      <div className="qr">{img && <img src={img} alt={`QR code ${code}`} />}<div>
        <p className="big mono">{code}</p>
        <p className="small">{t('record.seal_hash')} <span className="mono">{shortHash(hash)}</span></p>
        {batch.length > 0 && <p className="small">{t('record.batch_codes', { codes: batch.join(', ') })}</p>}
        <div className="row"><Link className="btn" to={`/labels/${code}`}>{t('labels.print')}</Link>
        <Link className="btn secondary" to={`/verify/${code}`}>{t('engine.public_page')}</Link></div>
      </div></div>
    </div>
  );
}

function Attachments({ detail }: { detail: FootprintDetail }) {
  const { t } = useI18n();
  const [urls, setUrls] = useState<Record<string, string>>({});
  const [check, setCheck] = useState<Record<string, 'ok' | 'bad' | 'missing'>>({});
  useEffect(() => {
    let live = true;
    // Hash check on retrieval (PRD §9 Evidence): re-hash the stored file and compare with the SHA-256 in the record.
    detail.attachments.forEach(async (a) => {
      const { data } = await supabase.storage.from('evidence').createSignedUrl(a.storage_path, 600);
      if (!live) return;
      if (!data?.signedUrl) { setCheck((c) => ({ ...c, [a.id]: 'missing' })); return; }
      setUrls((u) => ({ ...u, [a.id]: data.signedUrl }));
      try {
        const blob = await (await fetch(data.signedUrl)).blob();
        const h = await sha256Hex(blob);
        if (live) setCheck((c) => ({ ...c, [a.id]: h === a.sha256 ? 'ok' : 'bad' }));
      } catch { if (live) setCheck((c) => ({ ...c, [a.id]: 'missing' })); }
    });
    return () => { live = false; };
  }, [detail.attachments]);
  return (
    <div className="card">
      <h2>{t('record.evidence')}</h2>
      <ul>{detail.attachments.map((a) => (
        <li key={a.id} data-label={a.label ?? ''}>{urls[a.id] ? <a href={urls[a.id]} target="_blank" rel="noreferrer">{t(`record.kind_${a.kind}`, undefined, humanise(a.kind))}</a> : t(`record.kind_${a.kind}`, undefined, humanise(a.kind))}
          {a.label && <> · {t(`att.${a.label}`, undefined, humanise(a.label))}</>}
          {' '}<span className="mono small" title={a.sha256}>sha256 {shortHash(a.sha256)}</span> · {dateTime(a.created_at)}
          {' '}{check[a.id] === 'ok' && <Badge value="verified" label={t('record.hash_ok')} />}
          {check[a.id] === 'bad' && <Badge value="fail" label={t('record.hash_bad')} />}
          {check[a.id] === 'missing' && <Badge value="pending" label={t('record.hash_missing')} />}</li>
      ))}</ul>
    </div>
  );
}

/**
 * A photo or document added after the record was saved: shipment papers, a weighbridge slip, or the photo that did not
 * upload on a weak signal. The database decides who may (anyone who can see the record); the fingerprint is ledgered.
 */
function AddEvidence({ f, onDone }: { f: Footprint; onDone: () => void }) {
  const { t } = useI18n();
  const [file, setFile] = useState<File | null>(null);
  const [done, setDone] = useState(false);
  const [round, setRound] = useState(0);
  const act = useAction();
  const attach = () => act.run(async () => {
    setDone(false);
    await uploadEvidence(f, file!);
    setFile(null); setRound((n) => n + 1); setDone(true); onDone();
  });
  return (
    <div className="card">
      <h2>{t('record.add_evidence')}</h2>
      <div className="row">
        <input key={round} aria-label={t('record.add_evidence')} type="file" accept={EVIDENCE_ACCEPT} style={{ flex: '1 1 220px', width: 'auto', minWidth: 0, maxWidth: '100%' }}
          onChange={(e) => { setFile(e.target.files?.[0] ?? null); setDone(false); }} data-testid="evidence-file" />
        <button className="secondary" disabled={!file || act.busy} onClick={attach} data-testid="evidence-attach">{t('record.attach')}</button>
      </div>
      <ErrorBox error={act.error} />
      {done && <div className="alert ok" data-testid="evidence-attached">{t('record.attached')}</div>}
    </div>
  );
}

function Flags({ detail, onChange, canResolve, canRaise }: { detail: FootprintDetail; onChange: () => void; canResolve: boolean; canRaise: boolean }) {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const [text, setText] = useState('');
  const act = useAction();
  const raise = () => act.run(async () => {
    await q(supabase.from('flags').insert({ footprint_id: detail.footprint.id, raised_by: ctx!.user!.id, text: text.trim() }).select());
    setText(''); onChange();
  });
  const setStatus = (id: string, status: string) => act.run(async () => { await q(supabase.from('flags').update({ status }).eq('id', id).select()); onChange(); });
  return (
    <div className="card">
      <h2>{t('record.flags')}</h2>
      {detail.flags.length === 0 && <p className="muted">{t('record.no_flags')}</p>}
      <ul>{detail.flags.map((f) => (
        <li key={f.id} className="row" data-kind={f.kind ?? 'flag'}><Badge value={f.status} />{f.kind === 'condition' && <Badge value="pending" label={t('cond.badge')} />} {f.text} <span className="muted small">— {f.raised_by_name ?? '—'}, {dateTime(f.created_at)}</span>
          {canResolve && f.status === 'open' && <><button className="secondary" onClick={() => setStatus(f.id, 'resolved')}>{t('record.resolve')}</button>
            <button className="secondary" onClick={() => setStatus(f.id, 'dismissed')}>{t('record.dismiss')}</button></>}</li>
      ))}</ul>
      {canRaise && (
        <div className="row">
          <input aria-label={t('record.raise_flag')} placeholder={t('record.raise_flag')} value={text} onChange={(e) => setText(e.target.value)} style={{ flex: 1 }} />
          <button className="secondary" disabled={!text.trim() || act.busy} onClick={raise}>{t('record.raise_flag')}</button>
        </div>
      )}
      <ErrorBox error={act.error} />
    </div>
  );
}
