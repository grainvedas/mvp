// S3 states · S4 clients · S6 crop registry · open flags
// Migration 34 (Veda, 10 Oct 2026): states stay the admin's; clients and crops are the State Manager's (a client in a
// state they hold). Migration 41 (13 Oct): a crop belongs to a state; a State Manager sees and writes his state's crops,
// and sets the state of a crop made before crops had one (once, logged). The admin reads all.
// (S5 "Users & Roles" is gone: people are added by HR and given access on the People screens, pages/hr and pages/people.)
import { useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { q } from '../../lib/api';
import { toAppError } from '../../lib/errors';
import { supabase } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { dateTime, humanise } from '../../lib/format';
import { Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { useAuth } from '../../auth/AuthProvider';
import { isStateManager } from '../../lib/rights';

interface State { id: string; name: string; code: string }
interface Client { id: string; name: string; code: string; type: string; state_id: string }

export function States() {
  const { t } = useI18n();
  const list = useAsync(() => q(supabase.from('states').select('*').order('name')) as Promise<State[]>, []);
  const [name, setName] = useState(''); const [code, setCode] = useState('');
  const [editing, setEditing] = useState<State | null>(null);
  const act = useAction();
  const row = useAction();
  const add = (e: FormEvent) => { e.preventDefault(); void act.run(async () => { await q(supabase.from('states').insert({ name, code: code.toUpperCase() }).select()); setName(''); setCode(''); await list.reload(); }); };
  const save = (e: FormEvent) => { e.preventDefault(); if (!editing) return; void row.run(async () => {
    await q(supabase.from('states').update({ name: editing.name, code: editing.code.toUpperCase() }).eq('id', editing.id).select());
    setEditing(null); await list.reload();
  }); };
  const remove = (s: State) => row.run(async () => { await q(supabase.from('states').delete().eq('id', s.id)); setEditing(null); await list.reload(); });
  return (
    <div><h1><span aria-hidden="true">📍 </span>{t('states.title')}</h1>
      <div className="card">{list.loading ? <Loading /> : <ul>{list.data?.map((s) => (
        <li key={s.id} className="row">{editing?.id === s.id
          ? <form className="row" onSubmit={save} style={{ flex: 1 }}>
              <input aria-label="State name" value={editing.name} onChange={(e) => setEditing({ ...editing, name: e.target.value })} required style={{ flex: 2 }} />
              <input aria-label="Code" value={editing.code} onChange={(e) => setEditing({ ...editing, code: e.target.value })} required maxLength={4} style={{ flex: 1 }} />
              <button disabled={row.busy}>{t('common.save')}</button>
              <button type="button" className="secondary" onClick={() => setEditing(null)}>{t('common.cancel')}</button>
              <button type="button" className="danger" disabled={row.busy} onClick={() => void remove(s)}>Delete</button>
            </form>
          : <>{s.name} <span className="mono">{s.code}</span>
              <Link className="small" to={`/state/${s.id}`}>{t('state.title')}</Link>
              <button className="secondary" onClick={() => setEditing({ ...s })}>{t('common.edit')}</button></>}
        </li>))}</ul>}</div>
      <form className="card row" onSubmit={add}>
        <input aria-label="State name" placeholder="State name" value={name} onChange={(e) => setName(e.target.value)} required style={{ flex: 2 }} />
        <input aria-label="Code" placeholder="Code (e.g. BR)" value={code} onChange={(e) => setCode(e.target.value)} required maxLength={4} style={{ flex: 1 }} />
        <button disabled={act.busy}>{t('common.create')}</button>
      </form>
      <ErrorBox error={act.error} />
      <ErrorBox error={row.error} />
    </div>
  );
}

export function Clients() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const sm = isStateManager(ctx);
  // the states this State Manager holds: a client is onboarded in one of them
  const mine = new Set((ctx?.assignments ?? []).filter((a) => a.lens === 'state' && a.state_id).map((a) => a.state_id!));
  const states = useAsync(() => q(supabase.from('states').select('*').order('name')) as Promise<State[]>, []);
  const list = useAsync(() => q(supabase.from('clients').select('*').order('name')) as Promise<Client[]>, []);
  const [f, setF] = useState({ name: '', code: '', type: 'exporter', state_id: '' });
  const act = useAction();
  const add = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    // No .select() here: the list is read again below. Asking for the row back made every insert fail on a database
    // without migration 30 ("Not allowed for your role or stage", 5 Oct 2026: the read rule could not see the new row).
    const { error } = await supabase.from('clients').insert({ ...f, code: f.code.toUpperCase() });
    if (error) throw toAppError(error);
    setF({ ...f, name: '', code: '' }); await list.reload(); }); };
  return (
    <div><h1><span aria-hidden="true">🏢 </span>{t('clients.title')}</h1>
      <div className="card table-wrap">{list.loading ? <Loading /> : (
        <table><thead><tr><th>Name</th><th>Code</th><th>Type</th><th>State</th></tr></thead>
          <tbody>{list.data?.map((c) => <tr key={c.id}><td>{c.name}</td><td className="mono">{c.code}</td><td>{humanise(c.type)}</td>
            <td>{states.data?.find((s) => s.id === c.state_id)?.name}</td></tr>)}</tbody></table>)}</div>
      {!sm && <p className="small muted" data-testid="clients-readonly">{t('clients.sm_only')}</p>}
      {sm && <form className="card" onSubmit={add} data-testid="client-form">
        <h2>{t('clients.onboard')}</h2>
        <Field label="Name" htmlFor="cl-name"><input id="cl-name" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} required /></Field>
        <Field label="Code" hint="2–6 capitals, used in every footprint code" htmlFor="cl-code"><input id="cl-code" value={f.code} onChange={(e) => setF({ ...f, code: e.target.value })} required maxLength={6} /></Field>
        <Field label="Type" htmlFor="cl-type"><select id="cl-type" value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}>
          {['exporter', 'fpo', 'brand', 'grainveda'].map((x) => <option key={x} value={x}>{humanise(x)}</option>)}</select></Field>
        <Field label="State" htmlFor="cl-state"><select id="cl-state" value={f.state_id} onChange={(e) => setF({ ...f, state_id: e.target.value })} required>
          <option value="">—</option>{states.data?.filter((s) => mine.has(s.id)).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
        <ErrorBox error={act.error} /><button disabled={act.busy}>{t('common.create')}</button>
        <p className="small muted">{t('clients.next_step')}</p>
      </form>}
    </div>
  );
}

// The crop registry moved to pages/crops/CropRegistry.tsx (migration 42); its pure helpers are in lib/crops.ts.
export { Crops } from '../crops/CropRegistry';
export { cropsFor, limitInput, limitTyping } from '../../lib/crops';

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
    <div><h1><span aria-hidden="true">🚩 </span>{t('flags.title')}</h1>
      {list.loading ? <Loading /> : <ErrorBox error={list.error} />}
      {list.data?.length === 0 && <Empty />}
      {!!list.data?.length && <div className="card table-wrap"><table><thead><tr><th>Record</th><th>Flag</th><th>Raised</th></tr></thead>
        <tbody>{list.data.map((f) => <tr key={f.id}><td><Link className="mono" to={`/records/${f.footprint_id}`}>{f.fp?.footprint_code ?? 'record'}</Link> <span className="muted small">{f.fp ? t(`stage.${f.fp.stage_type}`, undefined, humanise(f.fp.stage_type)) : ''}</span></td>
          <td>{f.text}</td><td>{dateTime(f.created_at)}</td></tr>)}</tbody></table></div>}
    </div>
  );
}
