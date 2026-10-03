// S3 states · S4 clients · S5 users · S6 crop registry · open flags
import { useEffect, useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { q, callFunction } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { dateTime, humanise } from '../../lib/format';
import { ROLE_RANK, type QualityParam, type Role, type StageDefinition, type StageType } from '../../lib/types';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';

interface State { id: string; name: string; code: string }
interface Client { id: string; name: string; code: string; type: string; state_id: string }

export function States() {
  const { t } = useI18n();
  const list = useAsync(() => q(supabase.from('states').select('*').order('name')) as Promise<State[]>, []);
  const [name, setName] = useState(''); const [code, setCode] = useState('');
  const act = useAction();
  const add = (e: FormEvent) => { e.preventDefault(); void act.run(async () => { await q(supabase.from('states').insert({ name, code: code.toUpperCase() }).select()); setName(''); setCode(''); await list.reload(); }); };
  return (
    <div><h1>{t('states.title')}</h1>
      <div className="card">{list.loading ? <Loading /> : <ul>{list.data?.map((s) => <li key={s.id}>{s.name} <span className="mono">{s.code}</span></li>)}</ul>}</div>
      <form className="card row" onSubmit={add}>
        <input aria-label="State name" placeholder="State name" value={name} onChange={(e) => setName(e.target.value)} required style={{ flex: 2 }} />
        <input aria-label="Code" placeholder="Code (e.g. BR)" value={code} onChange={(e) => setCode(e.target.value)} required maxLength={4} style={{ flex: 1 }} />
        <button disabled={act.busy}>{t('common.create')}</button>
      </form>
      <ErrorBox error={act.error} />
    </div>
  );
}

export function Clients() {
  const { t } = useI18n();
  const states = useAsync(() => q(supabase.from('states').select('*').order('name')) as Promise<State[]>, []);
  const list = useAsync(() => q(supabase.from('clients').select('*').order('name')) as Promise<Client[]>, []);
  const [f, setF] = useState({ name: '', code: '', type: 'exporter', state_id: '' });
  const act = useAction();
  const add = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    await q(supabase.from('clients').insert({ ...f, code: f.code.toUpperCase() }).select()); setF({ ...f, name: '', code: '' }); await list.reload(); }); };
  return (
    <div><h1>{t('clients.title')}</h1>
      <div className="card table-wrap">{list.loading ? <Loading /> : (
        <table><thead><tr><th>Name</th><th>Code</th><th>Type</th><th>State</th></tr></thead>
          <tbody>{list.data?.map((c) => <tr key={c.id}><td>{c.name}</td><td className="mono">{c.code}</td><td>{humanise(c.type)}</td>
            <td>{states.data?.find((s) => s.id === c.state_id)?.name}</td></tr>)}</tbody></table>)}</div>
      <form className="card" onSubmit={add}>
        <h2>{t('common.create')}</h2>
        <Field label="Name" htmlFor="cl-name"><input id="cl-name" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} required /></Field>
        <Field label="Code" hint="2–6 capitals, used in every footprint code" htmlFor="cl-code"><input id="cl-code" value={f.code} onChange={(e) => setF({ ...f, code: e.target.value })} required maxLength={6} /></Field>
        <Field label="Type" htmlFor="cl-type"><select id="cl-type" value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}>
          {['exporter', 'fpo', 'brand', 'grainveda'].map((x) => <option key={x} value={x}>{humanise(x)}</option>)}</select></Field>
        <Field label="State" htmlFor="cl-state"><select id="cl-state" value={f.state_id} onChange={(e) => setF({ ...f, state_id: e.target.value })} required>
          <option value="">—</option>{states.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
        <ErrorBox error={act.error} /><button disabled={act.busy}>{t('common.create')}</button>
      </form>
    </div>
  );
}

interface UserRow { id: string; display_name: string; role: Role; email: string | null; phone: string | null; client_id: string | null; state_ids: string[]; active: boolean; auth_uid: string | null }

