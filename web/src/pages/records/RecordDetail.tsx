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
import { oversees, managesScope, isStateManager, isClientLogin } from '../../lib/rights';
import { type Footprint, type FootprintDetail, type QualityParam, type StageForm, type Withdrawal } from '../../lib/types';
import { Badge, ErrorBox, Loading, Field, plainText } from '../../shell/ui';
import { uploadEvidence } from '../../engine/evidence';
import { ErrorOrSameFile, useDupReason } from '../../engine/DupFile';
import { EVIDENCE_ACCEPT } from '../../engine/widgets';
import { ComputedRows, EnteredRows, capturedAt, paramName } from '../../engine/values';
import { localiseForm } from '../../engine/localise';
import { cached } from '../../offline/cache';
import { lotPayment } from './Receipt';
import { ForwardPanel } from '../trace/Forward';
import { paymentProblem } from '../../engine/offlinePreview';
import { SamplesPanel } from './Samples';
import { WarehousePanel } from './Warehouse';
import { BuyerSharePanel } from './BuyerShare';

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
      {/* migration 59 (B1): the client's login has no stage page */}
      <p className="muted small">{isClientLogin(ctx) ? <Link to="/">{t('nav.home')}</Link>
        : <Link to={`/work/${f.scope_id}/${f.stage_type}`}>{t(`stage.${f.stage_type}`, undefined, r.stage_label)}</Link>}</p>
      <h1 className="mono">{t('record.title', { code: f.footprint_code })}</h1>
      {r.data_note === 'practice_old_data' && <div className="alert warn" data-testid="old-data">{t('scope.old_data')}</div>}
      <div className="card">
        <div className="row"><Badge value={f.status} />{f.lot_closed && <Badge value="closed" label={t('record.lot_closed')} />}{f.grade && <Badge value="verified" label={t('record.grade', { grade: f.grade })} />}</div>
        <dl className="kv" style={{ marginTop: 12 }}>
          <dt>{t('record.stage')}</dt><dd>{t(`stage.${f.stage_type}`, undefined, r.stage_label)}</dd>
          {r.farmer && <><dt>{t('record.farmer')}</dt><dd>{r.farmer.name} <span className="mono">{r.farmer.farmer_code}</span>{r.farmer.state_farmer_code && <> · <span className="mono" data-testid="record-state-farmer">{r.farmer.state_farmer_code}</span></>} · {r.farmer.village}</dd></>}
          {r.prev && <><dt>{t('record.came_from')}</dt><dd><Link className="mono" to={`/records/${r.prev.id}`}>{r.prev.footprint_code}</Link> ({t(`stage.${r.prev.stage_type}`, undefined, humanise(r.prev.stage_type))})</dd></>}
          <dt>{t('record.qty_in')}</dt><dd>{kg(f.qty_in)}</dd>
          <dt>{t('record.qty_out')}</dt><dd className="big">{kg(f.qty_out)}</dd>
          <dt>{t('record.available')}</dt><dd>{kg(r.available_kg)}</dd>
          {/* migration 54: a bill of lading added after the ship sailed is no longer "to come" */}
          <ComputedRows computed={r.bill_of_lading ? { ...f.computed, bl_pending: false } : f.computed} t={t} />
          {/* migration 59 (A5): the lab with its accreditation number, wherever its report number is shown */}
          {r.lab?.name && <><dt>{t('trace.lab')}</dt><dd data-testid="record-lab">{r.lab.name}{r.lab.accreditation_no ? ` · ${t('lab.accreditation', { no: r.lab.accreditation_no })}` : ''}
            {r.lab.report_no ? ` · ${t('bv.report', { no: r.lab.report_no })}` : ''}</dd></>}
          {r.bill_of_lading && <><dt>{t('field.bl_no')}</dt><dd className="mono" data-testid="record-bl">{r.bill_of_lading.bl_no} · {date(r.bill_of_lading.added_at)}</dd></>}
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
            <EnteredRows payload={f.payload} fields={form?.stage.form_schema ?? []} stage={f.stage_type} params={form?.quality_params} computed={f.computed} t={t} />
          </dl>
        </details>
        <div className="row">
          {canCorrect && <Link className="btn secondary" to={`/work/${f.scope_id}/${f.stage_type}?edit=${f.id}`}>{t('record.edit_pending')}</Link>}
          {me.role !== 'operator' && <Link className="btn secondary" to={`/trace/${f.id}`} data-testid="trace-link">{t('record.trace')}</Link>}
          {f.stage_type === 'procurement' && <Link className="btn secondary" to={`/records/${f.id}/receipt`} data-testid="receipt-link">{t('rc.open')}</Link>}
        </div>
        {mine && frozen && <p className="hint">{t('record.fix_by_withdraw')}</p>}
      </div>
      <LotFacts r={r} />
      {f.stage_type === 'procurement' && <PaymentPanel f={f} mayAct={!watch && me.role !== 'client_view'} />}
      {sf.data?.next_stage?.stage_type === 'qc' && f.status === 'verified' && !watch && <SamplesPanel f={f} />}
      {f.stage_type === 'packing' && r.net_weight?.needed && <NetWeightPanel f={f} nw={r.net_weight} mayAct={!watch && me.role !== 'client_view'} onDone={reload} />}
      <ClosePanel r={r} mayAct={!watch && me.role !== 'client_view'} onDone={reload} />
      {f.status === 'verified' && (oversees(ctx) || (ctx?.scopes ?? []).some((x) => x.scope_id === f.scope_id && x.whole)) && <ForwardPanel fp={f.id} />}
      <WithdrawalInfo f={f} canRecord={me.role !== 'client_view' && !watch} />
      <ReturnsPanel r={r} senderReturned={senderReturned} canCorrect={canCorrect} onDone={reload} />
      {(boss || senderReturned) && (f.status === 'pending' || f.status === 'verified') && !r.seal && <WithdrawPanel f={f} onDone={reload} />}
      {r.qc && <QcPanel detail={r} onChange={reload} canOverride={boss} params={form?.quality_params ?? []} asksNames={form?.scope.stage_details_required === true} />}
      {r.seal && <SealPanel code={r.seal.qr_code} hash={r.seal.ledger_hash} batch={r.seal.batch_codes} />}
      {r.seal && r.release && <ReleasePanel r={r} mayChange={!watch && (boss || isStateManager(ctx))} onDone={reload} />}
      {/* migration 55 (C3): the Warehouse (or a manager) inspects; the Warehouse, the stage that takes the lot or a manager records bags out */}
      {f.stage_type === 'warehouse' && r.warehouse && (() => {
        const slots = (ctx?.slots ?? []).filter((x) => x.scope_id === f.scope_id);
        const next = slots[0]?.chain ? slots[0].chain[slots[0].chain.indexOf('warehouse') + 1] : undefined;
        const keeps = boss || slots.some((x) => x.stage_type === 'warehouse');
        const can = !watch && me.role !== 'client_view';
        return <WarehousePanel f={f} w={r.warehouse} mayInspect={can && keeps} mayMove={can && (keeps || slots.some((x) => x.stage_type === next))} onDone={reload} />;
      })()}
      {r.packs && <PacksPanel r={r} mayAct={me.role !== 'client_view' && !watch} onDone={reload} />}
      {r.sale_terms && <SaleTermsPanel s={r.sale_terms} />}
      {r.export_docs && r.export_docs.length > 0 && <ExportDocsPanel r={r} mayAct={me.role !== 'client_view' && !watch} onDone={reload} />}
      {f.stage_type === 'shipment' && f.computed?.market === 'export' && !r.bill_of_lading && !f.payload?.bl_no && (f.status === 'pending' || f.status === 'verified')
        && me.role !== 'client_view' && !watch && <BillOfLadingPanel f={f} onDone={reload} />}
      {f.stage_type === 'shipment' && <DeliveryPanel r={r} mayAct={me.role !== 'client_view' && !watch} onDone={reload} />}
      {/* migration 56 (Part F): a sale or a shipment shared with its buyer, by the managers of its scope */}
      {(f.stage_type === 'commercial' || f.stage_type === 'shipment') && boss && !watch && (f.status === 'pending' || f.status === 'verified')
        && <BuyerSharePanel fp={f.id} code={f.footprint_code} />}
      {f.stage_type === 'qr_activation' && f.status === 'pending' && !r.seal && me.role !== 'client_view' && !watch && <FinishSeal f={f} onDone={reload} />}
      {r.attachments.length > 0 && <Attachments detail={r} />}
      {me.role !== 'client_view' && !watch && f.status !== 'superseded' && <AddEvidence f={f} onDone={reload} />}
      <Flags detail={r} onChange={reload} canResolve={boss} canRaise={!isClientLogin(ctx)} />
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

