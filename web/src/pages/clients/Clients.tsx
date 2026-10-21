// Migration 64 (Phase 2, release 1: the client registry, Parts A and B of Veda's combined brief).
//   /clients        the clients the reader may see, with their status per state and the gates' progress
//   /clients/new    the State Manager: PAN first ("Already registered with GrainVeda"), then Gate 1
//   /clients/:id    the record: the shared identity for another state's State Manager; the full record by state for the
//                   client's State Managers (they fill the gates), the admin (approves the first Active, edits the
//                   national identity), the client's own login and its Client Manager (read)
// Migration 65 (release 2, Parts C and D): "Add [my state] to this client"; the status per state (suspend, resume, end,
// return; the admin also for every state at once); the warnings before a licence or the MSA expires; the renewals the
// client's own login uploads for its State Manager to accept.
// Every rule is the server's (tests/59_client_registry.sql, tests/60_client_states_status.sql).
import { useMemo, useState, type FormEvent } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { q } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { date, dateTime } from '../../lib/format';
import { useAuth } from '../../auth/AuthProvider';
import { isStateManager, myStateIds, oversees } from '../../lib/rights';
import { Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import {
  ENTITY_TYPES, NATIONAL_DOCS, PAN_LETTER, addClientState, addDocument, clientExpiries, clientRenewals, clientView, clientsPage,
  createClient, decideActivation, decideRenewal, docAccept, editIdentity, gateCount, kycTick, lookupPan, moveClient, nextMove, normId,
  openDocument, openPath, panProblem, proposeRenewal, regKind, saveDetails, setClientStatus, setPan, statusMoves,
  type ClientStatus, type ClientView, type Doc, type DocKind, type EntityType, type Expiry, type Gates, type Lookup, type RenewalKind,
  type StateRow, type StatusMove,
} from '../../lib/clients';

export function StatusBadge({ s }: { s: ClientStatus }) {
  const { t } = useI18n();
  const cls = s === 'active' ? 'active' : s === 'diagnostic' ? 'pending' : s === 'prospect' ? 'draft' : 'open';
  return <span className={`badge ${cls}`} data-testid="client-status" data-status={s}>{t(`cst.${s}`)}</span>;
}
function Flags({ panPending, ownBrand }: { panPending: boolean; ownBrand: boolean }) {
  const { t } = useI18n();
  return <>{panPending && <span className="badge pending" data-testid="pan-pending">{t('cl.pan_pending')}</span>}
    {ownBrand && <span className="badge lens-client" data-testid="own-brand">{t('cl.own_brand')}</span>}</>;
}

// ── the list ──────────────────────────────────────────────────────────────────────────────────────────────────────────
export function Clients() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const sm = isStateManager(ctx);
  const list = useAsync(() => clientsPage(), []);
  return (
    <div><h1><span aria-hidden="true">🏢 </span>{t('clients.title')}</h1>
      {sm && <p><Link className="button" to="/clients/new" data-testid="client-new">{t('cl.new')}</Link></p>}
      {!sm && <p className="small muted" data-testid="clients-readonly">{t(oversees(ctx) ? 'cl.admin_note' : 'clients.sm_only')}</p>}
      {(sm || oversees(ctx)) && <ExpiryCard />}
      {list.loading ? <Loading /> : <ErrorBox error={list.error} onRetry={list.reload} />}
      {list.data?.length === 0 && <Empty />}
      <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
        {list.data?.map((c) => (
          <li key={c.client_id} className="card" data-testid="client-row" data-code={c.code}>
            <div className="row wrap" style={{ justifyContent: 'space-between' }}>
              <Link to={`/clients/${c.client_id}`}><strong>{c.name}</strong></Link>
              <span className="mono">{c.code}</span>
            </div>
            <div className="small muted">{c.legal_name !== c.name && <>{c.legal_name} · </>}{t(`etype.${c.entity_type}`)}{c.pan_masked && <> · PAN <span className="mono">{c.pan_masked}</span></>}</div>
            <div className="row wrap" style={{ gap: 6, marginTop: 6 }}>
              <Flags panPending={c.pan_pending} ownBrand={c.own_brand} />
              {c.states.map((s) => (
                <span key={s.state_id} className="chip" data-testid="client-state" data-state={s.state}>
                  {s.state}: <StatusBadge s={s.status} />
                  {s.progress && s.status !== 'active' && <span className="small"> {t('cl.progress', { done: s.progress.done, of: s.progress.of })}</span>}
                  {s.awaiting_approval && <span className="small"> · {t('cl.awaiting_approval')}</span>}
                </span>))}
            </div>
          </li>))}
      </ul>
    </div>
  );
}