export function Users() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const me = ctx!.user!;
  const list = useAsync(() => q(supabase.from('app_users').select('*').order('role').order('display_name')) as Promise<UserRow[]>, []);
  const clients = useAsync(() => q(supabase.from('clients').select('id,name').order('name')) as Promise<{ id: string; name: string }[]>, []);
  const states = useAsync(() => q(supabase.from('states').select('*').order('name')) as Promise<State[]>, []);
  const creatable = (['state_manager', 'client_manager', 'client_view', 'operator'] as Role[]).filter((r) => me.role === 'admin' || ROLE_RANK[r] < ROLE_RANK[me.role]);
  const [f, setF] = useState({ role: creatable[creatable.length - 1] ?? 'operator', display_name: '', email: '', phone: '', client_id: me.client_id ?? '', state_id: '' });
  const [msg, setMsg] = useState<string | null>(null);
  const [resetting, setResetting] = useState<string | null>(null);     // the user whose reset is waiting for a second tap
  const act = useAction();                                             // the "new user" form
  const row = useAction();                                             // deactivate / reset on a row of the list
  useEffect(() => { if (!f.client_id && clients.data?.length) setF((s) => ({ ...s, client_id: clients.data![0].id })); }, [clients.data, f.client_id]);
  const add = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    const body = { role: f.role, display_name: f.display_name, email: f.role === 'operator' ? undefined : f.email, phone: f.phone || undefined,
      client_id: f.role === 'state_manager' ? null : f.client_id, state_ids: f.role === 'state_manager' && f.state_id ? [f.state_id] : [] };
    const r = await callFunction<{ sign_in: string; temporary_password: string }>('create-user', body);
    setMsg(t('users.temp_password', { who: r.sign_in, pw: r.temporary_password }));
    setF({ ...f, display_name: '', email: '', phone: '' }); await list.reload();
  }); };
  const toggle = (u: UserRow) => row.run(async () => { await q(supabase.from('app_users').update({ active: !u.active }).eq('id', u.id).select()); await list.reload(); });
  // Forgotten password or lost phone: a new temporary password, shown once to the manager. The database decides who
  // may reset whom (app.reset_login_allowed); the person must choose an own password at the next sign-in.
  const reset = (u: UserRow) => row.run(async () => {
    setMsg(null);
    try {
      const r = await callFunction<{ sign_in: string; temporary_password: string }>('reset-password', { app_user_id: u.id });
      setMsg(t('users.temp_password', { who: r.sign_in, pw: r.temporary_password }));
    } finally { setResetting(null); }
  });
  const linked = (u: UserRow) => !!u.auth_uid && u.auth_uid !== u.id;
  return (
    <div><h1>{t('users.title')}</h1>
      <div className="card table-wrap">{list.loading ? <Loading /> : (
        <table><thead><tr><th>Name</th><th>Role</th><th>Sign-in</th><th>Client</th><th>Login</th><th></th></tr></thead>
          <tbody>{list.data?.map((u) => <tr key={u.id} data-testid="user-row"><td>{u.display_name}</td><td>{humanise(u.role)}</td><td className="small">{u.email ?? u.phone}</td>
            <td>{clients.data?.find((c) => c.id === u.client_id)?.name ?? '—'}</td>
            <td>{linked(u) ? <Badge value="active" label="linked" /> : <Badge value="draft" label="no login" />}{!u.active && <Badge value="closed" label="inactive" />}</td>
            <td>{u.id !== me.id && (me.role === 'admin' || ROLE_RANK[u.role] < ROLE_RANK[me.role]) && <div className="row">
              <button className="secondary" onClick={() => void toggle(u)}>{u.active ? t('users.deactivate') : t('users.activate')}</button>
              {u.active && linked(u) && (resetting === u.id
                ? <button className="danger" disabled={row.busy} onClick={() => void reset(u)} data-testid="reset-confirm">{t('users.reset_sure')}</button>
                : <button className="secondary" onClick={() => setResetting(u.id)} data-testid="reset-password">{t('users.reset_password')}</button>)}
            </div>}</td></tr>)}</tbody></table>)}</div>
      {msg && <div className="alert ok" data-testid="temp-password">{msg}</div>}
      <ErrorBox error={row.error} />
      <form className="card" onSubmit={add}>
        <h2>{t('users.new')}</h2>
        <Field label="Role" htmlFor="u-role"><select id="u-role" value={f.role} onChange={(e) => setF({ ...f, role: e.target.value as Role })}>
          {creatable.map((r) => <option key={r} value={r}>{humanise(r)}</option>)}</select></Field>
        <Field label="Name" htmlFor="u-name"><input id="u-name" value={f.display_name} onChange={(e) => setF({ ...f, display_name: e.target.value })} required /></Field>
        {f.role !== 'operator' && <Field label="Email" htmlFor="u-email"><input id="u-email" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} required /></Field>}
        <Field label={f.role === 'operator' ? 'Mobile' : 'Mobile (optional)'} htmlFor="u-phone"><input id="u-phone" type="tel" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} required={f.role === 'operator'} /></Field>
        {f.role === 'state_manager'
          ? <Field label="State" htmlFor="u-state"><select id="u-state" value={f.state_id} onChange={(e) => setF({ ...f, state_id: e.target.value })} required>
              <option value="">—</option>{states.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
          : !me.client_id && <Field label="Client" htmlFor="u-client"><select id="u-client" value={f.client_id} onChange={(e) => setF({ ...f, client_id: e.target.value })}>
              {clients.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></Field>}
        <ErrorBox error={act.error} /><button disabled={act.busy}>{t('common.create')}</button>
      </form>
    </div>
  );
}

