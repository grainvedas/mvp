// Set-up lists (migration 51, Veda 15 Oct 2026: the operator-stages brief, Part B). What the stages pick from instead of
// typing: the Client Manager's collection points, mills, packing units, buyers and pack list; the State Manager's labs and
// market profiles (versioned, each with the document its limits come from); the places of a state (district, block,
// village); the parameter library (read-only, loaded once by GrainVeda). The database keeps every rule
// (tests/45_setup_lists.sql): who writes which list, the shapes, one name once; a list row is retired, never deleted.
import { useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { q, rpc } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { date } from '../../lib/format';
import { holdsClientAccount, isStateManager, myStateIds, oversees } from '../../lib/rights';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { useClientChoice } from '../farmers/Farmers';
import {
  CLIENT_LISTS, COUNTRIES, LIST_FIELDS, blocksOf, districtsOf, gpsProblem, limitWords, listProblems, listRow, parseGps, profileProblem,
  profileVersions, skuLabel, villagesOf, type LibraryParam, type ListKind, type ListRow, type MarketProfile, type ProfileParam,
} from '../../lib/setup';
import { referenceUrl, uploadReference, usePlaces } from './data';

type Tab = 'lists' | 'places' | 'labs' | 'profiles' | 'library';

/** Pure: which tabs a person sees, in order. The Client Manager keeps his client's lists; the State Manager the labs and
 *  market profiles of his state; both add places; the admin reads everything; everyone reads the library. */
export function setupTabs(w: { cm: boolean; sm: boolean; admin: boolean }): Tab[] {
  const out: Tab[] = [];
  if (w.cm || w.admin || w.sm) out.push('lists');
  if (w.cm || w.sm || w.admin) out.push('places');
  if (w.sm || w.admin) out.push('labs', 'profiles');
  out.push('library');
  return out;
}

export function SetupLists() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const { clientId, picker } = useClientChoice();
  const admin = oversees(ctx), sm = isStateManager(ctx), cm = holdsClientAccount(ctx, clientId);
  const tabs = setupTabs({ cm: (ctx?.assignments ?? []).some((a) => a.lens === 'client' && a.op_role === 'client_account'), sm, admin });
  const [params, setParams] = useSearchParams();
  const tab = (tabs.includes(params.get('tab') as Tab) ? params.get('tab') : tabs[0]) as Tab;
  const go = (x: Tab) => { const n = new URLSearchParams(params); n.set('tab', x); setParams(n, { replace: true }); };
  return (
    <div>
      <h1><span aria-hidden="true">🗂 </span>{t('set.title')}</h1>
      <p className="muted small">{t('set.sub')}</p>
      <div className="tabs" role="tablist">{tabs.map((x) => (
        <button key={x} role="tab" aria-selected={tab === x} className={tab === x ? 'active' : ''} onClick={() => go(x)} data-testid={`set-tab-${x}`}>{t(`set.tab_${x}`)}</button>))}</div>
      {tab === 'lists' && <>{picker}{clientId ? <ClientLists clientId={clientId} canEdit={cm} /> : <Empty />}</>}
      {tab === 'places' && <Places />}
      {tab === 'labs' && <Labs />}
      {tab === 'profiles' && <Profiles />}
      {tab === 'library' && <Library />}
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// The Client Manager's five lists and the State Manager's labs: one editor
// ---------------------------------------------------------------------------------------------------------------------
function ClientLists({ clientId, canEdit }: { clientId: string; canEdit: boolean }) {
  const { t } = useI18n();
  const [kind, setKind] = useState<ListKind>('collection_points');
  return (
    <div>
      {!canEdit && <p className="small muted" data-testid="set-readonly">{t('set.cm_only')}</p>}
      <div className="row wrap" role="tablist" style={{ marginBottom: 12 }}>{CLIENT_LISTS.map((k) => (
        <button key={k} role="tab" aria-selected={kind === k} className={kind === k ? '' : 'secondary'} onClick={() => setKind(k)} data-testid={`set-list-${k}`}>{t(`set.list_${k}`)}</button>))}</div>
      <ListEditor key={`${kind}-${clientId}`} kind={kind} owner={{ client_id: clientId }} canEdit={canEdit} />
    </div>);
}

function Labs() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const mine = myStateIds(ctx);
  const states = useAsync(() => q(supabase.from('states').select('id,name').order('name')) as Promise<{ id: string; name: string }[]>, []);
  const [stateId, setStateId] = useState(mine[0] ?? '');
  const sid = stateId || states.data?.[0]?.id || '';
  return (
    <div>
      <p className="small muted">{t('set.labs_note')}</p>
      <StatePicker states={states.data ?? []} value={sid} onChange={setStateId} />
      {sid && <ListEditor key={sid} kind="labs" owner={{ state_id: sid }} canEdit={mine.includes(sid)} />}
    </div>);
}

/** The state a person works in, for the first view of Places: the State Manager's own state; else the state of the
 *  person's client (found on staging, 15 Oct: the Client Manager of an Uttar Pradesh client opened on Bihar, the first
 *  state in the alphabet). */
export function homeState(ctx: Parameters<typeof myStateIds>[0], clientStates: Record<string, string>): string {
  const mine = myStateIds(ctx);
  if (mine[0]) return mine[0];
  const fromScope = (ctx?.scopes ?? []).find((x) => x.state_id)?.state_id;
  if (fromScope) return fromScope;
  const client = (ctx?.assignments ?? []).find((a) => a.client_id && clientStates[a.client_id])?.client_id ?? ctx?.user?.client_id ?? '';
  return (client && clientStates[client]) || ctx?.user?.state_ids?.[0] || '';
}
function useHomeState(): string {
  const { ctx } = useAuth();
  const clientIds = [...new Set([...(ctx?.assignments ?? []).map((a) => a.client_id), ctx?.user?.client_id].filter(Boolean) as string[])];
  const cs = useAsync(async () => {
    if (!clientIds.length || myStateIds(ctx).length) return {} as Record<string, string>;
    const rows = await q(supabase.from('clients').select('id,state_id').in('id', clientIds)) as { id: string; state_id: string | null }[];
    return Object.fromEntries(rows.filter((r) => r.state_id).map((r) => [r.id, r.state_id as string]));
  }, [clientIds.join(',')]);
  return homeState(ctx, cs.data ?? {});
}

function StatePicker({ states, value, onChange }: { states: { id: string; name: string }[]; value: string; onChange: (id: string) => void }) {
  const { t } = useI18n();
  if (states.length < 2) return null;
  return <Field label={t('lens.state')} htmlFor="set-state"><select id="set-state" value={value} onChange={(e) => onChange(e.target.value)} data-testid="set-state">
    {states.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>;
}

type Row = Record<string, unknown> & { id: string; active: boolean; created_at: string };
const toTyped = (kind: ListKind, r: Row): ListRow => {
  const out: ListRow = {};
  for (const f of LIST_FIELDS[kind]) {
    if (f.type === 'gps') { out.lat = r.lat == null ? '' : String(r.lat); out.lng = r.lng == null ? '' : String(r.lng); }
    else out[f.key] = r[f.key] == null ? '' : String(r[f.key]);
  }
  return out;
};

function ListEditor({ kind, owner, canEdit }: { kind: ListKind; owner: { client_id: string } | { state_id: string }; canEdit: boolean }) {
  const { t } = useI18n();
  const [col, val] = Object.entries(owner)[0];
  const rows = useAsync(() => q(supabase.from(kind).select('*').eq(col, val).order('active', { ascending: false }).order('created_at')) as Promise<Row[]>, [kind, col, val]);
  const crops = useAsync(() => (kind === 'mills' ? q(supabase.from('crops').select('id,name').is('retired_at', null).order('name')) as Promise<{ id: string; name: string }[]> : Promise.resolve([])), [kind]);
  const [edit, setEdit] = useState<{ id: string | null; row: ListRow } | null>(null);
  const [tried, setTried] = useState(false);
  const act = useAction();
  const problems = edit ? listProblems(kind, edit.row) : [];
  const save = () => { setTried(true); if (problems.length) return; void act.run(async () => {
    const r = listRow(kind, edit!.row);
    if (edit!.id) await q(supabase.from(kind).update(r).eq('id', edit!.id).select());
    else await q(supabase.from(kind).insert({ ...r, ...owner }).select());
    setEdit(null); setTried(false); await rows.reload();
  }); };
  const flip = (r: Row) => act.run(async () => { await q(supabase.from(kind).update({ active: !r.active }).eq('id', r.id).select()); await rows.reload(); });
  const word = (k: string, v: unknown) => (v == null || v === '' ? '—' : k === 'dedicated_crop_id' ? crops.data?.find((c) => c.id === v)?.name ?? '—'
    : ['kind', 'ownership', 'material', 'market', 'label_type'].includes(k) ? t(`set.o_${v}`, undefined, String(v)) : String(v));
  const title = (r: Row) => kind === 'pack_skus' ? `${skuLabel(r as never, (m) => t(`mat.${m}`, undefined, m))} · ${t(`set.o_${r.market}`)}` : String(r.name ?? '');
  return (
    <div data-testid={`set-editor-${kind}`}>
      {rows.loading ? <Loading /> : <ErrorBox error={rows.error} onRetry={rows.reload} />}
      {!rows.loading && (rows.data ?? []).length === 0 && <Empty>{t('set.empty')}</Empty>}
      <div className="crop-cards">{(rows.data ?? []).map((r) => (
        <div key={r.id} className="card crop-card" data-testid="set-row" data-active={r.active ? 'yes' : 'no'}>
          <div className="row wrap"><strong>{title(r)}</strong>{!r.active && <Badge value="closed" label={t('set.retired')} />}</div>
          <dl className="kv small">{LIST_FIELDS[kind].filter((f) => f.key !== 'name' && !(kind === 'pack_skus')).map((f) => f.type === 'gps'
            ? <FragmentKV key="gps" k={t('set.f_gps')} v={r.lat == null ? '—' : `${r.lat}, ${r.lng}`} />
            : <FragmentKV key={f.key} k={t(`set.f_${f.key}`)} v={word(f.key, r[f.key])} />)}
            {kind === 'pack_skus' && <FragmentKV k={t('set.f_label_type')} v={word('label_type', r.label_type)} />}
            <FragmentKV k={t('set.added')} v={date(r.created_at)} /></dl>
          {canEdit && <div className="row">
            <button className="secondary" onClick={() => { setEdit({ id: r.id, row: toTyped(kind, r) }); setTried(false); }} disabled={act.busy}>{t('common.edit')}</button>
            <button className="secondary" onClick={() => void flip(r)} disabled={act.busy} data-testid="set-flip">{t(r.active ? 'set.retire' : 'set.bring_back')}</button></div>}
        </div>))}</div>
      {canEdit && !edit && <button onClick={() => { setEdit({ id: null, row: kind === 'buyers' ? { country: 'IN' } : kind === 'pack_skus' ? { unit: 'kg', label_type: 'sticker', market: 'domestic' } : {} }); setTried(false); }}
        data-testid="set-add">{t(`set.add_${kind}`)}</button>}
      {canEdit && edit && (
        <div className="card" data-testid="set-form">
          <h2>{t(edit.id ? 'common.edit' : `set.add_${kind}`)}</h2>
          <div className="form-grid">{LIST_FIELDS[kind].map((f) => {
            const v = edit.row[f.key] ?? '';
            const setV = (x: string) => setEdit({ ...edit, row: { ...edit.row, [f.key]: x } });
            const id = `set-${kind}-${f.key}`;
            const label = `${t(`set.f_${f.key}`)}${f.required ? ' *' : ''}`;
            if (f.type === 'gps') return (
              <Field key="gps" label={t('set.f_gps')} hint={t('set.gps_hint')} htmlFor={`${id}-lat`}>
                <div className="row"><input id={`${id}-lat`} aria-label={t('fl.lat')} placeholder={t('fl.lat')} inputMode="decimal" value={edit.row.lat ?? ''} style={{ width: 'auto', flex: 1 }}
                  onChange={(e) => setEdit({ ...edit, row: { ...edit.row, lat: e.target.value } })}
                  // a pair is split when pasted or when the box is left, never while it is typed (staging, 15 Oct)
                  onPaste={(e) => { const b = parseGps(e.clipboardData.getData('text')); if (b) { e.preventDefault(); setEdit({ ...edit, row: { ...edit.row, lat: String(b.lat), lng: String(b.lng) } }); } }}
                  onBlur={() => { const b = parseGps(edit.row.lat ?? ''); if (b) setEdit({ ...edit, row: { ...edit.row, lat: String(b.lat), lng: String(b.lng) } }); }} />
                  <input aria-label={t('fl.lng')} placeholder={t('fl.lng')} inputMode="decimal" value={edit.row.lng ?? ''} style={{ width: 'auto', flex: 1 }}
                    onChange={(e) => setEdit({ ...edit, row: { ...edit.row, lng: e.target.value } })} /></div>
                {gpsProblem(edit.row.lat ?? '', edit.row.lng ?? '') && <div className="small" style={{ color: 'var(--red)' }}>{t(gpsProblem(edit.row.lat ?? '', edit.row.lng ?? '')!)}</div>}
              </Field>);
            if (f.type === 'select') return <Field key={f.key} label={label} htmlFor={id}><select id={id} value={v} onChange={(e) => setV(e.target.value)} data-testid={id}>
              <option value="">—</option>{(f.options ?? []).map((o) => <option key={o} value={o}>{t(f.key === 'material' ? `mat.${o}` : `set.o_${o}`, undefined, o)}</option>)}</select></Field>;
            if (f.type === 'crop') return <Field key={f.key} label={label} hint={t('set.dedicated_hint')} htmlFor={id}><select id={id} value={v} onChange={(e) => setV(e.target.value)}>
              <option value="">{t('set.no_crop')}</option>{(crops.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>;
            if (f.type === 'country') return <Field key={f.key} label={label} hint={t('set.country_hint')} htmlFor={id}>
              <input id={id} list="set-countries" value={v} maxLength={2} onChange={(e) => setV(e.target.value.toUpperCase().replace(/[^A-Z]/g, ''))} data-testid={id} />
              <datalist id="set-countries">{COUNTRIES.map((c) => <option key={c} value={c} />)}</datalist></Field>;
            return <Field key={f.key} label={label} htmlFor={id}><input id={id} value={v} maxLength={f.max} inputMode={f.type === 'number' || f.key === 'fssai_licence' ? 'decimal' : undefined}
              onChange={(e) => setV(e.target.value)} data-testid={id} /></Field>;
          })}</div>
          {tried && problems.length > 0 && <div className="alert warn small" data-testid="set-problems">{problems.map((p) => t(p)).join(' · ')}</div>}
          <ErrorBox error={act.error} />
          <div className="row"><button className="secondary" onClick={() => { setEdit(null); setTried(false); }}>{t('common.cancel')}</button>
            <button onClick={save} disabled={act.busy} data-testid="set-save">{t('common.save')}</button></div>
        </div>)}
    </div>);
}

function FragmentKV({ k, v }: { k: string; v: string }) {
  return <><dt>{k}</dt><dd>{v}</dd></>;
}

// ---------------------------------------------------------------------------------------------------------------------
// Places of a state: districts (the State Manager's), blocks and villages (whoever registers farmers there)
// ---------------------------------------------------------------------------------------------------------------------
function Places() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const mine = myStateIds(ctx);
  const states = useAsync(() => q(supabase.from('states').select('id,name').order('name')) as Promise<{ id: string; name: string }[]>, []);
  const home = useHomeState();
  const [stateId, setStateId] = useState(mine[0] ?? '');
  const sid = stateId || home || states.data?.[0]?.id || '';
  const [district, setDistrict] = useState('');
  const [block, setBlock] = useState('');
  const pl = usePlaces(sid, district);
  const ds = districtsOf(pl.places, sid);
  const [nb, setNb] = useState(''); const [nv, setNv] = useState(''); const [nd, setNd] = useState('');
  const act = useAction();
  const add = (d: string, b: string | null, v: string | null) => act.run(async () => {
    await rpc('add_place', { p_state: sid, p_district: d, p_block: b, p_village: v }); setNb(''); setNv(''); setNd(''); pl.reload();
  });
  const sm = mine.includes(sid);
  return (
    <div data-testid="set-places">
      <p className="small muted">{t('set.places_note')}</p>
      <StatePicker states={states.data ?? []} value={sid} onChange={(x) => { setStateId(x); setDistrict(''); setBlock(''); }} />
      {pl.loading ? <Loading /> : ds.length === 0 ? <p className="small" data-testid="set-no-list">{t('set.no_list')}</p> : (
        <Field label={t('farmer.district')} hint={t('set.n_districts', { n: ds.length })} htmlFor="set-district">
          <select id="set-district" value={district} onChange={(e) => { setDistrict(e.target.value); setBlock(''); }} data-testid="set-district">
            <option value="">—</option>{ds.map((d) => <option key={d} value={d}>{d}</option>)}</select></Field>)}
      {district && <>
        <h3>{t('set.blocks_of', { district })}</h3>
        {blocksOf(pl.places, sid, district).length === 0 ? <Empty>{t('set.none_yet')}</Empty> : (
          <div className="row wrap" data-testid="set-blocks">{blocksOf(pl.places, sid, district).map((b) => (
            <button key={b} className={block === b ? '' : 'secondary'} onClick={() => setBlock(block === b ? '' : b)}>{b}</button>))}</div>)}
        <div className="row"><input aria-label={t('set.new_block')} placeholder={t('set.new_block')} value={nb} maxLength={80} onChange={(e) => setNb(e.target.value)} data-testid="set-new-block" />
          <button className="secondary" disabled={act.busy || nb.trim().length < 2} onClick={() => void add(district, nb.trim(), null)} data-testid="set-add-block">{t('set.add_place')}</button></div>
      </>}
      {district && block && <>
        <h3>{t('set.villages_of', { block })}</h3>
        {villagesOf(pl.places, sid, district, block).length === 0 ? <Empty>{t('set.none_yet')}</Empty>
          : <p className="small" data-testid="set-villages">{villagesOf(pl.places, sid, district, block).join(' · ')}</p>}
        <div className="row"><input aria-label={t('set.new_village')} placeholder={t('set.new_village')} value={nv} maxLength={80} onChange={(e) => setNv(e.target.value)} data-testid="set-new-village" />
          <button className="secondary" disabled={act.busy || nv.trim().length < 2} onClick={() => void add(district, block, nv.trim())} data-testid="set-add-village">{t('set.add_place')}</button></div>
      </>}
      {sm && <div className="row" style={{ marginTop: 12 }}><input aria-label={t('set.new_district')} placeholder={t('set.new_district')} value={nd} maxLength={80} onChange={(e) => setNd(e.target.value)} data-testid="set-new-district" />
        <button className="secondary" disabled={act.busy || nd.trim().length < 2} onClick={() => void add(nd.trim(), null, null)}>{t('set.add_district')}</button></div>}
      <ErrorBox error={act.error} />
    </div>);
}

// ---------------------------------------------------------------------------------------------------------------------
// Market profiles (the State Manager's, per crop) and the parameter library
// ---------------------------------------------------------------------------------------------------------------------
const useLibrary = () => useAsync(() => q(supabase.from('quality_param_library').select('*').order('grp').order('sort_order')) as Promise<LibraryParam[]>, []);

function Profiles() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const mine = myStateIds(ctx);
  const crops = useAsync(async () => (await q(supabase.from('crops').select('id,name,state_id,retired_at').order('name')) as unknown as { id: string; name: string; state_id: string | null; retired_at: string | null }[])
    .filter((c) => !c.retired_at && (oversees(ctx) || !c.state_id || mine.includes(c.state_id))), []);
  const lib = useLibrary();
  const [cropId, setCropId] = useState('');
  const cid = cropId || crops.data?.[0]?.id || '';
  const all = useAsync(() => (cid ? q(supabase.from('market_profiles').select('*').eq('crop_id', cid).order('code').order('version', { ascending: false })) as Promise<MarketProfile[]> : Promise.resolve([])), [cid]);
  const codes = useMemo(() => [...new Set((all.data ?? []).map((p) => p.code))], [all.data]);
  const canEdit = !oversees(ctx) && isStateManager(ctx);
  const [newCode, setNewCode] = useState(''); const [newName, setNewName] = useState('');
  const act = useAction();
  const start = () => act.run(async () => { await rpc('save_market_profile', { p: { crop_id: cid, code: newCode.trim().toLowerCase(), name: newName.trim(), params: [] } }); setNewCode(''); setNewName(''); await all.reload(); });
  if (crops.loading || lib.loading) return <Loading />;
  return (
    <div data-testid="set-profiles">
      <p className="small muted">{t('set.profiles_note')}</p>
      <Field label={t('gap.crop')} htmlFor="set-crop"><select id="set-crop" value={cid} onChange={(e) => setCropId(e.target.value)} data-testid="set-crop">
        {(crops.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
      {all.loading ? <Loading /> : <ErrorBox error={all.error} onRetry={all.reload} />}
      {codes.map((code) => <ProfileCard key={code} all={all.data ?? []} crop={cid} code={code} lib={lib.data ?? []} canEdit={canEdit} onChanged={() => void all.reload()} />)}
      {canEdit && cid && (
        <div className="card" data-testid="set-new-profile">
          <h3>{t('set.new_profile')}</h3>
          <div className="row wrap">
            <Field label={t('set.p_code')} hint={t('set.p_code_hint')} htmlFor="np-code"><input id="np-code" value={newCode} maxLength={20} onChange={(e) => setNewCode(e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, ''))} data-testid="np-code" /></Field>
            <Field label={t('set.p_name')} htmlFor="np-name"><input id="np-name" value={newName} maxLength={60} onChange={(e) => setNewName(e.target.value)} data-testid="np-name" /></Field>
          </div>
          <button className="secondary" disabled={act.busy || !/^[a-z][a-z0-9_]{1,20}$/.test(newCode) || newName.trim().length < 2 || codes.includes(newCode)} onClick={() => void start()} data-testid="np-start">{t('set.start_profile')}</button>
          <ErrorBox error={act.error} />
        </div>)}
    </div>);
}

function ProfileCard({ all, crop, code, lib, canEdit, onChanged }: { all: MarketProfile[]; crop: string; code: string; lib: LibraryParam[]; canEdit: boolean; onChanged: () => void }) {
  const { t } = useI18n();
  const { versions, active, draft } = profileVersions(all, crop, code);
  const act = useAction();
  const head = draft ?? active ?? versions[0];
  const change = () => act.run(async () => { await rpc('save_market_profile', { p: { id: active!.id } }); onChanged(); });
  return (
    <div className="card" data-testid="profile-card" data-code={code}>
      <div className="row wrap"><strong>{head.name}</strong> <span className="mono small">{code}</span>
        {active && <Badge value="pass" label={t('set.v_active', { v: active.version })} />}
        {draft && <Badge value="pending" label={t('set.v_draft', { v: draft.version })} />}</div>
      {active && <ProfileView p={active} lib={lib} />}
      {draft && canEdit ? <DraftEditor p={draft} lib={lib} onChanged={onChanged} />
        : draft ? <ProfileView p={draft} lib={lib} /> : null}
      {canEdit && active && !draft && <button className="secondary" onClick={() => void change()} disabled={act.busy} data-testid="profile-change">{t('set.change_profile')}</button>}
      <ErrorBox error={act.error} />
      {versions.filter((v) => v.status === 'retired').length > 0 && (
        <details><summary className="small">{t('set.older_versions')}</summary>
          <ul className="small">{versions.filter((v) => v.status === 'retired').map((v) => <li key={v.id}>{t('set.v_retired', { v: v.version })} · {date(v.activated_at ?? v.created_at)}</li>)}</ul></details>)}
    </div>);
}

function ProfileView({ p, lib }: { p: MarketProfile; lib: LibraryParam[] }) {
  const { t } = useI18n();
  const yes = t('common.yes'), no = t('common.no');
  return (
    <dl className="kv small">
      <dt>{t('set.p_params')}</dt><dd data-testid="profile-params">{p.params.length ? p.params.map((x) => `${lib.find((l) => l.param === x.param)?.name ?? x.param} ${limitWords(x, lib.find((l) => l.param === x.param), yes, no)}`).join(' · ') : '—'}</dd>
      <dt>{t('set.p_docs')}</dt><dd>{p.export_docs.length ? p.export_docs.join(' · ') : '—'}</dd>
      <dt>{t('set.p_source')}</dt><dd><SourceLine p={p} /></dd>
    </dl>);
}

function SourceLine({ p }: { p: MarketProfile }) {
  const { t } = useI18n();
  const f = useAsync(async () => (p.source_file_id ? await q(supabase.from('reference_files').select('storage_path,file_name,sha256').eq('id', p.source_file_id).maybeSingle()) as unknown as { storage_path: string; file_name: string | null; sha256: string } | null : null), [p.source_file_id]);
  const open = async () => { if (!f.data) return; const u = await referenceUrl(f.data.storage_path); if (u) window.open(u, '_blank', 'noopener'); };
  if (!p.source_file_id) return <>{p.source_note ?? t('set.no_source')}</>;
  return <span data-testid="profile-source">{f.data ? <button className="linkish" onClick={() => void open()}>{f.data.file_name || t('set.source_file')}</button> : '…'}
    {p.source_note && ` · ${p.source_note}`}{f.data && <span className="mono muted"> · {f.data.sha256.slice(0, 12)}…</span>}</span>;
}

function DraftEditor({ p, lib, onChanged }: { p: MarketProfile; lib: LibraryParam[]; onChanged: () => void }) {
  const { t } = useI18n();
  const [params, setParams] = useState<ProfileParam[]>(p.params);
  const [typed, setTyped] = useState<Record<number, string>>(() => Object.fromEntries(p.params.map((x, i) => [i, x.limit == null ? '' : String(x.limit)])));
  const [docs, setDocs] = useState(p.export_docs.join(', '));
  const [note, setNote] = useState(p.source_note ?? '');
  const act = useAction();
  const problem = profileProblem(params, lib);
  const setP = (i: number, x: Partial<ProfileParam>) => setParams(params.map((y, j) => (j === i ? { ...y, ...x } : y)));
  const body = () => ({ id: p.id, params, export_docs: docs.split(',').map((x) => x.trim()).filter(Boolean), source_note: note.trim() || null });
  const save = () => act.run(async () => { await rpc('save_market_profile', { p: body() }); onChanged(); });
  const upload = (file: File | undefined) => file && act.run(async () => {
    const f = await uploadReference(p.crop_id, 'profile_source', file);
    await rpc('save_market_profile', { p: { ...body(), source_file_id: f.id } }); onChanged();
  });
  const activate = () => act.run(async () => { await rpc('save_market_profile', { p: body() }); await rpc('activate_market_profile', { p_id: p.id }); onChanged(); });
  return (
    <div className="stack sub-card" data-testid="profile-draft">
      <p className="small muted">{t('set.draft_note', { v: p.version })}</p>
      {params.map((x, i) => {
        const l = lib.find((y) => y.param === x.param);
        return (
          <div key={i} className="row wrap" data-testid="profile-param">
            <select aria-label={t('set.p_param')} value={x.param} onChange={(e) => { const nl = lib.find((y) => y.param === e.target.value);
              setP(i, nl?.type === 'number' ? { param: e.target.value, operator: '<=', limit: undefined, pass: undefined } : nl?.type === 'grade' ? { param: e.target.value, pass: [], operator: undefined, limit: undefined } : { param: e.target.value, pass: false, operator: undefined, limit: undefined });
              setTyped({ ...typed, [i]: '' }); }} style={{ width: 'auto' }}>
              <option value="">—</option>{lib.filter((y) => y.param === x.param || (!y.alias_of && !params.some((z) => z.param === y.param))).map((y) => <option key={y.param} value={y.param}>{y.name}{y.unit ? ` (${y.unit})` : ''}</option>)}</select>
            {l?.type === 'number' && <>
              <select aria-label={t('crops.p_rule')} value={x.operator ?? '<='} onChange={(e) => setP(i, { operator: e.target.value })} style={{ width: 'auto' }}>
                <option value="<=">{t('crops.r_at_most')}</option><option value=">=">{t('crops.r_at_least')}</option></select>
              <input aria-label={t('set.p_limit')} inputMode="decimal" value={typed[i] ?? ''} style={{ width: 90 }} data-testid="profile-limit"
                onChange={(e) => { setTyped({ ...typed, [i]: e.target.value }); const n = Number(e.target.value.replace(',', '.')); setP(i, { limit: e.target.value.trim() !== '' && Number.isFinite(n) ? n : undefined }); }} /></>}
            {l?.type === 'grade' && <input aria-label={t('crops.grades')} placeholder="A, B" value={Array.isArray(x.pass) ? x.pass.join(', ') : ''} style={{ width: 120 }}
              onChange={(e) => setP(i, { pass: e.target.value.split(',').map((g) => g.trim()).filter(Boolean) })} />}
            {l?.type === 'yesno' && <select aria-label={t('set.p_pass')} value={x.pass === true ? 'yes' : 'no'} onChange={(e) => setP(i, { pass: e.target.value === 'yes' })} style={{ width: 'auto' }}>
              <option value="no">{t('common.no')}</option><option value="yes">{t('common.yes')}</option></select>}
            <button className="secondary small-btn" onClick={() => setParams(params.filter((_, j) => j !== i))} aria-label={t('crops.remove_row')}>✕</button>
          </div>);
      })}
      <button className="secondary" onClick={() => setParams([...params, { param: '' }])} data-testid="profile-add-param">{t('set.add_param')}</button>
      <Field label={t('set.p_docs')} hint={t('set.docs_hint')} htmlFor={`pd-${p.id}`}><input id={`pd-${p.id}`} value={docs} onChange={(e) => setDocs(e.target.value)} /></Field>
      <Field label={t('set.p_source_note')} hint={t('set.source_note_hint')} htmlFor={`pn-${p.id}`}><input id={`pn-${p.id}`} value={note} maxLength={200} onChange={(e) => setNote(e.target.value)} /></Field>
      <div className="small">{t('set.p_source')}: <SourceLine p={p} /></div>
      <label className="btn secondary" style={{ alignSelf: 'flex-start' }}>{t(p.source_file_id ? 'set.source_replace' : 'set.source_upload')}
        <input type="file" accept="application/pdf,image/*" style={{ display: 'none' }} disabled={act.busy} onChange={(e) => void upload(e.target.files?.[0])} data-testid="profile-source-file" /></label>
      {problem && <div className="alert warn small" data-testid="profile-problem">{t(problem.key, problem.vars)}</div>}
      {!p.source_file_id && <p className="small muted">{t('set.needs_source')}</p>}
      <ErrorBox error={act.error} />
      <div className="row">
        <button className="secondary" onClick={() => void save()} disabled={act.busy || !!problem} data-testid="profile-save">{t('common.save')}</button>
        <button onClick={() => void activate()} disabled={act.busy || !!problem || params.length === 0 || !p.source_file_id} data-testid="profile-activate">{t('set.activate', { v: p.version })}</button>
      </div>
    </div>);
}

function Library() {
  const { t } = useI18n();
  const lib = useLibrary();
  if (lib.loading) return <Loading />;
  return (
    <div data-testid="set-library">
      <p className="small muted">{t('set.library_note')}</p>
      <ErrorBox error={lib.error} onRetry={lib.reload} />
      <div className="card table-wrap"><table>
        <thead><tr><th>{t('set.l_name')}</th><th>{t('set.l_unit')}</th><th className="hide-mobile">{t('set.l_method')}</th><th>{t('set.l_by')}</th></tr></thead>
        <tbody>{(lib.data ?? []).filter((l) => !l.alias_of).map((l) => (   // a second name of a test is not listed twice (migration 52)
          <tr key={l.param} data-testid="library-row"><td>{l.name}<div className="small muted">{t(`set.grp_${l.grp}`)}</div></td><td>{l.unit ?? (l.type === 'grade' ? t('crops.t_grade') : l.type === 'yesno' ? t('crops.t_yesno') : '—')}</td>
            <td className="hide-mobile small">{l.method ?? '—'}</td><td>{t(`set.by_${l.done_by}`)}</td></tr>))}</tbody>
      </table></div>
    </div>);
}