// ── a new client: PAN first, then Gate 1 ────────────────────────────────────────────────────────────────────────────────
export function NewClient() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const nav = useNavigate();
  const mine = myStateIds(ctx);
  const states = useAsync(() => q(supabase.from('states').select('id,name').order('name')) as Promise<{ id: string; name: string }[]>, []);
  const crops = useAsync(() => q(supabase.from('crops').select('id,name,state_id,retired_at').is('retired_at', null).order('name')) as Promise<{ id: string; name: string; state_id: string | null }[]>, []);
  const [pan, setPanText] = useState(''); const [type, setType] = useState<EntityType | ''>('');
  const [legal, setLegal] = useState(''); const [found, setFound] = useState<Lookup | null>(null);
  const [f, setF] = useState({ trade_name: '', name: '', designation: '', phone: '', email: '', source: '', client_type: 'exporter' });
  const [stateId, setStateId] = useState(''); const [interest, setInterest] = useState<string[]>([]); const [cropIds, setCropIds] = useState<string[]>([]);
  const look = useAction(); const make = useAction();
  const st = stateId || (mine.length === 1 ? mine[0] : '');
  const statesOfInterest = useMemo(() => [...new Set([st, ...interest].filter(Boolean))], [st, interest]);
  const problem = pan ? panProblem(pan, type) : null;
  const check = (e: FormEvent) => { e.preventDefault(); void look.run(async () => setFound(await lookupPan(pan, legal, type || null))); };
  const save = (e: FormEvent) => { e.preventDefault(); void make.run(async () => {
    const r = await createClient({ pan: normId(pan), entity_type: type, legal_name: legal, trade_name: f.trade_name, state_id: st,
      contact: { name: f.name, designation: f.designation, phone: f.phone, email: f.email }, source: f.source || null, client_type: f.client_type,
      states_of_interest: statesOfInterest, crops_of_interest: cropIds });
    nav(`/clients/${r.client_id}`);
  }); };
  const toggle = (list: string[], set: (x: string[]) => void, id: string) => set(list.includes(id) ? list.filter((x) => x !== id) : [...list, id]);
  return (
    <div><h1>{t('cl.new')}</h1>
      <form className="card stack" onSubmit={check} data-testid="pan-form">
        <p className="small muted">{t('cl.pan_first')}</p>
        <Field label={t('cl.entity_type')} htmlFor="cl-type">
          <select id="cl-type" value={type} onChange={(e) => { setType(e.target.value as EntityType); setFound(null); }} required>
            <option value="">—</option>{ENTITY_TYPES.map((x) => <option key={x} value={x}>{t(`etype.${x}`)} ({PAN_LETTER[x]})</option>)}</select></Field>
        <Field label="PAN" hint={t('cl.pan_hint')} htmlFor="cl-pan">
          <input id="cl-pan" className="mono" value={pan} maxLength={10} autoComplete="off" onChange={(e) => { setPanText(e.target.value.toUpperCase()); setFound(null); }} required /></Field>
        {problem && <p className="small text-danger" data-testid="pan-problem">{t(`cl.pan_${problem}`, { letter: type ? PAN_LETTER[type] : '' })}</p>}
        <Field label={t('cl.legal_name')} hint={t('cl.legal_hint')} htmlFor="cl-legal">
          <input id="cl-legal" value={legal} onChange={(e) => { setLegal(e.target.value); setFound(null); }} required maxLength={200} /></Field>
        <ErrorBox error={look.error} />
        <button className="secondary" disabled={look.busy || !!problem || !type} data-testid="pan-check">{t('cl.check_pan')}</button>
      </form>

      {found?.situation === 'client' && found.identity && (
        <div className="card" data-testid="already-registered">
          <div className="alert warn"><strong>{t('cl.already')}</strong></div>
          <SharedIdentity id={found.identity} />
          {found.in_my_state && <p className="small muted">{t('cl.already_mine')}</p>}
          <AddStates client={found.identity.client_id} states={found.add_states ?? []} />
          <Link to={`/clients/${found.identity.client_id}`}>{t('cl.open')}</Link>
        </div>)}

      {found && found.situation !== 'client' && (
        <form className="card stack" onSubmit={save} data-testid="gate1-form">
          {found.situation === 'known' && <div className="alert info" data-testid="known-business">{t('cl.known')}</div>}
          {found.similar && <div className="alert warn" data-testid="similar-name">{t('cl.similar')}</div>}
          <h2>{t('cl.gate1')}</h2>
          <Field label={t('cl.trade_name')} htmlFor="cl-trade"><input id="cl-trade" value={f.trade_name} onChange={(e) => setF({ ...f, trade_name: e.target.value })} maxLength={200} /></Field>
          <Field label={t('cl.kind')} htmlFor="cl-kind"><select id="cl-kind" value={f.client_type} onChange={(e) => setF({ ...f, client_type: e.target.value })}>
            {['exporter', 'fpo', 'brand', 'grainveda'].map((x) => <option key={x} value={x}>{t(`ctype.${x}`)}</option>)}</select></Field>
          <Field label={t('cl.start_state')} htmlFor="cl-state"><select id="cl-state" value={st} onChange={(e) => setStateId(e.target.value)} required>
            <option value="">—</option>{states.data?.filter((s) => mine.includes(s.id)).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
          <fieldset><legend>{t('cl.contact')}</legend>
            <Field label={t('cl.c_name')} htmlFor="cl-cn"><input id="cl-cn" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} required /></Field>
            <Field label={t('cl.c_designation')} htmlFor="cl-cd"><input id="cl-cd" value={f.designation} onChange={(e) => setF({ ...f, designation: e.target.value })} required /></Field>
            <Field label={t('cl.c_phone')} htmlFor="cl-cp"><input id="cl-cp" inputMode="tel" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} required /></Field>
            <Field label={t('cl.c_email')} htmlFor="cl-ce"><input id="cl-ce" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} required /></Field>
          </fieldset>
          <fieldset data-testid="states-of-interest"><legend>{t('cl.states_of_interest')}</legend>
            <div className="chips">{states.data?.map((s) => <label key={s.id} className="chip"><input type="checkbox" checked={statesOfInterest.includes(s.id)}
              disabled={s.id === st} onChange={() => toggle(interest, setInterest, s.id)} /> {s.name}</label>)}</div></fieldset>
          <fieldset data-testid="crops-of-interest"><legend>{t('cl.crops_of_interest')}</legend>
            <div className="chips">{crops.data?.filter((c) => !c.state_id || statesOfInterest.includes(c.state_id)).map((c) =>
              <label key={c.id} className="chip"><input type="checkbox" checked={cropIds.includes(c.id)} onChange={() => toggle(cropIds, setCropIds, c.id)} /> {c.name}</label>)}</div></fieldset>
          <Field label={t('cl.source')} htmlFor="cl-src"><select id="cl-src" value={f.source} onChange={(e) => setF({ ...f, source: e.target.value })}>
            <option value="">—</option>{['referral', 'outreach', 'event', 'inbound'].map((x) => <option key={x} value={x}>{t(`csrc.${x}`)}</option>)}</select></Field>
          <p className="small muted">{t('cl.code_made')}</p>
          <ErrorBox error={make.error} />
          <button disabled={make.busy || cropIds.length === 0 || !st} data-testid="client-create">{t('cl.create')}</button>
        </form>)}
    </div>
  );
}

