// Pieces the people screens share (identity layer): how a status, an access badge, a warning and a temporary
// password are shown; putting a document into the private HR store.
import { useState, type ReactNode } from 'react';
import { supabase } from '../../lib/supabase';
import { rpc, sha256Hex } from '../../lib/api';
import { toAppError } from '../../lib/errors';
import { useI18n } from '../../lib/i18n';
import { humanise } from '../../lib/format';
import { lensTone, safeFileName, statusTone, type AssignmentInfo, type OrgFacts, type Warning } from '../../lib/people';
import type { EmployeeStatus, StageType, SystemRole } from '../../lib/types';
import { Badge } from '../../shell/ui';

export const MAX_HR_FILE_BYTES = 10 * 1024 * 1024;

export function StatusBadge({ status }: { status: EmployeeStatus }) {
  const { t } = useI18n();
  return <Badge value={statusTone[status]} label={t(`pstatus.${status}`)} />;
}

export function useStageName() {
  const { t } = useI18n();
  return (s: StageType | string) => t(`stage.${s}`, undefined, humanise(s));
}

/** One coloured badge per thing that grants access: the system role (when it is not plain "operational") and each assignment. */
export function AccessBadges({ systemRole, assignments, elsewhere, unassigned }:
  { systemRole: SystemRole; assignments: AssignmentInfo[]; elsewhere: number; unassigned: boolean }) {
  const { t } = useI18n();
  const stage = useStageName();
  return (
    <span className="access" data-testid="access-badges">
      {systemRole !== 'operational' && <span className="badge sys">{t(`sysrole.${systemRole}`)}</span>}
      {assignments.map((a) => (
        <span key={a.id} className={`badge ${lensTone[a.lens]}${a.lapsed ? ' lapsed' : ''}`} title={t(`oprole.${a.op_role}`)}>
          {a.lens === 'scope' ? `${a.label}: ${a.stages.length ? a.stages.map(stage).join(', ') : t('oprole.export_manager')}`
            : `${t(`oprole.${a.op_role}`)}: ${a.label}`}{a.lapsed ? ` (${t('assign.lapsed')})` : ''}
        </span>))}
      {elsewhere > 0 && <span className="badge draft" data-testid="elsewhere">{t('people.elsewhere', { n: elsewhere })}</span>}
      {unassigned && systemRole === 'operational' && <span className="badge pending" data-testid="unassigned">{t('people.unassigned')}</span>}
    </span>
  );
}

/** Org facts in grey: they describe the person and open nothing. */
export function OrgLine({ org }: { org: OrgFacts | null | undefined }) {
  const { t } = useI18n();
  if (!org) return null;
  const parts = [org.job_title, org.designation_band, org.department, org.employment_type ? t(`emptype.${org.employment_type}`) : null].filter(Boolean);
  return parts.length ? <div className="org-line">{parts.join(' · ')}</div> : null;
}

export function WarningList({ warnings }: { warnings: Warning[] | null | undefined }) {
  const { t } = useI18n();
  const stage = useStageName();
  if (!warnings?.length) return null;
  const text = (w: Warning) => t(`warn.${w.code}`, { place: String(w.place ?? ''), state: String(w.state ?? ''), client: String(w.client ?? ''),
    first: stage(String(w.first ?? '')), second: stage(String(w.second ?? '')), status: w.status ? t(`pstatus.${String(w.status)}`) : '' }, w.code);
  return (
    <div className="alert warn" role="status" data-testid="assign-warnings">
      <strong>{t('warn.title')}</strong>
      <ul>{warnings.map((w, i) => <li key={`${w.code}-${i}`}>{text(w)}</li>)}</ul>
    </div>
  );
}

/** A password made by the server is shown once, to the person who will hand it over. */
export function TempPassword({ who, password, children }: { who: string; password: string; children?: ReactNode }) {
  const { t } = useI18n();
  return <div className="alert ok" data-testid="temp-password">{t('users.temp_password', { who, pw: password })}{children}</div>;
}

/**
 * A document goes to the private store `hr-docs` at <person>/<file> and is registered with its SHA-256. Only HR and
 * the admin can open it afterwards (migration 32): the person who uploaded it sees its name in their list, no more.
 */
export async function uploadHrFile(employeeId: string, kind: string, file: File, taskId?: string | null): Promise<void> {
  if (file.size > MAX_HR_FILE_BYTES) throw toAppError({ code: '23514', message: `the file is larger than ${MAX_HR_FILE_BYTES / 1024 / 1024} MB` });
  const hash = await sha256Hex(file);
  const path = `${employeeId}/${hash.slice(0, 12)}-${safeFileName(file.name)}`;
  const up = await supabase.storage.from('hr-docs').upload(path, file, { contentType: file.type || 'application/octet-stream', upsert: false });
  // "already exists": an earlier attempt stored the file but the registration did not get through; register it now
  if (up.error && !/already exists|duplicate/i.test(up.error.message)) throw toAppError({ code: '42501', message: up.error.message });
  try { await rpc('register_hr_file', { p_employee: employeeId, p_kind: kind, p_path: path, p_sha256: hash, p_file_name: file.name, p_task: taskId ?? null }); }
  catch (e) { if (toAppError(e).code !== '23505') throw e; }
}

/** A file box that remembers the chosen file's name (a phone shows nothing after the picker closes otherwise). */
export function FileBox({ id, label, hint, accept = 'image/*,application/pdf', onPick }:
  { id: string; label: string; hint?: string; accept?: string; onPick: (f: File | null) => void }) {
  const [name, setName] = useState('');
  return (
    <div className="field">
      <label htmlFor={id}>{label}{hint && <> <span className="hint">{hint}</span></>}</label>
      <input id={id} type="file" accept={accept} onChange={(e) => { const f = e.target.files?.[0] ?? null; setName(f?.name ?? ''); onPick(f); }} />
      {name && <p className="hint" data-testid={`${id}-name`}>{name}</p>}
    </div>
  );
}

/** A line of text that needs a second tap before something that cannot be undone from this screen. */
export function Confirm({ open, title, children, confirmLabel, busy, onConfirm, onCancel, danger = true }:
  { open: boolean; title: string; children?: ReactNode; confirmLabel: string; busy?: boolean; onConfirm: () => void; onCancel: () => void; danger?: boolean }) {
  const { t } = useI18n();
  if (!open) return null;
  return (
    <div className="card confirm" role="group" aria-label={title} data-testid="confirm">
      <h3>{title}</h3>
      {children}
      <div className="row">
        <button type="button" className="secondary" onClick={onCancel}>{t('common.cancel')}</button>
        <button type="button" className={danger ? 'danger' : ''} disabled={busy} onClick={onConfirm} data-testid="confirm-yes">{confirmLabel}</button>
      </div>
    </div>
  );
}
