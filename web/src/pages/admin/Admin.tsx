// S3 states · S4 clients · S6 crop registry · open flags
// (S5 "Users & Roles" is gone: people are added by HR and given access on the People screens, pages/hr and pages/people.)
import { useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { q } from '../../lib/api';
import { toAppError } from '../../lib/errors';
import { supabase } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { dateTime, humanise } from '../../lib/format';
import type { QualityParam, StageDefinition, StageType } from '../../lib/types';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';

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

interface CropRow { id: string; name: string; code: string; gi_tag: string | null; origin: string | null; primary_unit: string; quality_params: QualityParam[]; allowed_stages: StageType[] }

/** Text that can still become a number as typing goes on: digits with at most one point. */
export const limitTyping = (text: string) => /^\d*\.?\d*$/.test(text.trim());

/** A quality limit as typed: a number, or null while it is not one (empty, "12.", a letter). */
export function limitInput(text: string): number | null {
  const s = text.trim();
  if (s === '' || s.endsWith('.') || !/^\d*\.?\d+$/.test(s)) return null;
  return Number(s);
}

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
    setTyped({}); setEdit(null); await list.reload();
  });
  const setParam = (i: number, patch: Partial<QualityParam>) => setEdit({ ...edit!, quality_params: edit!.quality_params.map((p, j) => (j === i ? { ...p, ...patch } : p)) });
  // What is typed into a limit box, kept as typed. Before, the box was turned into a number at every key, so the decimal
  // point of "12.5" was dropped as soon as it was typed and the limit became 125.
  const [typed, setTyped] = useState<Record<string, string>>({});
  const limitBox = (i: number, which: 'domestic_limit' | 'export_limit', p: QualityParam) => {
    const k = `${i}:${which}`;
    const bad = k in typed && !limitTyping(typed[k]);
    return <input aria-label={which === 'domestic_limit' ? 'domestic limit' : 'export limit'} inputMode="decimal" value={typed[k] ?? String(p[which])}
      aria-invalid={bad || undefined} style={{ width: 90, borderColor: bad ? 'var(--bad)' : undefined }}
      onChange={(e) => { setTyped({ ...typed, [k]: e.target.value }); const n = limitInput(e.target.value); if (n !== null) setParam(i, { [which]: n }); }} />;
  };
  const limitsBad = Object.values(typed).some((x) => !limitTyping(x));            // letters, two points…: say so
  const limitsOpen = Object.values(typed).some((x) => limitInput(x) === null);   // not a number yet ("12.", empty): cannot be saved
  return (
    <div><h1><span aria-hidden="true">🌿 </span>{t('crops.title')}</h1>
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
                <td>{limitBox(i, 'domestic_limit', p)}</td>
                <td>{limitBox(i, 'export_limit', p)}</td>
                <td><button className="secondary" onClick={() => { setTyped({}); setEdit({ ...edit, quality_params: edit.quality_params.filter((_, j) => j !== i) }); }}>✕</button></td>
              </tr>))}</tbody></table></div>
          {/* a new row starts with empty limit boxes (they held "0", which had to be deleted before typing) and cannot be saved until both are numbers */}
          <button className="secondary" onClick={() => {
            const n = edit.quality_params.length;
            setTyped({ ...typed, [`${n}:domestic_limit`]: '', [`${n}:export_limit`]: '' });
            setEdit({ ...edit, quality_params: [...edit.quality_params, { param: '', label: '', unit: '%', operator: '<=', domestic_limit: 0, export_limit: 0 }] });
          }}>+ limit</button>
          <h3>{t('crops.allowed_stages')}</h3>
          {defs.data?.map((d) => <label key={d.stage_type} className="check"><input type="checkbox" checked={edit.allowed_stages.includes(d.stage_type)}
            onChange={(e) => setEdit({ ...edit, allowed_stages: e.target.checked ? [...edit.allowed_stages, d.stage_type] : edit.allowed_stages.filter((x) => x !== d.stage_type) })} />{d.label}</label>)}
          <ErrorBox error={act.error} />
          {limitsBad && <div className="alert error" data-testid="limit-not-a-number">{t('crops.limit_number')}</div>}
          <div className="row"><button className="secondary" onClick={() => { setTyped({}); setEdit(null); }}>{t('common.cancel')}</button><button onClick={save} disabled={act.busy || limitsOpen}>{t('common.save')}</button></div>
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
    <div><h1><span aria-hidden="true">🚩 </span>{t('flags.title')}</h1>
      {list.loading ? <Loading /> : <ErrorBox error={list.error} />}
      {list.data?.length === 0 && <Empty />}
      {!!list.data?.length && <div className="card table-wrap"><table><thead><tr><th>Record</th><th>Flag</th><th>Raised</th></tr></thead>
        <tbody>{list.data.map((f) => <tr key={f.id}><td><Link className="mono" to={`/records/${f.footprint_id}`}>{f.fp?.footprint_code ?? 'record'}</Link> <span className="muted small">{f.fp ? t(`stage.${f.fp.stage_type}`, undefined, humanise(f.fp.stage_type)) : ''}</span></td>
          <td>{f.text}</td><td>{dateTime(f.created_at)}</td></tr>)}</tbody></table></div>}
    </div>
  );
}