function SharedIdentity({ id }: { id: ClientView['identity'] }) {
  const { t } = useI18n();
  return (
    <dl className="kv" data-testid="shared-identity">
      <dt>{t('cl.legal_name')}</dt><dd>{id.legal_name}</dd>
      <dt>PAN</dt><dd className="mono">{id.pan_pending ? t('cl.pan_pending') : id.pan_masked}</dd>
      <dt>{t('cl.entity_type')}</dt><dd>{t(`etype.${id.entity_type}`)}</dd>
      <dt>{t('cl.office')}</dt><dd>{[id.office_city, id.office_state].filter(Boolean).join(', ') || '—'}</dd>
      <dt>{t('cl.status')}</dt><dd><StatusBadge s={id.status} /></dd>
      <dt>{t('cl.code')}</dt><dd className="mono">{id.code}</dd>
    </dl>
  );
}

// ── the record ───────────────────────────────────────────────────────────────────────────────────────────────────────
export function ClientPage() {
  const { id = '' } = useParams();
  const { t } = useI18n();
  const v = useAsync(() => clientView(id), [id]);
  const d = v.data;
  if (v.loading && !d) return <Loading />;
  if (!d) return <ErrorBox error={v.error} onRetry={v.reload} />;
  const idn = d.identity;
  return (
    <div data-testid="client-page">
      <p><Link to="/clients">← {t('clients.title')}</Link></p>
      <h1>{idn.name} <span className="mono small">{idn.code}</span></h1>
      <div className="row wrap" style={{ gap: 6 }}><StatusBadge s={idn.status} /><Flags panPending={idn.pan_pending} ownBrand={idn.own_brand} /></div>
      {idn.own_brand && <p className="small" data-testid="own-brand-note">{t('cl.own_brand_note')}</p>}
      {d.shared_only ? (
        <div className="card"><SharedIdentity id={idn} /><p className="small muted" data-testid="shared-only">{t('cl.shared_only')}</p>
          <AddStates client={idn.client_id} states={d.may.add_states ?? []} after={v.reload} /></div>
      ) : <>
        {(d.may.set_status || d.may.approve) && <ClientExpiries client={idn.client_id} />}
        <IdentityCard d={d} reload={v.reload} />
        {!!d.may.add_states?.length && <div className="card"><AddStates client={idn.client_id} states={d.may.add_states} after={v.reload} /></div>}
        {d.states.map((s) => <StateCard key={s.state_id} d={d} s={s} reload={v.reload} />)}
        {(d.may.renew || d.may.set_status || d.may.approve) && <Renewals d={d} reload={v.reload} />}
      </>}
    </div>
  );
}

function IdentityCard({ d, reload }: { d: ClientView; reload: () => void }) {
  const { t } = useI18n();
  const idn = d.identity;
  const [panning, setPanning] = useState(false); const [editing, setEditing] = useState(false);
  return (
    <div className="card" data-testid="identity">
      <h2>{t('cl.identity')}</h2>
      <dl className="kv">
        <dt>{t('cl.legal_name')}</dt><dd data-testid="legal-name">{idn.legal_name}</dd>
        {idn.trade_name && <><dt>{t('cl.trade_name')}</dt><dd>{idn.trade_name}</dd></>}
        <dt>{t('cl.entity_type')}</dt><dd>{t(`etype.${idn.entity_type}`)}</dd>
        <dt>PAN</dt><dd className="mono" data-testid="pan">{idn.pan_pending ? t('cl.pan_pending') : (idn.pan ?? idn.pan_masked)}</dd>
        {d.national?.reg_number && <><dt>{t(`idk.${d.national.reg_number.kind}`)}</dt><dd className="mono">{d.national.reg_number.value ?? d.national.reg_number.masked}</dd></>}
        <dt>{t('cl.office')}</dt><dd>{[idn.reg_office?.address, idn.reg_office?.city, idn.reg_office?.state].filter(Boolean).join(', ') || '—'}</dd>
        <dt>{t('cl.contact')}</dt><dd data-testid="contact">{[d.contact?.name, d.contact?.designation, d.contact?.phone, d.contact?.email].filter(Boolean).join(' · ') || '—'}</dd>
        <dt>{t('cl.states_of_interest')}</dt><dd>{d.states_of_interest?.map((s) => s.name).join(', ') || '—'}</dd>
        <dt>{t('cl.crops_of_interest')}</dt><dd>{d.crops_of_interest?.map((s) => s.name).join(', ') || '—'}</dd>
        {d.source && <><dt>{t('cl.source')}</dt><dd>{t(`csrc.${d.source}`)}</dd></>}
        {d.national?.iec && <><dt>IEC</dt><dd className="mono">{d.national.iec.value ?? d.national.iec.masked}</dd></>}
        {d.national?.rcmc && <><dt>RCMC</dt><dd className="mono">{d.national.rcmc.value ?? d.national.rcmc.masked} · {t('cl.expires', { on: date(d.national.rcmc.expires_on) })}</dd></>}
        {idn.approved_at && <><dt>{t('cl.approved')}</dt><dd>{dateTime(idn.approved_at)}</dd></>}
      </dl>
      {!!d.national?.documents.length && <DocList docs={d.national.documents} title={t('cl.national_docs')} />}
      <div className="row wrap">
        {d.may.set_pan && <button className="secondary" onClick={() => setPanning(!panning)} data-testid="set-pan-open">{t('cl.set_pan')}</button>}
        {d.may.edit_identity && <button className="secondary" onClick={() => setEditing(!editing)} data-testid="edit-identity-open">{t('cl.edit_identity')}</button>}
      </div>
      {d.may.approve && d.states.length > 1 && <StatusActions client={idn.client_id} state={null} status={idn.status} reload={reload} />}
      {panning && <SetPanForm client={idn.client_id} type={idn.entity_type} done={() => { setPanning(false); reload(); }} />}
      {editing && <IdentityForm d={d} done={() => { setEditing(false); reload(); }} />}
    </div>
  );
}

