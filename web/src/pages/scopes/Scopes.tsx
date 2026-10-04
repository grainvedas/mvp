// S7 scope list · S8 scope wizard (season + place → crop → chain with live problems → people) · scope view
import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { rpc, q, callFunction } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { humanise } from '../../lib/format';
import { isManager, type StageDefinition, type StageType } from '../../lib/types';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';

interface ScopeRow { id: string; client_id: string; crop_id: string; season_code: string; geography: string; chain: StageType[]; status: string; activated_at: string | null }
interface Crop { id: string; name: string; code: string; allowed_stages: StageType[] }
interface Client { id: string; name: string; code: string }

export function ScopeList() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  return (
    <div>
      <h1><span aria-hidden="true">🎯 </span>{t('scopes.title')}</h1>
      {isManager(ctx!.user!.role) && <p><Link className="btn" to="/scopes/new">{t('scopes.new')}</Link></p>}
      {ctx!.scopes.length === 0 ? <Empty /> : (
        <div className="card table-wrap"><table>
          <thead><tr><th>Client</th><th>Crop</th><th>Season</th><th>Place</th><th>Chain</th><th>{t('common.status')}</th></tr></thead>
          <tbody>{ctx!.scopes.map((s) => (
            <tr key={s.scope_id}><td>{s.client_name}</td><td>{s.crop_name}</td><td>{s.season_code}</td>
              <td><Link to={`/scopes/${s.scope_id}`}>{s.geography}</Link></td>
              <td className="small">{s.chain.map((x) => t(`stage.${x}`, undefined, humanise(x))).join(' → ')}</td><td><Badge value={s.status} /></td></tr>
          ))}</tbody>
        </table></div>
      )}
    </div>
  );
}

/** Builds the ordered chain from the builder's choices. Exported for tests. */
export function assembleChain(o: { entry: StageType; villageBatch: boolean; before: StageType[]; after: StageType[]; commercial: boolean; shipment: boolean }): StageType[] {
  return [o.entry, ...(o.villageBatch && o.entry === 'procurement' ? ['village_batch' as StageType] : []), ...o.before, 'qc',
    ...o.after, ...(o.commercial ? ['commercial' as StageType] : []), ...(o.shipment ? ['shipment' as StageType] : []), 'qr_activation'];
}

