// The farmer register of a state (migration 43, Veda 13 Oct 2026, State Manager brief part D). For the State Manager of
// the state (and the admin, reading): every farmer of the state across its clients, by district, with what each sold this
// season against what his GI land should give. Three flags: a possible duplicate (the same phone on another record in the
// state), past 120 % of the expected yield, and no GI land yet (needed before the Farmer ID). On a possible duplicate the
// State Manager decides: "Not the same person" (with a reason, logged) or deactivates one record. The phone shows only
// its last four digits here. app.farmer_register counts on the server; the page asks one page of rows at a time.
import { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { rpc, q } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { myStateIds, oversees } from '../../lib/rights';
import { kg, num } from '../../lib/format';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { StatButton } from '../dashboard/parts';
import { maskedPhone, NO_FILTER, PAGE, REGISTER_FLAGS, registerParams, yieldLevel, yieldShare,
  type Register, type RegisterFilter, type RegisterRow } from '../../lib/farmers';

export function FarmerRegister() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const watch = oversees(ctx);
  const mine = myStateIds(ctx);
  // the admin reads any state's register; a State Manager his own
  const states = useAsync(async () => watch
    ? await q(supabase.from('states').select('id,name').order('name')) as { id: string; name: string }[]
    : (ctx?.assignments ?? []).filter((a) => a.lens === 'state' && a.state_id).map((a) => ({ id: a.state_id!, name: a.state_name ?? '' })), [watch]);
  const [stateId, setStateId] = useState(mine[0] ?? '');
  useEffect(() => { if (!stateId && states.data?.length) setStateId(states.data[0].id); }, [stateId, states.data]);
  const [params] = useSearchParams();
  const [f, setF] = useState<RegisterFilter>(() => ({ ...NO_FILTER, flag: params.get('flag') ?? '' }));
  const [search, setSearch] = useState('');
  const [page, setPage] = useState(0);
  useEffect(() => { const h = setTimeout(() => setF((x) => (x.q === search ? x : { ...x, q: search })), 300); return () => clearTimeout(h); }, [search]);
  useEffect(() => setPage(0), [stateId, f]);
  const reg = useAsync(() => (stateId ? rpc<Register>('farmer_register', { p: registerParams(stateId, f, page) }) : Promise.resolve(null)), [stateId, f, page]);
  const d = reg.data;
  const set = (k: keyof RegisterFilter) => (v: string) => setF((x) => ({ ...x, [k]: v }));
  const flagTile = (flag: string) => set('flag')(f.flag === flag ? '' : flag);
  const pages = d ? Math.max(1, Math.ceil(Number(d.total) / PAGE)) : 1;
  return (
    <div data-testid="farmer-register">
      <h1><span aria-hidden="true">📒 </span>{t('reg.title', { state: d?.state.name ?? '…' })}</h1>
      <p className="small muted">{t('reg.sub')}</p>
      {watch && <p className="small muted" data-testid="reg-readonly">{t('reg.admin_reads')}</p>}
      {(states.data?.length ?? 0) > 1 && (
        <Field label={t('ov.state')} htmlFor="reg-state">
          <select id="reg-state" value={stateId} onChange={(e) => setStateId(e.target.value)} data-testid="reg-state">
            {states.data!.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select>
        </Field>)}
      {!stateId && !states.loading && <Empty>{t('sh.no_state')}</Empty>}
      {reg.loading && !d ? <Loading /> : <ErrorBox error={reg.error} onRetry={() => void reg.reload()} />}
      {d && (
        <>
          <div className="stats" data-testid="reg-cards">
            <StatButton testId="reg-card-farmers" open={f.status === 'active'} onClick={() => set('status')(f.status === 'active' ? '' : 'active')}
              value={String(d.cards.active)} label={t('reg.c_active')} sub={t('reg.c_active_sub', { all: d.cards.farmers, r: d.cards.under_review, dr: d.cards.draft })} />
            <Stat testId="reg-card-gi" value={num(d.cards.gi_acres, 2)} label={t('reg.c_gi')} sub={t('reg.c_gi_sub', { land: num(d.cards.land_acres, 2) })} />
            <Stat testId="reg-card-sold" value={kg(d.cards.sold_kg)} label={t('reg.c_sold', { season: d.season ?? '—' })}
              sub={Number(d.cards.expected_kg) > 0 ? t('reg.c_sold_sub', { pct: yieldShare(d.cards.sold_kg, d.cards.expected_kg) ?? 0, n: d.cards.selling }) : t('reg.c_sold_none')} />
            <StatButton testId="reg-card-flags" open={!!f.flag} onClick={() => flagTile(Number(d.cards.duplicates) > 0 ? 'duplicate' : Number(d.cards.over_yield) > 0 ? 'over_yield' : 'no_gi_land')}
              value={String(Number(d.cards.duplicates) + Number(d.cards.over_yield))} label={t('reg.c_flags')}
              sub={t('reg.c_flags_sub', { d: d.cards.duplicates, o: d.cards.over_yield, g: d.cards.no_gi_land })} />
          </div>

          {d.cards.by_district.length > 0 && (
            <details className="card" data-testid="reg-districts"><summary>{t('reg.by_district')}</summary>
              <ul className="ov-list">{d.cards.by_district.map((x) => (
                <li key={x.district}><button type="button" className="linkish" onClick={() => set('district')(f.district === x.district ? '' : x.district)}>{x.district}</button>
                  <span className="small muted"> · {t('reg.district_line', { n: x.farmers, gi: num(x.gi_acres, 2), sold: kg(x.sold_kg) })}</span></li>))}</ul>
            </details>)}

          <div className="reg-filters" data-testid="reg-filters">
            <select aria-label={t('reg.f_season')} value={f.season || d.season || ''} onChange={(e) => set('season')(e.target.value)} data-testid="reg-season">
              {(d.seasons.length ? d.seasons : [d.season ?? '']).map((s) => <option key={s} value={s}>{s || '—'}</option>)}</select>
            <select aria-label={t('reg.f_client')} value={f.client} onChange={(e) => set('client')(e.target.value)} data-testid="reg-client">
              <option value="">{t('reg.all_clients')}</option>
              {d.filters.clients.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select>
            <select aria-label={t('reg.f_district')} value={f.district} onChange={(e) => set('district')(e.target.value)} data-testid="reg-district">
              <option value="">{t('reg.all_districts')}</option>
              {d.filters.districts.map((x) => <option key={x} value={x}>{x}</option>)}</select>
            <select aria-label={t('reg.f_status')} value={f.status} onChange={(e) => set('status')(e.target.value)} data-testid="reg-status">
              <option value="">{t('reg.all_status')}</option>
              {['active', 'under_review', 'draft', 'inactive'].map((s) => <option key={s} value={s}>{t(`reg.st_${s}`)}</option>)}</select>
            <select aria-label={t('reg.f_flag')} value={f.flag} onChange={(e) => set('flag')(e.target.value)} data-testid="reg-flag">
              <option value="">{t('reg.all_flags')}</option>
              {REGISTER_FLAGS.map((x) => <option key={x} value={x}>{t(`reg.flag_${x}`)}</option>)}</select>
            <input aria-label={t('common.search')} placeholder={t('reg.search')} value={search} onChange={(e) => setSearch(e.target.value)} data-testid="reg-search" />
          </div>
          <p className="small muted" data-testid="reg-total">{t('reg.total', { n: d.total })}</p>

          {d.rows.length === 0 ? <Empty>{t('reg.none')}</Empty> : (
            <ul className="reg-list">{d.rows.map((r) => <RegisterCard key={r.id} r={r} stateName={d.state.name} canAct={!watch} onDone={() => void reg.reload()} />)}</ul>)}
          {Number(d.total) > PAGE && <p className="row pager" data-testid="reg-pager">
            <button type="button" className="secondary" disabled={page === 0} onClick={() => setPage(page - 1)}>{t('jl.prev')}</button>
            <span className="small">{t('reg.page', { page: page + 1, pages, total: d.total })}</span>
            <button type="button" className="secondary" disabled={page + 1 >= pages} onClick={() => setPage(page + 1)}>{t('jl.next')}</button></p>}
          <p className="small muted">{t('reg.note')}</p>
        </>)}
    </div>
  );
}

/** A figure that opens nothing: the look of the tiles, not a button. */
function Stat({ value, label, sub, testId }: { value: string; label: string; sub: string; testId: string }) {
  return <div className="stat" data-testid={testId}><div className="stat-val">{value}</div><div className="stat-label">{label}</div><div className="stat-sub">{sub}</div></div>;
}

function RegisterCard({ r, canAct, onDone }: { r: RegisterRow; stateName: string; canAct: boolean; onDone: () => void }) {
  const { t } = useI18n();
  const pct = yieldShare(r.sold_kg, r.expected_kg);
  const level = yieldLevel(pct);
  return (
    <li className="card reg-card" data-testid="reg-row">
      <div className="row" style={{ justifyContent: 'space-between', alignItems: 'baseline' }}>
        <div><strong>{r.name}</strong> <span className="small muted">{r.guardian_name}</span></div>
        <Badge value={r.status} label={t(`reg.st_${r.status}`)} />
      </div>
      <div className="small">
        {r.farmer_code ? <span className="mono">{r.farmer_code}</span> : <span className="muted">{t('reg.no_code')}</span>} · {r.village}, {r.district} · {r.client}
      </div>
      <div className="small muted" data-testid="reg-phone">{t('reg.phone', { p: maskedPhone(r.phone_last4) })}</div>
      <div className="small" data-testid="reg-land">{r.gi_land_acres === null
        ? <span className="muted">{t('reg.no_gi', { land: num(r.land_area_acres, 2) })}</span>
        : t('reg.land', { gi: num(r.gi_land_acres, 2), land: num(r.land_area_acres, 2) })}</div>
      {r.sold_kg !== null && (
        <div className="small" data-testid="reg-yield" style={level === 'flagged' ? { color: 'var(--red)' } : level === 'above' ? { color: 'var(--warn)' } : undefined}>
          {pct === null ? t('reg.sold_only', { sold: kg(r.sold_kg) }) : t('reg.sold', { sold: kg(r.sold_kg), exp: kg(r.expected_kg), pct })}</div>)}
      {r.flags.length > 0 && <div className="chips" data-testid="reg-flags">{r.flags.map((x) => (
        <span key={x} className={`badge ${x === 'no_gi_land' ? 'pending' : 'open'}`} data-testid={`reg-flag-${x}`}>{t(`reg.flag_${x}`)}</span>))}</div>}
      {r.duplicates.map((o) => <Duplicate key={o.id} r={r} other={o} canAct={canAct} onDone={onDone} />)}
    </li>
  );
}

function Duplicate({ r, other, canAct, onDone }: { r: RegisterRow; other: RegisterRow['duplicates'][number]; canAct: boolean; onDone: () => void }) {
  const { t } = useI18n();
  const act = useAction();
  const [mode, setMode] = useState<'' | 'distinct' | 'deactivate'>('');
  const [reason, setReason] = useState('');
  return (
    <div className="alert warn small" data-testid="reg-dup">
      <div>{t('reg.dup_line', { name: other.name, code: other.farmer_code ?? t('reg.no_code'), client: other.client })}</div>
      {canAct && mode === '' && (
        <div className="row" style={{ marginTop: 6 }}>
          <button type="button" className="secondary" onClick={() => setMode('distinct')} data-testid="reg-dup-distinct">{t('reg.not_same')}</button>
          {r.status !== 'inactive' && <button type="button" className="secondary" onClick={() => setMode('deactivate')} data-testid="reg-dup-deactivate">{t('reg.deactivate_this')}</button>}
        </div>)}
      {mode === 'distinct' && (
        <div className="stack" style={{ marginTop: 6 }}>
          <input aria-label={t('reg.why_distinct')} placeholder={t('reg.why_distinct')} value={reason} maxLength={200} onChange={(e) => setReason(e.target.value)} data-testid="reg-dup-reason" />
          <div className="row">
            <button type="button" disabled={!reason.trim() || act.busy} data-testid="reg-dup-save"
              onClick={() => act.run(async () => { await rpc('mark_not_duplicate', { p_farmer: r.id, p_other: other.id, p_note: reason.trim() }); onDone(); })}>{t('reg.not_same')}</button>
            <button type="button" className="secondary" onClick={() => setMode('')}>{t('reg.cancel')}</button>
          </div>
        </div>)}
      {mode === 'deactivate' && (
        <div className="stack" style={{ marginTop: 6 }}>
          <div>{r.farmer_code ? t('reg.deactivate_coded', { name: r.name }) : t('reg.deactivate_uncoded', { name: r.name })}</div>
          <div className="row">
            <button type="button" className="danger" disabled={act.busy} data-testid="reg-dup-deactivate-confirm"
              onClick={() => act.run(async () => { await q(supabase.from('farmers').update({ status: 'inactive' }).eq('id', r.id).select()); onDone(); })}>{t('reg.deactivate_this')}</button>
            <button type="button" className="secondary" onClick={() => setMode('')}>{t('reg.cancel')}</button>
          </div>
        </div>)}
      <ErrorBox error={act.error} />
    </div>
  );
}

/** The link to the register on the Farmers page, for the State Manager and the admin. */
export function RegisterLink() {
  const { t } = useI18n();
  return <Link className="btn secondary" to="/farmers/register" data-testid="to-register">{t('reg.open')}</Link>;
}
