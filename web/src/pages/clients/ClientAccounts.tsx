// Migration 67 (Phase 3, release 1, Part A): the client's own accounts, on the client's page. The admin makes an owner;
// an owner invites viewers (any of its scopes) and allows internal copies; the Client Manager makes viewers of one
// state and the client's own staff. Who may do what is the database's (app.client_may, app.may_manage_account); the
// card shows what the server says the reader may.
import { useEffect, useState, type FormEvent, type ReactNode } from 'react';
import { useI18n } from '../../lib/i18n';
import { useAction, useAsync } from '../../lib/useAsync';
import { Badge, ErrorBox, Field, Loading } from '../../shell/ui';
import { TempPassword } from '../people/shared';
import { clientAccounts, makeClientAccount, makeOwner, reachLabel, setAccountStatus, setViewerInternal, setViewerReach,
  type AccountStatus, type ClientAccount, type ClientAccounts, type NewAccount, type Reach } from '../../lib/clientAccounts';
import type { ClientAccountKind } from '../../lib/types';
import { date } from '../../lib/format';

const STATUS_TONE: Record<AccountStatus, string> = { active: 'active', suspended: 'pending', removed: 'closed' };

export function ClientAccountsCard({ client }: { client: string }) {
  const { t } = useI18n();
  const v = useAsync(() => clientAccounts(client), [client]);
  const d = v.data;
  if (v.loading && !d) return <div className="card"><Loading /></div>;
  if (!d) return <div className="card"><ErrorBox error={v.error} onRetry={v.reload} /></div>;
  const makes = d.may.owner || d.may.viewer || d.may.operator;
  return (
    <div className="card" data-testid="client-accounts" id="accounts">
      <h2 style={{ marginTop: 0 }}>{t('ca.title')}</h2>
      <p className="small muted">{t('ca.note')}</p>
      {d.accounts.length === 0 && <p className="small" data-testid="ca-none">{t('ca.none')}</p>}
      <ul className="plain" style={{ listStyle: 'none', paddingLeft: 0 }}>
        {d.accounts.map((a) => <AccountRow key={a.id} a={a} info={d} reload={v.reload} />)}
      </ul>
      {makes && <NewClientAccount client={client} info={d} done={() => void v.reload()} title={t('ca.form_title')} label={t('ca.form_title')} />}
    </div>
  );
}

function AccountRow({ a, info, reload }: { a: ClientAccount; info: ClientAccounts; reload: () => void }) {
  const { t } = useI18n();
  const act = useAction();
  const [mode, setMode] = useState<null | AccountStatus | 'reach'>(null);
  const [why, setWhy] = useState('');
  const done = async () => { setMode(null); setWhy(''); reload(); };
  const status = (s: AccountStatus) => act.run(async () => { await setAccountStatus(a.id, s, why); await done(); });
  const scopeLabel = (id: string) => info.scopes.find((s) => s.id === id)?.label ?? id;
  return (
    <li className="assignment" data-testid="ca-row" data-kind={a.kind} data-status={a.status} style={{ marginBottom: 8 }}>
      <div className="row wrap" style={{ gap: 6, justifyContent: 'flex-start' }}>
        <strong>{a.name}</strong>
        <span className="badge lens">{t(`ca.kind.${a.kind}`)}</span>
        <Badge value={STATUS_TONE[a.status]} label={t(`ca.status.${a.status}`)} />
        {!a.has_login && a.status !== 'removed' && <span className="small muted">{t('ca.no_login')}</span>}
      </div>
      <div className="small muted">
        {a.email && <>{a.email} · </>}
        {a.kind !== 'operator' && <span data-testid="ca-reach">{reachLabel(a, t)}</span>}
        {a.kind === 'viewer' && a.internal_copies && <> · {t('ca.internal_yes')}</>}
        {a.kind === 'operator' && <span data-testid="ca-stages">{a.stages?.length
          ? t('ca.stages', { list: a.stages.map((s) => `${scopeLabel(s.scope_id)}: ${s.stages.map((x) => t(`stage.${x}`)).join(', ')}`).join(' · ') })
          : t('ca.no_stages')}</span>}
        {' · '}{date(a.created_at)}
        {a.status !== 'active' && a.status_reason && <> · “{a.status_reason}”</>}
      </div>
      {a.status !== 'removed' && (a.may.manage || a.may.internal || a.may.promote) && !mode && (
        <div className="row wrap" style={{ gap: 6, marginTop: 4, justifyContent: 'flex-start' }}>
          {a.may.manage && a.status === 'active' && <button type="button" className="secondary small-btn" onClick={() => setMode('suspended')} data-testid="ca-suspend">{t('ca.suspend')}</button>}
          {a.may.manage && a.status === 'suspended' && <button type="button" className="secondary small-btn" onClick={() => setMode('active')} data-testid="ca-resume">{t('ca.resume')}</button>}
          {a.may.manage && <button type="button" className="danger small-btn" onClick={() => setMode('removed')} data-testid="ca-remove">{t('ca.remove')}</button>}
          {a.may.manage && a.kind === 'viewer' && <button type="button" className="secondary small-btn" onClick={() => setMode('reach')} data-testid="ca-edit-reach">{t('ca.edit_reach')}</button>}
          {a.may.internal && <button type="button" className="secondary small-btn" data-testid="ca-internal"
            onClick={() => void act.run(async () => { await setViewerInternal(a.id, !a.internal_copies); reload(); })}>{t(a.internal_copies ? 'ca.deny_internal' : 'ca.allow_internal')}</button>}
          {a.may.promote && <button type="button" className="secondary small-btn" data-testid="ca-promote"
            onClick={() => void act.run(async () => { await makeOwner(a.id); reload(); })}>{t('ca.promote')}</button>}
        </div>)}
      {mode && mode !== 'reach' && (
        <div className="row wrap" style={{ gap: 6, marginTop: 4, justifyContent: 'flex-start' }}>
          {mode === 'removed' && <p className="small" style={{ width: '100%' }}>{t('ca.remove_final')}</p>}
          <input aria-label={t('ca.reason')} placeholder={t('ca.reason')} value={why} onChange={(e) => setWhy(e.target.value)} data-testid="ca-reason" style={{ flex: '1 1 200px' }} />
          <button type="button" className={mode === 'removed' ? 'danger' : ''} disabled={act.busy || why.trim().length < 5} onClick={() => void status(mode)} data-testid="ca-confirm">
            {t(mode === 'active' ? 'ca.resume' : mode === 'suspended' ? 'ca.suspend' : 'ca.remove')}</button>
          <button type="button" className="secondary" onClick={() => setMode(null)}>{t('common.cancel')}</button>
        </div>)}
      {mode === 'reach' && <ReachEditor a={a} info={info} done={() => void done()} cancel={() => setMode(null)} />}
      <ErrorBox error={act.error} />
    </li>
  );
}

