// The generic 8-step coach engine (PRD §5.3, execution plan §6). One component for every stage type.
//   1 Look up   app.stage_form            5 Maths    app.preview_reconcile (same function the save trigger runs)
//   2 Arrival   app.incoming_records      6 Review   confirm what will be stored
//   3 Verify    app.verify_footprint      7 Save     insert footprints (gate stage: app.seal_lot)
//   4 Form      stage.form_schema         8 Handoff  the tick-list the next stage will check
import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import QRCode from 'qrcode';
import { rpc, q } from '../lib/api';
import { supabase } from '../lib/supabase';
import { useAsync, useAction } from '../lib/useAsync';
import { useI18n } from '../lib/i18n';
import { kg, dateTime, humanise, num } from '../lib/format';
import type { Footprint, Preview, StageForm, StageType } from '../lib/types';
import { ErrorBox, Loading, Badge, Empty } from '../shell/ui';
import { Widget, buildPayload, missingRequired, PREFILL_FROM_SOURCE, SUPPORTED, type FieldValue } from './widgets';
import { uploadEvidence } from './evidence';
import { offlinePreview, type OfflinePreview } from './offlinePreview';
import { localiseForm } from './localise';
import { cached, isNetworkError } from '../offline/cache';
import { enqueue, discard, getOutboxItem, type OutboxItem } from '../offline/outbox';
import { useOnline } from '../offline/useOutbox';
import { useAuth } from '../auth/AuthProvider';

type Step = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8;

export function Stepper({ current, form }: { current: Step; form: StageForm }) {
  const { t } = useI18n();
  const s = form.stage;
  const skipped = (n: number) => (s.is_first && (n === 2 || n === 3)) || (s.is_gate && n >= 4 && n <= 6);
  return (
    <ol className="stepper" aria-label="Steps">
      {[1, 2, 3, 4, 5, 6, 7, 8].map((n) => (
        <li key={n} className={skipped(n) ? 'skipped' : n < current ? 'done' : n === current ? 'current' : ''}
          aria-current={n === current ? 'step' : undefined}>{n} {t(`engine.step${n}`)}</li>
      ))}
    </ol>
  );
}

