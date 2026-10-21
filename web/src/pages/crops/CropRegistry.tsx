// S6 the crop registry (migration 42, Veda 13 Oct 2026, State Manager brief part C). A crop belongs to one state; its
// State Manager keeps it: unit, yield per acre, harvest window, typed quality limits (a number, a grade, yes/no), the
// practices a farmer answers (GAP), the recommended chain, the export documents. It is READY (and a scope may be
// activated with it) once it has a unit, a yield, a limit and a chain. The admin removes a crop nothing uses, retires one
// in use, or corrects the state of one nothing uses. Everyone else reads. Cards, one column on a phone.
import { useState } from 'react';
import type { AppError } from '../../lib/errors';
import { q, rpc } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { date } from '../../lib/format';
import type { QualityParam, StageDefinition, StageType } from '../../lib/types';
import { Badge, ErrorBox, Field, Loading } from '../../shell/ui';
import { giLabel } from '../../lib/gi';
import { MATERIALS, shelfLifeMap, type Material } from '../../lib/setup';
import { referenceUrl, uploadReference, useSetupServer } from '../setup/data';
import { useAuth } from '../../auth/AuthProvider';
import { isStateManager, myStateIds, oversees } from '../../lib/rights';
import {
  assembleChain, cropMissing, cropsFor, harvestText, limitInput, limitSummary, limitTyping, monthName, MONTHS, splitChain,
  type CropFull, type GapItem, type GapType, type RegistryRow,
} from '../../lib/crops';

const blank: CropFull = { id: '', name: '', code: '', gi_tag: '', origin: '', primary_unit: 'kg', quality_params: [], allowed_stages: [],
  yield_per_acre_kg: null, recommended_chain: [], gap_items: [], harvest_from: null, harvest_to: null, export_docs: [] };
const slug = (s: string) => s.toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').replace(/^(\d)/, 'p_$1').slice(0, 40);

