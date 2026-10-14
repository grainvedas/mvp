// A verified farmer for the person at Procurement (migration 47, Veda 14 Oct 2026). On staging p could not record a lot
// for farmer TCUP-F-0001: its good farming practice was not filled in and nothing let him fill it. Now:
//   · good farming practice: he answers it here and it counts at once ("count at once");
//   · any other detail he finds wrong or missing: he proposes the corrected value with a reason; nothing changes until
//     the Client Manager approves it ("if p does it it should go to lucky for verification") or refuses it with a reason.
// The Client Manager decides the proposals on the Farmers page (ProposalsCard) and here. Every rule is the database's
// (tests/41_farmer_proposals.sql).
import { useState, type FormEvent } from 'react';
import { Link, useParams } from 'react-router-dom';
import { q, rpc } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { dateTime } from '../../lib/format';
import { addsFarmers, holdsClientAccount } from '../../lib/rights';
import type { Farmer } from '../../lib/types';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import { FarmerGap } from './Farmers';

export const PROPOSAL_FIELDS = ['name', 'guardian_name', 'village', 'district', 'phone', 'land_area_acres', 'gi_land_acres', 'notes'] as const;
export type ProposalField = typeof PROPOSAL_FIELDS[number];
export interface Proposal {
  id: string; farmer_id: string; farmer_name: string; farmer_code: string | null; changes: Partial<Record<ProposalField, string | number>>;
  before: Partial<Record<ProposalField, string | number | null>>; reason: string; status: 'requested' | 'approved' | 'refused' | 'withdrawn';
  requested_by: string | null; requested_at: string; decided_by: string | null; decided_at: string | null; decided_reason: string | null;
  mine: boolean; can_decide: boolean;
}
/** Pure: only the details he changed, trimmed; an empty box is "no change", never "erase". */
type Typed = Partial<Record<ProposalField, string>>;
type Stored = Partial<Record<ProposalField, string | number | null | undefined>>;
export function changedFields(now: Typed, was: Stored) {
  const out: Partial<Record<ProposalField, string>> = {};
  for (const k of PROPOSAL_FIELDS) {
    const v = (now[k] ?? '').trim();
    if (v !== '' && v !== String(was[k] ?? '').trim()) out[k] = v;
  }
  return out;
}

const current = (f: Farmer): Partial<Record<ProposalField, string>> => ({ name: f.name ?? '', guardian_name: f.guardian_name ?? '', village: f.village ?? '',
  district: f.district ?? '', phone: f.phone ?? '', land_area_acres: f.land_area_acres == null ? '' : String(f.land_area_acres),
  gi_land_acres: f.gi_land_acres == null ? '' : String(f.gi_land_acres), notes: String((f.extra as Record<string, unknown> | null)?.notes ?? '') });

export function FarmerPractice() {
  const { id = '' } = useParams();
  const { t } = useI18n();
  const { ctx } = useAuth();
  const farmer = useAsync(() => q(supabase.from('farmers').select('*,state_farmer:state_farmers(code)').eq('id', id).single()) as unknown as Promise<Farmer & { state_farmer?: { code: string } | null }>, [id]);
  const [tick, setTick] = useState(0);
  if (farmer.loading && !farmer.data) return <Loading />;
  if (!farmer.data) return <ErrorBox error={farmer.error} onRetry={() => void farmer.reload()} />;
  const f = farmer.data;
  const cm = holdsClientAccount(ctx, f.client_id);
  const adds = addsFarmers(ctx, f.client_id);
  return (
    <div data-testid="farmer-practice">
      <p className="small"><Link to="/farmers">{t('farmers.title')}</Link></p>
      <h1><span aria-hidden="true">👨‍🌾 </span>{f.name}</h1>
      <p className="small">{[f.farmer_code, f.state_farmer?.code, f.village].filter(Boolean).join(' · ')} <Badge value={f.status} /></p>
      <div className="card"><FarmerGap farmerId={f.id} clientId={f.client_id} stateId={f.state_id ?? ''} /></div>
      {adds && !cm && f.status !== 'draft' && f.status !== 'inactive' && (
        <ProposeCard farmer={f} onSent={() => setTick((n) => n + 1)} />)}
      <ProposalsCard farmerId={f.id} tick={tick} onDecided={() => { setTick((n) => n + 1); void farmer.reload(); }} />
    </div>
  );
}