export function StagePage() {
  const { scopeId = '', stage = '' } = useParams();
  const [search] = useSearchParams();
  const editId = search.get('edit');
  const draftId = search.get('draft');
  const { t, lang } = useI18n();
  const form = useAsync(() => cached(`stage_form:${scopeId}:${stage}`, () => rpc<StageForm>('stage_form', { p_scope: scopeId, p_stage: stage })), [scopeId, stage]);
  const [draft, setDraft] = useState<OutboxItem | null>(null);
  useEffect(() => { if (draftId) void getOutboxItem(draftId).then((d) => setDraft(d ?? null)); else setDraft(null); }, [draftId]);
  const [tab, setTab] = useState<'incoming' | 'new' | 'records'>('incoming');
  const [source, setSource] = useState<Footprint | null>(null);
  const [editing, setEditing] = useState<Footprint | null>(null);

  useEffect(() => { if (form.data) setTab(form.data.stage.is_first ? 'new' : 'incoming'); }, [form.data]);
  useEffect(() => {
    if (!editId) { setEditing(null); return; }
    q(supabase.from('footprints').select('*').eq('id', editId).single()).then((f) => { setEditing(f as unknown as Footprint); setTab('new'); });
  }, [editId]);

  // eslint-disable-next-line react-hooks/exhaustive-deps
  const localised = useMemo(() => (form.data ? localiseForm(form.data, t) : null), [form.data, lang]);
  if (form.loading) return <Loading />;
  if (form.error || !form.data || !localised) return <ErrorBox error={form.error} onRetry={form.reload} />;
  const f = localised;
  const prevLabel = f.prev_stage?.label ?? '';

  return (
    <div>
      <p className="muted small"><Link to="/">{t('nav.home')}</Link> · {f.scope.client.name} · {f.scope.crop.name} · {f.scope.season_code} · {f.scope.geography}</p>
      <h1>{f.stage.label}</h1>
      <div className="tabs" role="tablist">
        {!f.stage.is_first && <button role="tab" aria-selected={tab === 'incoming'} className={tab === 'incoming' ? 'active' : ''}
          onClick={() => { setTab('incoming'); setSource(null); }}>{t('engine.incoming', { stage: prevLabel })}</button>}
        {(f.stage.is_first || f.stage.aggregates) && f.can_create && <button role="tab" aria-selected={tab === 'new'} className={tab === 'new' ? 'active' : ''}
          onClick={() => setTab('new')}>{t('engine.new_record', { stage: f.stage.label })}</button>}
        <button role="tab" aria-selected={tab === 'records'} className={tab === 'records' ? 'active' : ''} onClick={() => setTab('records')}>{t('engine.my_records')}</button>
      </div>
      {draft && <RecordForm key={draft.id} form={f} source={draft.source as Footprint | null} editing={null} draft={draft} />}
      {!draft && tab === 'incoming' && !source && <Incoming form={f} onPick={(fp) => setSource(fp)} />}
      {!draft && tab === 'incoming' && source && (
        <VerifyAndContinue form={f} source={source} onBack={() => setSource(null)} onReload={(fp) => setSource(fp)} />
      )}
      {!draft && tab === 'new' && (f.can_create || editing) && (
        <RecordForm key={editing?.id ?? 'new'} form={f} source={null} editing={editing} />
      )}
      {!draft && tab === 'records' && <Records form={f} />}
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Step 2: what is waiting from the stage behind (thumb rule: only that stage, only this scope)
// ---------------------------------------------------------------------------------------------------------------
function Incoming({ form, onPick }: { form: StageForm; onPick: (f: Footprint) => void }) {
  const { t } = useI18n();
  const inc = useAsync(() => cached(`incoming:${form.scope.id}:${form.stage.stage_type}`,
    () => rpc<Footprint[]>('incoming_records', { p_scope: form.scope.id, p_stage: form.stage.stage_type })), [form.scope.id, form.stage.stage_type]);
  return (
    <div className="card">
      <Stepper current={2} form={form} />
      {inc.loading ? <Loading /> : <ErrorBox error={inc.error} onRetry={inc.reload} />}
      {inc.data && inc.data.length === 0 && <Empty>{t('engine.no_incoming', { stage: form.prev_stage?.label ?? '' })}</Empty>}
      {inc.data && inc.data.length > 0 && (
        <div className="table-wrap">
          <table>
            <thead><tr><th>{t('engine.col_code')}</th><th>{t('engine.col_qty')}</th><th>{t('common.status')}</th><th className="hide-mobile">{t('engine.col_recorded')}</th></tr></thead>
            <tbody>
              {inc.data.map((r) => (
                <tr key={r.id} className="clickable" onClick={() => onPick(r)} data-testid="incoming-row">
                  <td className="mono">{r.footprint_code}{r.grade ? ` · Grade ${r.grade}` : ''}</td>
                  <td className="num">{kg(r.qty_out)}</td>
                  <td><Badge value={r.status} /></td>
                  <td className="hide-mobile">{dateTime(r.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Step 3: the receiving operator ticks the previous stage's handoff list and verifies; then records (or seals)
// ---------------------------------------------------------------------------------------------------------------
function VerifyAndContinue({ form, source, onBack, onReload }: {
  form: StageForm; source: Footprint; onBack: () => void; onReload: (f: Footprint) => void;
}) {
  const { t } = useI18n();
  const checks = form.prev_stage?.handoff_checks ?? [];
  const [ticked, setTicked] = useState<boolean[]>(checks.map(() => false));
  const [continueTo, setContinueTo] = useState(false);
  const [round, setRound] = useState(0);
  const act = useAction();
  const [sealed, setSealed] = useState<{ qr_code: string; img: string } | null>(null);

  const verify = () => act.run(async () => {
    const r = await rpc<Footprint>('verify_footprint', { p_fp: source.id });
    onReload(r);
  });

  const seal = () => act.run(async () => {
    const me = (await rpc<{ user: { id: string } }>('my_context')).user.id;
    const created = await q(supabase.from('footprints').insert({
      scope_id: form.scope.id, client_id: form.scope.client.id, stage_type: form.stage.stage_type,
      prev_footprint_id: source.id, created_by: me, payload: {},
    }).select().single()) as Footprint;
    const s = await rpc<{ qr_code: string }>('seal_lot', { p_qr_fp: created.id });
    setSealed({ qr_code: s.qr_code, img: await QRCode.toDataURL(`${window.location.origin}/verify/${s.qr_code}`, { margin: 1, width: 360 }) });
  });

  if (sealed) {
    return (
      <div className="card">
        <Stepper current={8} form={form} />
        <div className="alert ok" data-testid="sealed">{t('engine.sealed', { code: sealed.qr_code })}</div>
        <div className="qr"><img src={sealed.img} alt={`QR code ${sealed.qr_code}`} /><div>
          <p className="big mono">{sealed.qr_code}</p>
          <p>{t('engine.handoff_last')}</p>
          <div className="row"><Link className="btn" to={`/labels/${sealed.qr_code}`}>{t('labels.print')}</Link>
          <Link className="btn secondary" to={`/verify/${sealed.qr_code}`}>{t('engine.public_page')}</Link></div>
        </div></div>
      </div>
    );
  }
  if (continueTo) return <RecordForm key={round} form={form} source={source} editing={null} onAnother={() => setRound((r) => r + 1)} />;

  const verified = source.status === 'verified';
  return (
    <div className="card">
      <Stepper current={3} form={form} />
      <button className="secondary" onClick={onBack}>{t('common.back')}</button>
      <h2>{t('engine.verify_title', { stage: form.prev_stage?.label ?? '' })}</h2>
      <dl className="kv">
        <dt>{t('engine.col_code')}</dt><dd className="mono">{source.footprint_code}{source.grade ? ` · Grade ${source.grade}` : ''}</dd>
        <dt>{t('engine.qty_forwarded')}</dt><dd className="big">{kg(source.qty_out)}</dd>
        {Object.entries(source.computed ?? {}).map(([k, v]) => (
          <FragmentKV key={k} k={t(`computed.${k}`, undefined, humanise(k))} v={typeof v === 'object' ? JSON.stringify(v) : num(v as number)} />
        ))}
        <dt>{t('common.status')}</dt><dd><Badge value={source.status} /></dd>
      </dl>
      {source.warnings?.length > 0 && <div className="alert warn">{source.warnings.join(' · ')}</div>}
      <p><Link to={`/records/${source.id}`}>{t('engine.open_full')}</Link></p>
      {!verified && form.can_verify_incoming && (
        <>
          <p className="muted">{t('engine.verify_hint')}</p>
          {checks.map((c, i) => (
            <label key={c} className="check">
              <input type="checkbox" checked={ticked[i]} onChange={(e) => setTicked(ticked.map((x, j) => (j === i ? e.target.checked : x)))} />
              {c}
            </label>
          ))}
          <ErrorBox error={act.error} />
          <button onClick={verify} disabled={act.busy || ticked.some((x) => !x)}>{t('engine.verify_button')}</button>
        </>
      )}
      {!verified && !form.can_verify_incoming && <div className="alert info">{t('engine.waiting_verify', { stage: form.stage.label })}</div>}
      {verified && (
        <>
          <div className="alert ok">{t('engine.verified')}</div>
          <ErrorBox error={act.error} />
          {form.stage.is_gate
            ? form.can_create && <button className="gold" onClick={seal} disabled={act.busy}>{t('engine.seal_button')}</button>
            : form.can_create
              ? <button onClick={() => setContinueTo(true)}>{t('engine.use_lot', { stage: form.stage.label })}</button>
              : <div className="alert info">{t('engine.cannot_create')}</div>}
        </>
      )}
    </div>
  );
}

function FragmentKV({ k, v }: { k: string; v: string }) { return <><dt>{k}</dt><dd>{v}</dd></>; }

// ---------------------------------------------------------------------------------------------------------------
// Steps 4–8: form, live maths, review, save, handoff
// ---------------------------------------------------------------------------------------------------------------
function RecordForm({ form, source, editing, onAnother, draft }: {
  form: StageForm; source: Footprint | null; editing: Footprint | null; onAnother?: () => void; draft?: OutboxItem;
}) {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const online = useOnline();
  const fields = form.stage.form_schema;
  const [values, setValues] = useState<Record<string, FieldValue>>(() =>
    draft ? (draft.values as Record<string, FieldValue>) : initialValues(form, source, editing));
  const [preview, setPreview] = useState<Preview | OfflinePreview | null>(null);
  const [queued, setQueued] = useState<OutboxItem | null>(null);
  const [reviewing, setReviewing] = useState(false);
  const [confirmed, setConfirmed] = useState(false);
  const [saved, setSaved] = useState<Footprint | null>(null);
  const [photoError, setPhotoError] = useState<string | null>(null);
  const [gradeLots, setGradeLots] = useState<Footprint[]>([]);
  const [leftOnSource, setLeftOnSource] = useState<number | null>(null);
  const act = useAction();
  const unsupported = fields.filter((f) => !SUPPORTED.has(f.type) && f.required);
  const missing = missingRequired(fields, values);
  const built = useMemo(() => buildPayload(fields, values), [fields, values]);
  const timer = useRef<number | undefined>(undefined);

  useEffect(() => {
    setReviewing(false); setConfirmed(false);
    if (missing.length) { setPreview(null); return; }
    window.clearTimeout(timer.current);
    const local = () => offlinePreview(form.stage.stage_type, built.payload, built.columns, form.scope.tolerances);
    if (!online && !editing) { setPreview(local()); return; }
    timer.current = window.setTimeout(async () => {
      try {
        const p = editing
          ? await rpc<Preview>('preview_correction', { p_fp: editing.id, p_payload: built.payload, p_farmer: built.columns.farmer_id ?? null })
          : await rpc<Preview>('preview_reconcile', { p_scope: form.scope.id, p_stage: form.stage.stage_type,
              p_prev: source?.id ?? built.columns.prev_footprint_id ?? null, p_payload: built.payload, p_farmer: built.columns.farmer_id ?? null,
              p_split: built.columns.split_into_grades === true });
        setPreview(p);
      } catch (e) { setPreview(isNetworkError(e) && !editing ? local() : { ok: false, error: (e as Error).message }); }
    }, 350);
    return () => window.clearTimeout(timer.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(built.payload), JSON.stringify(built.columns), missing.length, online]);

  /** Keep the save on this phone; the outbox sends it when the connection returns (oldest first). */
  const queue = async (me: string) => {
    const row = { scope_id: form.scope.id, client_id: form.scope.client.id, stage_type: form.stage.stage_type,
      prev_footprint_id: source?.id ?? null, created_by: me, payload: built.payload, ...built.columns };
    const farmerName = document.querySelector('[data-testid="farmer-picked"] strong')?.textContent;
    const qty = (preview as OfflinePreview | null)?.qty_out;
    const item = await enqueue({
      user_id: me, scope_id: form.scope.id, stage_type: form.stage.stage_type, stage_label: form.stage.label,
      scope_label: `${form.scope.crop.name} · ${form.scope.season_code} · ${form.scope.geography}`,
      summary: [farmerName, source?.footprint_code, qty !== undefined ? kg(qty) : null].filter(Boolean).join(' · '),
      row, values: Object.fromEntries(Object.entries(values).filter(([, v]) => !(v instanceof File))),
      source: source ? { id: source.id, footprint_code: source.footprint_code, qty_out: source.qty_out } : null,
      split: built.columns.split_into_grades === true,
      files: built.files.map(({ file }) => ({ name: file.name, type: file.type, blob: file })),
    });
    if (draft) await discard(draft.id);
    setQueued(item);
  };

  const save = () => act.run(async () => {
    const me = ctx!.user!.id;
    let rec: Footprint;
    if (editing) {
      rec = await q(supabase.from('footprints').update({ payload: built.payload, ...built.columns }).eq('id', editing.id).select().single()) as Footprint;
    } else {
      if (!online) { await queue(me); return; }
      try {
        rec = await q(supabase.from('footprints').insert({
          scope_id: form.scope.id, client_id: form.scope.client.id, stage_type: form.stage.stage_type,
          prev_footprint_id: source?.id ?? null, created_by: me, payload: built.payload, ...built.columns,
        }).select().single()) as Footprint;
      } catch (e) {
        if (isNetworkError(e)) { await queue(me); return; }   // connection dropped while saving: keep it on the phone
        throw e;
      }
      if (draft) await discard(draft.id);
    }
    for (const { file } of built.files) {
      try { await uploadEvidence(rec, file); } catch (e) { setPhotoError((e as Error).message); }
    }
    if (form.stage.splits_forward && rec.split_into_grades && !editing) setGradeLots(await rpc<Footprint[]>('split_grades', { p_run: rec.id }));
    if (source && form.stage.splits_forward && !editing) setLeftOnSource(await rpc<number>('available_qty', { p_fp: source.id }));
    setSaved(rec);
  });

  if (queued) {
    return (
      <div className="card">
        <Stepper current={7} form={form} />
        <div className="alert warn" data-testid="queued">{t('engine.queued')}</div>
        <p className="small">{queued.summary}</p>
        <div className="row">
          <Link className="btn secondary" to="/outbox">{t('nav.outbox')}</Link>
          <button onClick={() => { setQueued(null); setValues(initialValues(form, source, null)); setPreview(null); }} data-testid="queue-another">
            {t('engine.new_record', { stage: form.stage.label })}</button>
        </div>
      </div>
    );
  }

  if (saved) {
    return (
      <div className="card">
        <Stepper current={8} form={form} />
        <div className="alert ok" data-testid="saved">{t('engine.saved', { code: saved.footprint_code })} · {kg(saved.qty_out)}</div>
        {photoError && <div className="alert warn">{t('engine.photo_failed', { reason: photoError })}</div>}
        {gradeLots.length > 0 && (
          <div className="alert info" data-testid="grade-lots">{t('engine.grade_lots', { lots: gradeLots.map((g) => `${g.footprint_code} (${kg(g.qty_out)})`).join(' · '), stage: form.next_stage?.label ?? '' })}</div>
        )}
        {leftOnSource !== null && leftOnSource > 0 && onAnother && (
          <div className="alert info">{t('engine.available', { kg: kg(leftOnSource) })}
            <div><button className="secondary" onClick={onAnother} data-testid="another">{t('engine.another', { stage: form.stage.label })}</button></div></div>
        )}
        {form.next_stage ? (
          <>
            <h3>{t('engine.handoff_title', { stage: form.next_stage.label })}</h3>
            <ul>{form.stage.handoff_checks.map((c) => <li key={c}>{c}</li>)}</ul>
          </>
        ) : <p>{t('engine.handoff_last')}</p>}
        <div className="row">
          <Link className="btn" to={`/records/${saved.id}`}>{t('common.open')} {saved.footprint_code}</Link>
          <button className="secondary" onClick={() => window.location.reload()}>{t('engine.new_record', { stage: form.stage.label })}</button>
        </div>
      </div>
    );
  }

  const step: Step = reviewing ? 6 : preview?.ok ? 5 : 4;
  return (
    <div className="card">
      <Stepper current={step} form={form} />
      {editing && <div className="alert info">{t('record.edit_pending')}: <span className="mono">{editing.footprint_code}</span></div>}
      {editing && !online && <div className="alert warn">{t('engine.correct_needs_network')}</div>}
      {draft?.error && <div className="alert error" data-testid="draft-error">{t('engine.draft_refused')} {draft.error}</div>}
      {source && <p className="muted">{t('engine.source_lot')} <span className="mono">{source.footprint_code}</span> · {kg(source.qty_out)}</p>}
      {unsupported.length > 0 && <div className="alert warn">{t('engine.widget_missing')} ({unsupported.map((f) => f.label).join(', ')})</div>}
      <form onSubmit={(e) => { e.preventDefault(); if (preview?.ok) setReviewing(true); }} aria-label={`${form.stage.label} form`}>
        <fieldset disabled={reviewing} style={{ border: 'none', padding: 0, margin: 0 }}>
          {fields.map((fd) => (
            <div className="field" key={fd.key}>
              <label htmlFor={`f-${fd.key}`}>{fd.label}{fd.unit ? ` (${fd.unit})` : ''}{fd.required ? ' *' : ''}</label>
              <Widget id={`f-${fd.key}`} field={fd} value={values[fd.key] ?? null} qualityParams={form.quality_params}
                clientId={form.scope.client.id} scopeId={form.scope.id} stageType={form.stage.stage_type}
                onChange={(v) => setValues((s) => ({ ...s, [fd.key]: v }))} />
            </div>
          ))}
        </fieldset>
        <MathsPanel preview={preview} missing={missing} />
        {!reviewing && <button type="submit" disabled={!preview?.ok || unsupported.length > 0}>{t('engine.review')}</button>}
      </form>
      {reviewing && preview?.ok && (
        <div className="stack" data-testid="review">
          <h3>{t('engine.will_save')}</h3>
          <dl className="kv">
            <dt>{t('engine.qty_in')}</dt><dd className="num">{kg(preview.qty_in)}</dd>
            <dt>{t('engine.qty_out')}</dt><dd className="big" data-testid="review-qty-out">{kg(preview.qty_out)}</dd>
            {Object.entries(preview.computed ?? {}).map(([k, v]) => <FragmentKV key={k} k={t(`computed.${k}`, undefined, humanise(k))} v={typeof v === 'object' ? JSON.stringify(v) : num(v as number, 3)} />)}
          </dl>
          {preview.warnings && preview.warnings.length > 0 && <div className="alert warn">{t('engine.warnings')}: {preview.warnings.join(' · ')}</div>}
          <label className="check"><input type="checkbox" checked={confirmed} onChange={(e) => setConfirmed(e.target.checked)} />{t('engine.review_confirm')}</label>
          <ErrorBox error={act.error} />
          <div className="row">
            <button className="secondary" onClick={() => setReviewing(false)}>{t('common.edit')}</button>
            <button onClick={save} disabled={!confirmed || act.busy || (!!editing && !online)}>{online ? t('engine.save_button') : t('engine.save_offline')}</button>
          </div>
        </div>
      )}
    </div>
  );
}

function MathsPanel({ preview, missing }: { preview: Preview | OfflinePreview | null; missing: string[] }) {
  const { t } = useI18n();
  if (missing.length) return <div className="alert info" aria-live="polite">{t('engine.preview_wait')} <span className="small">({missing.join(', ')})</span></div>;
  if (!preview) return <div className="alert info" aria-live="polite">{t('common.loading')}</div>;
  if (!preview.ok) return <div className="alert error" aria-live="polite" data-testid="preview-error">{t('engine.refused')} {preview.error}</div>;
  const off = (preview as OfflinePreview).offline;
  if (off && (preview as OfflinePreview).provisional)
    return <div className="alert warn" aria-live="polite" data-testid="preview-ok">{t('engine.offline_provisional')}</div>;
  return (
    <div className="alert ok" aria-live="polite" data-testid="preview-ok">
      {off && <div className="small" data-testid="offline-maths">{t('engine.offline_maths')}</div>}
      <strong>{kg(preview.qty_out)}</strong> {t('engine.forwarded')}
      {preview.available_on_prev != null && <> · {t('engine.available', { kg: kg(preview.available_on_prev) })}</>}
      {preview.warnings && preview.warnings.length > 0 && <div className="small">{preview.warnings.join(' · ')}</div>}
    </div>
  );
}

function initialValues(form: StageForm, source: Footprint | null, editing: Footprint | null): Record<string, FieldValue> {
  const v: Record<string, FieldValue> = {};
  const toStr = (x: unknown) => (x === undefined || x === null ? '' : String(x));
  for (const fd of form.stage.form_schema) {
    const from = editing ? (fd.column ? (editing as unknown as Record<string, unknown>)[fd.key] : editing.payload[fd.key]) : undefined;
    if (from !== undefined) {
      if (fd.type === 'number[3]') v[fd.key] = (from as unknown[]).map(toStr);
      else if (fd.type === 'breakdown' || fd.type === 'packets[]')
        v[fd.key] = (from as Record<string, unknown>[]).map((r) => Object.fromEntries(Object.entries(r).map(([k, x]) => [k, toStr(x)]))) as unknown as FieldValue;
      else if (fd.type === 'footprint[]') v[fd.key] = from as string[];
      else if (fd.type === 'readings') v[fd.key] = Object.fromEntries(Object.entries(from as Record<string, unknown>).map(([k, x]) => [k, toStr(x)]));
      else if (fd.type === 'boolean') v[fd.key] = from === true;
      else v[fd.key] = toStr(from);
    } else if (source && PREFILL_FROM_SOURCE.includes(fd.key)) {
      v[fd.key] = toStr(source.qty_out);
    }
  }
  return v;
}

// ---------------------------------------------------------------------------------------------------------------
// Records at this stage in this scope (what RLS lets the user see)
// ---------------------------------------------------------------------------------------------------------------
function Records({ form }: { form: StageForm }) {
  const { t } = useI18n();
  const list = useAsync(() => q(supabase.from('footprints').select('*').eq('scope_id', form.scope.id)
    .eq('stage_type', form.stage.stage_type as StageType).order('created_at', { ascending: false }).limit(200)) as Promise<Footprint[]>,
  [form.scope.id, form.stage.stage_type]);
  if (list.loading) return <Loading />;
  if (list.error) return <ErrorBox error={list.error} onRetry={list.reload} />;
  if (!list.data?.length) return <Empty />;
  return (
    <div className="card table-wrap">
      <table>
        <thead><tr><th>{t('engine.col_code')}</th><th>{t('engine.col_in')}</th><th>{t('engine.col_out')}</th><th>{t('common.status')}</th><th className="hide-mobile">{t('engine.col_recorded')}</th></tr></thead>
        <tbody>
          {list.data.map((r) => (
            <tr key={r.id} className="clickable" onClick={() => { window.location.href = `/records/${r.id}`; }}>
              <td className="mono"><Link to={`/records/${r.id}`}>{r.footprint_code}</Link></td>
              <td className="num">{kg(r.qty_in)}</td><td className="num">{kg(r.qty_out)}</td>
              <td><Badge value={r.status} />{r.lot_closed ? <> <Badge value="closed" /></> : null}</td>
              <td className="hide-mobile">{dateTime(r.created_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