export function Crops() {
  const { t, lang } = useI18n();
  const { ctx } = useAuth();
  const sm = isStateManager(ctx);                          // the State Manager makes and changes crops
  const admin = oversees(ctx);                              // the admin: remove, retire, correct a state
  const mine = sm ? myStateIds(ctx) : null;
  const list = useAsync(() => rpc<RegistryRow[]>('crop_registry'), []);
  const states = useAsync(() => q(supabase.from('states').select('id,name').order('name')) as Promise<{ id: string; name: string }[]>, []);
  const stateName = (id: string | null | undefined) => states.data?.find((s) => s.id === id)?.name ?? '';
  const defs = useAsync(() => q(supabase.from('stage_definitions').select('*').order('sort_order')) as Promise<StageDefinition[]>, []);
  const [edit, setEdit] = useState<CropFull | null>(null);
  const [keys, setKeys] = useState<Set<string>>(new Set());          // practice keys already saved: kept as they are
  const act = useAction();
  const yes = t('common.yes'), no = t('common.no');
  const rows = cropsFor(list.data ?? [], mine);

  const setupServer = useSetupServer() === true;                    // migration 51 on the server
  const [shelfTyped, setShelfTyped] = useState<Partial<Record<Material, string>>>({});
  const open = (c: CropFull) => { setEdit(structuredClone(c)); setKeys(new Set((c.gap_items ?? []).map((g) => g.key))); setTyped({});
    setShelfTyped(Object.fromEntries(Object.entries(c.shelf_life_by_material ?? {}).map(([k, v]) => [k, String(v)]))); };
  const save = () => act.run(async () => {
    const e = edit!;
    const row = { name: e.name.trim(), code: e.code.trim(), gi_tag: e.gi_tag || null, origin: e.origin || null, primary_unit: e.primary_unit || 'kg',
      // a limit with no key gets one from its label (shown greyed in the box)
      quality_params: e.quality_params.map((p) => ({ ...p, param: p.param || slug(p.label) })), allowed_stages: e.allowed_stages, yield_per_acre_kg: e.yield_per_acre_kg ?? null,
      recommended_chain: e.recommended_chain ?? [], gap_items: (e.gap_items ?? []).map((g) => ({ ...g, key: g.key || slug(g.label) })),
      harvest_from: e.harvest_from || null, harvest_to: e.harvest_to || null, export_docs: (e.export_docs ?? []).map((x) => x.trim()).filter(Boolean),
      // migration 49: the GI area and the crop's own thresholds (none typed: the defaults, 70 % and 10 runs)
      // migration 51: a crop without a GI number is not a GI crop and has no GI area at all
      gi_districts: e.gi_tag?.trim() ? (e.gi_districts ?? []).map((x) => x.trim()).filter(Boolean) : [],
      ...(setupServer ? { gi_blocks: e.gi_tag?.trim() ? (e.gi_blocks ?? []).map((x) => x.trim()).filter(Boolean) : [],
        shelf_life_by_material: shelfLifeMap(shelfTyped).map } : {}),
      thresholds: Object.fromEntries(Object.entries(e.thresholds ?? {}).filter(([, v]) => v !== null && v !== undefined && !Number.isNaN(v))),
      shelf_life_days: e.shelf_life_days ?? null,                                    // migration 50: the packs' best-before
      apeda_scheduled: !!e.apeda_scheduled,                                           // migration 64: the client's RCMC for its export
      // a crop is of his state: a new one, and one with no state yet (which this save sets, once)
      ...(!e.state_id && mine && mine.length > 0 ? { state_id: mine[0] } : {}) };
    if (e.id) await q(supabase.from('crops').update(row).eq('id', e.id).select()); else await q(supabase.from('crops').insert(row).select());
    setTyped({}); setEdit(null); await list.reload();
  });

  // What is typed into a number limit, kept as typed (the decimal point of "12.5" was once dropped at every key: fault 7).
  const [typed, setTyped] = useState<Record<string, string>>({});
  const limitsBad = Object.values(typed).some((x) => !limitTyping(x));
  const limitsOpen = Object.values(typed).some((x) => limitInput(x) === null);

  if (list.loading || defs.loading) return <Loading />;
  return (
    <div><h1><span aria-hidden="true">🌿 </span>{t('crops.title')}</h1>
      <p className="muted small">{t('crops.sub')}</p>
      {!sm && <p className="small muted" data-testid="crops-readonly">{t('crops.sm_only')}</p>}
      {admin && <p className="small muted" data-testid="crops-admin-note">{t('crops.admin_note')}</p>}
      <ErrorBox error={list.error} />
      <div className="crop-cards" data-testid="crop-list">
        {rows.map((c) => <CropCard key={c.id} c={c} stateName={c.state_name ?? stateName(c.state_id)} lang={lang} yes={yes} no={no}
          defs={defs.data ?? []} onEdit={sm && !c.retired_at ? () => open(c) : undefined}
          admin={admin} states={states.data ?? []} onDone={() => void list.reload()} />)}
        {rows.length === 0 && <p className="muted">{t('crops.none')}</p>}
      </div>
      {sm && !edit && <button onClick={() => open(blank)} data-testid="crop-create">{t('crops.create')}</button>}
      {sm && edit && <CropForm edit={edit} setEdit={setEdit} keys={keys} typed={typed} setTyped={setTyped} defs={defs.data ?? []}
        stateLabel={stateName(edit.state_id ?? mine?.[0])} settingState={!edit.state_id && !!edit.id} mineName={stateName(mine?.[0])}
        onSave={save} onCancel={() => { setTyped({}); setEdit(null); }} busy={act.busy} error={act.error} limitsBad={limitsBad} limitsOpen={limitsOpen || shelfLifeMap(shelfTyped).bad.length > 0}
        setupServer={setupServer} shelfTyped={shelfTyped} setShelfTyped={setShelfTyped} />}
    </div>
  );
}