function ProposeCard({ farmer, onSent }: { farmer: Farmer; onSent: () => void }) {
  const { t } = useI18n();
  const was = current(farmer);
  const [f, setF] = useState<Partial<Record<ProposalField, string>>>(was);
  const [reason, setReason] = useState('');
  const [sent, setSent] = useState(false);
  const act = useAction();
  const changes = changedFields(f, was);
  const send = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    await rpc('propose_farmer_change', { p_farmer: farmer.id, p: changes, p_reason: reason.trim() });
    setReason(''); setSent(true); onSent();
  }); };
  return (
    <form className="card" onSubmit={send} aria-label={t('fp.title')} data-testid="fp-form">
      <h2 style={{ marginTop: 0 }}>{t('fp.title')}</h2>
      <p className="small muted">{t('fp.sub')}</p>
      <div className="form-grid">
        {PROPOSAL_FIELDS.map((k) => (
          <Field key={k} label={t(`fp.f_${k}`)} htmlFor={`fp-${k}`}>
            <input id={`fp-${k}`} value={f[k] ?? ''} maxLength={200} inputMode={k.endsWith('acres') ? 'decimal' : k === 'phone' ? 'tel' : undefined}
              onChange={(e) => { setF({ ...f, [k]: e.target.value }); setSent(false); }} data-testid={`fp-${k}`} />
          </Field>))}
      </div>
      <Field label={t('fp.reason')} htmlFor="fp-reason"><input id="fp-reason" value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} data-testid="fp-reason" /></Field>
      {Object.keys(changes).length > 0 && <p className="small" data-testid="fp-changes">{t('fp.will_ask', { fields: Object.keys(changes).map((k) => t(`fp.f_${k}`)).join(', ') })}</p>}
      {sent && <div className="alert ok small" data-testid="fp-sent">{t('fp.sent')}</div>}
      <ErrorBox error={act.error} />
      <button type="submit" disabled={act.busy || Object.keys(changes).length === 0 || reason.trim().length < 3} data-testid="fp-send">{t('fp.send')}</button>
    </form>
  );
}

/** The proposals of one farmer (farmerId) or of a client (clientId): the Client Manager decides; the proposer withdraws his own. */
export function ProposalsCard({ farmerId, clientId, tick, onDecided }: { farmerId?: string; clientId?: string; tick?: number; onDecided?: () => void }) {
  const { t } = useI18n();
  const list = useAsync(() => rpc<Proposal[]>('farmer_proposals', { p_client: clientId ?? null, p_farmer: farmerId ?? null }).catch(() => null), [farmerId, clientId, tick]);
  const act = useAction();
  const [refusing, setRefusing] = useState<string | null>(null);
  const [why, setWhy] = useState('');
  if (!list.data || list.data.length === 0) return clientId ? null : (list.data ? <div className="card"><h2 style={{ marginTop: 0 }}>{t('fp.list')}</h2><Empty>{t('fp.none')}</Empty></div> : null);
  const done = async () => { setRefusing(null); setWhy(''); await list.reload(); onDecided?.(); };
  const decide = (p: Proposal, approve: boolean) => act.run(async () => {
    await rpc('decide_farmer_proposal', { p_id: p.id, p_approve: approve, p_reason: approve ? null : why.trim() }); await done();
  });
  const withdraw = (p: Proposal) => act.run(async () => { await rpc('withdraw_farmer_proposal', { p_id: p.id }); await done(); });
  const open = list.data.filter((p) => p.status === 'requested').length;
  return (
    <div className="card" data-testid="fp-list">
      <h2 style={{ marginTop: 0 }}>{t('fp.list')}{open > 0 && <span className="nav-badge">{open}</span>}</h2>
      <ul className="req-lines">{list.data.map((p) => (
        <li key={p.id} data-testid="fp-item" data-status={p.status}>
          <div>{clientId && <><Link to={`/farmers/${p.farmer_id}/practice`}>{p.farmer_name}</Link>{p.farmer_code ? ` · ${p.farmer_code}` : ''} · </>}
            <Badge value={p.status === 'approved' ? 'verified' : p.status === 'requested' ? 'pending' : 'closed'} label={t(`fp.st_${p.status}`)} /></div>
          <ul className="small" style={{ margin: '4px 0' }}>{Object.entries(p.changes).map(([k, v]) => (
            <li key={k}>{t(`fp.f_${k}`)}: <span className="muted">{String(p.before[k as ProposalField] ?? '—')}</span> → <strong>{String(v)}</strong></li>))}</ul>
          <div className="small muted">{t('fp.by', { who: p.requested_by ?? '—', at: dateTime(p.requested_at), why: p.reason })}</div>
          {p.decided_by && p.status !== 'withdrawn' && <div className="small muted">{t(p.status === 'approved' ? 'fp.approved_by' : 'fp.refused_by', { who: p.decided_by, at: dateTime(p.decided_at ?? '') })}{p.decided_reason ? ` · ${p.decided_reason}` : ''}</div>}
          {p.can_decide && refusing !== p.id && <div className="row" style={{ marginTop: 4 }}>
            <button type="button" className="small-btn" disabled={act.busy} onClick={() => void decide(p, true)} data-testid="fp-approve">{t('fp.approve')}</button>
            <button type="button" className="secondary small-btn" disabled={act.busy} onClick={() => { setRefusing(p.id); setWhy(''); }} data-testid="fp-refuse">{t('fp.refuse')}</button></div>}
          {refusing === p.id && <div className="row" style={{ marginTop: 4 }}>
            <input aria-label={t('fp.refuse_why')} placeholder={t('fp.refuse_why')} value={why} maxLength={300} onChange={(e) => setWhy(e.target.value)} data-testid="fp-refuse-why" />
            <button type="button" className="danger small-btn" disabled={act.busy || why.trim().length < 3} onClick={() => void decide(p, false)} data-testid="fp-refuse-confirm">{t('fp.refuse')}</button>
            <button type="button" className="secondary small-btn" onClick={() => setRefusing(null)}>{t('common.cancel')}</button></div>}
          {p.mine && p.status === 'requested' && <button type="button" className="secondary small-btn" disabled={act.busy} onClick={() => void withdraw(p)} data-testid="fp-withdraw">{t('fp.withdraw')}</button>}
        </li>))}</ul>
      <ErrorBox error={act.error} />
    </div>
  );
}