/** Migration 52 (C1): the lot's price and payment, kept apart from the record (only the person who recorded it and the
 *  client's Client Manager read it). Paid later: the transaction ID, never an account number. */
function PaymentPanel({ f, mayAct }: { f: Footprint; mayAct: boolean }) {
  const { t } = useI18n();
  const p = useAsync(() => lotPayment(f.id), [f.id]);
  const [open, setOpen] = useState(false);
  const [mode, setMode] = useState(''); const [ref, setRef] = useState(''); const [price, setPrice] = useState('');
  const act = useAction();
  const pm = p.data;
  if (!pm) return null;
  const problem = paymentProblem({ price_per_quintal: price || pm.price_per_quintal || undefined, payment_status: 'paid', payment_mode: mode || undefined, txn_ref: ref || undefined });
  const save = () => act.run(async () => {
    await rpc('save_lot_payment', { p_fp: f.id, p: { price_per_quintal: price ? Number(price) : pm.price_per_quintal, payment_status: 'paid', payment_mode: mode, txn_ref: ref.trim() || null } });
    setOpen(false); p.reload();
  });
  return (
    <div className="card" data-testid="payment-panel" data-status={pm.status}>
      <h2>{t('pay.title')}</h2>
      <dl className="kv">
        {pm.price_per_quintal !== null && <><dt>{t('field.price_per_quintal')}</dt><dd>₹ {num(pm.price_per_quintal, 2)} / {t('rc.quintal')}</dd></>}
        {pm.amount !== null && <><dt>{t('rc.amount')}</dt><dd>₹ {num(pm.amount, 2)}</dd></>}
        <dt>{t('field.payment_status')}</dt><dd>{t(`opt.${pm.status}`)}{pm.mode ? ` · ${t(`opt.${pm.mode}`)}` : ''}{pm.txn_ref ? <> · <span className="mono">{pm.txn_ref}</span></> : null}</dd>
      </dl>
      {mayAct && pm.status === 'pending' && !open && <button className="secondary" onClick={() => setOpen(true)} data-testid="pay-mark">{t('pay.mark_paid')}</button>}
      {open && (
        <div className="stack">
          {pm.price_per_quintal === null && <Field label={`${t('field.price_per_quintal')} *`} htmlFor="pay-price">
            <input id="pay-price" inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} data-testid="pay-price" /></Field>}
          <Field label={`${t('field.payment_mode')} *`} htmlFor="pay-mode"><select id="pay-mode" value={mode} onChange={(e) => setMode(e.target.value)} data-testid="pay-mode">
            <option value="">—</option>{['bank', 'upi', 'cash'].map((m) => <option key={m} value={m}>{t(`opt.${m}`)}</option>)}</select></Field>
          {mode && mode !== 'cash' && <Field label={`${t('field.txn_ref')} *`} htmlFor="pay-ref" hint={t('pay.ref_hint')}>
            <input id="pay-ref" value={ref} maxLength={40} autoComplete="off" onChange={(e) => setRef(e.target.value)} data-testid="pay-ref" /></Field>}
          {problem && (mode || ref) && <div className="small" style={{ color: 'var(--red)' }}>{plainText(`payment: ${problem}`, t)}</div>}
          <ErrorBox error={act.error} />
          <div className="row"><button onClick={save} disabled={act.busy || !!problem} data-testid="pay-save">{t('pay.save')}</button>
            <button className="secondary" onClick={() => setOpen(false)}>{t('common.cancel')}</button></div>
        </div>)}
    </div>);
}