function CropCard({ c, stateName, lang, yes, no, defs, onEdit, admin, states, onDone }: {
  c: RegistryRow; stateName: string; lang: string; yes: string; no: string; defs: StageDefinition[]; onEdit?: () => void;
  admin: boolean; states: { id: string; name: string }[]; onDone: () => void;
}) {
  const { t } = useI18n();
  const [doing, setDoing] = useState<'' | 'retire' | 'remove' | 'state'>('');
  const [reason, setReason] = useState('');
  const [to, setTo] = useState('');
  const act = useAction();
  const label = (x: StageType) => t(`stage.${x}`, undefined, defs.find((d) => d.stage_type === x)?.label ?? x);
  const used = c.use.scopes_active + c.use.scopes_setup + c.use.scopes_closed + c.use.farmers_gap > 0;
  const missing = (c.missing ?? []).map((m) => t(`crops.missing_${m}`));
  const go = () => act.run(async () => {
    if (doing === 'retire') await rpc('retire_crop', { p_crop: c.id, p_reason: reason });
    if (doing === 'remove') await rpc('remove_crop', { p_crop: c.id, p_reason: reason });
    if (doing === 'state') await rpc('correct_crop_state', { p_crop: c.id, p_state: to, p_reason: reason });
    setDoing(''); setReason(''); onDone();
  });
  return (
    <div className="card crop-card" data-testid="crop-row" data-code={c.code}>
      <div className="row wrap">
        <strong>{c.name}</strong> <span className="mono">{c.code}</span> {c.gi_tag && <Badge value="verified" label={giLabel(c.gi_tag, t)} />}
        {c.gi_tag && (c.gi_districts ?? []).length > 0 && <span className="small muted" data-testid="crop-gi-area"> · {t('crops.gi_area', { n: (c.gi_districts ?? []).length })}</span>}
        {c.state_id ? <span className="small muted" data-testid="crop-state">{stateName}</span> : <Badge value="pending" label={t('crops.state_not_set')} />}
        {c.retired_at ? <Badge value="closed" label={t('crops.retired')} />
          : c.ready ? <span data-testid="crop-ready"><Badge value="pass" label={t('crops.ready')} /></span>
          : <span data-testid="crop-not-ready"><Badge value="pending" label={t('crops.not_ready')} /></span>}
      </div>
      {!c.retired_at && !c.ready && <p className="small" data-testid="crop-missing">{t('crops.lacks', { what: missing.join(', ') })}</p>}
      <dl className="kv small">
        <dt>{t('crops.f_unit')}</dt><dd>{c.primary_unit}</dd>
        <dt>{t('crops.c_yield')}</dt><dd data-testid="crop-yield">{c.yield_per_acre_kg ? t('crops.per_acre', { n: c.yield_per_acre_kg }) : '—'}</dd>
        <dt>{t('crops.f_harvest')}</dt><dd>{harvestText(c, lang) || '—'}</dd>
        <dt>{t('crops.limits')}</dt><dd>{c.quality_params.length ? c.quality_params.map((p) => `${p.label} ${limitSummary(p, yes, no)}`).join(' · ') : '—'}</dd>
        <dt>{t('crops.c_gap')}</dt><dd>{c.gap_items?.length ? c.gap_items.map((g) => `${g.label}${g.required ? ' *' : ''}`).join(' · ') : '—'}</dd>
        <dt>{t('crops.c_chain')}</dt><dd data-testid="crop-chain">{c.recommended_chain?.length ? c.recommended_chain.map(label).join(' → ') : '—'}</dd>
        <dt>{t('crops.f_docs')}</dt><dd>{c.export_docs?.length ? c.export_docs.join(' · ') : '—'}</dd>
        <dt>{t('crops.apeda_short')}</dt><dd data-testid="crop-apeda-shown">{c.apeda_scheduled ? t('common.yes') : t('common.no')}</dd>
        {'gi_crop' in c && <><dt>{t('crops.c_gi')}</dt><dd data-testid="crop-gi-crop">{c.gi_crop
          ? `${t('common.yes')}${(c.gi_districts ?? []).length ? ` · ${(c.gi_districts ?? []).join(', ')}` : ''}${(c.gi_blocks ?? []).length ? ` (${(c.gi_blocks ?? []).join(', ')})` : ''}`
          : t('crops.not_gi')}</dd></>}
        {Object.keys(c.shelf_life_by_material ?? {}).length > 0 && <><dt>{t('crops.f_shelf_material')}</dt>
          <dd data-testid="crop-shelf-material">{Object.entries(c.shelf_life_by_material ?? {}).map(([m, d]) => `${t(`mat.${m}`, undefined, m)} ${t('crops.days', { n: d })}`).join(' · ')}</dd></>}
        <dt>{t('crops.f_use')}</dt><dd data-testid="crop-use">{used
          ? t('crops.use_line', { a: c.use.scopes_active, s: c.use.scopes_setup, c: c.use.scopes_closed, f: c.use.farmers_gap })
          : t('crops.unused')}</dd>
      </dl>
      {c.retired_at && <p className="small muted" data-testid="crop-retired-note">{t('crops.retired_note', { at: date(c.retired_at), by: c.retired_by_name ?? '', reason: c.retire_reason ?? '' })}</p>}
      <div className="row wrap">
        {onEdit && <button className="secondary" onClick={onEdit}>{t('common.edit')}</button>}
        {admin && !c.retired_at && <button className="secondary" onClick={() => setDoing('retire')} data-testid="crop-retire">{t('crops.retire')}</button>}
        {admin && !used && <button className="secondary" onClick={() => setDoing('remove')} data-testid="crop-remove">{t('crops.remove')}</button>}
        {admin && !used && <button className="secondary" onClick={() => setDoing('state')} data-testid="crop-correct-state">{t('crops.correct_state')}</button>}
      </div>
      {doing && (
        <div className="stack" data-testid="crop-admin-act">
          <p className="small">{t(`crops.${doing}_explain`)}</p>
          {doing === 'state' && <Field label={t('lens.state')} htmlFor={`cs-${c.id}`}><select id={`cs-${c.id}`} value={to} onChange={(e) => setTo(e.target.value)}>
            <option value="">—</option>{states.filter((s) => s.id !== c.state_id).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>}
          <Field label={t('crops.reason')} htmlFor={`cr-${c.id}`}><input id={`cr-${c.id}`} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          <ErrorBox error={act.error} />
          <div className="row"><button className="secondary" onClick={() => { setDoing(''); setReason(''); }}>{t('common.cancel')}</button>
            <button className={doing === 'remove' ? 'danger' : ''} disabled={act.busy || !reason.trim() || (doing === 'state' && !to)} onClick={go} data-testid="crop-admin-confirm">
              {t(`crops.${doing === 'state' ? 'correct_state' : doing}`)}</button></div>
        </div>)}
    </div>
  );
}

function CropForm({ edit, setEdit, keys, typed, setTyped, defs, stateLabel, settingState, mineName, onSave, onCancel, busy, error, limitsBad, limitsOpen, setupServer, shelfTyped, setShelfTyped }: {
  edit: CropFull; setEdit: (c: CropFull) => void; keys: Set<string>; typed: Record<string, string>; setTyped: (x: Record<string, string>) => void;
  defs: StageDefinition[]; stateLabel: string; settingState: boolean; mineName: string; onSave: () => void; onCancel: () => void;
  busy: boolean; error: AppError | null; limitsBad: boolean; limitsOpen: boolean;
  setupServer: boolean; shelfTyped: Partial<Record<Material, string>>; setShelfTyped: (x: Partial<Record<Material, string>>) => void;
}) {
  const { t, lang } = useI18n();
  const set = (patch: Partial<CropFull>) => setEdit({ ...edit, ...patch });
  const setParam = (i: number, patch: Partial<QualityParam>) => set({ quality_params: edit.quality_params.map((p, j) => (j === i ? { ...p, ...patch } : p)) });
  const processing = defs.filter((d) => d.is_processing);
  const isProc = (s: StageType) => !!defs.find((d) => d.stage_type === s)?.is_processing;
  const label = (x: StageType) => t(`stage.${x}`, undefined, defs.find((d) => d.stage_type === x)?.label ?? x);
  const parts = splitChain(edit.recommended_chain?.length ? edit.recommended_chain : ['procurement', 'qc', 'qr_activation'] as StageType[], isProc);
  const setChain = (p: Partial<typeof parts>) => {
    const next = { ...parts, ...p };
    const chain = assembleChain(next);
    // a stage in the chain is a stage the crop allows
    const allowed = [...new Set([...edit.allowed_stages, ...chain.filter(isProc)])];
    set({ recommended_chain: chain, allowed_stages: allowed });
  };
  const flip = (list: StageType[], x: StageType) => (list.includes(x) ? list.filter((y) => y !== x) : [...list, x]);
  const limitBox = (i: number, which: 'domestic_limit' | 'export_limit', p: QualityParam) => {
    const k = `${i}:${which}`;
    const bad = k in typed && !limitTyping(typed[k]);
    return <input aria-label={which === 'domestic_limit' ? 'domestic limit' : 'export limit'} inputMode="decimal" value={typed[k] ?? String(p[which])}
      aria-invalid={bad || undefined} style={{ width: 90, borderColor: bad ? 'var(--bad)' : undefined }}
      onChange={(e) => { setTyped({ ...typed, [k]: e.target.value }); const n = limitInput(e.target.value); if (n !== null) setParam(i, { [which]: n }); }} />;
  };
  const setType = (i: number, ty: 'number' | 'grade' | 'yesno') => {
    const p = edit.quality_params[i];
    const base = { param: p.param, label: p.label } as QualityParam;
    if (ty === 'number') { setTyped({ ...typed, [`${i}:domestic_limit`]: '', [`${i}:export_limit`]: '' });
      setParam(i, { ...base, type: undefined, unit: '%', operator: '<=', domestic_limit: 0, export_limit: 0, options: undefined, domestic_pass: undefined, export_pass: undefined }); }
    else { const tt = { ...typed }; delete tt[`${i}:domestic_limit`]; delete tt[`${i}:export_limit`]; setTyped(tt);
      setEdit({ ...edit, quality_params: edit.quality_params.map((x, j) => (j === i ? (ty === 'grade'
        ? { ...base, type: 'grade', options: ['A', 'B', 'C'], domestic_pass: ['A', 'B'], export_pass: ['A'] } as QualityParam
        : { ...base, type: 'yesno', domestic_pass: false, export_pass: false } as QualityParam) : x)) }); }
  };
  const gaps = edit.gap_items ?? [];
  const setGap = (i: number, patch: Partial<GapItem>) => set({ gap_items: gaps.map((g, j) => {
    if (j !== i) return g;
    const n = { ...g, ...patch };
    if (patch.label !== undefined && !keys.has(g.key)) n.key = slug(patch.label);     // a new practice: its key follows its label
    return n;
  }) });
  const miss = cropMissing(edit).map((m) => t(`crops.missing_${m}`));
  return (
    <div className="card" data-testid="crop-form" ref={(el) => { if (el && !el.dataset.shown) { el.dataset.shown = '1'; el.scrollIntoView({ block: 'start' }); } }}>
      <h2>{edit.id ? edit.name : t('crops.create')}</h2>
      <div className="form-grid">
        <Field label={t('crops.f_name')} htmlFor="cr-name"><input id="cr-name" value={edit.name} onChange={(e) => set({ name: e.target.value })} /></Field>
        <Field label={t('crops.f_code')} hint={t('crops.code_hint')} htmlFor="cr-code"><input id="cr-code" value={edit.code} maxLength={5} onChange={(e) => set({ code: e.target.value.toUpperCase() })} /></Field>
        <Field label={t('crops.f_gi')} htmlFor="cr-gi"><input id="cr-gi" value={edit.gi_tag ?? ''} onChange={(e) => set({ gi_tag: e.target.value })} /></Field>
        <Field label={t('crops.f_origin')} htmlFor="cr-origin"><input id="cr-origin" value={edit.origin ?? ''} onChange={(e) => set({ origin: e.target.value })} /></Field>
        <Field label={t('crops.f_gi_districts')} hint={edit.gi_tag?.trim() ? t('crops.gi_districts_hint') : t('crops.not_gi_hint')} htmlFor="cr-gid">
          <input id="cr-gid" value={(edit.gi_districts ?? []).join(', ')} disabled={setupServer && !edit.gi_tag?.trim()} onChange={(e) => set({ gi_districts: e.target.value.split(',').map((x) => x.replace(/^\s+/, '')) })} data-testid="crop-gi-districts" /></Field>
        {setupServer && <Field label={t('crops.f_gi_blocks')} hint={t('crops.gi_blocks_hint')} htmlFor="cr-gib">
          <input id="cr-gib" value={(edit.gi_blocks ?? []).join(', ')} disabled={!edit.gi_tag?.trim()} onChange={(e) => set({ gi_blocks: e.target.value.split(',').map((x) => x.replace(/^\s+/, '')) })} data-testid="crop-gi-blocks" /></Field>}
        <Field label={t('crops.f_ceiling')} hint={t('crops.ceiling_hint')} htmlFor="cr-ceil">
          <input id="cr-ceil" inputMode="decimal" value={edit.thresholds?.milling_outturn_ceiling_pct ?? ''} data-testid="crop-ceiling"
            onChange={(e) => set({ thresholds: { ...(edit.thresholds ?? {}), milling_outturn_ceiling_pct: e.target.value === '' ? undefined : Number(e.target.value) } })} /></Field>
        <Field label={t('crops.f_learn')} hint={t('crops.learn_hint')} htmlFor="cr-learn">
          <input id="cr-learn" inputMode="numeric" value={edit.thresholds?.learn_after_runs ?? ''}
            onChange={(e) => set({ thresholds: { ...(edit.thresholds ?? {}), learn_after_runs: e.target.value === '' ? undefined : Number(e.target.value) } })} /></Field>
        <Field label={t('crops.f_shelf_life')} hint={t('crops.shelf_life_hint')} htmlFor="cr-shelf">
          <input id="cr-shelf" inputMode="numeric" value={edit.shelf_life_days ?? ''} data-testid="crop-shelf-life"
            onChange={(e) => { const n = e.target.value.replace(/[^0-9]/g, ''); set({ shelf_life_days: n === '' ? null : Number(n) }); }} /></Field>
        <Field label={t('crops.f_unit')} hint={t('crops.unit_hint')} htmlFor="cr-unit"><input id="cr-unit" value={edit.primary_unit} readOnly /></Field>
        <Field label={`${t('crops.f_yield')} *`} hint={t('crops.yield_hint')} htmlFor="cr-yield">
          <input id="cr-yield" inputMode="decimal" value={edit.yield_per_acre_kg ?? ''} onChange={(e) => { const n = limitInput(e.target.value); set({ yield_per_acre_kg: n }); }} /></Field>
        <Field label={t('crops.harvest_from')} htmlFor="cr-hf"><select id="cr-hf" value={edit.harvest_from ?? ''} onChange={(e) => set({ harvest_from: e.target.value ? Number(e.target.value) : null, ...(e.target.value ? {} : { harvest_to: null }) })}>
          <option value="">—</option>{MONTHS.map((m) => <option key={m} value={m}>{monthName(m, lang)}</option>)}</select></Field>
        <Field label={t('crops.harvest_to')} htmlFor="cr-ht"><select id="cr-ht" value={edit.harvest_to ?? ''} onChange={(e) => set({ harvest_to: e.target.value ? Number(e.target.value) : null })} disabled={!edit.harvest_from}>
          <option value="">—</option>{MONTHS.map((m) => <option key={m} value={m}>{monthName(m, lang)}</option>)}</select></Field>
      </div>
      {setupServer && <ShelfLifeBoxes typed={shelfTyped} setTyped={setShelfTyped} />}
      {setupServer && edit.id && <ReferencePhoto crop={edit} onChange={(id) => set({ reference_photo_id: id })} />}
      <p className="small" data-testid="crop-state-field">{t('lens.state')}: <strong>{stateLabel}</strong>
        {settingState && <span className="muted"> · {t('crops.state_set_once', { state: mineName })}</span>}</p>

      <h3>{t('crops.limits')} *</h3>
      <p className="muted small">{t('crops.limits_note')}</p>
      {edit.quality_params.map((p, i) => {
        const ty = p.type ?? 'number';
        return (
          <div key={i} className="card sub-card" data-testid="limit-row">
            <div className="form-grid">
              <Field label={t('crops.p_label')} htmlFor={`qp-l-${i}`}><input id={`qp-l-${i}`} aria-label="label" value={p.label}
                onChange={(e) => setParam(i, { label: e.target.value })} /></Field>
              <Field label={t('crops.p_key')} hint={t('crops.p_key_hint')} htmlFor={`qp-k-${i}`}><input id={`qp-k-${i}`} aria-label="key" value={p.param} placeholder={slug(p.label)} onChange={(e) => setParam(i, { param: e.target.value.replace(/[^a-z0-9_]/g, '') })} /></Field>
              <Field label={t('crops.p_type')} htmlFor={`qp-t-${i}`}><select id={`qp-t-${i}`} aria-label="type" value={ty} onChange={(e) => setType(i, e.target.value as 'number' | 'grade' | 'yesno')}>
                <option value="number">{t('crops.t_number')}</option><option value="grade">{t('crops.t_grade')}</option><option value="yesno">{t('crops.t_yesno')}</option></select></Field>
            </div>
            {ty === 'number' && <div className="row wrap">
              <Field label={t('crops.p_unit')} htmlFor={`qp-u-${i}`}><input id={`qp-u-${i}`} aria-label="unit" value={p.unit ?? ''} onChange={(e) => setParam(i, { unit: e.target.value })} style={{ width: 70 }} /></Field>
              <Field label={t('crops.p_rule')} htmlFor={`qp-r-${i}`}><select id={`qp-r-${i}`} aria-label="rule" value={p.operator} onChange={(e) => setParam(i, { operator: e.target.value as QualityParam['operator'] })}>
                <option value="<=">{t('crops.r_at_most')}</option><option value=">=">{t('crops.r_at_least')}</option></select></Field>
              <Field label={t('pv.domestic')}>{limitBox(i, 'domestic_limit', p)}</Field>
              <Field label={t('pv.export')}>{limitBox(i, 'export_limit', p)}</Field>
            </div>}
            {ty === 'grade' && <div className="stack">
              <Field label={t('crops.grades')} hint={t('crops.grades_hint')} htmlFor={`qp-g-${i}`}><input id={`qp-g-${i}`} aria-label="grades" value={(p.options ?? []).join(', ')}
                onChange={(e) => { const o = e.target.value.split(',').map((x) => x.trim()).filter(Boolean);
                  setParam(i, { options: o, domestic_pass: ((p.domestic_pass as string[]) ?? []).filter((g) => o.includes(g)), export_pass: ((p.export_pass as string[]) ?? []).filter((g) => o.includes(g)) }); }} /></Field>
              {(['domestic_pass', 'export_pass'] as const).map((w) => (
                <div key={w} className="row wrap"><span className="small">{t(w === 'domestic_pass' ? 'crops.pass_domestic' : 'crops.pass_export')}:</span>
                  {(p.options ?? []).map((g) => <label key={g} className="check"><input type="checkbox" checked={((p[w] as string[]) ?? []).includes(g)}
                    onChange={() => { const cur = (p[w] as string[]) ?? []; setParam(i, { [w]: cur.includes(g) ? cur.filter((x) => x !== g) : [...cur, g] }); }} />{g}</label>)}</div>))}
            </div>}
            {ty === 'yesno' && <div className="row wrap">
              {(['domestic_pass', 'export_pass'] as const).map((w) => (
                <Field key={w} label={t(w === 'domestic_pass' ? 'crops.pass_domestic' : 'crops.pass_export')} htmlFor={`qp-${w}-${i}`}>
                  <select id={`qp-${w}-${i}`} value={p[w] ? 'yes' : 'no'} onChange={(e) => setParam(i, { [w]: e.target.value === 'yes' })}>
                    <option value="no">{t('common.no')}</option><option value="yes">{t('common.yes')}</option></select></Field>))}
            </div>}
            <button className="secondary" onClick={() => { setTyped({}); set({ quality_params: edit.quality_params.filter((_, j) => j !== i) }); }}>{t('crops.remove_row')}</button>
          </div>);
      })}
      {/* a new number row starts with empty limit boxes and cannot be saved until both are numbers */}
      <button className="secondary" onClick={() => {
        const n = edit.quality_params.length;
        setTyped({ ...typed, [`${n}:domestic_limit`]: '', [`${n}:export_limit`]: '' });
        set({ quality_params: [...edit.quality_params, { param: '', label: '', unit: '%', operator: '<=', domestic_limit: 0, export_limit: 0 }] });
      }}>{t('crops.add_limit')}</button>

      <h3>{t('crops.f_chain')} *</h3>
      <p className="muted small">{t('crops.chain_note')}</p>
      <div className="row wrap">
        {(['procurement', 'lot_inward'] as StageType[]).map((x) => <label key={x} className="check"><input type="radio" name="cr-entry" checked={parts.entry === x} onChange={() => setChain({ entry: x })} />{label(x)}</label>)}
        {parts.entry === 'procurement' && <label className="check"><input type="checkbox" checked={parts.villageBatch} onChange={(e) => setChain({ villageBatch: e.target.checked })} />{label('village_batch')}</label>}
        <label className="check"><input type="checkbox" data-testid="rc-warehouse" checked={parts.warehouse} onChange={(e) => setChain({ warehouse: e.target.checked })} />{label('warehouse')}</label>
      </div>
      <p className="small">{t('crops.before_qc')}</p>
      <div className="row wrap">{processing.map((d) => <label key={d.stage_type} className="check"><input type="checkbox" data-testid={`rc-before-${d.stage_type}`} checked={parts.before.includes(d.stage_type)}
        onChange={() => setChain({ before: flip(parts.before, d.stage_type), after: parts.after.filter((x) => x !== d.stage_type) })} />{label(d.stage_type)}</label>)}</div>
      <p className="small">{t('crops.after_qc')}</p>
      <div className="row wrap">{processing.map((d) => <label key={d.stage_type} className="check"><input type="checkbox" data-testid={`rc-after-${d.stage_type}`} checked={parts.after.includes(d.stage_type)}
        onChange={() => setChain({ after: flip(parts.after, d.stage_type), before: parts.before.filter((x) => x !== d.stage_type) })} />{label(d.stage_type)}</label>)}</div>
      <div className="row wrap">
        <label className="check"><input type="checkbox" checked={parts.commercial} onChange={(e) => setChain({ commercial: e.target.checked })} />{label('commercial')}</label>
        <label className="check"><input type="checkbox" checked={parts.shipment} onChange={(e) => setChain({ shipment: e.target.checked })} />{label('shipment')}</label>
      </div>
      <div className="alert info small" data-testid="crop-chain-preview">{edit.recommended_chain?.length ? edit.recommended_chain.map(label).join(' → ') : t('crops.chain_none')}
        {!edit.recommended_chain?.length && <> <button className="secondary" onClick={() => setChain({})} data-testid="crop-chain-start">{t('crops.chain_start')}</button></>}</div>
      <details><summary className="small">{t('crops.allowed_stages')}</summary>
        <div className="row wrap">{processing.map((d) => <label key={d.stage_type} className="check"><input type="checkbox" checked={edit.allowed_stages.includes(d.stage_type)}
          disabled={(edit.recommended_chain ?? []).includes(d.stage_type)}
          onChange={() => set({ allowed_stages: flip(edit.allowed_stages, d.stage_type) })} />{label(d.stage_type)}</label>)}</div></details>

      <h3>{t('crops.f_gap')}</h3>
      <p className="muted small">{t('crops.gap_note')}</p>
      {gaps.map((g, i) => (
        <div key={i} className="row wrap sub-card" data-testid="gap-row">
          <Field label={t('crops.g_label')} htmlFor={`gp-l-${i}`}><input id={`gp-l-${i}`} value={g.label} onChange={(e) => setGap(i, { label: e.target.value })} /></Field>
          <Field label={t('crops.p_type')} htmlFor={`gp-t-${i}`}><select id={`gp-t-${i}`} value={g.type} onChange={(e) => setGap(i, { type: e.target.value as GapType, ...(e.target.value === 'choice' ? { options: g.options ?? [] } : { options: undefined }) })}>
            {(['yesno', 'date', 'number', 'text', 'choice'] as GapType[]).map((x) => <option key={x} value={x}>{t(`crops.g_${x}`)}</option>)}</select></Field>
          {g.type === 'choice' && <Field label={t('crops.g_options')} hint={t('crops.grades_hint')} htmlFor={`gp-o-${i}`}><input id={`gp-o-${i}`} value={(g.options ?? []).join(', ')}
            onChange={(e) => setGap(i, { options: e.target.value.split(',').map((x) => x.trim()).filter(Boolean) })} /></Field>}
          <label className="check"><input type="checkbox" checked={!!g.required} onChange={(e) => setGap(i, { required: e.target.checked })} data-testid={`gap-required-${i}`} />{t('crops.g_required')}</label>
          <button className="secondary" onClick={() => set({ gap_items: gaps.filter((_, j) => j !== i) })}>{t('crops.remove_row')}</button>
        </div>))}
      <button className="secondary" onClick={() => set({ gap_items: [...gaps, { key: '', label: '', type: 'yesno', required: false }] })} data-testid="gap-add">{t('crops.add_gap')}</button>

      <h3>{t('crops.f_docs')}</h3>
      {(edit.export_docs ?? []).map((d, i) => (
        <div key={i} className="row"><input aria-label={t('crops.f_docs')} value={d} onChange={(e) => set({ export_docs: (edit.export_docs ?? []).map((x, j) => (j === i ? e.target.value : x)) })} style={{ flex: 1 }} />
          <button className="secondary" onClick={() => set({ export_docs: (edit.export_docs ?? []).filter((_, j) => j !== i) })}>✕</button></div>))}
      <button className="secondary" onClick={() => set({ export_docs: [...(edit.export_docs ?? []), ''] })} data-testid="doc-add">{t('crops.add_doc')}</button>
      <label className="row small"><input type="checkbox" checked={!!edit.apeda_scheduled} onChange={(e) => set({ apeda_scheduled: e.target.checked })} data-testid="crop-apeda" /> {t('crops.apeda')}</label>

      <div className={`alert ${miss.length ? 'warn' : 'ok'}`} data-testid="crop-form-ready">{miss.length ? t('crops.lacks', { what: miss.join(', ') }) : t('crops.will_be_ready')}</div>
      <ErrorBox error={error} />
      {limitsBad && <div className="alert error" data-testid="limit-not-a-number">{t('crops.limit_number')}</div>}
      <div className="row"><button className="secondary" onClick={onCancel}>{t('common.cancel')}</button><button onClick={onSave} disabled={busy || limitsOpen}>{t('common.save')}</button></div>
    </div>
  );
}

/** Shelf life per packing material (migration 51): whole days; an empty box means the crop's own shelf life. */
function ShelfLifeBoxes({ typed, setTyped }: { typed: Partial<Record<Material, string>>; setTyped: (x: Partial<Record<Material, string>>) => void }) {
  const { t } = useI18n();
  const bad = shelfLifeMap(typed).bad;
  return (
    <div className="stack" data-testid="crop-shelf-materials">
      <h3>{t('crops.f_shelf_material')}</h3>
      <p className="muted small">{t('crops.shelf_material_hint')}</p>
      <div className="row wrap">{MATERIALS.map((m) => (
        <Field key={m} label={t(`mat.${m}`)} htmlFor={`cr-sl-${m}`}>
          <input id={`cr-sl-${m}`} inputMode="numeric" value={typed[m] ?? ''} style={{ width: 90 }} aria-invalid={bad.includes(m) || undefined}
            onChange={(e) => setTyped({ ...typed, [m]: e.target.value.replace(/[^0-9]/g, '') })} data-testid={`crop-shelf-${m}`} /></Field>))}</div>
      {bad.length > 0 && <div className="small" style={{ color: 'var(--red)' }}>{t('crops.shelf_material_bad')}</div>}
    </div>);
}

/** The crop's reference photo (migration 51), for the optional quick look at Procurement: uploaded, fingerprinted, set. */
function ReferencePhoto({ crop, onChange }: { crop: CropFull; onChange: (id: string) => void }) {
  const { t } = useI18n();
  const act = useAction();
  const photo = useAsync(async () => {
    if (!crop.reference_photo_id) return null;
    const r = await q(supabase.from('reference_files').select('storage_path,file_name').eq('id', crop.reference_photo_id).maybeSingle()) as unknown as { storage_path: string; file_name: string | null } | null;
    return r ? { url: await referenceUrl(r.storage_path), name: r.file_name } : null;
  }, [crop.reference_photo_id]);
  const pick = (file: File | undefined) => file && act.run(async () => {
    const f = await uploadReference(crop.id, 'crop_photo', file);
    await q(supabase.from('crops').update({ reference_photo_id: f.id }).eq('id', crop.id).select());
    onChange(f.id);
  });
  return (
    <div className="stack" data-testid="crop-reference-photo">
      <h3>{t('crops.f_photo')}</h3>
      <p className="muted small">{t('crops.photo_hint')}</p>
      {photo.data?.url && <img src={photo.data.url} alt={t('crops.f_photo')} style={{ maxWidth: 220, maxHeight: 160, objectFit: 'cover', borderRadius: 8 }} data-testid="crop-photo-img" />}
      <label className="btn secondary" style={{ alignSelf: 'flex-start' }}>{t(crop.reference_photo_id ? 'crops.photo_replace' : 'crops.photo_add')}
        <input type="file" accept="image/*" style={{ display: 'none' }} disabled={act.busy} onChange={(e) => void pick(e.target.files?.[0])} data-testid="crop-photo-file" /></label>
      <ErrorBox error={act.error} />
    </div>);
}
