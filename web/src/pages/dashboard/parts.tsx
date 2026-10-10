// Pieces the first screens share: a number card and the result of the nightly ledger check.
import { q } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { dateTime } from '../../lib/format';

export function Stat({ value, label, sub }: { value: string; label: string; sub?: string }) {
  return <div className="stat"><div className="stat-val">{value}</div><div className="stat-label">{label}</div>{sub && <div className="stat-sub">{sub}</div>}</div>;
}

/** A number card that opens a panel of detail under the cards (the admin's overview). */
export function StatButton({ value, label, sub, open, onClick, testId }: { value: string; label: string; sub?: string; open: boolean; onClick: () => void; testId?: string }) {
  return <button type="button" className={`stat stat-btn${open ? ' open' : ''}`} aria-expanded={open} onClick={onClick} data-testid={testId}>
    <div className="stat-val">{value}</div><div className="stat-label">{label}</div>{sub && <div className="stat-sub">{sub}</div>}</button>;
}

interface LedgerCheck { checked_at: string; ok: boolean; blocks: number; first_bad_seq: number | null; problem: string | null; source: string }
/** Result of the nightly ledger check (migration 21). Silent while it is recent and clean. */
export function LedgerHealth() {
  const { t } = useI18n();
  const last = useAsync(async () => ((await q(supabase.from('ledger_checks').select('*').order('checked_at', { ascending: false }).limit(1))) as LedgerCheck[])[0] ?? null, []);
  if (!last.data) return null;
  const c = last.data;
  const stale = Date.now() - new Date(c.checked_at).getTime() > 36 * 3600 * 1000;
  if (c.ok && !stale) return <p className="small muted banner" data-testid="ledger-health">{t('home.ledger_ok', { n: c.blocks, at: dateTime(c.checked_at) })}</p>;
  return <div className={`alert ${c.ok ? 'warn' : 'error'} banner`} role="alert" data-testid="ledger-health">
    {c.ok ? t('home.ledger_stale', { at: dateTime(c.checked_at) }) : t('home.ledger_bad', { seq: c.first_bad_seq ?? '?', problem: c.problem ?? '', at: dateTime(c.checked_at) })}</div>;
}