function SetPanForm({ client, type: t0, done }: { client: string; type: EntityType; done: () => void }) {
  const { t } = useI18n();
  const [pan, setPanText] = useState(''); const [type, setType] = useState<EntityType>(t0);
  const act = useAction();
  const problem = pan ? panProblem(pan, type) : null;
  return (
    <form className="stack" data-testid="set-pan" onSubmit={(e) => { e.preventDefault(); void act.run(async () => { await setPan(client, pan, type); done(); }); }}>
      <Field label={t('cl.entity_type')} htmlFor="sp-type"><select id="sp-type" value={type} onChange={(e) => setType(e.target.value as EntityType)}>
        {ENTITY_TYPES.map((x) => <option key={x} value={x}>{t(`etype.${x}`)} ({PAN_LETTER[x]})</option>)}</select></Field>
      <Field label="PAN" htmlFor="sp-pan"><input id="sp-pan" className="mono" value={pan} maxLength={10} onChange={(e) => setPanText(e.target.value.toUpperCase())} required /></Field>
      {problem && <p className="small text-danger">{t(`cl.pan_${problem}`, { letter: PAN_LETTER[type] })}</p>}
      <ErrorBox error={act.error} /><button disabled={act.busy || !!problem}>{t('common.save')}</button>
    </form>
  );
}

function IdentityForm({ d, done }: { d: ClientView; done: () => void }) {
  const { t } = useI18n();
  const idn = d.identity;
  const [f, setF] = useState({ legal_name: idn.legal_name, code: idn.code, reg_number: '', pan: '', reason: '' });
  const act = useAction();
  const kind = regKind(idn.entity_type);
  const submit = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    const p: Record<string, unknown> = {};
    if (f.legal_name !== idn.legal_name) p.legal_name = f.legal_name;
    if (d.may.edit_code && f.code.toUpperCase() !== idn.code) p.code = f.code.toUpperCase();
    if (f.reg_number) p.reg_number = f.reg_number;
    if (f.pan && !idn.pan_pending) p.pan = f.pan;
    await editIdentity(idn.client_id, p, f.reason); done();
  }); };
  return (
    <form className="stack" onSubmit={submit} data-testid="identity-form">
      <Field label={t('cl.legal_name')} htmlFor="id-legal"><input id="id-legal" value={f.legal_name} onChange={(e) => setF({ ...f, legal_name: e.target.value })} /></Field>
      {d.may.edit_code && <Field label={t('cl.code')} hint={t('cl.code_once')} htmlFor="id-code"><input id="id-code" className="mono" value={f.code} maxLength={5} onChange={(e) => setF({ ...f, code: e.target.value.toUpperCase() })} /></Field>}
      {kind && <Field label={t(`idk.${kind}`)} htmlFor="id-reg"><input id="id-reg" className="mono" value={f.reg_number} onChange={(e) => setF({ ...f, reg_number: e.target.value })} /></Field>}
      {!idn.pan_pending && <Field label={t('cl.new_pan')} htmlFor="id-pan"><input id="id-pan" className="mono" value={f.pan} maxLength={10} onChange={(e) => setF({ ...f, pan: e.target.value.toUpperCase() })} /></Field>}
      <Field label={t('cl.reason')} htmlFor="id-why"><input id="id-why" value={f.reason} minLength={10} onChange={(e) => setF({ ...f, reason: e.target.value })} required /></Field>
      <ErrorBox error={act.error} /><button disabled={act.busy}>{t('common.save')}</button>
    </form>
  );
}

function DocList({ docs, title }: { docs: Doc[]; title: string }) {
  const { t } = useI18n();
  const act = useAction();
  return (
    <div><h3>{title}</h3>
      <ul className="small" data-testid="doc-list">{docs.map((x) => (
        <li key={x.id} data-testid="doc" data-kind={x.kind}>
          {x.path ? <button type="button" className="linkish" onClick={() => void act.run(() => openDocument(x))}>{t(`cdoc.${x.kind}`)}</button>
            : <span data-testid="doc-on-file">{t(`cdoc.${x.kind}`)}: {t('cl.on_file')}</span>}
          {x.signed_on && <> · {t('cl.signed', { on: date(x.signed_on) })}</>}
          {x.term_end && <> · {t('cl.term_end', { on: date(x.term_end) })}</>}
          {x.expires_on && <> · {t('cl.expires', { on: date(x.expires_on) })}</>}
          {x.amount != null && <> · ₹{x.amount}</>}
          <span className="muted mono"> · {x.sha256.slice(0, 10)}…</span>
        </li>))}</ul>
      <ErrorBox error={act.error} />
    </div>
  );
}

export function Checklist({ g }: { g: Gates }) {
  const { t } = useI18n();
  return (
    <div data-testid="gates">
      {g.gates.map((gate) => {
        const n = gateCount(g, gate.gate);
        return (
          <details key={gate.gate} open={n.done < n.of} data-testid="gate" data-gate={gate.gate} data-done={n.done} data-of={n.of}>
            <summary><strong>{t(`cl.gate${gate.gate}`)}</strong> · {t('cl.progress', { done: n.done, of: n.of })}</summary>
            <ul className="small" style={{ listStyle: 'none', paddingLeft: 4 }}>
              {gate.items.filter((i) => i.needed).map((i) => (
                <li key={i.key} data-testid="gate-item" data-key={i.key} data-done={i.done ? 'yes' : 'no'}>
                  <span aria-hidden="true">{i.done ? '✓' : '○'}</span> {t(`cg.${i.key}`)}
                </li>))}
            </ul>
          </details>);
      })}
    </div>
  );
}