export function ScopeWizard() {
  const { id } = useParams();
  const [search] = useSearchParams();
  const { t } = useI18n();
  const { ctx, refresh } = useAuth();
  const nav = useNavigate();
  const me = ctx!.user!;
  const clients = useAsync(() => q(supabase.from('clients').select('id,name,code').order('name')) as Promise<Client[]>, []);
  const crops = useAsync(() => q(supabase.from('crops').select('id,name,code,allowed_stages').order('name')) as Promise<Crop[]>, []);
  const defs = useAsync(() => q(supabase.from('stage_definitions').select('*').order('sort_order')) as Promise<StageDefinition[]>, []);
  const existing = useAsync(() => id ? q(supabase.from('scopes').select('*').eq('id', id).single()) as Promise<ScopeRow> : Promise.resolve(null), [id]);
  const [step, setStep] = useState(1);
  const [clientId, setClientId] = useState(me.client_id ?? '');
  const [season, setSeason] = useState('KH26');
  const [geo, setGeo] = useState('');
  const [cropId, setCropId] = useState('');
  const [entry, setEntry] = useState<StageType>('procurement');
  const [villageBatch, setVillageBatch] = useState(false);
  const [before, setBefore] = useState<StageType[]>([]);
  const [after, setAfter] = useState<StageType[]>([]);
  const [commercial, setCommercial] = useState(false);
  const [shipment, setShipment] = useState(false);
  const [problems, setProblems] = useState<string[] | null>(null);
  const act = useAction();

  useEffect(() => {
    const s = existing.data;
    if (!s) return;
    setClientId(s.client_id); setSeason(s.season_code); setGeo(s.geography); setCropId(s.crop_id);
    const c = s.chain, qi = c.indexOf('qc');
    setEntry(c[0]); setVillageBatch(c.includes('village_batch'));
    const proc = (x: StageType) => defs.data?.find((d) => d.stage_type === x)?.is_processing;
    setBefore(c.slice(1, qi).filter(proc)); setAfter(c.slice(qi + 1).filter(proc));
    setCommercial(c.includes('commercial')); setShipment(c.includes('shipment'));
    setStep(s.status === 'draft' && search.get('step') !== 'people' ? 3 : 4);
  }, [existing.data, defs.data, search]);

  const chain = useMemo(() => assembleChain({ entry, villageBatch, before, after, commercial, shipment }), [entry, villageBatch, before, after, commercial, shipment]);
  useEffect(() => {
    if (!cropId) return;
    const h = setTimeout(() => { void rpc<string[]>('check_chain', { p_chain: chain, p_crop: cropId }).then(setProblems).catch(() => setProblems(null)); }, 250);
    return () => clearTimeout(h);
  }, [chain, cropId]);

  if (clients.loading || crops.loading || defs.loading || existing.loading) return <Loading />;
  const s = existing.data;
  const frozen = !!s && s.status !== 'draft';
  const crop = crops.data?.find((c) => c.id === cropId);
  const processing = (defs.data ?? []).filter((d) => d.is_processing && crop?.allowed_stages.includes(d.stage_type));
  const label = (x: StageType) => defs.data?.find((d) => d.stage_type === x)?.label ?? humanise(x);
  const toggle = (list: StageType[], set: (v: StageType[]) => void, other: StageType[], setOther: (v: StageType[]) => void, x: StageType) => {
    if (list.includes(x)) set(list.filter((y) => y !== x)); else { set([...list, x]); setOther(other.filter((y) => y !== x)); }
  };

  const saveDraft = () => act.run(async () => {
    const row = { client_id: clientId, crop_id: cropId, season_code: season.trim().toUpperCase(), geography: geo.trim(), chain };
    const saved = s ? await q(supabase.from('scopes').update(row).eq('id', s.id).select().single()) as ScopeRow
                    : await q(supabase.from('scopes').insert({ ...row, status: 'draft' }).select().single()) as ScopeRow;
    await refresh();
    if (!s) nav(`/scopes/${saved.id}?step=people`, { replace: true }); else existing.setData(saved);
    setStep(4);
  });
  const activate = () => act.run(async () => {
    if (!window.confirm(t('wizard.activate_warning'))) return;
    const saved = await q(supabase.from('scopes').update({ status: 'active' }).eq('id', s!.id).select().single()) as ScopeRow;
    existing.setData(saved); await refresh();
  });

  return (
    <div>
      <p className="small"><Link to="/scopes">{t('scopes.title')}</Link></p>
      <h1>{s ? `${crop?.name ?? ''} · ${s.season_code} · ${s.geography}` : t('scopes.new')} {s && <Badge value={s.status} />}</h1>
      <ol className="stepper">{[1, 2, 3, 4].map((n) => <li key={n} className={n < step ? 'done' : n === step ? 'current' : ''}>{n} {t(`wizard.step${n}`)}</li>)}</ol>
      {frozen && <div className="alert info">{t('wizard.activate_warning')}</div>}

      {step === 1 && !frozen && (
        <div className="card">
          {!me.client_id && <Field label="Client" htmlFor="wz-client"><select id="wz-client" value={clientId} onChange={(e) => setClientId(e.target.value)}>
            <option value="">—</option>{(clients.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>}
          <Field label="Season code" hint="two letters + year, e.g. KH26 for Kharif 2026" htmlFor="wz-season">
            <input id="wz-season" value={season} onChange={(e) => setSeason(e.target.value.toUpperCase())} maxLength={4} /></Field>
          <Field label="Geography" hint="district, block or mandi" htmlFor="wz-geo"><input id="wz-geo" value={geo} onChange={(e) => setGeo(e.target.value)} /></Field>
          <button disabled={!clientId || !/^[A-Z]{2}[0-9]{2}$/.test(season) || !geo.trim()} onClick={() => setStep(2)}>{t('common.next')}</button>
        </div>
      )}
      {step === 2 && !frozen && (
        <div className="card">
          <Field label="Crop" htmlFor="wz-crop"><select id="wz-crop" value={cropId} onChange={(e) => { setCropId(e.target.value); setBefore([]); setAfter([]); }}>
            <option value="">—</option>{(crops.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>
          <div className="row"><button className="secondary" onClick={() => setStep(1)}>{t('common.back')}</button><button disabled={!cropId} onClick={() => setStep(3)}>{t('common.next')}</button></div>
        </div>
      )}
      {step === 3 && !frozen && (
        <div className="card">
          <h3>Entry</h3>
          {(['procurement', 'lot_inward'] as StageType[]).map((x) => (
            <label key={x} className="check"><input type="radio" name="entry" checked={entry === x} onChange={() => setEntry(x)} />{label(x)}</label>))}
          {entry === 'procurement' && <label className="check"><input type="checkbox" checked={villageBatch} onChange={(e) => setVillageBatch(e.target.checked)} />{label('village_batch')}</label>}
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
          {problems && problems.length > 0 && <div className="alert error" data-testid="chain-problems">{t('wizard.problems')}<ul>{problems.map((p) => <li key={p}>{p}</li>)}</ul></div>}
          {problems && problems.length === 0 && <div className="alert ok">{t('wizard.ok')}</div>}
          <ErrorBox error={act.error} />
          <div className="row">{!s && <button className="secondary" onClick={() => setStep(2)}>{t('common.back')}</button>}
            <button onClick={saveDraft} disabled={act.busy || !problems || problems.length > 0}>{t('wizard.save_draft')} → {t('wizard.step4')}</button></div>
        </div>
      )}
      {step === 4 && s && (
        <div className="card">
          <div className="alert info"><strong>Chain:</strong> {s.chain.map(label).join(' → ')}</div>
          <SlotAssigner scope={s} label={label} canManage={isManager(me.role)} />
          <ErrorBox error={act.error} />
          {s.status === 'draft' && isManager(me.role) && <div className="row"><button className="secondary" onClick={() => setStep(3)}>{t('common.back')}</button>
            <button className="gold" onClick={activate} disabled={act.busy}>{t('wizard.activate')}</button></div>}
          {s.status !== 'draft' && <p className="small"><Link to="/">{t('nav.home')}</Link></p>}
        </div>
      )}
    </div>
  );
}

interface UserRow { id: string; display_name: string; role: string; phone: string | null; client_id: string | null; active: boolean }
interface SlotRow { id: string; user_id: string; stage_type: StageType }

/**
 * Who holds each stage. Only a manager of the client may change it (the database decides); anyone else who can open the
 * scope, a client viewer for one, sees the names and no controls. Before, the controls were drawn for everyone.
 * Laid out as a grid so that it folds to one column on a phone; the table roles keep it a table for a screen reader
 * (and for the tests, which find a stage by its row).
 */
function SlotAssigner({ scope, label, canManage }: { scope: ScopeRow; label: (x: StageType) => string; canManage: boolean }) {
  const { t } = useI18n();
  // every operator of the client, active or not: a deactivated person still holding a stage must be shown by name
  const users = useAsync(() => q(supabase.from('app_users').select('id,display_name,role,phone,client_id,active')
    .eq('client_id', scope.client_id).eq('role', 'operator').order('display_name')) as Promise<UserRow[]>, [scope.client_id]);
  const slots = useAsync(() => q(supabase.from('slot_assignments').select('id,user_id,stage_type').eq('scope_id', scope.id)) as Promise<SlotRow[]>, [scope.id]);
  const act = useAction();
  const [newUser, setNewUser] = useState<{ stage: StageType; name: string; phone: string } | null>(null);
  const [created, setCreated] = useState<string | null>(null);
  if (users.loading || slots.loading) return <Loading />;
  const assign = (stage: StageType, userId: string) => act.run(async () => {
    await q(supabase.from('slot_assignments').insert({ user_id: userId, scope_id: scope.id, stage_type: stage }).select()); await slots.reload();
  });
  // Taking a stage away from a person (migration 25). On an active scope the database writes it to the ledger.
  const remove = (slot: SlotRow, name: string) => act.run(async () => {
    if (!window.confirm(t('wizard.remove_confirm', { name, stage: label(slot.stage_type) }))) return;
    const gone = await q(supabase.from('slot_assignments').delete().eq('id', slot.id).select()) as SlotRow[];
    if (gone.length === 0) throw new Error(t('wizard.remove_refused'));
    await slots.reload();
  });
  const create = () => act.run(async () => {
    const r = await callFunction<{ temporary_password: string; sign_in: string }>('create-user', {
      role: 'operator', display_name: newUser!.name, phone: newUser!.phone, client_id: scope.client_id,
      slot: { scope_id: scope.id, stage_type: newUser!.stage } });
    setCreated(t('users.temp_password', { who: r.sign_in, pw: r.temporary_password }));
    setNewUser(null); await users.reload(); await slots.reload();
  });
  return (
    <div>
      <h3>{t('wizard.step4')}</h3>
      {created && <div className="alert ok" data-testid="temp-password">{created}</div>}
      <div className="slots" role="table" aria-label={t('wizard.step4')} data-testid="slots">{scope.chain.map((stage) => {
        const assigned = (slots.data ?? []).filter((x) => x.stage_type === stage);
        return (
          <div className="slot" role="row" key={stage}><div role="cell"><strong>{label(stage)}</strong></div>
            <div role="cell">{assigned.length === 0 && <span className="muted">{t('wizard.nobody')}</span>}
              {assigned.map((a) => {
                const u = users.data?.find((x) => x.id === a.user_id);
                const name = u?.display_name ?? 'manager';
                return (
                  <div key={a.id} className="row" data-testid={`slot-holder-${stage}`}>
                    <span>{name}{u && !u.active && <> <Badge value="closed" label={t('wizard.inactive')} /></>}</span>
                    {canManage && <button className="secondary small-btn" aria-label={`${t('wizard.remove')}: ${name} · ${label(stage)}`} onClick={() => void remove(a, name)}>{t('wizard.remove')}</button>}
                  </div>
                );
              })}</div>
            {canManage && <div className="row slot-controls" role="cell">
              <select aria-label={`Assign ${label(stage)}`} defaultValue="" onChange={(e) => { if (e.target.value) void assign(stage, e.target.value); e.target.value = ''; }}>
                <option value="">Assign existing…</option>
                {(users.data ?? []).filter((u) => u.active && !assigned.some((a) => a.user_id === u.id)).map((u) => <option key={u.id} value={u.id}>{u.display_name}</option>)}
              </select>
              <button className="secondary" onClick={() => setNewUser({ stage, name: '', phone: '' })}>+ new person</button>
            </div>}</div>
        );
      })}</div>
      {newUser && (
        <div className="card">
          <h3>New operator for {label(newUser.stage)}</h3>
          <Field label="Name" htmlFor="nu-name"><input id="nu-name" value={newUser.name} onChange={(e) => setNewUser({ ...newUser, name: e.target.value })} /></Field>
          <Field label="Mobile" htmlFor="nu-phone"><input id="nu-phone" type="tel" value={newUser.phone} onChange={(e) => setNewUser({ ...newUser, phone: e.target.value })} /></Field>
          <div className="row"><button className="secondary" onClick={() => setNewUser(null)}>{t('common.cancel')}</button>
            <button onClick={create} disabled={act.busy || !newUser.name.trim() || !newUser.phone.trim()}>{t('common.create')}</button></div>
        </div>
      )}
      <ErrorBox error={act.error} />
    </div>
  );
}