interface CropRow { id: string; name: string; code: string; gi_tag: string | null; origin: string | null; primary_unit: string; quality_params: QualityParam[]; allowed_stages: StageType[] }

export function Crops() {
  const { t } = useI18n();
  const list = useAsync(() => q(supabase.from('crops').select('*').order('name')) as Promise<CropRow[]>, []);
  const defs = useAsync(() => q(supabase.from('stage_definitions').select('*').eq('is_processing', true).order('sort_order')) as Promise<StageDefinition[]>, []);
  const [edit, setEdit] = useState<CropRow | null>(null);
  const act = useAction();
  const blank: CropRow = { id: '', name: '', code: '', gi_tag: '', origin: '', primary_unit: 'kg', quality_params: [], allowed_stages: [] };
  const save = () => act.run(async () => {
    const { id, ...row } = edit!;
    if (id) await q(supabase.from('crops').update(row).eq('id', id).select()); else await q(supabase.from('crops').insert(row).select());
    setEdit(null); await list.reload();
  });
  const setParam = (i: number, patch: Partial<QualityParam>) => setEdit({ ...edit!, quality_params: edit!.quality_params.map((p, j) => (j === i ? { ...p, ...patch } : p)) });
  return (
    <div><h1>{t('crops.title')}</h1>
      <div className="card">{list.loading ? <Loading /> : <ul>{list.data?.map((c) => (
        <li key={c.id} className="row">{c.name} <span className="mono">{c.code}</span> {c.gi_tag && <Badge value="verified" label={c.gi_tag} />}
          <button className="secondary" onClick={() => setEdit(structuredClone(c))}>{t('common.edit')}</button></li>))}</ul>}
        {!edit && <button onClick={() => setEdit(structuredClone(blank))}>{t('common.create')}</button>}</div>
      {edit && (
        <div className="card">
          <div className="grid">
            <Field label="Name" htmlFor="cr-name"><input id="cr-name" value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} /></Field>
            <Field label="Code" htmlFor="cr-code"><input id="cr-code" value={edit.code} maxLength={5} onChange={(e) => setEdit({ ...edit, code: e.target.value.toUpperCase() })} /></Field>
            <Field label="GI tag" htmlFor="cr-gi"><input id="cr-gi" value={edit.gi_tag ?? ''} onChange={(e) => setEdit({ ...edit, gi_tag: e.target.value })} /></Field>
            <Field label="Origin" htmlFor="cr-origin"><input id="cr-origin" value={edit.origin ?? ''} onChange={(e) => setEdit({ ...edit, origin: e.target.value })} /></Field>
          </div>
          <h3>{t('crops.limits')}</h3>
          <p className="muted small">Active scopes keep the limits they were activated with; edits apply to scopes activated afterwards.</p>
          <div className="table-wrap"><table><thead><tr><th>Parameter key</th><th>Label</th><th>Unit</th><th>Rule</th><th>Domestic</th><th>Export</th><th></th></tr></thead>
            <tbody>{edit.quality_params.map((p, i) => (
              <tr key={i}>
                <td><input aria-label="key" value={p.param} onChange={(e) => setParam(i, { param: e.target.value.replace(/[^a-z0-9_]/g, '') })} /></td>
                <td><input aria-label="label" value={p.label} onChange={(e) => setParam(i, { label: e.target.value })} /></td>
                <td><input aria-label="unit" value={p.unit ?? ''} onChange={(e) => setParam(i, { unit: e.target.value })} style={{ width: 70 }} /></td>
                <td><select aria-label="rule" value={p.operator} onChange={(e) => setParam(i, { operator: e.target.value as QualityParam['operator'] })}>
                  <option value="<=">≤ at most</option><option value=">=">≥ at least</option></select></td>
                <td><input aria-label="domestic limit" inputMode="decimal" value={String(p.domestic_limit)} onChange={(e) => setParam(i, { domestic_limit: Number(e.target.value) })} style={{ width: 90 }} /></td>
                <td><input aria-label="export limit" inputMode="decimal" value={String(p.export_limit)} onChange={(e) => setParam(i, { export_limit: Number(e.target.value) })} style={{ width: 90 }} /></td>
                <td><button className="secondary" onClick={() => setEdit({ ...edit, quality_params: edit.quality_params.filter((_, j) => j !== i) })}>✕</button></td>
              </tr>))}</tbody></table></div>
          <button className="secondary" onClick={() => setEdit({ ...edit, quality_params: [...edit.quality_params, { param: '', label: '', unit: '%', operator: '<=', domestic_limit: 0, export_limit: 0 }] })}>+ limit</button>
          <h3>{t('crops.allowed_stages')}</h3>
          {defs.data?.map((d) => <label key={d.stage_type} className="check"><input type="checkbox" checked={edit.allowed_stages.includes(d.stage_type)}
            onChange={(e) => setEdit({ ...edit, allowed_stages: e.target.checked ? [...edit.allowed_stages, d.stage_type] : edit.allowed_stages.filter((x) => x !== d.stage_type) })} />{d.label}</label>)}
          <ErrorBox error={act.error} />
          <div className="row"><button className="secondary" onClick={() => setEdit(null)}>{t('common.cancel')}</button><button onClick={save} disabled={act.busy}>{t('common.save')}</button></div>
        </div>
      )}
    </div>
  );
}