function StateCard({ d, s, reload }: { d: ClientView; s: StateRow; reload: () => void }) {
  const { t } = useI18n();
  const mine = !!d.may.edit_states?.includes(s.state_id);
  const act = useAction();
  const [why, setWhy] = useState(''); const [declining, setDeclining] = useState(false);
  const nx = nextMove(s.gates, s);
  const run = (fn: () => Promise<unknown>) => void act.run(async () => { await fn(); reload(); });
  return (
    <div className="card" data-testid="client-state-card" data-state={s.state} data-status={s.status}>
      <div className="row wrap" style={{ justifyContent: 'space-between' }}><h2>{s.state}</h2><StatusBadge s={s.status} /></div>
      {s.legacy && <p className="small muted" data-testid="legacy-note">{t('cl.legacy')}</p>}
      {s.activation_requested_at && <div className="alert info" data-testid="awaiting-approval">{t('cl.awaiting_approval_since', { at: dateTime(s.activation_requested_at) })}</div>}
      {s.status === 'suspended' && <div className="alert warn" data-testid="status-note">{t('cl.suspended_note')}{s.status_reason && <> · {s.status_reason}</>}</div>}
      {s.status === 'ended' && <div className="alert info" data-testid="status-note">{t('cl.ended_note', { on: date(s.ended_on ?? null) })}{s.status_reason && <> · {s.status_reason}</>}</div>}
      <dl className="kv small">
        <dt>GSTIN</dt><dd className="mono" data-testid="gstin">{s.gstin ? (s.gstin.value ?? s.gstin.masked) : s.gst_not_registered_reason ? t('cl.no_gst', { why: s.gst_not_registered_reason }) : '—'}</dd>
        {(s.signatory.name || s.signatory.designation) && <><dt>{t('cl.signatory')}</dt><dd>{[s.signatory.name, s.signatory.designation].filter(Boolean).join(', ')}</dd></>}
        <dt>{t('cl.billing')}</dt><dd>{[s.billing.contact, s.billing.email].filter(Boolean).join(' · ') || '—'}</dd>
        {(s.state_contact.name || s.state_contact.phone) && <><dt>{t('cl.state_contact')}</dt><dd>{[s.state_contact.name, s.state_contact.designation, s.state_contact.phone, s.state_contact.email].filter(Boolean).join(' · ')}</dd></>}
        {s.brand_on_pack && <><dt>{t('cl.brand_on_pack')}</dt><dd>{t('common.yes')}</dd></>}
        {s.fssai && <><dt>FSSAI</dt><dd className="mono">{s.fssai.value ?? s.fssai.masked} · {t('cl.expires', { on: date(s.fssai.expires_on) })}</dd></>}
        {s.kyc_at && <><dt>KYC</dt><dd data-testid="kyc-done">{t('cl.kyc_by', { by: s.kyc_by ?? '—', at: dateTime(s.kyc_at) })}</dd></>}
      </dl>
      {s.gates && <Checklist g={s.gates} />}
      {!!s.documents.length && <DocList docs={s.documents} title={t('cl.state_docs')} />}

      {mine && s.status !== 'suspended' && s.status !== 'ended' && <DetailsForm d={d} s={s} reload={reload} />}
      {mine && s.status !== 'suspended' && s.status !== 'ended' && <Uploads d={d} s={s} reload={reload} />}

      {mine && nx.to && (
        <div className="row wrap">
          {nx.to === 'diagnostic' && <button disabled={!nx.ready || act.busy} data-testid="move-diagnostic" onClick={() => run(() => moveClient(d.identity.client_id, s.state_id, 'diagnostic'))}>{t('cl.to_diagnostic')}</button>}
          {nx.to === 'kyc' && <button disabled={!nx.ready || act.busy} data-testid="kyc-tick" onClick={() => run(() => kycTick(d.identity.client_id, s.state_id))}>{t('cl.kyc_tick')}</button>}
          {nx.to === 'active' && <button disabled={!nx.ready || act.busy} data-testid="move-active" onClick={() => run(() => moveClient(d.identity.client_id, s.state_id, 'active'))}>{d.identity.approved_at ? t('cl.to_active') : t('cl.request_active')}</button>}
          {!nx.ready && <span className="small muted">{t('cl.complete_first')}</span>}
        </div>)}
      {d.may.approve && s.activation_requested_at && (
        <div className="stack" data-testid="approval">
          <div className="row wrap">
            <button disabled={act.busy} data-testid="approve" onClick={() => run(() => decideActivation(d.identity.client_id, s.state_id, true))}>{t('cl.approve')}</button>
            <button className="secondary" onClick={() => setDeclining(!declining)} data-testid="decline-open">{t('cl.decline')}</button>
          </div>
          {declining && <div className="row wrap"><input aria-label={t('cl.reason')} value={why} onChange={(e) => setWhy(e.target.value)} data-testid="decline-why" />
            <button disabled={act.busy || why.trim().length < 10} data-testid="decline-go" onClick={() => run(() => decideActivation(d.identity.client_id, s.state_id, false, why))}>{t('cl.decline')}</button></div>}
        </div>)}
      {(mine || d.may.approve) && (!s.status_by_admin || d.may.approve || (s.status !== 'suspended' && s.status !== 'ended')) &&
        <StatusActions client={d.identity.client_id} state={s.state_id} status={s.status} reload={reload} />}
      <ErrorBox error={act.error} />
      {!!s.events.length && <details className="small"><summary>{t('cl.history')}</summary><ul data-testid="client-events">{s.events.map((e, i) => (
        <li key={i}>{dateTime(e.at)} · {t(`cev.${e.act}`, undefined, e.act)}{e.to && e.from !== e.to && <> · {t(`cst.${e.to}`)}</>}{e.by && <> · {e.by}</>}{e.reason && <> · {e.reason}</>}</li>))}</ul></details>}
    </div>
  );
}

