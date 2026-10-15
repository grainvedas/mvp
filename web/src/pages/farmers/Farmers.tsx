// S9 farmer list · S10 farmer form · S12 verification — S11 import lives in FarmerImport.tsx
// Two verifications (migration 34, Veda 10 Oct 2026): the Client Manager verifies a draft (step 1); the State Manager of
// the farmer's state then verifies its location and issues the Farmer ID (step 2), never the same person. Stage people
// save drafts only. The admin reads farmers and changes none. The database refuses all of this on its own; the buttons
// below only follow it.
import { useEffect, useState, type FormEvent } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { rpc, q } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import type { Farmer } from '../../lib/types';
import { actsAsStateManager, addsFarmers, holdsClientAccount, isStateManager, oversees, supervisesState, type Ctx } from '../../lib/rights';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { date, dateTime, humanise, kg } from '../../lib/format';
import { gapMissing, type GapItem } from '../../lib/crops';
import { giLandProblem, needsGiLand } from '../../lib/farmers';
import { RegisterLink } from './FarmerRegister';
import { ProposalsCard } from './FarmerPractice';

/** The client whose farmers this user works with; State Managers and admins pick one. */
export function useClientChoice() {
  const { ctx } = useAuth();
  const { t } = useI18n();
  const me = ctx!.user!;
  const fixed = me.client_id;
  const clients = useAsync(() => fixed ? Promise.resolve([]) : q(supabase.from('clients').select('id,name,code').order('name')) as Promise<{ id: string; name: string; code: string }[]>, [fixed]);
  const [chosen, setChosen] = useState<string>(() => { try { return localStorage.getItem('grainveda-client') ?? ''; } catch { return ''; } });
  const clientId = fixed ?? chosen ?? '';
  useEffect(() => { if (!fixed && clients.data?.length) setChosen((c) => c || clients.data![0].id); }, [fixed, clients.data]);
  const picker = fixed ? null : (
    <Field label={t('account.client')} htmlFor="client-pick">
      <select id="client-pick" value={clientId} onChange={(e) => { setChosen(e.target.value); try { localStorage.setItem('grainveda-client', e.target.value); } catch { /* ignore */ } }}>
        {(clients.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
      </select>
    </Field>
  );
  return { clientId, picker };
}

/** The note above the form of a farmer who is past "draft": only an active (or deactivated) farmer has been verified. */
export const farmerNote = (status: string) => (status === 'under_review' ? 'farmers.waiting_note' : 'farmers.change_recorded');

export function FarmerList() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const me = ctx!.user!;
  const { clientId, picker } = useClientChoice();
  const watch = oversees(ctx);
  const cm = holdsClientAccount(ctx, clientId);
  const [tab, setTab] = useState<'draft' | 'under_review' | 'active' | 'inactive'>(isStateManager(ctx) ? 'under_review' : cm ? 'draft' : 'active');
  const [search, setSearch] = useState('');
  const list = useAsync(async () => {
    if (!clientId) return [] as FarmerRow[];
    // migration 44: with the state farmer ID; a server before it has none to join (the list asks again without it)
    const ask = (withStateIds: boolean) => {
      let r = supabase.from('farmers').select('*,state:states(name),reviewer:app_users!farmers_reviewed_by_fkey(display_name)' + (withStateIds ? ',state_farmer:state_farmers(code)' : ''))
        .eq('client_id', clientId).eq('status', tab).order('created_at', { ascending: false }).limit(500);
      const s = search.trim();
      if (s) r = r.or(`name.ilike.%${s}%,village.ilike.%${s}%,farmer_code.ilike.%${s}%,phone.ilike.%${s}%`);
      return q(r) as unknown as Promise<FarmerRow[]>;
    };
    try { return await ask(true); } catch { return await ask(false); }
  }, [clientId, tab, search]);
  // Who adds farmers (migration 41): the client's Client Manager, or Procurement / Village Batch in its scopes. A State
  // Manager verifies after the Client Manager and adds none; a server from before 41 sends no `state_manager`: as before.
  const canEdit = me.role !== 'client_view' && !watch && (ctx?.user?.can?.state_manager === undefined || addsFarmers(ctx, clientId));
  const isSM = isStateManager(ctx) || watch;                // who sees the "inactive" tab
  return (
    <div>
      <h1><span aria-hidden="true">👨‍🌾 </span>{t('farmers.title')}</h1>
      {picker}
      {watch && <p className="small muted" data-testid="farmers-readonly">{t('farmers.admin_reads')}</p>}
      {!watch && !cm && canEdit && <p className="small muted" data-testid="farmers-draft-note">{t('farmers.drafts_only')}</p>}
      {actsAsStateManager(ctx) && <p className="small muted" data-testid="farmers-sm-note">{t('farmers.sm_verifies')}</p>}
      <div className="row" style={{ marginBottom: 12 }}>
        {canEdit && <Link className="btn" to="/farmers/new">{t('farmers.new')}</Link>}
        {canEdit && <Link className="btn secondary" to="/farmers/import">{t('farmers.import')}</Link>}
        {(actsAsStateManager(ctx) || watch) && <RegisterLink />}
        <input aria-label={t('common.search')} placeholder={t('common.search')} value={search} onChange={(e) => setSearch(e.target.value)} style={{ flex: '1 1 200px', width: 'auto' }} />
      </div>
      {cm && clientId && <ProposalsCard clientId={clientId} onDecided={() => void list.reload()} />}
      <div className="tabs" role="tablist">
        {(isSM ? ['draft', 'under_review', 'active', 'inactive'] as const : ['draft', 'under_review', 'active'] as const).map((s) => (
          <button key={s} role="tab" aria-selected={tab === s} className={tab === s ? 'active' : ''} onClick={() => setTab(s)}>
            {t(s === 'draft' ? 'farmers.tab_draft' : s === 'under_review' ? 'farmers.tab_review' : s === 'active' ? 'farmers.tab_active' : 'farmers.tab_inactive')}
          </button>
        ))}
      </div>
      {list.loading ? <Loading /> : <ErrorBox error={list.error} onRetry={list.reload} />}
      {/* the list of the client and tab now chosen only: while another loads, the one before is not shown (a click on
          it could act on the other client's farmer, 14 Oct 2026) */}
      {!list.loading && list.data && list.data.length === 0 && <Empty />}
      {!list.loading && list.data && list.data.length > 0 && (
        <div className="card table-wrap"><table>
          <thead><tr><th>{t('farmer.name')}</th><th>{t('farmer.code')}</th><th>{t('farmer.village')}</th><th className="hide-mobile">{t('farmer.phone')}</th><th className="hide-mobile">{t('farmer.land_gi')}</th><th></th></tr></thead>
          <tbody>{list.data.map((f) => (
            <tr key={f.id} data-testid="farmer-row">
              <td>{f.name}<div className="muted small">{f.guardian_name}</div>
                {typeof f.extra?.sent_back_reason === 'string' && <div className="small" style={{ color: 'var(--warn)' }}>{t('farmers.sent_back')}: {f.extra.sent_back_reason as string}</div>}</td>
              <td className="mono">{f.farmer_code ?? '—'}{f.state_farmer?.code && <div className="small muted" data-testid="farmer-state-id">{f.state_farmer.code}</div>}</td><td>{f.village}</td><td className="hide-mobile">{f.phone}</td><td className="hide-mobile num">{f.land_area_acres} · {f.gi_land_acres ?? '—'}</td>
              <td><FarmerActions farmer={f} canEdit={canEdit} onDone={list.reload} /></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}
    </div>
  );
}

/** The farmer row as the list reads it: with its state's name and the name of whoever did step 1 (when readable). */
type FarmerRow = Farmer & { state?: { name: string } | null; reviewer?: { display_name: string } | null; state_farmer?: { code: string } | null };
/** A state farmer the State Manager may link a record to at step 2 (migration 44). */
interface StateCandidate { id: string; code: string; records: { name: string; farmer_code: string | null; client: string; village: string }[] | null }

type FarmerStep = Pick<Farmer, 'client_id' | 'status' | 'state_id' | 'reviewed_by'>;
/** Pure: who may do what to this farmer now, from the server's own context. */
export function farmerRights(ctx: Ctx, f: FarmerStep) {
  const me = ctx?.user?.id;
  // farmers made before migration 34 have no state: any State Manager of a state the client works in, as before
  const sm = f.state_id ? supervisesState(ctx, f.state_id) : isStateManager(ctx);
  return {
    step1: f.status === 'draft' && holdsClientAccount(ctx, f.client_id),
    step2: f.status === 'under_review' && sm && (!f.reviewed_by || f.reviewed_by !== me),
    sameHands: f.status === 'under_review' && sm && !!f.reviewed_by && f.reviewed_by === me,
    sendBack: f.status === 'under_review' && sm,
    afterwards: (f.status === 'active' || f.status === 'inactive') && sm,
    // migration 44 (Veda, 14 Oct): the Client Manager also changes a verified farmer (with a reason)
    cmEdits: (f.status === 'under_review' || f.status === 'active') && holdsClientAccount(ctx, f.client_id),
  };
}

function FarmerActions({ farmer, canEdit, onDone }: { farmer: FarmerRow; canEdit: boolean; onDone: () => void }) {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const act = useAction();
  const [reason, setReason] = useState('');
  const [sending, setSending] = useState(false);
  const r = farmerRights(ctx, farmer);
  // migration 43: the Farmer ID needs the GI land; a server from before it sends no such field (undefined): as before
  const noGi = 'gi_land_acres' in farmer && needsGiLand(farmer);
  // migration 44: at step 2, the state farmers with this phone; Ram links to one, or says why it is another person
  const choice = useAsync(() => r.step2 ? rpc<StateCandidate[]>('state_choice', { p_farmer: farmer.id }).catch(() => [] as StateCandidate[])
    : Promise.resolve([] as StateCandidate[]), [farmer.id, r.step2]);
  const [notSame, setNotSame] = useState(false);
  const [why, setWhy] = useState('');
  const [flipping, setFlipping] = useState(false);
  const cands = choice.data ?? [];
  if (farmer.status === 'draft' && canEdit) return (
    <div className="row">
      <Link className="btn secondary" to={`/farmers/${farmer.id}`}>{t('common.edit')}</Link>
      {r.step1 ? <button onClick={() => act.run(async () => { await rpc('submit_farmer', { p_farmer: farmer.id }); onDone(); })} disabled={act.busy} data-testid="farmer-step1">{t('farmers.verify_step1')}</button>
        : <span className="small muted">{t('farmers.waits_cm')}</span>}
      <ErrorBox error={act.error} />
    </div>
  );
  if (r.step2 || r.sameHands) return (
    <div className="stack" data-testid="farmer-step2-box">
      <div className="small">
        <div>{t('farmers.location', { village: farmer.village, district: farmer.district, state: farmer.state?.name ?? '—' })}</div>
        <div className="muted">{farmer.reviewed_at ? t('farmers.step1_by', { name: farmer.reviewer?.display_name ?? t('farmers.the_cm'), at: date(farmer.reviewed_at) }) : t('farmers.step1_legacy')}</div>
      </div>
      {r.sameHands ? <div className="small" style={{ color: 'var(--warn)' }}>{t('farmers.same_hands')}</div> : (
        <div className="stack">
          {cands.map((c) => (
            <div key={c.id} className="alert warn small" data-testid="farmer-same-phone">
              <div>{t('farmers.same_phone', { code: c.code, who: (c.records ?? []).map((x) => `${x.name} (${x.client})`).join(', ') })}</div>
              <button className="small-btn" disabled={act.busy || noGi} data-testid="farmer-link"
                onClick={() => act.run(async () => { await rpc('verify_farmer_state', { p_farmer: farmer.id, p_link: c.id, p_reason: null }); onDone(); })}>
                {t('farmers.link_to', { code: c.code })}</button>
            </div>))}
          <div className="row">
            {cands.length === 0 && <button onClick={() => act.run(async () => { await rpc('verify_farmer', { p_farmer: farmer.id }); onDone(); })} disabled={act.busy || noGi} data-testid="farmer-step2">{t('farmers.verify_step2')}</button>}
            {cands.length > 0 && <button className="secondary" onClick={() => setNotSame(!notSame)} data-testid="farmer-not-same">{t('reg.not_same')}</button>}
            <button className="secondary" onClick={() => setSending(!sending)}>{t('farmers.send_back')}</button>
          </div>
          {notSame && <div className="row"><input aria-label={t('reg.why_distinct')} placeholder={t('reg.why_distinct')} value={why} maxLength={200} onChange={(e) => setWhy(e.target.value)} data-testid="farmer-not-same-why" />
            <button disabled={!why.trim() || act.busy || noGi} data-testid="farmer-new-id"
              onClick={() => act.run(async () => { await rpc('verify_farmer_state', { p_farmer: farmer.id, p_link: null, p_reason: why.trim() }); onDone(); })}>{t('farmers.new_state_id')}</button></div>}
        </div>)}
      {!r.sameHands && noGi && <div className="small" style={{ color: 'var(--warn)' }} data-testid="farmer-needs-gi">{t('farmers.needs_gi')} <Link to={`/farmers/${farmer.id}`}>{t('farmers.add_gi')}</Link></div>}
      {sending && <div className="row"><input aria-label={t('farmers.send_back_reason')} placeholder={t('farmers.send_back_reason')} value={reason} onChange={(e) => setReason(e.target.value)} />
        <button className="secondary" disabled={!reason.trim() || act.busy} onClick={() => act.run(async () => { await rpc('send_back_farmer', { p_farmer: farmer.id, p_reason: reason }); onDone(); })}>{t('farmers.send_back')}</button></div>}
      <ErrorBox error={act.error} />
    </div>
  );
  if (farmer.status === 'under_review') return (
    <div className="stack"><span className="small muted">{t('farmers.waits_sm', { state: farmer.state?.name ?? '—' })}</span>
      {r.cmEdits && <Link className="btn secondary" to={`/farmers/${farmer.id}`}>{t('common.edit')}</Link>}
      {!r.cmEdits && canEdit && <Link className="btn secondary" to={`/farmers/${farmer.id}/practice`} data-testid="farmer-practice-link">{t('fp.open')}</Link>}</div>);
  // After verification the State Manager (and, migration 44, the Client Manager) changes a farmer, each time with a
  // reason; every change is a ledger block (migration 22). Activating and deactivating stay the State Manager's.
  if (r.afterwards) {
    const flip = farmer.status === 'active' ? 'inactive' : 'active';
    return (
      <div className="stack">
        <div className="row">
          <Link className="btn secondary" to={`/farmers/${farmer.id}`}>{t('common.edit')}</Link>
          <button className="secondary" disabled={act.busy} data-testid={`farmer-${flip}`} onClick={() => setFlipping(!flipping)}>
            {t(flip === 'inactive' ? 'farmers.deactivate' : 'farmers.reactivate')}</button>
        </div>
        {flipping && <div className="row"><input aria-label={t('farmers.why_change')} placeholder={t('farmers.why_change')} value={why} maxLength={200} onChange={(e) => setWhy(e.target.value)} data-testid="farmer-flip-why" />
          <button disabled={!why.trim() || act.busy} data-testid={`farmer-${flip}-confirm`}
            onClick={() => act.run(async () => { await rpc('change_farmer', { p_farmer: farmer.id, p: { status: flip }, p_reason: why.trim() }); onDone(); })}>
            {t(flip === 'inactive' ? 'farmers.deactivate' : 'farmers.reactivate')}</button></div>}
        <ErrorBox error={act.error} />
      </div>
    );
  }
  if (r.cmEdits) return <Link className="btn secondary" to={`/farmers/${farmer.id}`}>{t('common.edit')}</Link>;
  // migration 47 (Veda, 14 Oct): Procurement answers good farming practice, and proposes other corrections to the Client Manager
  if (canEdit && farmer.status === 'active')
    return <Link className="btn secondary" to={`/farmers/${farmer.id}/practice`} data-testid="farmer-practice-link">{t('fp.open')}</Link>;
  return <span className="muted small">{farmer.status === 'active' ? <Badge value="active" /> : date(farmer.created_at)}</span>;
}

export function FarmerForm() {
  const { id } = useParams();
  const { t } = useI18n();
  const nav = useNavigate();
  const { ctx } = useAuth();
  const { clientId: chosenClient, picker } = useClientChoice();
  const [f, setF] = useState({ name: '', guardian_name: '', village: '', district: '', phone: '', land_area_acres: '', gi_land_acres: '', photo_consent: false, public_id_consent: false, notes: '' });
  const [code, setCode] = useState<string | null>(null);          // the client farmer ID: from then on, a change says why (migration 44)
  const [hasIds, setHasIds] = useState(false);                     // false: a server from before migration 44
  const [why, setWhy] = useState('');
  const [tick, setTick] = useState(0);
  const [status, setStatus] = useState<Farmer['status']>('draft');
  const [ownClient, setOwnClient] = useState<string | null>(null);      // an existing farmer's client
  const [stateId, setStateId] = useState('');
  const clientId = ownClient ?? chosenClient;
  const watch = oversees(ctx);
  const cm = holdsClientAccount(ctx, clientId);
  // The states the client works in (its home state and its scopes' states): a farmer belongs to one of them.
  const states = useAsync(async () => {
    if (!clientId) return [] as { id: string; name: string }[];
    const c = await q(supabase.from('clients').select('state_id,states(id,name)').eq('id', clientId).maybeSingle()) as unknown as { state_id: string; states: { id: string; name: string } | null } | null;
    const sc = await q(supabase.from('scopes').select('states(id,name)').eq('client_id', clientId)) as unknown as { states: { id: string; name: string } | null }[];
    const all = [c?.states, ...sc.map((x) => x.states)].filter((x): x is { id: string; name: string } => !!x);
    return [...new Map(all.map((x) => [x.id, x])).values()];
  }, [clientId]);
  useEffect(() => { if (!id && !stateId && states.data?.length) setStateId(states.data[0].id); }, [id, stateId, states.data]);
  const [extra, setExtra] = useState<Record<string, unknown>>({});
  const [hasGi, setHasGi] = useState(true);                          // false: a server from before migration 43
  const giProblem = giLandProblem(f.gi_land_acres, f.land_area_acres);     // everything else kept in farmers.extra (import columns, photo)
  const act = useAction();
  useEffect(() => {
    if (!id) return;
    let gone = false;          // a second load (React's development double run) must not overwrite what was typed meanwhile
    q(supabase.from('farmers').select('*').eq('id', id).single()).then((r) => {
      if (gone) return;
      const x = r as unknown as Farmer;
      setStatus(x.status);
      setCode(x.farmer_code);
      setHasIds('public_id_consent' in x);
      setOwnClient(x.client_id);
      setStateId(x.state_id ?? '');
      setExtra(x.extra ?? {});
      setF({ name: x.name, guardian_name: x.guardian_name, village: x.village, district: x.district, phone: x.phone,
        land_area_acres: String(x.land_area_acres), gi_land_acres: x.gi_land_acres == null ? '' : String(x.gi_land_acres),
        photo_consent: x.photo_consent, public_id_consent: !!x.public_id_consent, notes: String(x.extra?.notes ?? '') });
      setHasGi('gi_land_acres' in x);
    });
    return () => { gone = true; };
  }, [id]);
  const set = (k: keyof typeof f) => (e: { target: { value: string; checked?: boolean; type?: string } }) =>
    setF((s) => ({ ...s, [k]: e.target.type === 'checkbox' ? !!e.target.checked : e.target.value }));
  const submit = (e: FormEvent, andSubmit: boolean) => { e.preventDefault(); void act.run(async () => {
    const digits = f.phone.replace(/[^0-9]/g, '');
    const phone = digits.length === 10 ? `+91${digits}` : f.phone;
    const row = { name: f.name.trim(), guardian_name: f.guardian_name.trim(), village: f.village.trim(), district: f.district.trim(), phone,
      land_area_acres: Number(f.land_area_acres), photo_consent: f.photo_consent,
      ...(hasGi ? { gi_land_acres: f.gi_land_acres.trim() ? Number(f.gi_land_acres.trim().replace(',', '.')) : null } : {}),
      ...(status === 'draft' && stateId ? { state_id: stateId } : {}), extra: (() => { const e = { ...extra }; if (f.notes) e.notes = f.notes; else delete e.notes; return e; })() };
    // migration 44: a farmer with a Farmer ID changes through the server's change, with the reason (kept in the ledger)
    const withReason = !!id && !!code && hasIds;
    const saved = withReason
      ? await rpc<Farmer>('change_farmer', { p_farmer: id, p_reason: why.trim(), p: { name: row.name, guardian_name: row.guardian_name, village: row.village,
          district: row.district, phone: row.phone, land_area_acres: String(row.land_area_acres), gi_land_acres: f.gi_land_acres.trim().replace(',', '.'),
          photo_consent: row.photo_consent, public_id_consent: f.public_id_consent, notes: f.notes } })
      : id
      ? await q(supabase.from('farmers').update({ ...row, ...(hasIds ? { public_id_consent: f.public_id_consent } : {}) }).eq('id', id).select().single()) as Farmer
      : await q(supabase.from('farmers').insert({ ...row, ...(hasIds ? { public_id_consent: f.public_id_consent } : {}), client_id: clientId, status: 'draft' }).select().single()) as Farmer;
    if (andSubmit) await rpc('submit_farmer', { p_farmer: saved.id });
    nav('/farmers');
  }); };
  const needReason = !!id && !!code && hasIds && !watch;
  const input = (k: keyof typeof f, label: string, extra: Record<string, unknown> = {}) => (
    <Field label={`${label} *`} htmlFor={`farmer-${k}`}><input id={`farmer-${k}`} value={f[k] as string} onChange={set(k)} required {...extra} /></Field>
  );
  return (
    <div className="card" style={{ maxWidth: 560 }}>
      <h1>{id ? t('common.edit') : t('farmers.new')}</h1>
      {id && hasIds && <FarmerIds farmerId={id} tick={tick} />}
      {!id && picker}
      {watch && <div className="alert info" data-testid="farmers-readonly">{t('farmers.admin_reads')}</div>}
      {status !== 'draft' && <div className="alert info" data-testid="farmer-verified-note">{t(farmerNote(status))}</div>}
      {status === 'draft' && !cm && !watch && <p className="small muted" data-testid="farmers-draft-note">{t('farmers.drafts_only')}</p>}
      <form onSubmit={(e) => submit(e, false)}>
        {input('name', t('farmer.name'))}
        {input('guardian_name', t('farmer.guardian'))}
        {input('village', t('farmer.village'))}
        {input('district', t('farmer.district'))}
        {(states.data?.length ?? 0) > 0 && (
          <Field label={`${t('farmer.state')} *`} hint={t('farmer.state_hint')} htmlFor="farmer-state">
            <select id="farmer-state" value={stateId} onChange={(e) => setStateId(e.target.value)} disabled={status !== 'draft'} data-testid="farmer-state">
              {states.data!.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
            </select>
          </Field>)}
        {input('phone', t('farmer.mobile'), { type: 'tel', inputMode: 'tel' })}
        {input('land_area_acres', t('farmer.land'), { inputMode: 'decimal' })}
        {hasGi && (
          <Field label={t('farmer.gi_land')} hint={t('farmer.gi_land_hint')} htmlFor="farmer-gi_land_acres">
            <input id="farmer-gi_land_acres" value={f.gi_land_acres} onChange={set('gi_land_acres')} inputMode="decimal" data-testid="farmer-gi-land" />
            {giProblem && <div className="small" style={{ color: 'var(--red)' }} data-testid="farmer-gi-problem">{t(`farmer.${giProblem}`)}</div>}
          </Field>)}
        <details><summary>{t('farmer.optional')}</summary>
          <Field label={t('farmer.notes')} htmlFor="farmer-notes"><textarea id="farmer-notes" value={f.notes} onChange={set('notes')} rows={2} /></Field>
        </details>
        <label className="check"><input type="checkbox" checked={f.photo_consent} onChange={set('photo_consent')} />{t('farmers.consent')}</label>
        {hasIds && <label className="check"><input type="checkbox" checked={f.public_id_consent} onChange={set('public_id_consent')} data-testid="farmer-id-consent" />{t('farmers.id_consent')}</label>}
        {needReason && <Field label={`${t('farmers.why_change')} *`} hint={t('farmers.why_hint')} htmlFor="farmer-why">
          <input id="farmer-why" value={why} maxLength={200} onChange={(e) => setWhy(e.target.value)} data-testid="farmer-why" /></Field>}
        <ErrorBox error={act.error} />
        {!watch && (
          <div className="row">
            <button type="submit" className="secondary" disabled={act.busy || !!giProblem || (needReason && !why.trim())}>{t(status === 'draft' ? 'farmers.save_draft' : 'common.save')}</button>
            {status === 'draft' && cm && <button type="button" disabled={act.busy || !!giProblem || (needReason && !why.trim())} onClick={(e) => submit(e as unknown as FormEvent, true)} data-testid="farmer-save-verify">{t('farmers.save_verify')}</button>}
          </div>)}
      </form>
      {id && clientId && <FarmerGap farmerId={id} clientId={clientId} stateId={stateId} />}
      {id && hasIds && <FarmerHistory farmerId={id} tick={tick} onAccepted={() => setTick(tick + 1)} />}
    </div>
  );
}

/** Good farming practice for each crop of the farmer's state (migration 42, Veda 13 Oct 2026): answered by those who add
 *  the client's farmers (its Client Manager, Procurement); a REQUIRED practice not answered refuses the farmer's lot at
 *  Procurement, an optional one is a warning on the lot. Everyone else who reads the farmer reads the answers. */
export function FarmerGap({ farmerId, clientId, stateId }: { farmerId: string; clientId: string; stateId: string }) {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const canEdit = addsFarmers(ctx, clientId);
  const crops = useAsync(async () => (await q(supabase.from('crops').select('id,name,code,state_id,gap_items,retired_at').order('name')) as unknown as
    { id: string; name: string; code: string; state_id: string | null; gap_items?: GapItem[]; retired_at?: string | null }[])
    .filter((c) => (c.gap_items?.length ?? 0) > 0 && !c.retired_at && (!c.state_id || !stateId || c.state_id === stateId)), [stateId]);
  const saved = useAsync(() => q(supabase.from('farmer_gap').select('crop_id,answers,updated_at').eq('farmer_id', farmerId)) as Promise<{ crop_id: string; answers: Record<string, unknown>; updated_at: string }[]>, [farmerId]);
  const [cropId, setCropId] = useState('');
  const [answers, setAnswers] = useState<Record<string, unknown>>({});
  const act = useAction();
  const crop = crops.data?.find((c) => c.id === (cropId || crops.data?.[0]?.id));
  useEffect(() => { setAnswers(saved.data?.find((x) => x.crop_id === crop?.id)?.answers ?? {}); }, [crop?.id, saved.data]);
  if (crops.loading || saved.loading) return null;
  if (!crops.data?.length) return null;
  const items = crop?.gap_items ?? [];
  const open = gapMissing(items, answers);
  // only the practices the crop lists now: an answer to a practice the State Manager took off the list is not sent back
  const save = () => act.run(async () => {
    const now = Object.fromEntries(Object.entries(answers).filter(([k]) => items.some((g) => g.key === k)));
    await rpc('save_farmer_gap', { p_farmer: farmerId, p_crop: crop!.id, p_answers: now }); await saved.reload();
  });
  const box = (g: GapItem) => {
    const v = answers[g.key];
    const setV = (x: unknown) => setAnswers({ ...answers, [g.key]: x });
    const idf = `gap-${g.key}`;
    if (g.type === 'yesno') return <select id={idf} value={v === true ? 'yes' : v === false ? 'no' : ''} disabled={!canEdit} onChange={(e) => setV(e.target.value === '' ? '' : e.target.value === 'yes')}>
      <option value="">—</option><option value="yes">{t('common.yes')}</option><option value="no">{t('common.no')}</option></select>;
    if (g.type === 'choice') return <select id={idf} value={String(v ?? '')} disabled={!canEdit} onChange={(e) => setV(e.target.value)}>
      <option value="">—</option>{(g.options ?? []).map((o) => <option key={o} value={o}>{t(`opt.${o}`, undefined, o.replace(/_/g, ' '))}</option>)}</select>;
    if (g.type === 'date') return <input id={idf} type="date" value={String(v ?? '')} disabled={!canEdit} onChange={(e) => setV(e.target.value)} />;
    if (g.type === 'number') return <input id={idf} inputMode="decimal" value={String(v ?? '')} disabled={!canEdit} onChange={(e) => setV(e.target.value.replace(',', '.'))} />;
    return <input id={idf} value={String(v ?? '')} maxLength={200} disabled={!canEdit} onChange={(e) => setV(e.target.value)} />;
  };
  return (
    <div className="stack" data-testid="farmer-gap">
      <h2>{t('gap.title')}</h2>
      <p className="small muted">{t('gap.sub')}</p>
      {crops.data.length > 1 && <Field label={t('gap.crop')} htmlFor="gap-crop"><select id="gap-crop" value={crop?.id ?? ''} onChange={(e) => setCropId(e.target.value)}>
        {crops.data.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>}
      {crops.data.length === 1 && <p className="small"><strong>{crop?.name}</strong></p>}
      {items.map((g) => <Field key={g.key} label={`${g.label}${g.required ? ' *' : ''}`} htmlFor={`gap-${g.key}`}>{box(g)}</Field>)}
      {open.required.length > 0 && <div className="alert warn" data-testid="gap-open-required">{t('gap.required_open', { what: open.required.join(', ') })}</div>}
      {open.required.length === 0 && open.optional.length > 0 && <div className="alert info small" data-testid="gap-open-optional">{t('gap.optional_open', { what: open.optional.join(', ') })}</div>}
      {open.required.length === 0 && open.optional.length === 0 && <div className="alert ok small" data-testid="gap-complete">{t('gap.complete')}</div>}
      <ErrorBox error={act.error} />
      {canEdit && <button className="secondary" onClick={save} disabled={act.busy} data-testid="gap-save">{t('gap.save')}</button>}
    </div>
  );
}

/** The farmer's history (migration 44, E3): who drafted, who verified (Client Manager, then State Manager), every later change. */
interface FarmerHistoryData {
  farmer_code: string | null; state_farmer_code: string | null;
  drafted: { by: string | null; at: string; role: string | null };
  client_verified: { by: string | null; at: string } | null; state_verified: { by: string | null; at: string } | null;
  events: { seq: number; at: string; kind: string; by: string | null; role: string | null; before: Record<string, unknown> | null;
    after: Record<string, unknown> | null; reason: string | null; farmer_code: string | null; state_farmer_code: string | null; linked: boolean | null;
    /** migration 48: a lot of the farmer (its number, stage, quantity) and good farming practice answered (the crop) */
    record?: string | null; stage?: string | null; qty?: number | null; crop?: string | null }[];
  open_changes: { id: string; field: string; before: string | null; after: string | null; reason: string | null; by: string | null; at: string }[];
  can_accept: boolean;
}
const useHistory = (farmerId: string, tick: number) =>
  useAsync(() => rpc<FarmerHistoryData>('farmer_history', { p_farmer: farmerId }).catch(() => null), [farmerId, tick]);

function FarmerIds({ farmerId, tick }: { farmerId: string; tick: number }) {
  const { t } = useI18n();
  const h = useHistory(farmerId, tick);
  if (!h.data) return null;
  return (
    <p className="small" data-testid="farmer-ids">
      <span>{t('farmers.client_id')}: <strong className="mono" data-testid="farmer-client-id">{h.data.farmer_code ?? '—'}</strong></span>
      {' · '}<span>{t('farmers.state_id')}: <strong className="mono" data-testid="farmer-state-id">{h.data.state_farmer_code ?? '—'}</strong></span>
    </p>);
}

/** Pure: one history line's words, from the block's kind (the farmer's ledger). */
export function historyLine(e: FarmerHistoryData['events'][number], t: (k: string, v?: Record<string, string | number>, f?: string) => string): string {
  const fields = (o: Record<string, unknown> | null) => Object.keys(o ?? {}).map((k) => t(`farmer.f_${k}`, undefined, k.replace(/_/g, ' '))).join(', ');
  switch (e.kind) {
    case 'farmer_verified_client': return t('fh.client', { code: e.farmer_code ?? '—' });
    case 'farmer_verified_state': return t(e.linked ? 'fh.state_linked' : 'fh.state_new', { code: e.state_farmer_code ?? '—' });
    case 'state_farmer_id_given': return t('fh.state_given', { code: e.state_farmer_code ?? '—' });
    case 'farmer_verified': return t('fh.verified_old', { code: e.farmer_code ?? '—' });
    case 'farmer_changed': return t('fh.changed', { what: fields(e.after) });
    // migration 48 (Veda, 15 Oct: the blank line): practice answered, and the farmer's lots
    case 'practice_saved': return t('fh.practice', { crop: e.crop ?? '—' });
    case 'lot_create': case 'lot_supervisory': case 'lot_verify': case 'lot_supersede': case 'lot_close':
      return t(`fh.${e.kind}`, { code: e.record ?? '—', stage: e.stage ? t(`stage.${e.stage}`, undefined, humanise(e.stage)) : '—', kg: kg(e.qty ?? null) });
    default: return e.kind ? t(`fh.${e.kind}`, { code: e.record ?? '—' }, humanise(e.kind)) : t('fh.other');
  }
}

function FarmerHistory({ farmerId, tick, onAccepted }: { farmerId: string; tick: number; onAccepted: () => void }) {
  const { t } = useI18n();
  const h = useHistory(farmerId, tick);
  const act = useAction();
  const role = (r: string | null) => (r ? t(`wrole.${r}`, undefined, r) : '');
  if (!h.data) return null;
  const x = h.data;
  return (
    <div className="stack" data-testid="farmer-history">
      <h2>{t('fh.title')}</h2>
      <ul className="ov-list">
        <li>{t('fh.drafted', { name: x.drafted.by ?? '—', at: dateTime(x.drafted.at) })}{x.drafted.role && <span className="muted small"> ({role(x.drafted.role)})</span>}</li>
        {x.events.map((e) => (
          <li key={e.seq} data-testid="fh-event">{historyLine(e, t)} · {e.by ?? '—'}{e.role && <span className="muted small"> ({role(e.role)})</span>}
            <span className="muted small"> · {dateTime(e.at)}</span>
            {e.reason && <div className="small">{t('fh.reason', { reason: e.reason })}</div>}</li>))}
      </ul>
      {x.open_changes.length > 0 && (
        <div className="alert warn small" data-testid="fh-open-changes">
          <strong>{t('fh.open_changes')}</strong>
          <ul>{x.open_changes.map((c) => (
            <li key={c.id}>{t('fh.change_line', { field: t(`farmer.f_${c.field}`, undefined, c.field), before: c.before ?? '—', after: c.after ?? '—', by: c.by ?? '—' })}
              {c.reason && <> · {c.reason}</>}
              {x.can_accept && <> <button className="secondary small-btn" disabled={act.busy} data-testid="fh-accept"
                onClick={() => act.run(async () => { await rpc('accept_farmer_change', { p_flag: c.id }); onAccepted(); })}>{t('fh.accept')}</button></>}</li>))}</ul>
          <ErrorBox error={act.error} />
        </div>)}
    </div>);
}