interface FlagRow { id: string; footprint_id: string; text: string; status: string; created_at: string }
export function OpenFlags() {
  const { t } = useI18n();
  const list = useAsync(async () => {
    const flags = await q(supabase.from('flags').select('*').eq('status', 'open').order('created_at', { ascending: false })) as FlagRow[];
    const ids = [...new Set(flags.map((f) => f.footprint_id))];
    const fps = ids.length ? await q(supabase.from('footprints').select('id,footprint_code,stage_type').in('id', ids)) as { id: string; footprint_code: string; stage_type: string }[] : [];
    return flags.map((f) => ({ ...f, fp: fps.find((x) => x.id === f.footprint_id) }));
  }, []);
  return (
    <div><h1>{t('flags.title')}</h1>
      {list.loading ? <Loading /> : <ErrorBox error={list.error} />}
      {list.data?.length === 0 && <Empty />}
      {!!list.data?.length && <div className="card table-wrap"><table><thead><tr><th>Record</th><th>Flag</th><th>Raised</th></tr></thead>
        <tbody>{list.data.map((f) => <tr key={f.id}><td><Link className="mono" to={`/records/${f.footprint_id}`}>{f.fp?.footprint_code ?? 'record'}</Link> <span className="muted small">{humanise(f.fp?.stage_type ?? '')}</span></td>
          <td>{f.text}</td><td>{dateTime(f.created_at)}</td></tr>)}</tbody></table></div>}
    </div>
  );
}