// the State Manager's details for his state (Gate 2 and 3's fields), and the national ones while not Active
function DetailsForm({ d, s, reload }: { d: ClientView; s: StateRow; reload: () => void }) {
  const { t } = useI18n();
  const idn = d.identity;
  const kind = regKind(idn.entity_type);
  const locked = !!idn.approved_at;           // national identity is the admin's after Active
  const [f, setF] = useState({
    office_address: idn.reg_office?.address ?? '', office_city: idn.reg_office?.city ?? '', office_state: idn.reg_office?.state ?? '',
    reg_number: '', gstin: '', no_gst: !!s.gst_not_registered_reason, gst_reason: s.gst_not_registered_reason ?? '',
    sig_name: s.signatory.name ?? '', sig_designation: s.signatory.designation ?? '',
    bill_contact: s.billing.contact ?? '', bill_email: s.billing.email ?? '', brand_on_pack: s.brand_on_pack,
    fssai: '', fssai_exp: s.fssai?.expires_on ?? '', iec: '', rcmc: '', rcmc_exp: d.national?.rcmc?.expires_on ?? '',
  });
  const act = useAction(); const [saved, setSaved] = useState(false);
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => { setF({ ...f, [k]: e.target.value }); setSaved(false); };
  const submit = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    const p: Record<string, unknown> = {};
    if (f.office_address !== (idn.reg_office?.address ?? '') || f.office_city !== (idn.reg_office?.city ?? '') || f.office_state !== (idn.reg_office?.state ?? ''))
      p.reg_office = { address: f.office_address, city: f.office_city, state: f.office_state };
    if (kind && f.reg_number && !locked) p.reg_number = f.reg_number;
    if (f.no_gst) { if (f.gst_reason !== (s.gst_not_registered_reason ?? '')) p.gst_not_registered_reason = f.gst_reason; }
    else if (f.gstin) p.gstin = f.gstin;
    if (f.sig_name !== (s.signatory.name ?? '') || f.sig_designation !== (s.signatory.designation ?? '')) p.signatory = { name: f.sig_name, designation: f.sig_designation };
    if (f.bill_contact !== (s.billing.contact ?? '') || f.bill_email !== (s.billing.email ?? '')) p.billing = { contact: f.bill_contact, email: f.bill_email };
    if (f.brand_on_pack !== s.brand_on_pack) p.brand_on_pack = f.brand_on_pack;
    if (f.fssai) p.fssai = { number: f.fssai, expires_on: f.fssai_exp };
    if (f.iec) p.iec = f.iec;
    if (f.rcmc) p.rcmc = { number: f.rcmc, expires_on: f.rcmc_exp };
    if (Object.keys(p).length) await saveDetails(idn.client_id, s.state_id, p);
    setSaved(true); reload();
  }); };
  const ex = d.exports ?? { export: false, apeda: false };
  return (
    <form className="stack" onSubmit={submit} data-testid="details-form">
      <h3>{t('cl.details')}</h3>
      <fieldset><legend>{t('cl.office')}</legend>
        <Field label={t('cl.address')} htmlFor="df-oa"><input id="df-oa" value={f.office_address} onChange={set('office_address')} /></Field>
        <div className="row wrap">
          <Field label={t('cl.city')} htmlFor="df-oc"><input id="df-oc" value={f.office_city} onChange={set('office_city')} /></Field>
          <Field label={t('cl.office_state')} htmlFor="df-os"><input id="df-os" value={f.office_state} onChange={set('office_state')} /></Field>
        </div>
      </fieldset>
      {kind && !locked && <Field label={t(`idk.${kind}`)} hint={d.national?.reg_number ? t('cl.on_file') : undefined} htmlFor="df-reg">
        <input id="df-reg" className="mono" value={f.reg_number} onChange={set('reg_number')} placeholder={d.national?.reg_number?.masked ?? ''} /></Field>}
      <fieldset><legend>GSTIN · {s.state}</legend>
        <label className="row"><input type="checkbox" checked={f.no_gst} onChange={(e) => setF({ ...f, no_gst: e.target.checked })} data-testid="no-gst" /> {t('cl.no_gst_choice')}</label>
        {f.no_gst
          ? <Field label={t('cl.reason')} htmlFor="df-gr"><input id="df-gr" value={f.gst_reason} onChange={set('gst_reason')} /></Field>
          : <Field label="GSTIN" hint={s.gstin ? t('cl.on_file') : t('cl.gstin_hint')} htmlFor="df-gst"><input id="df-gst" className="mono" maxLength={15} value={f.gstin} onChange={set('gstin')} placeholder={s.gstin?.masked ?? ''} /></Field>}
      </fieldset>
      <div className="row wrap">
        <Field label={t('cl.signatory_name')} htmlFor="df-sn"><input id="df-sn" value={f.sig_name} onChange={set('sig_name')} /></Field>
        <Field label={t('cl.c_designation')} htmlFor="df-sd"><input id="df-sd" value={f.sig_designation} onChange={set('sig_designation')} /></Field>
      </div>
      <div className="row wrap">
        <Field label={t('cl.billing_contact')} htmlFor="df-bc"><input id="df-bc" value={f.bill_contact} onChange={set('bill_contact')} /></Field>
        <Field label={t('cl.invoice_email')} htmlFor="df-be"><input id="df-be" type="email" value={f.bill_email} onChange={set('bill_email')} /></Field>
      </div>
      <label className="row"><input type="checkbox" checked={f.brand_on_pack} onChange={(e) => setF({ ...f, brand_on_pack: e.target.checked })} data-testid="brand-on-pack" /> {t('cl.brand_on_pack_q')}</label>
      {f.brand_on_pack && <div className="row wrap">
        <Field label={t('cl.fssai')} hint={s.fssai ? t('cl.on_file') : undefined} htmlFor="df-fs"><input id="df-fs" className="mono" inputMode="numeric" maxLength={14} value={f.fssai} onChange={set('fssai')} placeholder={s.fssai?.masked ?? ''} /></Field>
        <Field label={t('cl.expiry')} htmlFor="df-fe"><input id="df-fe" type="date" value={f.fssai_exp} onChange={set('fssai_exp')} /></Field>
      </div>}
      {ex.export && <Field label="IEC" hint={d.national?.iec ? t('cl.on_file') : t('cl.export_needs')} htmlFor="df-iec"><input id="df-iec" className="mono" maxLength={10} value={f.iec} onChange={set('iec')} placeholder={d.national?.iec?.masked ?? ''} /></Field>}
      {ex.apeda && <div className="row wrap">
        <Field label={t('cl.rcmc')} hint={d.national?.rcmc ? t('cl.on_file') : undefined} htmlFor="df-rc"><input id="df-rc" className="mono" value={f.rcmc} onChange={set('rcmc')} placeholder={d.national?.rcmc?.masked ?? ''} /></Field>
        <Field label={t('cl.expiry')} htmlFor="df-re"><input id="df-re" type="date" value={f.rcmc_exp} onChange={set('rcmc_exp')} /></Field>
      </div>}
      <ErrorBox error={act.error} />
      <div className="row"><button disabled={act.busy} data-testid="details-save">{t('common.save')}</button>{saved && <span className="small" data-testid="details-saved">{t('cl.saved')}</span>}</div>
    </form>
  );
}