/** Migration 53 (C6): the net weight check: the system picks 5 packs; the operator weighs them (grams). */
function NetWeightPanel({ f, nw, mayAct, onDone }: { f: Footprint; nw: NonNullable<FootprintDetail['net_weight']>; mayAct: boolean; onDone: () => void }) {
  const { t } = useI18n();
  const act = useAction();
  const [g, setG] = useState<Record<string, string>>({});
  const c = nw.check;
  const pick = () => act.run(async () => { await rpc('pick_net_weight', { p_fp: f.id }); onDone(); });
  const save = () => act.run(async () => {
    await rpc('record_net_weights', { p_fp: f.id, p_weights: Object.fromEntries(Object.entries(g).map(([k, x]) => [k, Number(x)])) });
    setG({}); onDone();
  });
  return (
    <div className="card" data-testid="net-weight" data-result={c?.result ?? ''}>
      <h2>{t('nw.title')}</h2>
      <p className="small muted">{t('nw.why')}</p>
      {c?.result && <div className={`alert ${c.result === 'pass' ? 'ok' : 'error'}`} data-testid="nw-result">{t(`nw.${c.result}`)}</div>}
      {!c && mayAct && <button onClick={pick} disabled={act.busy} data-testid="nw-pick">{t('nw.pick')}</button>}
      {c && (
        <div className="stack">
          {c.serials.map((s) => {
            const w = c.weights?.[s];
            return (
              <div key={s} className="row">
                <label htmlFor={`nw-${s}`} className="mono small" style={{ flex: '1 1 180px', margin: 0 }}>{s}</label>
                {w && <span className="small" data-ok={w.ok}>{w.g} g {w.ok ? '✓' : '✗'} <span className="muted">({t('nw.allowed', { size: w.size_g, short: w.allowed_short_g })})</span></span>}
                {mayAct && <input id={`nw-${s}`} inputMode="decimal" placeholder={t('nw.grams')} style={{ flex: '0 0 110px', width: 'auto' }} value={g[s] ?? ''}
                  onChange={(e) => setG({ ...g, [s]: e.target.value.replace(',', '.') })} data-testid="nw-g" />}
              </div>);
          })}
          {mayAct && <button onClick={save} disabled={act.busy || c.serials.some((s) => !g[s])} data-testid="nw-save">{t(c.result ? 'nw.again' : 'nw.save')}</button>}
        </div>)}
      <ErrorBox error={act.error} />
    </div>);
}

