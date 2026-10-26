// The generic 8-step coach engine (PRD §5.3, execution plan §6). One component for every stage type.
//   1 Look up   app.stage_form            5 Maths    app.preview_reconcile (same function the save trigger runs)
//   2 Arrival   app.incoming_records      6 Review   confirm what will be stored
//   3 Verify    app.verify_footprint      7 Save     insert footprints (gate stage: app.seal_lot)
//   4 Form      stage.form_schema         8 Handoff  the tick-list the next stage will check
// The gate stage saves nothing by insert: app.seal_source creates the QR record and seals it in one transaction.
import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import QRCode from 'qrcode';
import { rpc, q, within } from '../lib/api';
import { toAppError } from '../lib/errors';
import { supabase } from '../lib/supabase';
import { useAsync, useAction } from '../lib/useAsync';
import { useI18n } from '../lib/i18n';
import { kg, dateTime, date, humanise, todayIST } from '../lib/format';
import type { Footprint, FootprintReturn, IncomingLot, LotMarkets, Preview, QualityParam, ReleasePreview, StageForm, StageType, SystemCheck, VerdictPreview, Withdrawal } from '../lib/types';
import { giLabel } from '../lib/gi';
import { ErrorBox, Loading, Badge, Empty, Field, errorText, plainText } from '../shell/ui';
import { Widget, buildPayload, missingRequired, missingFiles, withScopeRules, withLotRules, withValueRules, groupSections, FULL_WIDTH, PREFILL_FROM_SOURCE, SUPPORTED, KNOWN_LOTS, loadIncomingLots, useLotNames, lotVillages, filterLots, type FieldValue, type PackLeft } from './widgets';
import { SamplesPanel } from '../pages/records/Samples';
import { SECTION_ICON, stageIcon } from './icons';
import { uploadEvidence, UPLOAD_WAIT_MS } from './evidence';
import { isSameFile } from './DupFile';
import { offlinePreview, paymentProblem, type OfflinePreview, type OfflineRules } from './offlinePreview';
import { localiseForm } from './localise';
import { waitingSplit } from '../lib/waiting';
import { ComputedRows, capturedAt, leftAfter } from './values';
import { cached, isNetworkError } from '../offline/cache';
import { enqueue, discard, getOutboxItem, insertOnce, type OutboxItem } from '../offline/outbox';
import { useOnline } from '../offline/useOutbox';
import { useAuth } from '../auth/AuthProvider';
import { orderOfPart } from '../lib/orders';   // migration 70

