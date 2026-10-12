// HR by geography (migration 39, Veda 12 Oct 2026). An HR resource works for her states: she sees and acts on the
// people based there, and nobody else's. The HR Admin works for every state and gives each HR resource her states.
// Every person has a base location (state, district) on their HR record; it grants nothing. HR holds no seat.
// What a reader may do is the database's: these screens show what it says (app.hr_scope, app.person_geo).
import { useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { q, rpc } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { ErrorBox, Field } from '../../shell/ui';
import { useAuth } from '../../auth/AuthProvider';
import { DeputyCard, HrLinks } from './Scale';

export interface Named { id: string; name: string }
export interface HrScope { full: boolean; hr: boolean; states: Named[] }
export interface PersonGeo { state_id: string | null; state_name: string | null; district: string | null;
  hr_states: (Named & { since: string })[] | null; can_set_base: boolean; can_set_hr_states: boolean }
interface HrPerson { id: string; name: string; system_role: 'hr_admin' | 'hr_resource'; status: string; states: Named[]; seats: number }

/** Am I limited to some states, and which (an HR resource); the HR Admin and the admin: every state. */
export const useHrScope = () => useAsync(() => rpc<HrScope>('hr_scope'), []);
export const useAllStates = () => useAsync(() => q(supabase.from('states').select('id,name').order('name')) as Promise<Named[]>, []);
/** Pure: the states a reader may choose (all for the HR Admin, her own for an HR resource). */
export const stateChoices = (all: Named[], scope: HrScope | null | undefined): Named[] =>
  !scope || scope.full || !scope.hr ? all : all.filter((s) => scope.states.some((m) => m.id === s.id));

/** For an HR resource: which states her lists are of (or that she has none yet). Nothing for the HR Admin. */
export function HrScopeNote() {
  const { t } = useI18n();
  const s = useHrScope();
  if (!s.data || s.data.full || !s.data.hr) return null;
  return s.data.states.length
    ? <p className="small muted" data-testid="hr-scope">{t('geo.you_work_for', { states: s.data.states.map((x) => x.name).join(', ') })}</p>
    : <div className="alert warn" data-testid="hr-scope-none">{t('geo.no_states_yet')}</div>;
}

/** A person's base location on the profile and the joiner page; HR of that state may change it. */
export function BaseLocation({ employeeId, onChanged }: { employeeId: string; onChanged?: () => void }) {
  const { t } = useI18n();
  const g = useAsync(() => rpc<PersonGeo>('person_geo', { p_employee: employeeId }), [employeeId]);
  const scope = useHrScope();
  const all = useAllStates();
  const act = useAction();
  const [edit, setEdit] = useState<{ state: string; district: string } | null>(null);
  if (!g.data) return null;
  const x = g.data;
  const save = (e: FormEvent) => { e.preventDefault(); if (!edit) return; void act.run(async () => {
    await rpc('set_base_location', { p_employee: employeeId, p_state: edit.state, p_district: edit.district });
    setEdit(null); await g.reload(); onChanged?.();
  }); };
  return (
    <div data-testid="base-location">
      <p className="small"><strong>{t('geo.based_in')}:</strong>{' '}
        <span data-testid="base-location-text">{x.state_name ? [x.state_name, x.district].filter(Boolean).join(' · ') : <span className="gap">{t('geo.not_set')}</span>}</span>
        {x.can_set_base && !edit && <> <button type="button" className="secondary small-btn" onClick={() => setEdit({ state: x.state_id ?? '', district: x.district ?? '' })} data-testid="base-edit">{t('common.edit')}</button></>}</p>
      {edit && <form className="row" onSubmit={save} aria-label={t('geo.based_in')} data-testid="base-form" style={{ alignItems: 'flex-end' }}>
        <Field label={t('lens.state')} htmlFor={`bs-${employeeId}`}><select id={`bs-${employeeId}`} value={edit.state} onChange={(e) => setEdit({ ...edit, state: e.target.value })} required>
          <option value="">—</option>{stateChoices(all.data ?? [], scope.data).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></Field>
        <Field label={t('geo.district')} hint={t('common.optional')} htmlFor={`bd-${employeeId}`}><input id={`bd-${employeeId}`} value={edit.district} maxLength={60} onChange={(e) => setEdit({ ...edit, district: e.target.value })} /></Field>
        <button type="submit" disabled={act.busy || !edit.state} data-testid="base-save">{t('common.save')}</button>
        <button type="button" className="secondary" onClick={() => setEdit(null)}>{t('common.cancel')}</button>
      </form>}
      {x.hr_states && <p className="small" data-testid="hr-states-line"><strong>{t('geo.works_for')}:</strong>{' '}
        {x.hr_states.length ? x.hr_states.map((s) => s.name).join(', ') : <span className="gap">{t('geo.no_states')}</span>}
        {x.can_set_hr_states && <> · <Link to="/hr/team">{t('geo.change_on_team')}</Link></>}</p>}
      <ErrorBox error={act.error} />
    </div>
  );
}

/** Ticks of states for one HR resource; saved as the whole list. */
function HrStatesEditor({ person, all, onSaved }: { person: HrPerson; all: Named[]; onSaved: () => void }) {
  const { t } = useI18n();
  const act = useAction();
  const [pick, setPick] = useState<Set<string>>(new Set(person.states.map((s) => s.id)));
  const changed = pick.size !== person.states.length || person.states.some((s) => !pick.has(s.id));
  const save = () => act.run(async () => { await rpc('set_hr_states', { p_employee: person.id, p_states: [...pick] }); onSaved(); });
  return (
    <div className="row" style={{ alignItems: 'center' }}>
      {all.map((s) => (
        <label key={s.id} className="check"><input type="checkbox" checked={pick.has(s.id)} data-testid={`hr-state-${s.name}`}
          onChange={(e) => { const n = new Set(pick); if (e.target.checked) n.add(s.id); else n.delete(s.id); setPick(n); }} />{s.name}</label>))}
      <button type="button" className="small-btn" disabled={!changed || act.busy} onClick={() => void save()} data-testid="hr-states-save">{t('common.save')}</button>
      <ErrorBox error={act.error} />
    </div>
  );
}

/** The Seats page: every HR person, her states, and any seat she still holds (HR holds none). */
export function HrStatesCard({ canEdit }: { canEdit: boolean }) {
  const { t } = useI18n();
  const d = useAsync(() => rpc<HrPerson[]>('hr_people_states'), []);
  const all = useAllStates();
  if (!d.data) return null;
  return (
    <div className="card" data-testid="hr-states-card">
      <h2 style={{ marginTop: 0 }}>{t('geo.title')}</h2>
      <p className="small muted">{t('geo.note')}</p>
      <ul className="ready-list">{d.data.map((p) => (
        <li key={p.id} data-testid="hr-person" data-name={p.name}>
          <strong><Link to={`/people/${p.id}`}>{p.name}</Link></strong> <span className="small muted">{t(`sysrole.${p.system_role}`)}</span>
          {p.system_role === 'hr_admin'
            ? <div className="small">{t('geo.every_state')}</div>
            : canEdit ? <HrStatesEditor person={p} all={all.data ?? []} onSaved={() => void d.reload()} />
              : <div className="small">{p.states.length ? p.states.map((s) => s.name).join(', ') : <span className="gap">{t('geo.no_states')}</span>}</div>}
          {p.seats > 0 && <div className="alert warn" data-testid="hr-holds-seat">{t('geo.holds_seat', { name: p.name, n: p.seats })} <Link to={`/people/${p.id}`}>{t('geo.open_profile')}</Link></div>}
        </li>))}</ul>
    </div>
  );
}

/** HR · Team (the HR Admin's page): who in HR works for which states, and the Deputy. */
export function HrTeam() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const role = ctx?.user?.system_role;
  return (
    <div style={{ maxWidth: 900 }}>
      <div className="page-hd"><h1><span aria-hidden="true">🗺️ </span>{t('geo.team')}</h1><div className="sub">{t('geo.team_sub')}</div></div>
      <HrLinks here="team" />
      <HrScopeNote />
      <HrStatesCard canEdit={role === 'hr_admin'} />
      <DeputyCard />
    </div>
  );
}
