// S7 scope list · S8 scope wizard (season + place → crop → chain with live problems → people) · scope view
// Identity layer (6 Oct 2026): a scope has its own state (a client may work in several); the People step gives stages
// to people from the pool HR has made (pages/people: RosterEditor) and no longer creates anybody.
import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { rpc, q } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { toAppError, type AppError } from '../../lib/errors';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { humanise } from '../../lib/format';
import { isManager, type StageDefinition, type StageType } from '../../lib/types';
import { actsAsStateManager, buildsScope, buildsScopes, oversees } from '../../lib/rights';
import { RosterEditor } from '../people/People';
import { assembleChain, offeredForScope, splitChain, type CropFull } from '../../lib/crops';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { plainWords } from '../../lib/plainErrors';
import { clientScopeStates } from '../../lib/clients';

interface ScopeRow { id: string; client_id: string; crop_id: string; season_code: string; geography: string; chain: StageType[]; status: string; activated_at: string | null;
  /** migration 48 (E4): in the scope's record numbers */ short_code?: string | null;
  /** migration 50 (C5): the lab record names the lab, the report and attaches it (set before activation) */ qc_report_required?: boolean;
  state_id?: string; season_end?: string | null;
  /** migration 55 (C3): a stored lot is inspected every so many days (its Client Manager, any time) */ warehouse_inspection_days?: number;
  /** migration 52 (C1): Procurement records price and payment; asks where, the GPS and who delivered. Changed at any time. */
  record_price?: boolean; procurement_details_required?: boolean;
  /** migration 53 (C4–C6): Milling, Quality Control and Packing ask the mill, sample, lab, packing unit and packs from
   *  the lists; the markets QC judges each lot against. Changed at any time. */
  stage_details_required?: boolean; market_codes?: string[] }
type Crop = CropFull;   // migration 42: with its readiness and recommended chain
interface Client { id: string; name: string; code: string; state_id?: string }
interface StateRow { id: string; name: string }

export function ScopeList() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  return (
    <div>
      <h1><span aria-hidden="true">🎯 </span>{t('scopes.title')}</h1>
      {oversees(ctx) ? <p className="small muted" data-testid="scopes-readonly">{t('scopes.admin_reads')}</p>
        : actsAsStateManager(ctx) ? <p className="small muted" data-testid="scopes-sm-reads">{t('scopes.sm_reads')}</p>
        : (ctx!.user!.can?.build_scope ?? ctx!.user!.can?.assign ?? isManager(ctx!.user!.role)) && <p><Link className="btn" to="/scopes/new">{t('scopes.new')}</Link></p>}
      {ctx!.scopes.length === 0 ? <Empty /> : (
        <div className="card table-wrap"><table>
          <thead><tr><th>Client</th><th>{t('lens.state')}</th><th>Crop</th><th>Season</th><th>Place</th><th>Chain</th><th>{t('common.status')}</th><th /></tr></thead>
          <tbody>{ctx!.scopes.map((s) => (
            <tr key={s.scope_id}><td>{s.client_name}</td><td>{s.state_name ?? ''}</td><td>{s.crop_name}</td><td>{s.season_code}</td>
              <td><Link to={`/scopes/${s.scope_id}`}>{s.geography}</Link></td>
              <td className="small">{s.chain.map((x) => t(`stage.${x}`, undefined, humanise(x))).join(' → ')}</td><td><Badge value={s.status} /></td>
              <td>{(s.whole ?? true) && <Link className="small" to={`/scopes/${s.scope_id}/roster`}>{t('roster.title')}</Link>}</td></tr>
          ))}</tbody>
        </table></div>
      )}
    </div>
  );
}

/** Builds the ordered chain from the builder's choices (lib/crops.ts since migration 42; the crop's recommended chain uses it too). */
export { assembleChain };