type Step = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8;
/** How long the maths step waits for the server before working the numbers out on the phone (dead link). */
const PREVIEW_WAIT_MS = 8000;

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
  const [search, setSearch] = useSearchParams();
  const editId = search.get('edit');
  const draftId = search.get('draft');
  const replacesId = search.get('replaces');
  const { t, lang } = useI18n();
  const form = useAsync(() => cached(`stage_form:${scopeId}:${stage}`, () => rpc<StageForm>('stage_form', { p_scope: scopeId, p_stage: stage })), [scopeId, stage]);
  const [draft, setDraft] = useState<OutboxItem | null>(null);
  const [draftMissing, setDraftMissing] = useState(false);
  useEffect(() => {
    setDraftMissing(false);
    if (draftId) void getOutboxItem(draftId).then((d) => { setDraft(d ?? null); setDraftMissing(!d); }, () => { setDraft(null); setDraftMissing(true); });
    else setDraft(null);
  }, [draftId]);
  // ?replaces=<id>: record the replacement of a withdrawn record (same source lot, values prefilled, linked by supersedes_id)
  const [replaces, setReplaces] = useState<{ old: Footprint; source: Footprint | null } | null>(null);
  useEffect(() => {
    if (!replacesId) { setReplaces(null); return; }
    setReplacesFailed(false);
    void (async () => {
      const old = await q(supabase.from('footprints').select('*').eq('id', replacesId).single()) as unknown as Footprint;
      const src = old.prev_footprint_id && !old.is_grade_lot
        ? await q(supabase.from('footprints').select('*').eq('id', old.prev_footprint_id).single()) as unknown as Footprint : null;
      setReplaces({ old, source: src });
    })().catch(() => { setReplaces(null); setReplacesFailed(true); });
  }, [replacesId]);
  const [tab, setTab] = useState<'incoming' | 'new' | 'records'>('incoming');
  const [incCount, setIncCount] = useState<number | null>(null);   // migration 57 (G22): the waiting tab says how many
  const [newKey, setNewKey] = useState(0);                  // migration 49 (A5/G11): a new record without reloading the page
  const [source, setSource] = useState<Footprint | null>(null);
  const [editing, setEditing] = useState<Footprint | null>(null);
  const [editFailed, setEditFailed] = useState(false);
  const [replacesFailed, setReplacesFailed] = useState(false);

  // A first stage has no "waiting" list. Someone who may not record there (a client viewer, a manager looking in, the
  // operator of another stage) lands on its records; before, the page showed its tabs and nothing under them.
  // ?tab=records: a link from a first screen ("review what waits at this stage") opens the stage on its records.
  const wantRecords = search.get('tab') === 'records';
  useEffect(() => { if (form.data) setTab(wantRecords ? 'records' : form.data.stage.is_first ? (form.data.can_create ? 'new' : 'records') : 'incoming'); }, [form.data, wantRecords]);
  useEffect(() => {
    if (!editId) { setEditing(null); return; }
    setEditFailed(false);
    void q(supabase.from('footprints').select('*').eq('id', editId).single()).then((f) => setEditing(f as unknown as Footprint), () => { setEditing(null); setEditFailed(true); });
  }, [editId]);
  // A form opened by a link (?edit, ?draft, ?replaces) is shown whatever tab is selected: before, the correction form
  // of any stage but the first was replaced by the "waiting" list as soon as the stage definition finished loading.
  const opened = !!(draft || replaces || editing);
  // A link to a form (?edit, ?draft, ?replaces) whose record is still loading: nothing else is shown meanwhile. Before,
  // the empty "new record" form stood there and took what was typed, then the correction replaced it (14 Oct 2026).
  const opening = !opened && !!((editId && editing === null && !editFailed) || (draftId && draft === null && !draftMissing) || (replacesId && replaces === null && !replacesFailed));
  const pick = (next: 'incoming' | 'new' | 'records') => {
    if (opened) setSearch({}, { replace: true });                       // leaving the opened form
    setTab(next); setSource(null);
  };

  // eslint-disable-next-line react-hooks/exhaustive-deps
  const localised = useMemo(() => (form.data ? localiseForm(form.data, t) : null), [form.data, lang]);
  if (form.loading) return <Loading />;
  if (form.error || !form.data || !localised) return <ErrorBox error={form.error} onRetry={form.reload} />;
  const f = localised;
  const prevLabel = f.prev_stage?.label ?? '';

  return (
    <div>
      <p className="muted small"><Link to="/">{t('nav.back_home')}</Link></p>
      <div className="band">
        <div><div className="band-title">{f.scope.crop.name} · {f.scope.season_code} · {f.scope.geography}</div>
          <div className="sub">{f.scope.client.name}{f.scope.crop.gi_tag ? ` · ${giLabel(f.scope.crop.gi_tag, t)}` : ''}</div></div>
      </div>
      <div className="page-hd"><h1><span aria-hidden="true">{stageIcon(f.stage.stage_type)} </span>{f.stage.label}</h1>
        {/* migration 57 (G22): the short name in the title, what the stage is under it */}
        {t(`stage_sub.${f.stage.stage_type}`, undefined, '') && <p className="sub small muted" data-testid="stage-sub">{t(`stage_sub.${f.stage.stage_type}`, undefined, '')}</p>}</div>
      {/* migration 57 (G22): one row of short words on a phone; the full words stay the tabs' names */}
      <div className="tabs one-row" role="tablist">
        {!f.stage.is_first && <button role="tab" aria-selected={!opened && tab === 'incoming'} className={!opened && tab === 'incoming' ? 'active' : ''}
          aria-label={t('engine.incoming', { stage: prevLabel })} onClick={() => pick('incoming')}>{t('engine.tab_waiting')}{incCount !== null ? ` · ${incCount}` : ''}</button>}
        {(f.stage.is_first || f.stage.aggregates) && f.can_create && <button role="tab" aria-selected={!opened && tab === 'new'} className={!opened && tab === 'new' ? 'active' : ''}
          aria-label={t('engine.new_record', { stage: f.stage.label })} onClick={() => pick('new')}>{t('engine.tab_new')}</button>}
        <button role="tab" aria-selected={!opened && tab === 'records'} className={!opened && tab === 'records' ? 'active' : ''}
          aria-label={t('engine.my_records')} onClick={() => pick('records')}>{t('engine.tab_records')}</button>
      </div>
      {draft && <RecordForm key={draft.id} form={f} source={draft.source as Footprint | null} editing={null} draft={draft} onNew={() => pick(f.stage.is_first ? 'new' : 'incoming')} />}
      {!draft && replaces && <RecordForm key={`r-${replaces.old.id}`} form={f} source={replaces.source} editing={null} replaces={replaces.old} onNew={() => pick(f.stage.is_first ? 'new' : 'incoming')} />}
      {!draft && !replaces && editing && <RecordForm key={`e-${editing.id}`} form={f} source={null} editing={editing} onNew={() => pick(f.stage.is_first ? 'new' : 'incoming')} />}
      {opening && <Loading />}
      {!opened && !opening && tab === 'incoming' && !source && <Incoming form={f} onPick={(fp) => setSource(fp)} onCount={setIncCount} />}
      {!opened && !opening && tab === 'incoming' && source && (
        <VerifyAndContinue form={f} source={source} onBack={() => setSource(null)} onReload={(fp) => setSource(fp)} />
      )}
      {!opened && !opening && tab === 'new' && f.can_create && <RecordForm key={`new-${newKey}`} form={f} source={null} editing={null} onNew={() => setNewKey((n) => n + 1)} />}
      {!opened && !opening && tab === 'records' && <Records form={f} />}
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Step 2: what is waiting from the stage behind (thumb rule: only that stage, only this scope)
// ---------------------------------------------------------------------------------------------------------------
function Incoming({ form, onPick, onCount }: { form: StageForm; onPick: (f: Footprint) => void; onCount?: (n: number) => void }) {
  const { t } = useI18n();
  // migration 49 (A3/G2): each waiting lot with what is left on it; a server before migration 49: the older list
  const inc = useAsync(() => loadIncomingLots(form.scope.id, form.stage.stage_type), [form.scope.id, form.stage.stage_type]);
  // migration 57 (G22, Part H 2): a card per lot (its number on one line, farmer · village, kg left, status), and the
  // batch form's village filter and search above them (Veda: "there will be many lots per farmer per village")
  const names = useLotNames(form.scope.id, form.stage.stage_type, inc.data ?? null);
  const [fVillage, setFVillage] = useState('');
  const [fText, setFText] = useState('');
  useEffect(() => { if (inc.data) onCount?.(inc.data.length); }, [inc.data, onCount]);
  const lots = inc.data ?? [];
  const villages = lotVillages(lots, names);
  const shown = filterLots(lots, names, fVillage, fText);
  const toCheck = lots.filter((r) => r.status === 'pending').length;
  return (
    <div className="card">
      <Stepper current={2} form={form} />
      {inc.loading ? <Loading /> : <ErrorBox error={inc.error} onRetry={inc.reload} />}
      {inc.data && inc.data.length === 0 && <Empty>{t('engine.no_incoming', { stage: form.prev_stage?.label ?? '' })}</Empty>}
      {lots.length > 0 && <p className="small" data-testid="incoming-split">{waitingSplit(t, toCheck, lots.length - toCheck)}</p>}
      {lots.length > 1 && (
        <div className="lot-filters" data-testid="incoming-filter">
          {villages.length > 1 && <select aria-label={t('cb.f_village')} value={fVillage} onChange={(e) => setFVillage(e.target.value)} data-testid="inc-f-village">
            <option value="">{t('cb.f_all_villages', { n: lots.length })}</option>
            {villages.map((v) => <option key={v.key} value={v.key}>{v.village} ({v.n})</option>)}
          </select>}
          <input type="search" aria-label={t('cb.f_search')} placeholder={t('cb.f_search')} value={fText} onChange={(e) => setFText(e.target.value)} data-testid="inc-f-text" />
        </div>)}
      {lots.length > 0 && shown.length === 0 && <p className="small muted" data-testid="inc-f-none">{t('cb.f_none')}</p>}
      {shown.length > 0 && (
        <div className="lot-cards">
          {shown.map((r) => {
            const fm = r.farmer_id ? names[r.farmer_id] : undefined;
            return (
              <button type="button" key={r.id} className="lot-card" onClick={() => onPick(r)} data-testid="incoming-row">
                <span className="lot-card-hd"><span className="mono lot-code">{r.footprint_code}{r.grade ? ` · Grade ${r.grade}` : ''}</span>
                  {r.returned ? <Badge value="pending" label={t('ret.badge')} /> : <Badge value={r.status} label={r.status === 'pending' ? t('inc.to_check_in') : r.status === 'verified' ? t('inc.ready') : undefined} />}</span>
                <span className="lot-card-ln"><span>{fm ? `${fm.name} · ${fm.village}` : r.maker_name ? t('inc.by', { name: r.maker_name }) : ''}</span>
                  <strong data-testid="incoming-left">{Number(r.available_kg) < Number(r.qty_out) ? t('inc.left', { left: kg(r.available_kg), all: kg(r.qty_out) }) : kg(r.qty_out)}</strong></span>
                <span className="lot-card-ln small muted"><span>{dateTime(capturedAt(r).at)}</span>
                  {r.made_by_me && <span className="same-person" data-testid="incoming-mine">{t('inc.mine')}</span>}</span>
              </button>);
          })}
        </div>)}
    </div>
  );
}

/** Migration 48 (A1): which of these records are returned to their sender and wait for the correction. */
function useOpenReturns(ids: string[]) {
  const key = ids.join(',');
  const r = useAsync(() => ids.length === 0 ? Promise.resolve([] as { footprint_id: string }[])
    : (q(supabase.from('footprint_returns').select('footprint_id').eq('status', 'open').in('footprint_id', ids)) as Promise<{ footprint_id: string }[]>).catch(() => []),
  // eslint-disable-next-line react-hooks/exhaustive-deps
  [key]);
  return new Set((r.data ?? []).map((x) => x.footprint_id));
}
/** The open return of one record, with its reason and who returned it (null: none). */
function useOpenReturn(id: string, tick: number) {
  const r = useAsync(() => rpc<{ returns?: FootprintReturn[] }>('footprint_detail', { p_fp: id })
    .then((d) => (d.returns ?? []).find((x) => x.status === 'open') ?? null).catch(() => null), [id, tick]);
  return r.data ?? null;
}

// ---------------------------------------------------------------------------------------------------------------
// Step 3: the receiving operator ticks the previous stage's handoff list and verifies; then records (or seals)
// ---------------------------------------------------------------------------------------------------------------
function VerifyAndContinue({ form, source, onBack, onReload }: {
  form: StageForm; source: Footprint; onBack: () => void; onReload: (f: Footprint) => void;
}) {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const myId = ctx?.user?.id;
  // migration 49 (A2/G3): the person ticks only what he sees (the stage's physical checks, kept in English for the
  // server, shown in his language); the system checks the rest. A server before migration 49: the older list.
  const physical = form.prev_stage?.physical_checks;
  const checks = physical ?? form.prev_stage?.handoff_checks ?? [];
  const sys = useAsync(() => rpc<SystemCheck[]>('system_checks', { p_fp: source.id }).catch(() => null), [source.id, source.status]);
  const lot = source as IncomingLot;
  const [ticked, setTicked] = useState<boolean[]>(checks.map(() => false));
  const [continueTo, setContinueTo] = useState(false);
  const [round, setRound] = useState(0);
  const act = useAction();
  const [sealed, setSealed] = useState<{ qr_code: string; img: string } | null>(null);
  const markets = useLotMarkets(source.id);
  // migration 48: a manager's reason (A10), a condition, a return to its sender (A1)
  const [why, setWhy] = useState('');
  const [withCondition, setWithCondition] = useState(false);
  const [condition, setCondition] = useState('');
  const [returning, setReturning] = useState(false);
  const [returnWhy, setReturnWhy] = useState('');
  const [tick, setTick] = useState(0);
  const openReturn = useOpenReturn(source.id, tick);
  const asManager = !!form.verifies_as_manager;
  const sealAsManager = !!form.records_as_manager;
  // migration 50 (G9): the summary before release, read and confirmed
  const [readSummary, setReadSummary] = useState(false);
  const summary = useAsync(() => (form.stage.is_gate && source.status === 'verified'
    ? rpc<ReleasePreview>('release_preview', { p_source: source.id }).catch(() => null) : Promise.resolve(null)), [source.id, source.status]);

  const verify = () => act.run(async () => {
    const r = await rpc<Footprint>('verify_record', { p_fp: source.id, p_reason: asManager ? why.trim() : null,
      p_condition: withCondition ? condition.trim() : null, ...(physical ? { p_checked: physical.filter((_, i) => ticked[i]) } : {}) });
    onReload(r);
  });
  const sendBack = () => act.run(async () => {
    await rpc('return_footprint', { p_fp: source.id, p_reason: returnWhy.trim() });
    setReturning(false); setReturnWhy(''); setTick((n) => n + 1);
  });

  const seal = () => act.run(async () => {
    // One request, one transaction (migration 24): if the gate refuses (an open flag, …) nothing is saved and the lot
    // stays in this list, to be sealed once the reason is fixed.
    const s = sealAsManager ? await rpc<{ qr_code: string }>('seal_source_as_manager', { p_source: source.id, p_reason: why.trim() })
      : await rpc<{ qr_code: string }>('seal_source', { p_source: source.id });
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
  if (continueTo) return <RecordForm key={round} form={form} source={source} editing={null} onAnother={() => setRound((r) => r + 1)} onNew={onBack} />;

  const verified = source.status === 'verified';
  return (
    <div className="card">
      <Stepper current={3} form={form} />
      <button className="secondary" onClick={onBack}>{t('common.back')}</button>
      <h2>{t('engine.verify_title', { stage: form.prev_stage?.label ?? '' })}</h2>
      <dl className="kv">
        <dt>{t('engine.col_code')}</dt><dd className="mono">{source.footprint_code}{source.grade ? ` · Grade ${source.grade}` : ''}</dd>
        <dt>{t('engine.qty_forwarded')}</dt><dd className="big">{kg(source.qty_out)}</dd>
        {lot.available_kg !== undefined && Number(lot.available_kg) < Number(source.qty_out) && <><dt>{t('inc.col_left')}</dt><dd data-testid="verify-left">{kg(lot.available_kg)}</dd></>}
        <ComputedRows computed={source.computed} t={t} />
        <dt>{t('common.status')}</dt><dd><Badge value={source.status} /></dd>
      </dl>
      <MarketVerdict m={markets} />
      <ReplacesNote withdrawnId={source.supersedes_id} />
      {source.warnings?.length > 0 && <div className="alert warn">{source.warnings.map((w) => plainText(w, t)).join(' · ')}</div>}
      {source.created_by === myId && !verified && <div className="alert info" data-testid="same-person-note">{t('sp.you_made', { stage: form.prev_stage?.label ?? '' })}</div>}
      {sys.data && sys.data.length > 0 && (
        <div className="stack" data-testid="system-checks">
          <h3>{t('sys.title')}</h3>
          <ul className="sys-checks">{sys.data.map((c) => (
            <li key={c.key} data-ok={c.ok} className={c.ok ? 'ok' : 'not'}><span aria-hidden="true">{c.ok ? '✓' : '✗'}</span> {t(`chk.${c.key}`, c.vars, c.key)}</li>))}</ul>
        </div>)}
      <p><Link to={`/records/${source.id}`}>{t('engine.open_full')}</Link></p>
      {!verified && openReturn && (
        <div className="alert warn" data-testid="returned-note">{t('ret.waiting', { by: openReturn.returned_by_name ?? '', reason: openReturn.reason, at: dateTime(openReturn.returned_at) })}</div>)}
      {!verified && form.can_verify_incoming && !openReturn && !returning && (
        <>
          <p className="muted">{t(physical ? 'phys.title' : 'engine.verify_hint')}</p>
          {checks.map((c, i) => (
            <label key={c} className="check">
              <input type="checkbox" checked={ticked[i]} onChange={(e) => setTicked(ticked.map((x, j) => (j === i ? e.target.checked : x)))} />
              {physical ? t(`check.${c}`, undefined, c) : c}
            </label>
          ))}
          {asManager && <Field label={t('mgr.verify_why')} htmlFor="v-why" hint={t('mgr.min10')}>
            <input id="v-why" value={why} maxLength={500} onChange={(e) => setWhy(e.target.value)} data-testid="verify-why" /></Field>}
          {/* a button, not a box: the handoff list is the only list of boxes to tick */}
          <p><button type="button" className="secondary small-btn" aria-pressed={withCondition} onClick={() => setWithCondition(!withCondition)} data-testid="with-condition">
            {t(withCondition ? 'cond.without' : 'cond.with')}</button></p>
          {withCondition && <Field label={t('cond.what')} htmlFor="v-cond" hint={t('cond.hint')}>
            <input id="v-cond" value={condition} maxLength={500} onChange={(e) => setCondition(e.target.value)} data-testid="condition-text" /></Field>}
          <ErrorBox error={act.error} />
          <div className="row">
            <button onClick={verify} disabled={act.busy || ticked.some((x) => !x) || (asManager && why.trim().length < 10) || (withCondition && condition.trim().length < 10)}
              data-testid="verify-button">{t(withCondition ? 'cond.verify' : 'engine.verify_button')}</button>
            {source.created_by !== myId && <button className="secondary" onClick={() => setReturning(true)} disabled={act.busy} data-testid="return-open">{t('ret.button')}</button>}
          </div>
        </>
      )}
      {!verified && returning && (
        <div className="stack" data-testid="return-form">
          <Field label={t('ret.why')} htmlFor="r-why" hint={t('mgr.min10')}>
            <textarea id="r-why" rows={2} value={returnWhy} maxLength={500} onChange={(e) => setReturnWhy(e.target.value)} data-testid="return-why" /></Field>
          <ErrorBox error={act.error} />
          <div className="row">
            <button className="danger" onClick={sendBack} disabled={act.busy || returnWhy.trim().length < 10} data-testid="return-send">{t('ret.send')}</button>
            <button className="secondary" onClick={() => setReturning(false)}>{t('common.cancel')}</button>
          </div>
        </div>)}
      {!verified && !form.can_verify_incoming && <div className="alert info">{t('engine.waiting_verify', { stage: form.stage.label })}</div>}
      {verified && (
        <>
          <div className="alert ok">{t('engine.verified')}</div>
          {/* migration 53 (C5): where the scope asks the details, the sample is drawn (and sent to the lab) before its results are recorded */}
          {form.stage.stage_type === 'qc' && form.can_create && form.scope.stage_details_required === true && <SamplesPanel f={source} />}
          <ErrorBox error={act.error} />
          {form.stage.is_gate && form.can_create && sealAsManager && <Field label={t('mgr.record_why')} htmlFor="s-why" hint={t('mgr.min10')}>
            <input id="s-why" value={why} maxLength={500} onChange={(e) => setWhy(e.target.value)} data-testid="seal-why" /></Field>}
          {form.stage.is_gate && form.can_create && <ReleaseSummary p={summary.data ?? null} loading={summary.loading} read={readSummary} onRead={setReadSummary} />}
          {form.stage.is_gate
            ? form.can_create && <button className="gold" onClick={seal} disabled={act.busy || summary.loading || (!!summary.data && !readSummary) || (sealAsManager && why.trim().length < 10)} data-testid="seal-button">{t('engine.seal_button')}</button>
            : form.can_create
              ? <button onClick={() => setContinueTo(true)}>{t('engine.use_lot', { stage: form.stage.label })}</button>
              : <div className="alert info">{t('engine.cannot_create')}</div>}
        </>
      )}
    </div>
  );
}

/** Migration 50 (G9): what the release will carry, read before the QR is made: everything verified, no open flag, the
 *  lab's verdict, GI, the farmers, the packs (and, for export, the documents). The person confirms he has read it. */
function ReleaseSummary({ p, loading, read, onRead }: { p: ReleasePreview | null; loading: boolean; read: boolean; onRead: (v: boolean) => void }) {
  const { t } = useI18n();
  if (loading) return <Loading />;
  if (!p) return null;                                   // a server before migration 50: as before
  return (
    <div className="stack" data-testid="release-summary">
      <h3>{t('rel.summary', { code: p.source.code })}</h3>
      <ul className="sys-checks">{p.checks.map((c) => (
        <li key={c.key} data-ok={c.ok} className={c.ok ? 'ok' : 'not'}><span aria-hidden="true">{c.ok ? '✓' : '✗'}</span> {t(c.key === 'lab_verdict' && (c.vars as Record<string, unknown>).released ? 'rel.lab_verdict_released' : c.key === 'packs' && Number((c.vars as Record<string, unknown>).old ?? 0) > 0 ? 'rel.packs_old' : `rel.${c.key}`, relVars(c.vars, t), c.key)}</li>))}</ul>
      {!p.ready && <div className="alert warn" data-testid="release-not-ready">{t('rel.not_ready')}</div>}
      <label className="check"><input type="checkbox" checked={read} onChange={(e) => onRead(e.target.checked)} data-testid="release-read" />{t('rel.read')}</label>
    </div>
  );
}
/** The words inside a summary line: a verdict, a GI status (their own dictionary words), a list or a number as it is. */
export const relVars = (v: Record<string, string | number | boolean>, t: (k: string, vars?: Record<string, string | number>, fb?: string) => string) => {
  const o: Record<string, string | number> = {};
  for (const [k, x] of Object.entries(v ?? {})) {
    if (k === 'domestic' || k === 'export') o[k] = t(`pv.v_${x}`, undefined, String(x));
    else if (k === 'status') o[k] = t(`gi.${x}`, undefined, String(x));
    else if (typeof x === 'boolean') o[k] = x ? t('common.yes') : t('common.no');
    else o[k] = x === '' ? '—' : x;
  }
  return o;
};

/** What the lab said about a lot, for any stage after QC (the verdict travels with the lot). */
function useLotMarkets(lotId: string | undefined) {
  const [m, setM] = useState<LotMarkets | null>(null);
  useEffect(() => {
    setM(null);
    if (!lotId) return;
    let live = true;
    cached(`lot_markets:${lotId}`, () => rpc<LotMarkets>('lot_markets', { p_fp: lotId })).then((r) => { if (live) setM(r); }).catch(() => undefined);
    return () => { live = false; };
  }, [lotId]);
  return m;
}
function MarketVerdict({ m }: { m: LotMarkets | null }) {
  const { t } = useI18n();
  if (!m?.has_qc) return null;
  return (
    <p data-testid="market-verdict">{t('engine.lab_verdict')}: {t('pv.domestic')} <Badge value={m.domestic} label={t(`pv.v_${m.domestic}`)} /> · {t('pv.export')} <Badge value={m.export} label={t(`pv.v_${m.export}`)} />
      {m.overridden && <> <Badge value="pending" label={t('mv.released')} /></>}</p>
  );
}

/** "This record replaces X, withdrawn by a manager: reason" — shown to whoever records or verifies the replacement. */
function ReplacesNote({ withdrawnId }: { withdrawnId: string | null | undefined }) {
  const { t } = useI18n();
  const [info, setInfo] = useState<{ code: string; reason: string } | null>(null);
  useEffect(() => {
    setInfo(null);
    if (!withdrawnId) return;
    let live = true;
    void (async () => {
      const old = await q(supabase.from('footprints').select('footprint_code').eq('id', withdrawnId).single()) as unknown as { footprint_code: string };
      const w = await q(supabase.from('withdrawals').select('*').eq('footprint_id', withdrawnId).maybeSingle()) as unknown as Withdrawal | null;
      if (live) setInfo({ code: old.footprint_code, reason: w?.reason ?? '' });
    })().catch(() => undefined);
    return () => { live = false; };
  }, [withdrawnId]);
  if (!info) return null;
  return <div className="alert info" data-testid="replaces-note">{t('engine.replaces', { code: info.code, reason: info.reason })}</div>;
}

// ---------------------------------------------------------------------------------------------------------------
// Steps 4–8: form, live maths, review, save, handoff
// ---------------------------------------------------------------------------------------------------------------
function RecordForm({ form, source, editing, onAnother, draft, replaces, onNew }: {
  form: StageForm; source: Footprint | null; editing: Footprint | null; onAnother?: () => void; draft?: OutboxItem; replaces?: Footprint;
  /** migration 49 (A5/G11): "New record" opens an empty form without reloading the page */ onNew?: () => void;
}) {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const online = useOnline();
  // migration 54 (C7, C8): what the lot this record is made from decides: the order's market (Shipment: its papers) and
  // whether it has packs by type (the packs are chosen, not the kilograms)
  const [values, setValues] = useState<Record<string, FieldValue>>(() =>
    draft ? (draft.values as Record<string, FieldValue>) : initialValues(form, source, editing ?? replaces ?? null));
  // migration 70 (Phase 3, D): a part of a client order is recorded as the stage details ask (the order's buyer and number,
  // the packs by type), whatever the scope's setting: the server reconciles it so
  const orderChosen = typeof values.client_order_id === 'string' && values.client_order_id !== '';
  const lotRuled = form.stage.form_schema.some((fd) => fd.for_market || fd.with_packs || fd.hidden_when_packs || fd.when_packed);
  const lotId = source?.id ?? editing?.prev_footprint_id ?? replaces?.prev_footprint_id ?? undefined;
  const [lot, setLot] = useState<{ market: string | null; packs: boolean; packed?: boolean }>({ market: null, packs: false });
  // migration 70 (Phase 3, D): a shipment of a part of a client order carries the order's one invoice (the server fills it in)
  const partId = form.stage.stage_type === 'shipment' ? lotId : undefined;
  const [partOrder, setPartOrder] = useState<{ code: string; invoice_no: string | null } | null>(null);
  useEffect(() => {
    if (!partId) { setPartOrder(null); return; }
    let live = true;
    void cached(`order_of_part:${partId}`, () => orderOfPart(partId)).then((o) => {
      if (!live) return;
      setPartOrder(o ?? null);
      if (o?.invoice_no) setValues((s) => (s.invoice_no ? s : { ...s, invoice_no: o.invoice_no as string }));
    }).catch(() => undefined);
    return () => { live = false; };
  }, [partId]);
  // a part, and its shipment, as the details ask (the shipment's papers of its market)
  const asDetails = orderChosen || !!partOrder;
  const rulesScope = useMemo(() => (asDetails ? { ...form.scope, stage_details_required: true } : form.scope), [form.scope, asDetails]);
  useEffect(() => {
    if (!lotRuled || !lotId) return;
    let live = true;
    void (async () => {
      const known = (source?.id === lotId ? source.computed : null) as Record<string, unknown> | null;
      const c = known ?? (await cached(`lot_computed:${lotId}`, async () => ((await q(supabase.from('footprints').select('computed').eq('id', lotId).single())) as unknown as { computed: Record<string, unknown> | null }).computed).catch(() => null));
      const packs = form.scope.stage_details_required === true || asDetails                         // migration 70: a part takes packs
        ? (await cached(`packs_left:${lotId}`, () => rpc<PackLeft[]>('packs_left', { p_fp: lotId })).catch(() => [])).length > 0 : false;
      // migration 62 (E2.1): is the order's lot packed at all (any pack of its batch not void)? Then the codes are asked
      const packed = form.stage.form_schema.some((fd) => fd.when_packed)
        ? (await cached(`order_pack_codes:${lotId}:${editing?.id ?? ''}`, () => rpc<{ void: boolean }[]>('order_pack_codes', { p_fp: lotId, ...(editing?.id ? { p_except: editing.id } : {}) }))
            .catch(() => [])).some((p) => !p.void) : false;
      if (live) setLot({ market: typeof c?.market === 'string' ? c.market : null, packs, packed });
    })();
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lotId, lotRuled, asDetails]);
  // migration 50 (C5): the lab report's fields are required where the scope asks for the report
  const lotFields = useMemo(() => withLotRules(withScopeRules(form.stage.form_schema, rulesScope), lot), [form, lot, rulesScope]);
  const stateId = ctx?.scopes.find((x) => x.scope_id === form.scope.id)?.state_id;
  // migration 55: a field shown only for a value of another (a domestic order has no export market, country or Incoterms)
  const fields = useMemo(() => withValueRules(lotFields, values), [lotFields, values]);
  // migration 52: a correction of a lot whose price was recorded opens with that price and payment (kept apart from the record)
  useEffect(() => {
    const id = editing?.id;
    if (!id || draft || !form.scope.record_price || form.stage.stage_type !== 'procurement') return;
    let live = true;
    void (async () => {
      const { data } = await supabase.from('lot_payments').select('price_per_quintal,status,mode,txn_ref').eq('footprint_id', id).maybeSingle();
      if (!live || !data) return;
      const d = data as { price_per_quintal: number | null; status: string; mode: string | null; txn_ref: string | null };
      setValues((s) => ({ ...s, price_per_quintal: s.price_per_quintal || (d.price_per_quintal === null ? '' : String(d.price_per_quintal)),
        payment_status: s.payment_status || d.status, payment_mode: s.payment_mode || (d.mode ?? ''), txn_ref: s.txn_ref || (d.txn_ref ?? '') }));
    })();
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editing?.id]);
  // Fields gated on the lab verdict (Commercial "market"): only what the source lot may be sold to is offered.
  const gated = fields.some((fd) => fd.gate === 'market_verdict');
  const markets = useLotMarkets(gated ? source?.id : undefined);
  useEffect(() => {
    if (!markets) return;
    for (const fd of fields) {
      if (fd.gate === 'market_verdict' && typeof values[fd.key] === 'string' && values[fd.key] && !markets.markets.includes(values[fd.key] as string)) {
        setValues((s) => ({ ...s, [fd.key]: '' }));
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [markets]);
  const [preview, setPreview] = useState<Preview | OfflinePreview | null>(null);
  // A lab record: what the save would derive from the readings typed so far (PRD §4: the technician sees both verdicts).
  const readingsKey = fields.find((fd) => fd.type === 'readings')?.key;
  const [verdict, setVerdict] = useState<VerdictPreview | null>(null);
  const [queued, setQueued] = useState<OutboxItem | null>(null);
  const [reviewing, setReviewing] = useState(false);
  const [confirmed, setConfirmed] = useState(false);
  const [saved, setSaved] = useState<Footprint | null>(null);
  const [photoError, setPhotoError] = useState<string | null>(null);
  const [gradeLots, setGradeLots] = useState<Footprint[]>([]);
  const [leftOnSource, setLeftOnSource] = useState<number | null>(null);
  // migration 49 (A3/G2): the quantity fields start from what is LEFT on the source, not what it once held
  useEffect(() => {
    if (!source || editing || draft) return;
    let live = true;
    void rpc<number>('available_qty', { p_fp: source.id }).then((left) => {
      if (!live || left === null || left === undefined) return;
      setValues((v) => {
        const n = { ...v };
        for (const fd of form.stage.form_schema) if (PREFILL_FROM_SOURCE.includes(fd.key) && (n[fd.key] === String(source.qty_out) || n[fd.key] === '')) n[fd.key] = String(left);
        return n;
      });
    }).catch(() => undefined);
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [source?.id]);
  // migration 48: the date it happened (A9; today by default) and, for a manager at a stage he does not hold, why (A10)
  const [on, setOn] = useState<string>(() => (editing?.happened_on ?? (draft?.row.happened_on as string | undefined)) || todayIST());
  const [why, setWhy] = useState<string>(() => String(draft?.row.manager_reason ?? ''));
  const asManager = !!form.records_as_manager && !editing;
  const extra = { happened_on: on, ...(asManager ? { manager_reason: why.trim() } : {}) };
  const act = useAction();
  // One id for this save, whichever way it reaches the server: sent now, or kept on the phone and sent later. The
  // database refuses the same id twice, so a save whose answer was lost on a weak signal is never made twice.
  const saveRef = useRef<string>('');
  const unsupported = fields.filter((f) => !SUPPORTED.has(f.type) && f.required);
  const missing = [...missingRequired(fields, values), ...(editing ? [] : missingFiles(fields, values))];
  const built = useMemo(() => buildPayload(fields, values), [fields, values]);
  const timer = useRef<number | undefined>(undefined);
  // Only the answer to the latest values is shown: on a slow line an earlier preview could arrive last and show figures
  // for values no longer on the form (14 Oct 2026: the correction showed "98 kg" after the weight was changed to 110).
  const asked = useRef(0);

  useEffect(() => {
    const n = ++asked.current;
    setReviewing(false); setConfirmed(false);
    if (missing.length) { setPreview(null); setVerdict(null); return; }
    window.clearTimeout(timer.current);
    const local = () => offlinePreview(form.stage.stage_type, built.payload, built.columns, form.scope.tolerances, offlineRules(form));
    if (!online && !editing) { setPreview(local()); setVerdict(null); return; }
    timer.current = window.setTimeout(async () => {
      try {
        const p = editing
          ? await rpc<Preview>('preview_correction', { p_fp: editing.id, p_payload: built.payload, p_farmer: built.columns.farmer_id ?? null })
          : await within(PREVIEW_WAIT_MS, rpc<Preview>('preview_reconcile', { p_scope: form.scope.id, p_stage: form.stage.stage_type,
              p_prev: source?.id ?? built.columns.prev_footprint_id ?? null, p_payload: built.payload, p_farmer: built.columns.farmer_id ?? null,
              p_split: built.columns.split_into_grades === true }));
        if (n !== asked.current) return;
        // migration 52: the price and payment are checked by the save (kept apart from the record): said here first
        const pp = p.ok && form.stage.stage_type === 'procurement' ? paymentProblem(built.payload) : null;
        setPreview(pp ? { ok: false, error: `payment: ${pp}` } : p);
        if (readingsKey && p.ok) {
          // The same judging the save runs (migration 29). No answer (no network, or a server without it): the screen
          // says the result comes with the save, as before.
          try { const v = await within(PREVIEW_WAIT_MS, rpc<VerdictPreview>('preview_verdict', { p_scope: form.scope.id, p_readings: built.payload[readingsKey] ?? {} })); if (n === asked.current) setVerdict(v); }
          catch { if (n === asked.current) setVerdict(null); }
        } else setVerdict(null);
      } catch (e) { if (n !== asked.current) return; setVerdict(null); setPreview(isNetworkError(e) && !editing ? local() : { ok: false, error: errorText(toAppError(e), t) }); }
    }, 350);
    return () => window.clearTimeout(timer.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(built.payload), JSON.stringify(built.columns), missing.length, online]);

  /** Keep the save on this phone; the outbox sends it when the connection returns (oldest first). */
  const queue = async (me: string) => {
    const row = { scope_id: form.scope.id, client_id: form.scope.client.id, stage_type: form.stage.stage_type,
      prev_footprint_id: source?.id ?? null, created_by: me, payload: built.payload, ...built.columns, ...extra,
      ...(replaces ? { supersedes_id: replaces.id } : {}) };
    const farmerName = document.querySelector('[data-testid="farmer-picked"] strong')?.textContent;
    const qty = (preview as OfflinePreview | null)?.qty_out;
    const item = await enqueue({
      id: saveRef.current || undefined,
      user_id: me, scope_id: form.scope.id, stage_type: form.stage.stage_type, stage_label: form.stage.label,
      scope_label: `${form.scope.crop.name} · ${form.scope.season_code} · ${form.scope.geography}`,
      summary: [farmerName, source?.footprint_code, qty !== undefined ? kg(qty) : null].filter(Boolean).join(' · '),
      row, values: Object.fromEntries(Object.entries(values).filter(([, v]) => !(v instanceof File))),
      source: source ? { id: source.id, footprint_code: source.footprint_code, qty_out: source.qty_out } : null,
      split: built.columns.split_into_grades === true,
      files: built.files.map(({ file, field }) => ({ name: file.name, type: file.type, blob: file, label: field.label_as ?? null })),
    });
    saveRef.current = '';                                  // the id now belongs to the save waiting in the outbox; the next lot gets its own
    if (draft && draft.id !== item.id) await discard(draft.id);
    setQueued(item);
  };

  const save = () => act.run(async () => {
    const me = ctx!.user!.id;
    let rec: Footprint;
    if (editing) {
      rec = await q(supabase.from('footprints').update({ payload: built.payload, ...built.columns, happened_on: on }).eq('id', editing.id).select().single()) as Footprint;
    } else {
      saveRef.current ||= crypto.randomUUID();
      if (!online) { await queue(me); return; }
      try {
        rec = await insertOnce({
          scope_id: form.scope.id, client_id: form.scope.client.id, stage_type: form.stage.stage_type,
          prev_footprint_id: source?.id ?? null, created_by: me, payload: built.payload, ...built.columns, ...extra,
          ...(replaces ? { supersedes_id: replaces.id } : {}),
        }, saveRef.current);
      } catch (e) {
        // Connection dropped, or no answer in time: keep it on the phone under the same save id. If the server did
        // store it and only the answer was lost, the outbox finds that record instead of making a second one.
        if (isNetworkError(e)) { await queue(me); return; }
        throw toAppError(e);
      }
      if (draft) await discard(draft.id);
    }
    // The record is stored. From here on a lost connection must not make the save look failed.
    for (const { file, field } of built.files) {
      try { await within(UPLOAD_WAIT_MS, uploadEvidence(rec, file, field.label_as)); }
      catch (e) {
        // No connection for the photo: it waits on the phone under the same save id. The outbox finds the record that
        // was just made (it is not made twice) and attaches the photo when the network is back.
        if (isNetworkError(e) && !editing) { await queue(me); return; }
        // migration 59 (A6): the same file is attached elsewhere as another kind: the record page asks for the reason
        setPhotoError(errorText(toAppError(e), t) + (isSameFile(e) ? ` ${t('dup.on_record_page')}` : ''));
      }
    }
    try {
      // The save itself made the grade lots (migration 24); this asks for them to show their codes. On a database
      // that has not had that migration yet the same call creates them, as before.
      if (form.stage.splits_forward && rec.split_into_grades) setGradeLots(await rpc<Footprint[]>('split_grades', { p_run: rec.id }));
      if (source && form.stage.splits_forward && !editing) setLeftOnSource(await rpc<number>('available_qty', { p_fp: source.id }));
    } catch (e) { if (!isNetworkError(e)) throw e; }         // only what the "saved" screen shows extra; the record page has it
    saveRef.current = '';
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
        {form.stage.stage_type === 'packing' && saved.payload?.batch_code !== undefined && (
          <div className="alert info" data-testid="packed">{t('pk.saved', { batch: String(saved.payload.batch_code) })}
            <div><Link className="btn" to={`/records/${saved.id}/labels`} data-testid="print-labels">{t('pk.print')}</Link></div></div>)}
        {form.stage.stage_type === 'procurement' && (
          <div className="alert info" data-testid="receipt-offer">{t('rc.offer')}
            <div><Link className="btn" to={`/records/${saved.id}/receipt`} data-testid="open-receipt">{t('rc.open')}</Link></div></div>)}
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
          <button className="secondary" onClick={() => onNew?.()} data-testid="new-record">{t('engine.new_record', { stage: form.stage.label })}</button>
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
      {draft?.error && <div className="alert error" data-testid="draft-error">{t('engine.draft_refused')} {plainText(draft.error, t)}</div>}
      <ReplacesNote withdrawnId={replaces?.id} />
      {!editing && <div className="sign-banner">{form.next_stage
        ? t('engine.sign_banner', { name: ctx?.user?.display_name ?? '', stage: form.next_stage.label })
        : t('engine.sign_banner_last', { name: ctx?.user?.display_name ?? '' })}</div>}
      {gated && <MarketVerdict m={markets} />}
      {source && <p className="muted">{t('engine.source_lot')} <span className="mono">{source.footprint_code}</span> · {kg(source.qty_out)}</p>}
      {partOrder && <div className={`alert ${partOrder.invoice_no ? 'info' : 'warn'}`} data-testid="part-order-note">
        {partOrder.invoice_no ? t('ord.ship_invoice', { code: partOrder.code, invoice: partOrder.invoice_no }) : t('ord.ship_no_invoice', { code: partOrder.code })}</div>}
      {unsupported.length > 0 && <div className="alert warn">{t('engine.widget_missing')} ({unsupported.map((f) => f.label).join(', ')})</div>}
      <form onSubmit={(e) => { e.preventDefault(); if (preview?.ok) setReviewing(true); }} aria-label={form.stage.label}>
        <fieldset disabled={reviewing} style={{ border: 'none', padding: 0, margin: 0 }}>
          <div className="form-section" data-section="when">
            <div className="form-grid">
              <Field label={`${t('on.label')} *`} htmlFor="f-happened-on" hint={t('on.hint')}>
                <input id="f-happened-on" type="date" value={on} max={todayIST()} min={shiftDay(todayIST(), -31)} onChange={(e) => setOn(e.target.value)} data-testid="happened-on" />
              </Field>
              {asManager && (
                <Field label={`${t('mgr.record_why')} *`} htmlFor="f-manager-why" hint={t('mgr.min10')}>
                  <input id="f-manager-why" value={why} maxLength={500} onChange={(e) => setWhy(e.target.value)} data-testid="manager-why" />
                </Field>)}
            </div>
          </div>
          {groupSections(fields).map((g) => (
            <div className="form-section" key={g.fields[0].key} data-section={g.section ?? ''}>
              {g.section && <h3><span aria-hidden="true">{SECTION_ICON[g.section] ?? ''}</span>{t(`section.${g.section}`, undefined, humanise(g.section))}</h3>}
              <div className="form-grid">
                {g.fields.map((fd) => (
                  <div className={`field${FULL_WIDTH.has(fd.type) ? ' full' : ''}`} key={fd.key}>
                    <label htmlFor={`f-${fd.key}`}>{fd.label}{fd.unit ? ` (${fd.unit})` : ''}{fd.required ? ' *' : ''}</label>
                    <Widget id={`f-${fd.key}`} field={fd} value={values[fd.key] ?? null} qualityParams={form.quality_params}
                      clientId={form.scope.client.id} scopeId={form.scope.id} stageType={form.stage.stage_type}
                      sourceId={source?.id ?? (editing?.prev_footprint_id ?? undefined)} stateId={stateId} values={values} editingId={editing?.id}
                      allowed={fd.gate === 'market_verdict' && markets ? markets.markets : undefined}
                      onChange={(v) => setValues((s) => ({ ...s, [fd.key]: v }))} />
                    {fd.gate === 'market_verdict' && markets && !markets.export_allowed && (
                      <p className="hint" data-testid="market-gate">{t(markets.has_qc ? 'engine.market_domestic_only' : 'engine.market_no_verdict')}</p>
                    )}
                  </div>
                ))}
              </div>
            </div>
          ))}
        </fieldset>
        <MathsPanel preview={preview} missing={missing} aggregates={form.stage.aggregates} farmerId={typeof built.columns.farmer_id === 'string' ? built.columns.farmer_id : null} />
        {readingsKey && preview?.ok && !reviewing && <VerdictLine v={verdict} params={form.quality_params} />}   {/* at review it is in the summary below */}
        {!reviewing && <button type="submit" disabled={!preview?.ok || unsupported.length > 0 || !on || (asManager && why.trim().length < 10)}>{t('engine.review')}</button>}
      </form>
      {reviewing && preview?.ok && (
        <div className="stack" data-testid="review">
          <h3>{t('engine.will_save')}</h3>
          <dl className="kv">
            <dt>{t('on.label')}</dt><dd data-testid="review-on">{date(on)}</dd>
            {asManager && <><dt>{t('mgr.record_why')}</dt><dd data-testid="review-why">{why.trim()}</dd></>}
            <dt>{t('engine.qty_in')}</dt><dd className="num">{kg(preview.qty_in)}</dd>
            <dt>{t('engine.qty_out')}</dt><dd className="big" data-testid="review-qty-out">{kg(preview.qty_out)}</dd>
            <ComputedRows computed={preview.computed} t={t} />
          </dl>
          {readingsKey && <VerdictLine v={verdict} params={form.quality_params} />}
          {preview.warnings && preview.warnings.length > 0 && <div className="alert warn">{t('engine.warnings')}: {preview.warnings.map((w) => plainText(w, t)).join(' · ')}</div>}
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

/** The lab result the save would derive, shown before saving. */
function VerdictLine({ v, params }: { v: VerdictPreview | null; params: QualityParam[] }) {
  const { t } = useI18n();
  if (!v?.ok) return <p className="hint" data-testid="verdict-later">{t('engine.verdict_later')}</p>;
  const name = (p: string) => params.find((q) => q.param === p)?.label ?? p;
  const failed = v.judged.filter((j) => j.domestic === 'fail' || j.export === 'fail');
  return (
    <div className={`alert ${v.domestic === 'fail' || v.export === 'fail' ? 'warn' : 'info'}`} aria-live="polite" data-testid="verdict-preview">
      {t('engine.verdict_preview')}: {t('pv.domestic')} <Badge value={v.domestic} label={t(`pv.v_${v.domestic}`)} /> · {t('pv.export')} <Badge value={v.export} label={t(`pv.v_${v.export}`)} />
      {failed.length > 0 && (
        <div className="small">{t('engine.verdict_not_met')}: {failed.map((j) =>
          `${name(j.param)} (${[j.domestic === 'fail' ? t('pv.domestic') : '', j.export === 'fail' ? t('pv.export') : ''].filter(Boolean).join(', ')})`).join(' · ')}</div>
      )}
    </div>
  );
}

function MathsPanel({ preview, missing, aggregates, farmerId }: { preview: Preview | OfflinePreview | null; missing: string[]; aggregates: boolean; farmerId?: string | null }) {
  const { t } = useI18n();
  if (missing.length) return <div className="alert info" aria-live="polite">{t('engine.preview_wait')} <span className="small">({missing.join(', ')})</span></div>;
  if (!preview) return <div className="alert info" aria-live="polite">{t('common.loading')}</div>;
  // migration 47: the farmer's good farming practice is missing: the way to fill it in, from the form itself
  if (!preview.ok) return <div className="alert error" aria-live="polite" data-testid="preview-error">{t('engine.refused')} {plainText(preview.error ?? '', t)}
    {farmerId && /good farming practice/i.test(preview.error ?? '') && <div><Link to={`/farmers/${farmerId}/practice`} data-testid="fill-practice">{t('fp.fill_practice')}</Link></div>}</div>;
  const off = (preview as OfflinePreview).offline;
  if (off && (preview as OfflinePreview).provisional)
    return <div className="alert warn" aria-live="polite" data-testid="preview-ok">{t('engine.offline_provisional')}</div>;
  const left = leftAfter(preview, aggregates);
  return (
    <div className="alert ok" aria-live="polite" data-testid="preview-ok">
      {off && <div className="small" data-testid="offline-maths">{t('engine.offline_maths')}</div>}
      <strong>{kg(preview.qty_out)}</strong> {t('engine.forwarded')}
      {left !== null && <> · {t('engine.left_after', { kg: kg(left) })}</>}
      {preview.warnings && preview.warnings.length > 0 && <div className="small">{preview.warnings.map((w) => plainText(w, t)).join(' · ')}</div>}
    </div>
  );
}

/** "YYYY-MM-DD" moved by whole days (the date input's lower bound: 31 days back, as the server allows). */
export const shiftDay = (ymd: string, days: number) => { const d = new Date(`${ymd}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + days); return d.toISOString().slice(0, 10); };

/** What the offline mirror needs to know of the scope, the crop and the lots (migration 52). */
export function offlineRules(form: StageForm): OfflineRules {
  const m = form.quality_params.find((q) => ['moisture_pct', 'moisture'].includes(q.param) && ['<=', '<'].includes(q.operator ?? '<='));
  return { procurement_details_required: form.scope.procurement_details_required === true, record_price: form.scope.record_price === true,
    stage_details_required: form.scope.stage_details_required === true,
    moisture_limit: m && typeof m.domestic_limit === 'number' ? m.domestic_limit : null, thresholds: form.scope.crop.thresholds ?? null, lots: KNOWN_LOTS };
}

function initialValues(form: StageForm, source: Footprint | null, editing: Footprint | null): Record<string, FieldValue> {
  const v: Record<string, FieldValue> = {};
  const toStr = (x: unknown) => (x === undefined || x === null ? '' : String(x));
  for (const fd of form.stage.form_schema) {
    const from = editing ? (fd.column ? (editing as unknown as Record<string, unknown>)[fd.key] : editing.payload[fd.key]) : undefined;
    if (editing && fd.type === 'gps' && ('gps_lat' in editing.payload || 'gps_lng' in editing.payload)) {   // kept as two numbers
      v[fd.key] = { lat: toStr(editing.payload.gps_lat), lng: toStr(editing.payload.gps_lng) };
    } else if (from !== undefined) {
      if (fd.type === 'number[3]') v[fd.key] = (from as unknown[]).map(toStr);
      else if (fd.type === 'breakdown' || fd.type === 'packets[]')
        v[fd.key] = (from as Record<string, unknown>[]).map((r) => Object.fromEntries(Object.entries(r).map(([k, x]) => [k, toStr(x)]))) as unknown as FieldValue;
      else if (fd.type === 'footprint[]') v[fd.key] = from as string[];
      else if (fd.type === 'readings') v[fd.key] = Object.fromEntries(Object.entries(from as Record<string, unknown>).map(([k, x]) => [k, toStr(x)]));
      else if (fd.type === 'boolean') v[fd.key] = from === true;
      else if (fd.type === 'gps') v[fd.key] = { lat: toStr(from), lng: '' };
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
  const navigate = useNavigate();
  const list = useAsync(() => q(supabase.from('footprints').select('*').eq('scope_id', form.scope.id)
    .eq('stage_type', form.stage.stage_type as StageType).order('created_at', { ascending: false }).limit(200)) as Promise<Footprint[]>,
  [form.scope.id, form.stage.stage_type]);
  const returned = useOpenReturns((list.data ?? []).filter((r) => r.status === 'pending').map((r) => r.id));
  if (list.loading) return <Loading />;
  if (list.error) return <ErrorBox error={list.error} onRetry={list.reload} />;
  if (!list.data?.length) return <Empty />;
  return (
    <div className="card table-wrap">
      <table>
        <thead><tr><th>{t('engine.col_code')}</th><th>{t('engine.col_in')}</th><th>{t('engine.col_out')}</th><th>{t('common.status')}</th><th className="hide-mobile">{t('engine.col_recorded')}</th></tr></thead>
        <tbody>
          {list.data.map((r) => (
            <tr key={r.id} className="clickable" onClick={(e) => { if (!(e.target as HTMLElement).closest('a')) navigate(`/records/${r.id}`); }}>
              <td className="mono"><Link to={`/records/${r.id}`}>{r.footprint_code}</Link></td>
              <td className="num">{kg(r.qty_in)}</td><td className="num">{kg(r.qty_out)}</td>
              <td>{returned.has(r.id) ? <Badge value="pending" label={t('ret.badge')} /> : <Badge value={r.status} />}{r.lot_closed ? <> <Badge value="closed" /></> : null}</td>
              <td className="hide-mobile">{dateTime(capturedAt(r).at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
