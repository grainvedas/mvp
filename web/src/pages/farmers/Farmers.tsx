// S9 farmer list · S10 farmer form · S12 verification (State Manager) — S11 import lives in FarmerImport.tsx
import { useEffect, useState, type FormEvent } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { rpc, q } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import type { Farmer } from '../../lib/types';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { date } from '../../lib/format';

/** The client whose farmers this user works with; State Managers and admins pick one. */
export function useClientChoice() {
  const { ctx } = useAuth();
  const me = ctx!.user!;
  const fixed = me.client_id;
  const clients = useAsync(() => fixed ? Promise.resolve([]) : q(supabase.from('clients').select('id,name,code').order('name')) as Promise<{ id: string; name: string; code: string }[]>, [fixed]);
  const [chosen, setChosen] = useState<string>(() => { try { return localStorage.getItem('grainveda-client') ?? ''; } catch { return ''; } });
  const clientId = fixed ?? chosen ?? '';
  useEffect(() => { if (!fixed && clients.data?.length) setChosen((c) => c || clients.data![0].id); }, [fixed, clients.data]);
  const picker = fixed ? null : (
    <Field label="Client" htmlFor="client-pick">
      <select id="client-pick" value={clientId} onChange={(e) => { setChosen(e.target.value); try { localStorage.setItem('grainveda-client', e.target.value); } catch { /* ignore */ } }}>
        {(clients.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
      </select>
    </Field>
  );
  return { clientId, picker };
}

export function FarmerList() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const me = ctx!.user!;
  const { clientId, picker } = useClientChoice();
  const [tab, setTab] = useState<'draft' | 'under_review' | 'active'>(me.role === 'state_manager' ? 'under_review' : 'active');
  const [search, setSearch] = useState('');
  const list = useAsync(async () => {
    if (!clientId) return [] as Farmer[];
    let r = supabase.from('farmers').select('*').eq('client_id', clientId).eq('status', tab).order('created_at', { ascending: false }).limit(500);
    const s = search.trim();
    if (s) r = r.or(`name.ilike.%${s}%,village.ilike.%${s}%,farmer_code.ilike.%${s}%,phone.ilike.%${s}%`);
    return await q(r) as Farmer[];
  }, [clientId, tab, search]);
  const canEdit = me.role !== 'client_view';
  const isSM = me.role === 'state_manager' || me.role === 'admin';
  return (
    <div>
      <h1>{t('farmers.title')}</h1>
      {picker}
      <div className="row" style={{ marginBottom: 12 }}>
        {canEdit && <Link className="btn" to="/farmers/new">{t('farmers.new')}</Link>}
        {canEdit && <Link className="btn secondary" to="/farmers/import">{t('farmers.import')}</Link>}
        <input aria-label={t('common.search')} placeholder={t('common.search')} value={search} onChange={(e) => setSearch(e.target.value)} style={{ flex: '1 1 200px', width: 'auto' }} />
      </div>
      <div className="tabs" role="tablist">
        {(['draft', 'under_review', 'active'] as const).map((s) => (
          <button key={s} role="tab" aria-selected={tab === s} className={tab === s ? 'active' : ''} onClick={() => setTab(s)}>
            {t(s === 'draft' ? 'farmers.tab_draft' : s === 'under_review' ? 'farmers.tab_review' : 'farmers.tab_active')}
          </button>
        ))}
      </div>
      {list.loading ? <Loading /> : <ErrorBox error={list.error} onRetry={list.reload} />}
      {list.data && list.data.length === 0 && <Empty />}
      {list.data && list.data.length > 0 && (
        <div className="card table-wrap"><table>
          <thead><tr><th>{t('farmer.name')}</th><th>{t('farmer.code')}</th><th>{t('farmer.village')}</th><th className="hide-mobile">{t('farmer.phone')}</th><th className="hide-mobile">{t('farmer.land')}</th><th></th></tr></thead>
          <tbody>{list.data.map((f) => (
            <tr key={f.id} data-testid="farmer-row">
              <td>{f.name}<div className="muted small">{f.guardian_name}</div>
                {typeof f.extra?.sent_back_reason === 'string' && <div className="small" style={{ color: 'var(--warn)' }}>{t('farmers.sent_back')}: {f.extra.sent_back_reason as string}</div>}</td>
              <td className="mono">{f.farmer_code ?? '—'}</td><td>{f.village}</td><td className="hide-mobile">{f.phone}</td><td className="hide-mobile num">{f.land_area_acres}</td>
              <td><FarmerActions farmer={f} isSM={isSM} canEdit={canEdit} onDone={list.reload} /></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}
    </div>
  );
}

function FarmerActions({ farmer, isSM, canEdit, onDone }: { farmer: Farmer; isSM: boolean; canEdit: boolean; onDone: () => void }) {
  const { t } = useI18n();
  const act = useAction();
  const [reason, setReason] = useState('');
  const [sending, setSending] = useState(false);
  if (farmer.status === 'draft' && canEdit) return (
    <div className="row">
      <Link className="btn secondary" to={`/farmers/${farmer.id}`}>{t('common.edit')}</Link>
      <button onClick={() => act.run(async () => { await rpc('submit_farmer', { p_farmer: farmer.id }); onDone(); })} disabled={act.busy}>{t('farmers.submit')}</button>
      <ErrorBox error={act.error} />
    </div>
  );
  if (farmer.status === 'under_review' && isSM) return (
    <div className="stack">
      <div className="row">
        <button onClick={() => act.run(async () => { await rpc('verify_farmer', { p_farmer: farmer.id }); onDone(); })} disabled={act.busy}>{t('farmers.verify')}</button>
        <button className="secondary" onClick={() => setSending(!sending)}>{t('farmers.send_back')}</button>
      </div>
      {sending && <div className="row"><input aria-label={t('farmers.send_back_reason')} placeholder={t('farmers.send_back_reason')} value={reason} onChange={(e) => setReason(e.target.value)} />
        <button className="secondary" disabled={!reason.trim() || act.busy} onClick={() => act.run(async () => { await rpc('send_back_farmer', { p_farmer: farmer.id, p_reason: reason }); onDone(); })}>{t('farmers.send_back')}</button></div>}
      <ErrorBox error={act.error} />
    </div>
  );
  return <span className="muted small">{farmer.status === 'active' ? <Badge value="active" /> : date(farmer.created_at)}</span>;
}

export function FarmerForm() {
  const { id } = useParams();
  const { t } = useI18n();
  const nav = useNavigate();
  const { clientId, picker } = useClientChoice();
  const [f, setF] = useState({ name: '', guardian_name: '', village: '', district: '', phone: '', land_area_acres: '', photo_consent: false, notes: '' });
  const act = useAction();
  useEffect(() => {
    if (!id) return;
    q(supabase.from('farmers').select('*').eq('id', id).single()).then((r) => {
      const x = r as unknown as Farmer;
      setF({ name: x.name, guardian_name: x.guardian_name, village: x.village, district: x.district, phone: x.phone,
        land_area_acres: String(x.land_area_acres), photo_consent: x.photo_consent, notes: String(x.extra?.notes ?? '') });
    });
  }, [id]);
  const set = (k: keyof typeof f) => (e: { target: { value: string; checked?: boolean; type?: string } }) =>
    setF((s) => ({ ...s, [k]: e.target.type === 'checkbox' ? !!e.target.checked : e.target.value }));
  const submit = (e: FormEvent, andSubmit: boolean) => { e.preventDefault(); void act.run(async () => {
    const digits = f.phone.replace(/[^0-9]/g, '');
    const phone = digits.length === 10 ? `+91${digits}` : f.phone;
    const row = { name: f.name.trim(), guardian_name: f.guardian_name.trim(), village: f.village.trim(), district: f.district.trim(), phone,
      land_area_acres: Number(f.land_area_acres), photo_consent: f.photo_consent, extra: f.notes ? { notes: f.notes } : {} };
    const saved = id
      ? await q(supabase.from('farmers').update(row).eq('id', id).select().single()) as Farmer
      : await q(supabase.from('farmers').insert({ ...row, client_id: clientId, status: 'draft' }).select().single()) as Farmer;
    if (andSubmit) await rpc('submit_farmer', { p_farmer: saved.id });
    nav('/farmers');
  }); };
  const input = (k: keyof typeof f, label: string, extra: Record<string, unknown> = {}) => (
    <Field label={`${label} *`} htmlFor={`farmer-${k}`}><input id={`farmer-${k}`} value={f[k] as string} onChange={set(k)} required {...extra} /></Field>
  );
  return (
    <div className="card" style={{ maxWidth: 560 }}>
      <h1>{id ? t('common.edit') : t('farmers.new')}</h1>
      {!id && picker}
      <form onSubmit={(e) => submit(e, false)}>
        {input('name', t('farmer.name'))}
        {input('guardian_name', t('farmer.guardian'))}
        {input('village', t('farmer.village'))}
        {input('district', t('farmer.district'))}
        {input('phone', t('farmer.mobile'), { type: 'tel', inputMode: 'tel' })}
        {input('land_area_acres', t('farmer.land'), { inputMode: 'decimal' })}
        <details><summary>{t('farmer.optional')}</summary>
          <Field label={t('farmer.notes')} htmlFor="farmer-notes"><textarea id="farmer-notes" value={f.notes} onChange={set('notes')} rows={2} /></Field>
        </details>
        <label className="check"><input type="checkbox" checked={f.photo_consent} onChange={set('photo_consent')} />{t('farmers.consent')}</label>
        <ErrorBox error={act.error} />
        <div className="row">
          <button type="submit" className="secondary" disabled={act.busy}>{t('common.save')}</button>
          <button type="button" disabled={act.busy} onClick={(e) => submit(e as unknown as FormEvent, true)}>{t('farmers.submit')}</button>
        </div>
      </form>
    </div>
  );
}