export function ScopeWizard() {
  const { id } = useParams();
  const [search] = useSearchParams();
  const { t } = useI18n();
  const { ctx, refresh } = useAuth();
  const nav = useNavigate();
  const me = ctx!.user!;
  const clients = useAsync(() => q(supabase.from('clients').select('id,name,code,state_id').order('name')) as Promise<Client[]>, []);
  const states = useAsync(() => q(supabase.from('states').select('id,name').order('name')) as Promise<StateRow[]>, []);
  const crops = useAsync(() => q(supabase.from('crops').select('*').order('name')) as Promise<Crop[]>, []);
  const defs = useAsync(() => q(supabase.from('stage_definitions').select('*').order('sort_order')) as Promise<StageDefinition[]>, []);
  const existing = useAsync(() => id ? q(supabase.from('scopes').select('*').eq('id', id).single()) as Promise<ScopeRow> : Promise.resolve(null), [id]);
  // what still stops activation (migration 44, Veda 14 Oct): a person on every stage, a ready crop. A server before 44: nothing listed.
  const missing = useAsync(() => id ? rpc<ActivationMissing>('activation_missing', { p_scope: id }).catch(() => null) : Promise.resolve(null), [id]);
  const [step, setStep] = useState(1);
  const [clientId, setClientId] = useState(me.client_id ?? '');
  const [season, setSeason] = useState('KH26');
  const [geo, setGeo] = useState('');
  const [labReport, setLabReport] = useState(true);          // migration 50 (C5): ask the lab for its report (the default)
  const [short, setShort] = useState('');                   // migration 48 (E4): the short code in record numbers
  const [stateId, setStateId] = useState('');              // '' = the client's home state (the database fills it in)
  const [seasonEnd, setSeasonEnd] = useState('');
  const [cropId, setCropId] = useState('');
  const [entry, setEntry] = useState<StageType>('procurement');
  const [villageBatch, setVillageBatch] = useState(false);
  const [warehouse, setWarehouse] = useState(false);        // migration 55 (C3): a Warehouse after the entry (or the batch)
  const [before, setBefore] = useState<StageType[]>([]);
  const [after, setAfter] = useState<StageType[]>([]);
  const [commercial, setCommercial] = useState(false);
  const [shipment, setShipment] = useState(false);
  const [problems, setProblems] = useState<string[] | null>(null);
  const [checkError, setCheckError] = useState<AppError | null>(null);
  const act = useAction();
  const placed = useRef<string | null>(null);           // the scope whose first step was chosen (14 Oct: a save sent it back)
  // migration 65 (Part C): the client's states and its status in each (a server before 65: none, the home state as before)
  const cstates = useAsync(() => clientId ? clientScopeStates(clientId).catch(() => null) : Promise.resolve(null), [clientId]);

  useEffect(() => {
    const s = existing.data;
    if (!s) return;
    setClientId(s.client_id); setSeason(s.season_code); setGeo(s.geography); setCropId(s.crop_id); setShort(s.short_code ?? ''); setLabReport(s.qc_report_required !== false);
    setStateId(s.state_id ?? ''); setSeasonEnd(s.season_end ?? '');
    const c = s.chain, qi = c.indexOf('qc');
    setEntry(c[0]); setVillageBatch(c.includes('village_batch')); setWarehouse(c.includes('warehouse'));
    const proc = (x: StageType) => defs.data?.find((d) => d.stage_type === x)?.is_processing;
    setBefore(c.slice(1, qi).filter(proc)); setAfter(c.slice(qi + 1).filter(proc));
    setCommercial(c.includes('commercial')); setShipment(c.includes('shipment'));
    // a draft whose chain is saved opens on step 4, People (14 Oct 2026, brief F); ?step=chain opens the chain. Chosen once
    // per scope: before, every save re-ran this and put a reopened draft back on step 3, so "Save draft → People" seemed
    // to do nothing.
    // (16 Oct 2026, release 8: a link with ?step=chain put the draft back on step 3 after "Save draft → People" too;
    // the step a link asks for is now taken once per scope and link, like the scope's own first step)
    const placeKey = `${s.id}:${search.get('step') ?? ''}`;
    if (placed.current !== placeKey) {
      placed.current = placeKey;
      const want = search.get('step');
      setStep(s.status !== 'draft' ? 4 : want === 'chain' ? 3 : want === 'crop' ? 2 : want === 'season' ? 1 : 4);
    }
  }, [existing.data, defs.data, search]);

  const chain = useMemo(() => assembleChain({ entry, villageBatch, warehouse, before, after, commercial, shipment }), [entry, villageBatch, warehouse, before, after, commercial, shipment]);
  useEffect(() => {
    if (!cropId) return;
    // a refusal of the check is shown, never swallowed (14 Oct 2026, brief F: the button stayed off with no word)
    const h = setTimeout(() => { void rpc<string[]>('check_chain', { p_chain: chain, p_crop: cropId })
      .then((p) => { setProblems(p); setCheckError(null); }, (e) => { setProblems(null); setCheckError(toAppError(e)); }); }, 250);
    return () => clearTimeout(h);
  }, [chain, cropId]);

  if (clients.loading || crops.loading || defs.loading || existing.loading || states.loading) return <Loading />;
  const s = existing.data;
  const frozen = !!s && s.status !== 'draft';
  // Does the signed-in person build THIS scope (its client's Client Manager, migration 41)? A State Manager reads it; since
  // migration 44 he does not staff it either (the roster shows no controls to him). (A server before migration 41 sends no `build`: manage, as before.)
  const known = s ? ctx!.scopes.find((x) => x.scope_id === s.id) : undefined;
  const canManage = s ? (known?.build ?? (ctx!.user!.can?.build_scope === undefined ? known?.manage ?? isManager(me.role) : buildsScope(ctx, s.id)))
    : buildsScopes(ctx) || (ctx!.user!.can?.build_scope === undefined && !oversees(ctx));
  // Someone who reads this scope but does not manage it (the admin, a viewer): what it is, and who holds what. No editor.
  if (!canManage) return (
    <div data-testid="scope-readonly">
      <p className="small"><Link to="/scopes">{t('scopes.title')}</Link></p>
      <h1>{s ? `${crops.data?.find((c) => c.id === s.crop_id)?.name ?? ''} · ${s.season_code} · ${s.geography}` : t('scopes.new')} {s && <Badge value={s.status} />}</h1>
      <div className="alert info">{t(s ? 'scopes.read_only' : 'scopes.admin_reads')}</div>
      {s && <div className="card">
        <p><strong>{t('ov.c_client')}:</strong> {clients.data?.find((c) => c.id === s.client_id)?.name ?? '—'} · <strong>{t('lens.state')}:</strong> {states.data?.find((x) => x.id === s.state_id)?.name ?? '—'}</p>
        <p><strong>Chain:</strong> {s.chain.map((x) => defs.data?.find((d) => d.stage_type === x)?.label ?? humanise(x)).join(' → ')}</p>
        <p className="small"><Link to={`/scopes/${s.id}/roster`}>{t('roster.title')}</Link>{s.status !== 'draft' && <> · <Link to={`/dashboard/${s.id}`}>{t('dash.open')}</Link></>}</p>
        <h3>{t('wizard.step4')}</h3>
        <RosterEditor scopeId={s.id} />
      </div>}
    </div>);
  const homeState = clients.data?.find((c) => c.id === clientId)?.state_id ?? '';
  // migration 65 (Part C): a client in several states: the scope is made in one where it is Diagnostic or Active
  const crop = crops.data?.find((c) => c.id === cropId);
  const processing = (defs.data ?? []).filter((d) => d.is_processing && crop?.allowed_stages.includes(d.stage_type));
  const label = (x: StageType) => defs.data?.find((d) => d.stage_type === x)?.label ?? humanise(x);
  const toggle = (list: StageType[], set: (v: StageType[]) => void, other: StageType[], setOther: (v: StageType[]) => void, x: StageType) => {
    if (list.includes(x)) set(list.filter((y) => y !== x)); else { set([...list, x]); setOther(other.filter((y) => y !== x)); }
  };

  const saveDraft = () => act.run(async () => {
    const row = { client_id: clientId, crop_id: cropId, season_code: season.trim().toUpperCase(), geography: geo.trim(), chain,
      ...(short.trim() ? { short_code: short.trim().toUpperCase() } : {}),          // migration 48: none typed, the server gives one
      qc_report_required: labReport,
      ...(stateId || homeState ? { state_id: stateId || homeState } : {}), season_end: seasonEnd || null };
    const saved = s ? await q(supabase.from('scopes').update(row).eq('id', s.id).select().single()) as ScopeRow
                    : await q(supabase.from('scopes').insert({ ...row, status: 'draft' }).select().single()) as ScopeRow;
    await refresh();
    if (!s) nav(`/scopes/${saved.id}?step=people`, { replace: true }); else existing.setData(saved);
    setStep(4);
  });
  const lacks = activationLacks(missing.data ?? null, label, t);
  const activate = () => act.run(async () => {
    if (!window.confirm(t('wizard.activate_warning'))) return;
    const saved = await q(supabase.from('scopes').update({ status: 'active' }).eq('id', s!.id).select().single()) as ScopeRow;
    existing.setData(saved); await refresh();
  });

  return (
    <div>
      <p className="small"><Link to="/scopes">{t('scopes.title')}</Link></p>
      <h1>{s ? `${crop?.name ?? ''} · ${s.season_code} · ${s.geography}` : t('scopes.new')} {s && <Badge value={s.status} />}</h1>
      {s?.short_code && <p className="small" data-testid="scope-short-code">{t('scope.short_code')}: <strong className="mono">{s.short_code}</strong></p>}
      <ol className="stepper">{[1, 2, 3, 4].map((n) => {
        const open = !frozen && n !== step && (n < step || (!!s && s.status === 'draft'));   // a saved draft: every step; a new one: the steps done
        return <li key={n} className={n < step ? 'done' : n === step ? 'current' : ''} aria-current={n === step ? 'step' : undefined}>
          {open ? <button type="button" className="step-link" onClick={() => setStep(n)} data-testid={`step-${n}`}>{n} {t(`wizard.step${n}`)}</button>
                : <>{n} {t(`wizard.step${n}`)}</>}</li>;
      })}</ol>
      {frozen && <div className="alert info">{t('wizard.activate_warning')}</div>}
      {s && s.chain.includes('procurement') && <ProcurementSettings s={s} onSaved={(x) => existing.setData(x)} />}
      {s && s.chain.includes('procurement') && <ScopePartners scopeId={s.id} manage={buildsScope(ctx, s.id) && s.status !== 'closed'} />}
      {s && s.chain.some((x) => x === 'milling' || x === 'qc' || x === 'packing') && <StageSettings s={s} onSaved={(x) => existing.setData(x)} />}

      {step === 1 && !frozen && (
        <div className="card">
          {!me.client_id && <Field label="Client" htmlFor="wz-client"><select id="wz-client" value={clientId} onChange={(e) => setClientId(e.target.value)}>
            <option value="">—</option>{(clients.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>}
          <Field label="Season code" hint="two letters + year, e.g. KH26 for Kharif 2026" htmlFor="wz-season">
            <input id="wz-season" value={season} onChange={(e) => setSeason(e.target.value.toUpperCase())} maxLength={4} /></Field>
          <Field label="Geography" hint="district, block or mandi" htmlFor="wz-geo"><input id="wz-geo" value={geo} onChange={(e) => setGeo(e.target.value)} /></Field>
          <Field label={t('scope.short_code')} hint={t('scope.short_code_hint')} htmlFor="wz-short">
            <input id="wz-short" value={short} maxLength={4} onChange={(e) => setShort(e.target.value.toUpperCase().replace(/[^A-Z]/g, ''))} data-testid="wz-short" /></Field>
          <label className="check"><input type="checkbox" checked={labReport} onChange={(e) => setLabReport(e.target.checked)} data-testid="wz-lab-report" />{t('scope.qc_report')}</label>
          <p className="hint">{t('scope.qc_report_hint')}</p>
          {/* migration 41 (Veda, 13 Oct): a new scope is in its client's own state; a scope made earlier elsewhere keeps its state.
              migration 65 (Part C): a client added to other states: one of its states where it is Diagnostic or Active */}
          {(cstates.data?.length ?? 0) > 1 ? (
            <Field label={t('lens.state')} hint={t('wizard.state_client')} htmlFor="wz-state-pick">
              <select id="wz-state-pick" data-testid="wz-state-pick" value={stateId || homeState} onChange={(e) => { setStateId(e.target.value); setCropId(''); }}>
                {cstates.data!.map((x) => <option key={x.id} value={x.id} disabled={x.status !== 'diagnostic' && x.status !== 'active'}>
                  {x.name} · {t(`cst.${x.status}`)}</option>)}</select></Field>
          ) : <p className="small" data-testid="wz-state">{t('lens.state')}: <strong>{states.data?.find((x) => x.id === (stateId || homeState))?.name ?? '—'}</strong>
            <span className="muted"> · {t('wizard.state_home_only')}</span></p>}
          <Field label={t('wizard.season_end')} hint={t('wizard.season_end_hint')} htmlFor="wz-end"><input id="wz-end" type="date" value={seasonEnd} onChange={(e) => setSeasonEnd(e.target.value)} /></Field>
          <button disabled={!clientId || !/^[A-Z]{2}[0-9]{2}$/.test(season) || !geo.trim() || (short !== '' && short.length < 2)} onClick={() => setStep(2)}>{t('common.next')}</button>
        </div>
      )}
      {step === 2 && !frozen && (
        <div className="card">
          {/* migration 42: a retired crop is not offered; one that is not ready is shown but cannot be picked; the chain starts
              from the crop's recommended chain */}
          <Field label="Crop" htmlFor="wz-crop"><select id="wz-crop" value={cropId} onChange={(e) => {
            const c = crops.data?.find((x) => x.id === e.target.value);
            setCropId(e.target.value);
            if (c?.recommended_chain?.length) {
              const p = splitChain(c.recommended_chain, (x) => !!defs.data?.find((d) => d.stage_type === x)?.is_processing);
              setEntry(p.entry); setVillageBatch(p.villageBatch); setWarehouse(p.warehouse); setBefore(p.before); setAfter(p.after); setCommercial(p.commercial); setShipment(p.shipment);
            } else { setBefore([]); setAfter([]); }
          }}>
            <option value="">—</option>{(crops.data ?? []).filter((c) => (!c.state_id || c.state_id === (stateId || homeState)) && !c.retired_at)
              .map((c) => <option key={c.id} value={c.id} disabled={!offeredForScope(c)}>{offeredForScope(c) ? c.name : `${c.name} (${t('crops.not_ready')})`}</option>)}</select></Field>
          {crops.data?.some((c) => (!c.state_id || c.state_id === (stateId || homeState)) && !c.retired_at && !offeredForScope(c)) &&
            <p className="small muted" data-testid="wz-not-ready">{t('wizard.crop_not_ready')}</p>}
          <div className="row"><button className="secondary" onClick={() => setStep(1)}>{t('common.back')}</button><button disabled={!cropId} onClick={() => setStep(3)}>{t('common.next')}</button></div>
        </div>
      )}
      {step === 3 && !frozen && (
        <div className="card">
          <h3>Entry</h3>
          {(['procurement', 'lot_inward'] as StageType[]).map((x) => (
            <label key={x} className="check"><input type="radio" name="entry" checked={entry === x} onChange={() => setEntry(x)} />{label(x)}</label>))}
          {entry === 'procurement' && <label className="check"><input type="checkbox" checked={villageBatch} onChange={(e) => setVillageBatch(e.target.checked)} />{label('village_batch')}</label>}
          <label className="check"><input type="checkbox" data-testid="wz-warehouse" checked={warehouse} onChange={(e) => setWarehouse(e.target.checked)} />{label('warehouse')}</label>
          <p className="muted small">{t('wizard.warehouse_note')}</p>
          <h3>Processing before QC</h3>
          {processing.map((d) => <label key={d.stage_type} className="check"><input type="checkbox" data-testid={`before-${d.stage_type}`} checked={before.includes(d.stage_type)}
            onChange={() => toggle(before, setBefore, after, setAfter, d.stage_type)} />{d.label}</label>)}
          <h3>Quality Control</h3><p className="muted small">Always in the chain.</p>
          <h3>Processing after QC</h3>
          {processing.map((d) => <label key={d.stage_type} className="check"><input type="checkbox" data-testid={`after-${d.stage_type}`} checked={after.includes(d.stage_type)}
            onChange={() => toggle(after, setAfter, before, setBefore, d.stage_type)} />{d.label}</label>)}
          <h3>Exit</h3>
          <label className="check"><input type="checkbox" checked={commercial} onChange={(e) => setCommercial(e.target.checked)} />{label('commercial')}</label>
          <label className="check"><input type="checkbox" checked={shipment} onChange={(e) => setShipment(e.target.checked)} />{label('shipment')}</label>
          <p className="muted small">Ends with {label('qr_activation')}.</p>
          <div className="alert info" data-testid="chain-preview"><strong>Chain:</strong> {chain.map(label).join(' → ')}</div>
          {problems && problems.length > 0 && <div className="alert error" data-testid="chain-problems">{t('wizard.problems')}<ul>{problems.map((p) => <li key={p}>{plainWords(p, t) ?? p}</li>)}</ul></div>}
          {problems && problems.length === 0 && <div className="alert ok">{t('wizard.ok')}</div>}
          <ErrorBox error={checkError} />
          <ErrorBox error={act.error} />
          <div className="row">{!s && <button className="secondary" onClick={() => setStep(2)}>{t('common.back')}</button>}
            <button onClick={saveDraft} disabled={act.busy || !problems || problems.length > 0}>{t('wizard.save_draft')} → {t('wizard.step4')}</button></div>
        </div>
      )}
      {step === 4 && s && (
        <div className="card">
          <div className="alert info"><strong>Chain:</strong> {s.chain.map(label).join(' → ')}</div>
          <h3>{t('wizard.step4')}</h3>
          <RosterEditor scopeId={s.id} onChanged={() => void missing.reload()} />
          <ErrorBox error={act.error} />
          {s.status === 'draft' && canManage && lacks.length > 0 && (
            <div className="alert warn" data-testid="activation-missing">{t('wizard.cannot_activate')}
              <ul>{lacks.map((x, i) => { const st = missing.data?.stages[i - (lacks.length - (missing.data?.stages.length ?? 0))];   // migration 46: a stage links to its request
                return <li key={x}>{st ? <a href={`#req-${st}`} data-testid="lack-link">{x}</a> : x}</li>; })}</ul></div>)}
          {s.status === 'draft' && canManage && <div className="row"><button className="secondary" onClick={() => setStep(3)}>{t('common.back')}</button>
            <button className="gold" onClick={activate} disabled={act.busy || lacks.length > 0} data-testid="activate">{t('wizard.activate')}</button></div>}
          {s.status !== 'draft' && <p className="small"><Link to="/">{t('nav.home')}</Link> · <Link to={`/scopes/${s.id}/roster`}>{t('roster.title')}</Link></p>}
        </div>
      )}
    </div>
  );
}

/** What the server says still stops a scope's activation (migration 44). */
export interface ActivationMissing { crop: string[]; retired: boolean; stages: StageType[] }
/** Pure: the lines "what is missing" under the Activate button, crop first, then each stage with nobody. */
export function activationLacks(m: ActivationMissing | null, label: (x: StageType) => string,
  t: (k: string, v?: Record<string, string | number>, f?: string) => string): string[] {
  if (!m) return [];
  return [
    ...(m.retired ? [t('wizard.lack_retired')] : []),
    ...m.crop.map((k) => t('wizard.lack_crop', { what: t(`crops.missing_${k}`, undefined, k) })),
    ...m.stages.map((x) => t('wizard.lack_stage', { stage: label(x) })),
  ];
}

/** Migration 52 (C1): how this scope's farm-gate form works. The Client Manager changes these at any time, also once the
 *  scope is active: they decide what the next lots ask, not what was recorded. */
/** migration 66 (Part E3): the scope's sourcing partners (an FPO or aggregator its lots are procured through), from the
 *  registry; a new one registered by its PAN. "Partner agrees to be named publicly": only then does the public page say
 *  "Sourced through …". Its Client Manager sets them; the scope's people read them. */
type PartnerRow = { entity_id: string; name: string; pan_masked: string | null; named_publicly: boolean };
const PARTNER_TYPES = ['cooperative', 'company', 'society', 'firm', 'llp', 'trust', 'individual', 'huf', 'government'];
function ScopePartners({ scopeId, manage }: { scopeId: string; manage: boolean }) {
  const { t } = useI18n();
  const list = useAsync(() => rpc<PartnerRow[]>('scope_partners', { p_scope: scopeId }).catch(() => null), [scopeId]);
  const reg = useAsync(() => manage ? rpc<{ entity_id: string; name: string; pan_masked: string | null }[]>('sourcing_partners').catch(() => []) : Promise.resolve([]), [manage]);
  const act = useAction();
  const [pick, setPick] = useState(''); const [named, setNamed] = useState(false);
  const [adding, setAdding] = useState(false); const [pan, setPan] = useState(''); const [ptype, setPtype] = useState('cooperative'); const [pname, setPname] = useState('');
  const [removing, setRemoving] = useState<string | null>(null); const [why, setWhy] = useState('');
  if (list.data === null) return null;                                     // a server from before migration 66
  const rows = list.data ?? [];
  const offer = (reg.data ?? []).filter((x) => !rows.some((r) => r.entity_id === x.entity_id));
  const add = () => void act.run(async () => { list.setData(await rpc<PartnerRow[]>('set_scope_partner', { p_scope: scopeId, p_entity: pick, p_named: named })); setPick(''); setNamed(false); });
  const register = () => void act.run(async () => {
    const r = await rpc<{ entity_id: string }>('register_sourcing_partner', { p_pan: pan.trim().toUpperCase(), p_type: ptype, p_name: pname });
    reg.reload(); setPick(r.entity_id); setAdding(false); setPan(''); setPname('');
  });
  return (
    <div className="card" data-testid="scope-partners">
      <h3>{t('sp.partners_title')}</h3>
      <p className="small muted">{t('sp.partners_note')}</p>
      {rows.length === 0 && <p className="small" data-testid="sp-none">{t('sp.none')}</p>}
      <ul className="small" style={{ listStyle: 'none', paddingLeft: 0 }}>{rows.map((r) => (
        <li key={r.entity_id} data-testid="sp-row" data-named={r.named_publicly ? 'yes' : 'no'}>
          <strong>{r.name}</strong>{r.pan_masked && <span className="mono"> · {r.pan_masked}</span>} · {t(r.named_publicly ? 'sp.named' : 'sp.not_named')}
          {manage && <> <button type="button" className="linkish" data-testid="sp-toggle-named"
            onClick={() => void act.run(async () => list.setData(await rpc<PartnerRow[]>('set_scope_partner', { p_scope: scopeId, p_entity: r.entity_id, p_named: !r.named_publicly })))}>
            {t(r.named_publicly ? 'sp.unname' : 'sp.name')}</button>
            {' · '}<button type="button" className="linkish" data-testid="sp-remove-open" onClick={() => setRemoving(removing === r.entity_id ? null : r.entity_id)}>{t('sp.remove')}</button></>}
          {removing === r.entity_id && <div className="row wrap"><input aria-label={t('cl.reason')} value={why} onChange={(e) => setWhy(e.target.value)} data-testid="sp-why" />
            <button type="button" disabled={act.busy || why.trim().length < 10} data-testid="sp-remove"
              onClick={() => void act.run(async () => { list.setData(await rpc<PartnerRow[]>('remove_scope_partner', { p_scope: scopeId, p_entity: r.entity_id, p_reason: why })); setRemoving(null); setWhy(''); })}>{t('sp.remove')}</button></div>}
        </li>))}</ul>
      {manage && <div className="stack">
        <Field label={t('sp.add')} htmlFor="sp-pick"><select id="sp-pick" value={pick} onChange={(e) => setPick(e.target.value)} data-testid="sp-pick">
          <option value="">—</option>{offer.map((x) => <option key={x.entity_id} value={x.entity_id}>{x.name}{x.pan_masked ? ` · ${x.pan_masked}` : ''}</option>)}</select></Field>
        <label className="check"><input type="checkbox" checked={named} onChange={(e) => setNamed(e.target.checked)} data-testid="sp-named" />{t('sp.agrees')}</label>
        <div className="row wrap">
          <button type="button" disabled={act.busy || !pick} onClick={add} data-testid="sp-add">{t('sp.add_go')}</button>
          <button type="button" className="secondary" onClick={() => setAdding(!adding)} data-testid="sp-register-open">{t('sp.register')}</button>
        </div>
        {adding && <div className="stack" data-testid="sp-register">
          <Field label={t('cl.entity_type')} htmlFor="sp-type"><select id="sp-type" value={ptype} onChange={(e) => setPtype(e.target.value)}>
            {PARTNER_TYPES.map((x) => <option key={x} value={x}>{t(`etype.${x}`)}</option>)}</select></Field>
          <Field label="PAN" htmlFor="sp-pan"><input id="sp-pan" className="mono" maxLength={10} value={pan} onChange={(e) => setPan(e.target.value.toUpperCase())} /></Field>
          <Field label={t('cl.legal_name')} hint={t('sp.name_hint')} htmlFor="sp-name"><input id="sp-name" value={pname} maxLength={200} onChange={(e) => setPname(e.target.value)} /></Field>
          <button type="button" disabled={act.busy || pan.trim().length !== 10} onClick={register} data-testid="sp-register-go">{t('sp.register_go')}</button>
        </div>}
      </div>}
      <ErrorBox error={act.error} />
    </div>
  );
}

function ProcurementSettings({ s, onSaved }: { s: ScopeRow; onSaved: (x: ScopeRow) => void }) {
  const { t } = useI18n();
  const act = useAction();
  // shown at once; put back if the save is refused
  const [on, setOn] = useState({ details: s.procurement_details_required !== false, price: s.record_price === true });
  const set = (k: 'record_price' | 'procurement_details_required', v: boolean) => {
    const was = on;
    setOn({ ...on, [k === 'record_price' ? 'price' : 'details']: v });
    void act.run(async () => {
      try { onSaved(await q(supabase.from('scopes').update({ [k]: v }).eq('id', s.id).select().single()) as ScopeRow); }
      catch (e) { setOn(was); throw e; }
    });
  };
  return (
    <div className="card" data-testid="proc-settings">
      <h3>{t('ps.title')}</h3>
      <label className="check"><input type="checkbox" checked={on.details} disabled={act.busy}
        onChange={(e) => set('procurement_details_required', e.target.checked)} data-testid="ps-details" />{t('ps.details')}</label>
      <p className="hint">{t('ps.details_hint')}</p>
      <label className="check"><input type="checkbox" checked={on.price} disabled={act.busy}
        onChange={(e) => set('record_price', e.target.checked)} data-testid="ps-price" />{t('ps.price')}</label>
      <p className="hint">{t('ps.price_hint')}</p>
      <ErrorBox error={act.error} />
    </div>);
}

/** Migration 53 (C4–C6): how this scope's Milling, Quality Control and Packing forms work, and which markets each lot is
 *  judged against at QC. Like the farm-gate settings, these decide what the next records ask, not what was recorded. */
function StageSettings({ s, onSaved }: { s: ScopeRow; onSaved: (x: ScopeRow) => void }) {
  const { t } = useI18n();
  const act = useAction();
  const profiles = useAsync(() => q(supabase.from('market_profiles').select('code, name').eq('crop_id', s.crop_id).eq('status', 'active').order('code')) as Promise<{ code: string; name: string }[]>, [s.crop_id]);
  const [details, setDetails] = useState(s.stage_details_required !== false);
  const [codes, setCodes] = useState<string[]>(s.market_codes ?? ['domestic', 'export']);
  const [every, setEvery] = useState(String(s.warehouse_inspection_days ?? 15));
  const everyOk = /^[0-9]{1,3}$/.test(every) && Number(every) >= 1 && Number(every) <= 120;
  const save = (patch: Partial<ScopeRow>, undo: () => void) => void act.run(async () => {
    try { onSaved(await q(supabase.from('scopes').update(patch).eq('id', s.id).select().single()) as ScopeRow); }
    catch (e) { undo(); throw e; }
  });
  const toggle = (code: string, v: boolean) => {
    const was = codes;
    const next = v ? [...codes.filter((c) => c !== code), code] : codes.filter((c) => c !== code);
    if (next.length === 0) return;   // at least one market: the database refuses none
    setCodes(next); save({ market_codes: next }, () => setCodes(was));
  };
  return (
    <div className="card" data-testid="stage-settings">
      <h3>{t('ss.title')}</h3>
      <label className="check"><input type="checkbox" checked={details} disabled={act.busy} data-testid="ss-details"
        onChange={(e) => { const v = e.target.checked; setDetails(v); save({ stage_details_required: v }, () => setDetails(!v)); }} />{t('ss.details')}</label>
      <p className="hint">{t('ss.details_hint')}</p>
      <p className="small"><strong>{t('ss.markets')}</strong></p>
      {profiles.loading ? <Loading /> : (profiles.data ?? []).length === 0 ? <p className="small muted" data-testid="ss-no-markets">{t('ss.no_markets')}</p>
        : (profiles.data ?? []).map((m) => (
          <label key={m.code} className="check"><input type="checkbox" checked={codes.includes(m.code)} disabled={act.busy || (codes.length === 1 && codes.includes(m.code))}
            onChange={(e) => toggle(m.code, e.target.checked)} data-testid={`ss-market-${m.code}`} />{m.name}</label>))}
      <p className="hint">{t('ss.markets_hint')}</p>
      {s.chain.includes('warehouse') && <>
        <Field label={t('ss.inspection_days')} htmlFor="ss-every" hint={t('ss.inspection_hint')}>
          <div className="row"><input id="ss-every" inputMode="numeric" value={every} style={{ maxWidth: 90 }} data-testid="ss-every"
            onChange={(e) => setEvery(e.target.value.replace(/[^0-9]/g, ''))} />
            <button className="secondary" disabled={act.busy || !everyOk || Number(every) === (s.warehouse_inspection_days ?? 15)} data-testid="ss-every-save"
              onClick={() => { const was = String(s.warehouse_inspection_days ?? 15); save({ warehouse_inspection_days: Number(every) }, () => setEvery(was)); }}>{t('common.save')}</button></div></Field>
      </>}
      <ErrorBox error={act.error} />
    </div>);
}