// the documents the gates ask, each uploaded with what it needs (dates, amount)
const DOC_FIELDS: Record<DocKind, ('signed_on' | 'term_end' | 'expires_on' | 'amount')[]> = {
  diagnostic_order: ['signed_on', 'amount'], incorporation: [], msa: ['signed_on', 'term_end'], consent_addendum: ['signed_on'],
  signatory_authority: [], fssai: ['expires_on'], iec: [], rcmc: ['expires_on'],
};
function Uploads({ d, s, reload }: { d: ClientView; s: StateRow; reload: () => void }) {
  const { t } = useI18n();
  const needed = (s.gates?.gates.flatMap((g) => g.items) ?? []).filter((i) => i.needed).map((i) => i.key);
  const kinds = (Object.keys(DOC_FIELDS) as DocKind[]).filter((k) => needed.includes(k) && (d.may.national_docs !== false || !NATIONAL_DOCS.includes(k)));
  const [kind, setKind] = useState<DocKind | ''>(''); const [file, setFile] = useState<File | null>(null);
  const [meta, setMeta] = useState<Record<string, string>>({});
  const act = useAction();
  if (!kinds.length) return null;
  const have = (k: DocKind) => (NATIONAL_DOCS.includes(k) ? d.national?.documents ?? [] : s.documents).some((x) => x.kind === k);
  const submit = (e: FormEvent) => { e.preventDefault(); if (!kind || !file) return; void act.run(async () => {
    await addDocument(d.identity.client_id, s.state_id, kind, file, Object.fromEntries(Object.entries(meta).filter(([, v]) => v !== '')));
    setKind(''); setFile(null); setMeta({}); reload();
  }); };
  return (
    <form className="stack" onSubmit={submit} data-testid="doc-upload">
      <h3>{t('cl.add_document')}</h3>
      <Field label={t('cl.document')} htmlFor="du-kind"><select id="du-kind" value={kind} onChange={(e) => { setKind(e.target.value as DocKind); setMeta({}); }} required>
        <option value="">—</option>{kinds.map((k) => <option key={k} value={k}>{t(`cdoc.${k}`)}{have(k) ? ` (${t('cl.on_file')})` : ''}</option>)}</select></Field>
      {kind && DOC_FIELDS[kind].map((m) => (
        <Field key={m} label={t(`cl.meta_${m}`)} htmlFor={`du-${m}`}>
          <input id={`du-${m}`} type={m === 'amount' ? 'number' : 'date'} min={m === 'amount' ? 0 : undefined} value={meta[m] ?? ''} required
            onChange={(e) => setMeta({ ...meta, [m]: e.target.value })} /></Field>))}
      <Field label={t('cl.file')} htmlFor="du-file"><input id="du-file" type="file" accept={docAccept} onChange={(e) => setFile(e.target.files?.[0] ?? null)} required /></Field>
      <ErrorBox error={act.error} />
      <button disabled={act.busy || !kind || !file} data-testid="doc-save">{t('cl.upload')}</button>
    </form>
  );
}


// ── migration 65 ─────────────────────────────────────────────────────────────────────────────────────────────────────
/** Part C: "Add [my state] to this client", one button per state of his own the client is not in yet. */
function AddStates({ client, states, after }: { client: string; states: { id: string; name: string }[]; after?: () => void }) {
  const { t } = useI18n();
  const nav = useNavigate();
  const act = useAction();
  if (!states.length) return null;
  return (
    <div className="stack" data-testid="add-states">
      <p className="small muted">{t('cl.add_state_note')}</p>
      <div className="row wrap">{states.map((x) => (
        <button key={x.id} disabled={act.busy} data-testid="add-state" data-state={x.name}
          onClick={() => void act.run(async () => { await addClientState(client, x.id); if (after) after(); else nav(`/clients/${client}`); })}>
          {t('cl.add_state', { state: x.name })}</button>))}</div>
      <ErrorBox error={act.error} />
    </div>
  );
}

/** Part D: suspend, resume, end, return — in one state (its State Manager, the admin) or in every state (the admin). */
function StatusActions({ client, state, status, reload }: { client: string; state: string | null; status: ClientStatus; reload: () => void }) {
  const { t } = useI18n();
  const act = useAction();
  const [move, setMove] = useState<StatusMove | null>(null); const [why, setWhy] = useState('');
  const moves: StatusMove[] = state ? statusMoves(status) : ['suspended', 'active', 'ended'];
  const pre = state ? 'status' : 'national';
  const go = () => void act.run(async () => { await setClientStatus(client, state, move!, why); setMove(null); setWhy(''); reload(); });
  return (
    <div className="stack" data-testid={`${pre}-actions`}>
      {!state && <p className="small muted">{t('cl.all_states_note')}</p>}
      <div className="row wrap">{moves.map((m) => (
        <button key={m} type="button" className={m === 'ended' || m === 'suspended' ? 'secondary danger' : 'secondary'} data-testid={`${pre}-${m}`}
          aria-pressed={move === m} onClick={() => setMove(move === m ? null : m)}>{t(`cl.move_${m}${state ? '' : '_all'}`)}</button>))}</div>
      {move && <div className="row wrap">
        <input aria-label={t('cl.reason')} value={why} onChange={(e) => setWhy(e.target.value)} data-testid={`${pre}-why`} placeholder={t('cl.reason_10')} />
        <button disabled={act.busy || why.trim().length < 10} data-testid={`${pre}-go`} onClick={go}>{t(`cl.move_${move}${state ? '' : '_all'}`)}</button></div>}
      <ErrorBox error={act.error} />
    </div>
  );
}