/** Migration 53 (C4): a lot with 2 % or less left is closed by the next stage or a manager; the rest is floor loss. */
function ClosePanel({ r, mayAct, onDone }: { r: FootprintDetail; mayAct: boolean; onDone: () => void }) {
  const { t } = useI18n();
  const f = r.footprint;
  const act = useAction();
  const [why, setWhy] = useState('');
  if (r.closure) return <div className="card" data-testid="lot-closure"><p className="small">{t('cl.closed', { kg: kg(r.closure.floor_loss_kg), why: r.closure.reason, by: r.closure.closed_by_name ?? '—', at: dateTime(r.closure.closed_at) })}</p></div>;
  const left = Number(r.available_kg);
  if (!mayAct || f.status !== 'verified' || f.lot_closed || !(left > 0) || left > Math.max(Number(f.qty_out) * 0.02, 2)) return null;
  const close = () => act.run(async () => { await rpc('close_lot', { p_fp: f.id, p_reason: why.trim() }); onDone(); });
  return (
    <div className="card" data-testid="close-lot">
      <p className="small">{t('cl.offer', { kg: kg(left) })}</p>
      <Field label={`${t('cl.why')} *`} htmlFor="cl-why"><input id="cl-why" value={why} onChange={(e) => setWhy(e.target.value)} data-testid="close-why" /></Field>
      <ErrorBox error={act.error} />
      <button className="secondary" onClick={close} disabled={act.busy || why.trim().length < 5} data-testid="close-go">{t('cl.go')}</button>
    </div>);
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

function QcPanel({ detail, onChange, canOverride, params, asksNames }: { detail: FootprintDetail; onChange: () => void; canOverride: boolean; params: QualityParam[];
  /** migration 53: the scope asks the stage details: the export release names who accepted it, their title and the date */ asksNames: boolean }) {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const qc = detail.qc!;
  const unit = (p: string) => { const q = params.find((x) => x.param === p); return { label: q?.label, unit: q?.unit }; };
  const [reason, setReason] = useState('');
  // migration 50: the client's written acceptance is attached before an export release
  const hasAcceptance = detail.attachments.some((a) => a.label === 'acceptance');
  const [acceptance, setAcceptance] = useState<File | null>(null);
  const act = useAction();
  const dup = useDupReason();
  // migration 53 (C5): who at the client accepted it, their title, the date of the acceptance
  const [person, setPerson] = useState(''); const [title, setTitle] = useState(''); const [accOn, setAccOn] = useState('');
  const override = () => act.run(async () => {
    if (!hasAcceptance && acceptance) await uploadEvidence(detail.footprint, acceptance, 'acceptance', dup.value);
    const named = { client_person: person.trim(), client_title: title.trim(), accepted_on: accOn };
    await q(supabase.from('qc_verdicts').update({ override: { market: 'export', reason, authoriser: ctx!.user!.id,
      ...Object.fromEntries(Object.entries(named).filter(([, x]) => x !== '')) } })
      .eq('footprint_id', detail.footprint.id).select());
    onChange();
  });
  return (
    <div className="card">
      <h2>{t('record.qc_title')}</h2>
      <p>{t('record.domestic')} <Badge value={qc.domestic_verdict} /> · {t('record.export')} <Badge value={qc.export_verdict} /> <span className="muted small">{t('record.derived')}</span></p>
      {(detail.profile_verdicts ?? []).length > 0 && (
        <p data-testid="profile-verdicts">{t('qcm.by_market')}: {(detail.profile_verdicts ?? []).map((v, i) => (
          <span key={v.code} data-market={v.code} data-verdict={v.verdict}>{i > 0 ? ' · ' : ''}{v.name} <Badge value={v.verdict} />
            {v.failed.length > 0 && <span className="small"> ({v.failed.join(', ')})</span>}
            {v.verdict === 'pending' && v.missing.length > 0 && <span className="small muted"> ({t('qcm.not_read', { what: v.missing.join(', ') })})</span>}</span>))}</p>)}
      <div className="table-wrap"><table>
        <thead><tr><th>{t('record.param')}</th><th>{t('record.reading')}</th><th>{t('record.domestic')}</th><th>{t('record.export')}</th></tr></thead>
        <tbody>{qc.judged.map((j) => <tr key={j.param}><td>{t(`qp.${j.param}`, undefined, unit(j.param).label ?? paramName(j.param))}</td><td className="num">{typeof j.value === 'boolean' ? t(j.value ? 'common.yes' : 'common.no') : typeof j.value === 'string' ? j.value : <>{num(j.value)}{j.value !== null && unit(j.param).unit ? ` ${unit(j.param).unit}` : ''}</>}</td>
          <td><Badge value={j.domestic} /></td><td><Badge value={j.export} /></td></tr>)}</tbody>
      </table></div>
      {qc.override && <div className="alert warn">{t('record.override_done', { market: t(`opt.${String(qc.override.market)}`, undefined, String(qc.override.market)), reason: String(qc.override.reason), at: dateTime(String(qc.override.at)) })}
        {qc.override.client_person ? <div className="small" data-testid="override-by-client">{t('ov.accepted_by', { person: String(qc.override.client_person), title: String(qc.override.client_title ?? ''), on: date(String(qc.override.accepted_on ?? '')) })}</div> : null}</div>}
      {canOverride && !qc.override && qc.export_verdict === 'fail' && (
        <div className="stack">
          <h3>{t('record.override')}</h3>
          <Field label={t('record.override_reason')} htmlFor="ov-reason"><textarea id="ov-reason" value={reason} onChange={(e) => setReason(e.target.value)} rows={2} /></Field>
          {hasAcceptance ? <p className="small" data-testid="acceptance-on-file">{t('ov.acceptance_on_file')}</p>
            : <Field label={`${t('ov.acceptance')} *`} htmlFor="ov-acc" hint={t('ov.acceptance_hint')}>
                <input id="ov-acc" type="file" accept={EVIDENCE_ACCEPT} onChange={(e) => setAcceptance(e.target.files?.[0] ?? null)} data-testid="acceptance-file" /></Field>}
          <Field label={`${t('ov.client_person')}${asksNames ? ' *' : ''}`} htmlFor="ov-person"><input id="ov-person" value={person} onChange={(e) => setPerson(e.target.value)} data-testid="ov-person" /></Field>
          <Field label={`${t('ov.client_title')}${asksNames ? ' *' : ''}`} htmlFor="ov-title"><input id="ov-title" value={title} onChange={(e) => setTitle(e.target.value)} data-testid="ov-title" /></Field>
          <Field label={`${t('ov.accepted_on')}${asksNames ? ' *' : ''}`} htmlFor="ov-on"><input id="ov-on" type="date" value={accOn} max={todayIST()} onChange={(e) => setAccOn(e.target.value)} data-testid="ov-on" /></Field>
          <ErrorOrSameFile error={act.error} reason={dup.reason} setReason={dup.setReason} retry={override} busy={act.busy} />
          <button className="danger" disabled={!reason.trim() || act.busy || (!hasAcceptance && !acceptance) || (asksNames && (person.trim().length < 2 || title.trim().length < 2 || !accOn))} onClick={override}>{t('record.override')}</button>
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
  const dup = useDupReason();
  const confirm = () => act.run(async () => {
    if (pod && !hasPod) await uploadEvidence(f, pod, 'pod', dup.value);
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
      <ErrorOrSameFile error={act.error} reason={dup.reason} setReason={dup.setReason} retry={confirm} busy={act.busy} />
      <button disabled={act.busy || got === '' || !Number.isFinite(n) || !on} onClick={confirm} data-testid="delivery-confirm">{t('dl.confirm')}</button>
    </div>
  );
}

/** Migration 54 (C7): the sale's price and terms, kept apart from the record (the recorder, the client's Client Manager). */
function SaleTermsPanel({ s }: { s: NonNullable<FootprintDetail['sale_terms']> }) {
  const { t } = useI18n();
  return (
    <div className="card" data-testid="sale-terms">
      <h2>{t('section.terms')}</h2>
      <dl className="kv">
        <dt>{t('field.price_per_kg')}</dt><dd>{s.price_per_kg === null ? '—' : `${s.currency} ${num(s.price_per_kg, 2)} / kg`}</dd>
        {s.incoterms && <><dt>{t('field.incoterms')}</dt><dd>{s.incoterms}</dd></>}
        {s.total_value !== null && <><dt>{t('ord.value')}</dt><dd data-testid="sale-value">{s.currency} {num(s.total_value, 2)}</dd></>}
      </dl>
    </div>);
}

/** Migration 54 (C7): the export documents the buyer's market asks for (its profile). Each is received (with its file),
 *  applied for, or not required (with why). The shipment of the order waits until every one is received or not
 *  required. Kept by Commercial or a manager of the scope: the server decides. */
function ExportDocsPanel({ r, mayAct, onDone }: { r: FootprintDetail; mayAct: boolean; onDone: () => void }) {
  const { t } = useI18n();
  const f = r.footprint;
  const docs = r.export_docs ?? [];
  const [edit, setEdit] = useState<{ doc: string; status: string; note: string; file: File | null } | null>(null);
  const act = useAction();
  const dup = useDupReason();
  const save = () => act.run(async () => {
    let att: string | null = null;
    if (edit!.status === 'received' && edit!.file) {
      const path = await uploadEvidence(f, edit!.file, 'export_doc', dup.value);
      att = ((await q(supabase.from('attachments').select('id').eq('footprint_id', f.id).eq('storage_path', path).single())) as unknown as { id: string }).id;
    }
    await rpc('set_export_doc', { p_fp: f.id, p_doc: edit!.doc, p_status: edit!.status, p_attachment: att, p_note: edit!.note.trim() || null });
    setEdit(null); onDone();
  });
  const done = docs.filter((d) => d.done).length;
  const open = mayAct && (f.status === 'pending' || f.status === 'verified');
  return (
    <div className="card stack" data-testid="export-docs" data-done={done === docs.length ? 'yes' : 'no'}>
      <h2>{t('xd.title')}</h2>
      <p className="small muted">{t('xd.n_of_m', { n: done, m: docs.length })}</p>
      <ul className="sys-checks">{docs.map((d, i) => (
        <li key={d.doc} className={d.done ? 'ok' : 'not'} data-testid={`export-doc-${i}`} data-status={d.status ?? 'none'}>
          <span aria-hidden="true">{d.done ? '✓' : '✗'}</span> {d.doc} · {t(`xd.st_${d.status ?? 'none'}`)}{d.note ? ` (“${d.note}”)` : ''}
          {open && edit?.doc !== d.doc && <> <button type="button" className="secondary small" onClick={() => setEdit({ doc: d.doc, status: d.status ?? 'received', note: d.note ?? '', file: null })}
            data-testid={`export-doc-edit-${i}`}>{t('common.edit')}</button></>}
          {open && edit?.doc === d.doc && (
            <div className="stack">
              <Field label={t('common.status')} htmlFor={`xd-st-${i}`}><select id={`xd-st-${i}`} value={edit.status} onChange={(e) => setEdit({ ...edit, status: e.target.value })} data-testid={`export-doc-status-${i}`}>
                {['received', 'applied', 'not_required'].map((x) => <option key={x} value={x}>{t(`xd.st_${x}`)}</option>)}</select></Field>
              {edit.status === 'received' && <Field label={`${t('xd.file')} *`} htmlFor={`xd-file-${i}`}>
                <input id={`xd-file-${i}`} type="file" accept={EVIDENCE_ACCEPT} onChange={(e) => setEdit({ ...edit, file: e.target.files?.[0] ?? null })} data-testid={`export-doc-file-${i}`} /></Field>}
              {edit.status === 'not_required' && <Field label={`${t('xd.why')} *`} htmlFor={`xd-note-${i}`}>
                <input id={`xd-note-${i}`} value={edit.note} maxLength={300} onChange={(e) => setEdit({ ...edit, note: e.target.value })} data-testid={`export-doc-note-${i}`} /></Field>}
              <ErrorOrSameFile error={act.error} reason={dup.reason} setReason={dup.setReason} retry={save} busy={act.busy} />
              <div className="row"><button onClick={save} data-testid={`export-doc-save-${i}`}
                disabled={act.busy || (edit.status === 'received' && !edit.file && !d.attachment_id) || (edit.status === 'not_required' && edit.note.trim().length < 5)}>{t('common.save')}</button>
                <button className="secondary" onClick={() => setEdit(null)}>{t('common.cancel')}</button></div>
            </div>)}
        </li>))}</ul>
    </div>);
}

/** Migration 54 (C8): the bill of lading, when it comes after the ship sailed ("Sailed, BL pending"): added once. */
function BillOfLadingPanel({ f, onDone }: { f: Footprint; onDone: () => void }) {
  const { t } = useI18n();
  const [bl, setBl] = useState('');
  const act = useAction();
  return (
    <div className="card stack" data-testid="bl-panel">
      <h2>{t('bl.title')}</h2>
      <p className="small muted">{t('bl.hint')}</p>
      <Field label={`${t('field.bl_no')} *`} htmlFor="bl-no"><input id="bl-no" value={bl} maxLength={30} autoComplete="off" onChange={(e) => setBl(e.target.value)} data-testid="bl-no" /></Field>
      <ErrorBox error={act.error} />
      <button disabled={act.busy || !/^[A-Za-z0-9/-]{4,30}$/.test(bl.trim())} onClick={() => void act.run(async () => { await rpc('add_bill_of_lading', { p_fp: f.id, p_bl: bl.trim() }); onDone(); })}
        data-testid="bl-save">{t('bl.save')}</button>
    </div>);
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
  const dup = useDupReason();
  const attach = () => act.run(async () => {
    setDone(false);
    await uploadEvidence(f, file!, null, dup.value);
    setFile(null); setRound((n) => n + 1); setDone(true); dup.setReason(''); onDone();
  });
  return (
    <div className="card">
      <h2>{t('record.add_evidence')}</h2>
      <div className="row">
        <input key={round} aria-label={t('record.add_evidence')} type="file" accept={EVIDENCE_ACCEPT} style={{ flex: '1 1 220px', width: 'auto', minWidth: 0, maxWidth: '100%' }}
          onChange={(e) => { setFile(e.target.files?.[0] ?? null); setDone(false); dup.setReason(''); }} data-testid="evidence-file" />
        <button className="secondary" disabled={!file || act.busy} onClick={attach} data-testid="evidence-attach">{t('record.attach')}</button>
      </div>
      <ErrorOrSameFile error={act.error} reason={dup.reason} setReason={dup.setReason} retry={attach} busy={act.busy} />
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