function ReachEditor({ a, info, done, cancel }: { a: ClientAccount; info: ClientAccounts; done: () => void; cancel: () => void }) {
  const { t } = useI18n();
  const act = useAction();
  const [reach, setReach] = useState<Reach>(a.reach);
  const [state, setState] = useState<string>(a.state_id ?? info.states[0]?.id ?? '');
  const [scopes, setScopes] = useState<string[]>(a.scopes.map((s) => s.id));
  return (
    <div style={{ marginTop: 6 }} data-testid="ca-reach-editor">
      <ReachPicker info={info} reach={reach} setReach={setReach} state={state} setState={setState} scopes={scopes} setScopes={setScopes} idp={`re-${a.id}`} />
      <div className="row" style={{ gap: 6 }}>
        <button type="button" disabled={act.busy} onClick={() => void act.run(async () => { await setViewerReach(a.id, reach, state || null, scopes); done(); })}>{t('ca.save')}</button>
        <button type="button" className="secondary" onClick={cancel}>{t('common.cancel')}</button>
      </div>
      <ErrorBox error={act.error} />
    </div>
  );
}

/** What a viewer sees: the whole client (an owner's choice), one state's scopes, or the scopes chosen. */
function ReachPicker({ info, reach, setReach, state, setState, scopes, setScopes, idp }: {
  info: ClientAccounts; reach: Reach; setReach: (r: Reach) => void; state: string; setState: (s: string) => void;
  scopes: string[]; setScopes: (s: string[]) => void; idp: string;
}) {
  const { t } = useI18n();
  const reaches: Reach[] = info.may.viewer_whole_client ? ['client', 'state', 'scopes'] : ['state', 'scopes'];
  const shown = info.may.viewer_whole_client || !state ? info.scopes : info.scopes.filter((s) => s.state_id === state);
  return (
    <div className="form-grid">
      <Field label={t('ca.f_sees')} hint={info.may.viewer_whole_client ? undefined : t('ca.cm_one_state')} htmlFor={`${idp}-reach`}>
        <select id={`${idp}-reach`} value={reach} onChange={(e) => setReach(e.target.value as Reach)} data-testid="ca-reach-pick">
          {reaches.map((r) => <option key={r} value={r}>{t(`ca.sees_${r}`)}</option>)}</select></Field>
      {(reach === 'state' || (reach === 'scopes' && !info.may.viewer_whole_client)) && (
        <Field label={t('ca.f_state')} htmlFor={`${idp}-state`}>
          <select id={`${idp}-state`} value={state} onChange={(e) => { setState(e.target.value); setScopes([]); }} data-testid="ca-state-pick">
            {info.states.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>)}
      {reach === 'scopes' && (
        <fieldset className="field" data-testid="ca-scopes-pick" style={{ border: 0, padding: 0, margin: 0 }}>
          <legend>{t('ca.f_scopes')}</legend>
          {shown.map((s) => (
            <label key={s.id} className="check" style={{ minHeight: 0 }}>
              <input type="checkbox" checked={scopes.includes(s.id)}
                onChange={(e) => setScopes(e.target.checked ? [...scopes, s.id] : scopes.filter((x) => x !== s.id))} />{s.label}
              {s.status !== 'active' && <span className="muted small" data-testid="ca-scope-status"> ({t(`cv.st.${s.status}`, undefined, s.status)})</span>}</label>))}   {/* migration 68 (item 65) */}
        </fieldset>)}
    </div>
  );
}

/** A new client account: what it is and what it sees first, then its sign-in (the temporary password shown once). */
export function NewClientAccount({ client, info, done, title, label, before, note }: {
  client: string; info: ClientAccounts; done: () => void; title: string; label: string; before?: ReactNode; note?: string;
}) {
  const { t } = useI18n();
  const act = useAction();
  const kinds: ClientAccountKind[] = [...(info.may.owner ? ['owner' as const] : []), ...(info.may.viewer ? ['viewer' as const] : []), ...(info.may.operator ? ['operator' as const] : [])];
  const [f, setF] = useState<NewAccount>({ kind: kinds[0] ?? 'viewer', name: '', email: '', reach: info.may.viewer_whole_client ? 'client' : 'state',
    state: info.states[0]?.id ?? null, scopes: [], internal: false });
  const [made, setMade] = useState<{ who: string; pw: string } | null>(null);
  // the client changed (the People screen's picker): what may be made and seen is that client's
  useEffect(() => { setF((x) => ({ ...x, kind: kinds.includes(x.kind) ? x.kind : (kinds[0] ?? 'viewer'), state: info.states[0]?.id ?? null, scopes: [],
    reach: info.may.viewer_whole_client ? x.reach : (x.reach === 'client' ? 'state' : x.reach) })); },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [client, info.may.viewer_whole_client, info.may.owner, info.may.viewer, info.may.operator]);
  const submit = (e: FormEvent) => { e.preventDefault(); void act.run(async () => {
    const r = await makeClientAccount(client, f);
    setMade({ who: r.sign_in, pw: r.temporary_password }); setF({ ...f, name: '', email: '', scopes: [] }); done();
  }); };
  if (kinds.length === 0) return null;
  return (
    <form className="card" onSubmit={submit} aria-label={label} data-testid="ca-new" style={{ marginTop: 12 }}>
      <h3 style={{ marginTop: 0 }}>{title}</h3>
      {note && <p className="muted small">{note}</p>}
      {made && <TempPassword who={made.who} password={made.pw} />}
      <div className="form-grid">
        {before}
        {kinds.length > 1 && <Field label={t('ca.f_kind')} htmlFor="ca-kind"><select id="ca-kind" value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value as ClientAccountKind })} data-testid="ca-kind">
          {kinds.map((k) => <option key={k} value={k}>{t(`ca.kind.${k}`)}</option>)}</select></Field>}
        <Field label={t('hr.f_name')} htmlFor="ca-name"><input id="ca-name" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} required /></Field>
        <Field label={t('hr.f_email')} htmlFor="ca-email"><input id="ca-email" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} required /></Field>
      </div>
      {f.kind === 'owner' && <p className="small muted" data-testid="ca-owner-note">{t('ca.owner_note')}</p>}
      {f.kind === 'operator' && <p className="small muted" data-testid="ca-operator-note">{t('ca.operator_note')}</p>}
      {f.kind === 'viewer' && <>
        <ReachPicker info={info} reach={f.reach} setReach={(r) => setF({ ...f, reach: r })} state={f.state ?? ''} setState={(s) => setF({ ...f, state: s, scopes: [] })}
          scopes={f.scopes} setScopes={(s) => setF({ ...f, scopes: s })} idp="ca-new" />
        {info.may.internal && <label className="check"><input type="checkbox" checked={f.internal} onChange={(e) => setF({ ...f, internal: e.target.checked })} data-testid="ca-internal-new" />{t('ca.f_internal')}</label>}
      </>}
      <ErrorBox error={act.error} />
      <button type="submit" disabled={act.busy} data-testid="ca-create">{t('common.create')}</button>
    </form>
  );
}