function ExpiryLine({ x, showClient }: { x: Expiry; showClient: boolean }) {
  const { t } = useI18n();
  return (
    <li data-testid="expiry" data-kind={x.kind} data-level={x.level} data-client={x.code}>
      <span className={`badge ${x.level === 'expired' ? 'open' : 'pending'}`}>{t(`exp.${x.level}`)}</span>{' '}
      {showClient && <><Link to={`/clients/${x.client_id}`}>{x.name}</Link> · </>}
      {t(`exp.kind_${x.kind}`)}{x.state && <> · {x.state}</>} · {x.level === 'expired' ? t('exp.expired_on', { on: date(x.expires_on) }) : t('exp.expires_in', { n: x.days_left, on: date(x.expires_on) })}
    </li>
  );
}
/** The warnings before a licence or the MSA expires (60 and 15 days ahead, and after): renew, or suspend. */
function ExpiryCard() {
  const { t } = useI18n();
  const ex = useAsync(() => clientExpiries().catch(() => [] as Expiry[]), []);
  if (!ex.data?.length) return null;
  return (
    <div className="card" data-testid="expiries"><h2>{t('exp.title')}</h2>
      <ul className="small" style={{ listStyle: 'none', paddingLeft: 0 }}>{ex.data.map((x) => <ExpiryLine key={`${x.client_id}-${x.kind}-${x.state_id ?? ''}`} x={x} showClient />)}</ul>
      <p className="small muted">{t('exp.note')}</p>
    </div>
  );
}
function ClientExpiries({ client }: { client: string }) {
  const { t } = useI18n();
  const ex = useAsync(() => clientExpiries().catch(() => [] as Expiry[]), [client]);
  const mine = (ex.data ?? []).filter((x) => x.client_id === client);
  if (!mine.length) return null;
  return (
    <div className="alert warn" role="alert" data-testid="client-expiries">
      <strong>{t('exp.title')}</strong>
      <ul className="small" style={{ listStyle: 'none', paddingLeft: 0, margin: '4px 0' }}>{mine.map((x) => <ExpiryLine key={`${x.kind}-${x.state_id ?? ''}`} x={x} showClient={false} />)}</ul>
      <span className="small">{t('exp.note')}</span>
    </div>
  );
}

const RENEWAL_FIELDS: Record<RenewalKind, ('signed_on' | 'term_end' | 'expires_on')[]> = { fssai: ['expires_on'], rcmc: ['expires_on'], msa: ['signed_on', 'term_end'] };
/** B5: the client's own login uploads a renewed licence or agreement; its State Manager accepts it (or declines, with a reason). */
function Renewals({ d, reload }: { d: ClientView; reload: () => void }) {
  const { t } = useI18n();
  const client = d.identity.client_id;
  const list = useAsync(() => clientRenewals(client).catch(() => []), [client]);
  const act = useAction();
  const [kind, setKind] = useState<RenewalKind | ''>(''); const [state, setState] = useState(''); const [file, setFile] = useState<File | null>(null);
  const [meta, setMeta] = useState<Record<string, string>>({});
  const [declining, setDeclining] = useState<string | null>(null); const [why, setWhy] = useState('');
  const owner = !!d.may.renew;                       // the client's own login (the server says so)
  const rows = list.data ?? [];
  if (!owner && !rows.length) return null;
  const submit = (e: FormEvent) => { e.preventDefault(); if (!kind || !file) return; void act.run(async () => {
    await proposeRenewal(client, kind === 'fssai' ? state : null, kind, file, Object.fromEntries(Object.entries(meta).filter(([, v]) => v !== '')));
    setKind(''); setFile(null); setMeta({}); setState(''); list.reload();
  }); };
  const decide = (id: string, ok: boolean) => void act.run(async () => { await decideRenewal(id, ok, ok ? undefined : why); setDeclining(null); setWhy(''); list.reload(); reload(); });
  return (
    <div className="card" data-testid="renewals"><h2>{t('rn.title')}</h2>
      {rows.length > 0 && <ul className="small" style={{ listStyle: 'none', paddingLeft: 0 }}>{rows.map((r) => (
        <li key={r.id} data-testid="renewal" data-kind={r.kind} data-state={r.state ?? ''} data-decided={r.decided_at ? (r.accepted ? 'accepted' : 'declined') : 'waiting'}>
          <button type="button" className="linkish" onClick={() => void act.run(() => openPath(r.path))}>{t(`cdoc.${r.kind}`)}</button>
          {r.state && <> · {r.state}</>}
          {r.expires_on && <> · {t('cl.expires', { on: date(r.expires_on) })}</>}{r.term_end && <> · {t('cl.term_end', { on: date(r.term_end) })}</>}
          {' · '}{r.decided_at ? (r.accepted ? t('rn.accepted') : t('rn.declined', { why: r.reason ?? '' })) : t('rn.waiting')}
          {r.may_decide && <div className="row wrap" style={{ marginTop: 4 }}>
            <button disabled={act.busy} data-testid="renewal-accept" onClick={() => decide(r.id, true)}>{t('rn.accept')}</button>
            <button className="secondary" data-testid="renewal-decline-open" onClick={() => setDeclining(declining === r.id ? null : r.id)}>{t('cl.decline')}</button>
            {declining === r.id && <><input aria-label={t('cl.reason')} value={why} onChange={(e) => setWhy(e.target.value)} data-testid="renewal-why" />
              <button disabled={act.busy || why.trim().length < 10} data-testid="renewal-decline" onClick={() => decide(r.id, false)}>{t('cl.decline')}</button></>}
          </div>}
        </li>))}</ul>}
      {owner && <form className="stack" onSubmit={submit} data-testid="renewal-form">
        <p className="small muted">{t('rn.note')}</p>
        <Field label={t('cl.document')} htmlFor="rn-kind"><select id="rn-kind" value={kind} onChange={(e) => { setKind(e.target.value as RenewalKind); setMeta({}); }} required>
          <option value="">—</option>{(['fssai', 'rcmc', 'msa'] as RenewalKind[]).map((k) => <option key={k} value={k}>{t(`cdoc.${k}`)}</option>)}</select></Field>
        {kind === 'fssai' && <Field label={t('lens.state')} htmlFor="rn-state"><select id="rn-state" value={state} onChange={(e) => setState(e.target.value)} required>
          <option value="">—</option>{d.states.map((x) => <option key={x.state_id} value={x.state_id}>{x.state}</option>)}</select></Field>}
        {kind && RENEWAL_FIELDS[kind].map((m) => (
          <Field key={m} label={t(`cl.meta_${m}`)} htmlFor={`rn-${m}`}>
            <input id={`rn-${m}`} type="date" value={meta[m] ?? ''} required onChange={(e) => setMeta({ ...meta, [m]: e.target.value })} /></Field>))}
        <Field label={t('cl.file')} htmlFor="rn-file"><input id="rn-file" type="file" accept={docAccept} onChange={(e) => setFile(e.target.files?.[0] ?? null)} required /></Field>
        <button disabled={act.busy || !kind || !file || (kind === 'fssai' && !state)} data-testid="renewal-save">{t('rn.upload')}</button>
      </form>}
      <ErrorBox error={act.error} />
    </div>
  );
}
