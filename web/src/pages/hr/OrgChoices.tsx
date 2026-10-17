// Migration 58 (Veda, 16 Oct 2026, on the HR Admin's screens: "report to - it sees all people which should not be the
// case"; "department ... there should be drop down"): Reports to offers only the managers of the person's state (band
// Manager or above, or one who holds a seat; head office for everyone), the buddy only colleagues of that state, the
// department one of the HR Admin's list. The lists are the server's (app.org_choices), the same rule the database keeps
// when the record is saved; a choice made before that is no longer offered stays shown, marked, until it is changed.
import { useEffect, useState } from 'react';
import { q, rpc } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useI18n } from '../../lib/i18n';
import { useAction } from '../../lib/useAsync';
import { ErrorBox, Field } from '../../shell/ui';

export interface OrgPerson { id: string; name: string; band: string | null; seat?: string | null; state: string | null }
export interface OrgChoices { managers: OrgPerson[]; buddies: OrgPerson[]; departments: string[] }

const memo = new Map<string, Promise<OrgChoices>>();
/** The choices for a person based in a state (null: not chosen yet, every state). Kept for the page's life. */
export function loadOrgChoices(state: string | null, fresh = false): Promise<OrgChoices> {
  const k = state ?? '';
  if (fresh) memo.delete(k);
  if (!memo.has(k)) memo.set(k, rpc<OrgChoices>('org_choices', { p_state: state || null }).catch((e) => { memo.delete(k); throw e; }));
  return memo.get(k)!;
}
export function useOrgChoices(state: string | null | undefined): OrgChoices | null {
  const [c, setC] = useState<OrgChoices | null>(null);
  useEffect(() => {
    let live = true;
    setC(null);
    void loadOrgChoices(state || null).then((r) => { if (live) setC(r); }).catch(() => { if (live) setC({ managers: [], buddies: [], departments: [] }); });
    return () => { live = false; };
  }, [state]);
  return c;
}

/** Pure: people grouped by state, head office (no state) first; each group by name. */
export function byState(people: OrgPerson[]): { state: string | null; people: OrgPerson[] }[] {
  const groups = new Map<string, OrgPerson[]>();
  for (const p of people) { const k = p.state ?? ''; groups.set(k, [...(groups.get(k) ?? []), p]); }
  return [...groups.entries()].sort(([a], [b]) => (a === '' ? -1 : b === '' ? 1 : a.localeCompare(b)))
    .map(([k, v]) => ({ state: k || null, people: [...v].sort((x, y) => x.name.localeCompare(y.name)) }));
}

function PersonSelect({ id, value, onChange, people, exclude, before, kind }: {
  id: string; value: string; onChange: (v: string) => void; people: OrgPerson[] | null; exclude?: string; before?: string | null; kind: 'manager' | 'buddy';
}) {
  const { t } = useI18n();
  const list = (people ?? []).filter((p) => p.id !== exclude);
  const known = !value || list.some((p) => p.id === value);
  const what = (p: OrgPerson) => [p.seat ? t(`org.seat_${p.seat}`, undefined, p.seat) : '', p.band ?? ''].filter(Boolean).join(', ');
  return (
    <select id={id} value={value} onChange={(e) => onChange(e.target.value)} data-testid={id} disabled={people === null}>
      <option value="">—</option>
      {!known && <option value={value}>{t('org.before', { name: before ?? '?' })}</option>}
      {byState(list).map((g) => (
        <optgroup key={g.state ?? ''} label={g.state ?? t('org.head_office')}>
          {g.people.map((p) => <option key={p.id} value={p.id}>{p.name}{kind === 'manager' && what(p) ? ` · ${what(p)}` : ''}</option>)}
        </optgroup>))}
    </select>);
}

export function ReportsToSelect(p: { id: string; value: string; onChange: (v: string) => void; choices: OrgChoices | null; exclude?: string; before?: string | null }) {
  return <PersonSelect {...p} people={p.choices?.managers ?? null} kind="manager" />;
}
export function BuddySelect(p: { id: string; value: string; onChange: (v: string) => void; choices: OrgChoices | null; exclude?: string; before?: string | null }) {
  return <PersonSelect {...p} people={p.choices?.buddies ?? null} kind="buddy" />;
}
export function DepartmentSelect({ id, value, onChange, choices }: { id: string; value: string; onChange: (v: string) => void; choices: OrgChoices | null }) {
  const { t } = useI18n();
  const list = choices?.departments ?? [];
  const old = value && !list.some((d) => d.toLowerCase() === value.toLowerCase());
  return (
    <select id={id} value={old ? value : list.find((d) => d.toLowerCase() === value.toLowerCase()) ?? ''} onChange={(e) => onChange(e.target.value)} data-testid={id} disabled={choices === null}>
      <option value="">—</option>
      {old && <option value={value}>{t('org.old_department', { name: value })}</option>}
      {list.map((d) => <option key={d} value={d}>{d}</option>)}
    </select>);
}

/** The HR Admin's list of departments (Templates page): add one, retire one, bring one back. */
export function DepartmentsCard({ canEdit }: { canEdit: boolean }) {
  const { t } = useI18n();
  const [all, setAll] = useState<{ name: string; active: boolean }[] | null>(null);
  const [name, setName] = useState('');
  const act = useAction();
  const load = () => (q(supabase.from('departments').select('name,active').order('sort').order('name')) as Promise<{ name: string; active: boolean }[]>)
    .then(setAll).catch(() => setAll([]));
  useEffect(() => { void load(); }, []);
  const set = (n: string, active: boolean) => act.run(async () => { await rpc('set_department', { p_name: n, p_active: active }); memo.clear(); setName(''); await load(); });
  return (
    <section className="card" data-testid="departments">
      <h2 style={{ marginTop: 0 }}>{t('org.departments')}</h2>
      <p className="small muted">{t('org.departments_note')}</p>
      <div className="stack" style={{ gap: 6 }}>{(all ?? []).map((d) => (
        <div key={d.name} className="row wrap" data-testid="department-row" data-active={d.active ? 'yes' : 'no'}>
          <span style={{ flex: '1 1 160px' }}>{d.name}{!d.active && <span className="small muted"> · {t('set.retired')}</span>}</span>
          {canEdit && <button type="button" className="secondary small" disabled={act.busy} onClick={() => void set(d.name, !d.active)}>{t(d.active ? 'set.retire' : 'set.bring_back')}</button>}
        </div>))}</div>
      {canEdit && <form className="row wrap" style={{ marginTop: 12 }} onSubmit={(e) => { e.preventDefault(); void set(name, true); }}>
        <Field label={t('org.new_department')} htmlFor="dep-new"><input id="dep-new" value={name} maxLength={60} onChange={(e) => setName(e.target.value)} data-testid="dep-new" /></Field>
        <button type="submit" disabled={act.busy || name.trim().length < 2} data-testid="dep-add">{t('org.add_department')}</button>
      </form>}
      <ErrorBox error={act.error} />
    </section>);
}
