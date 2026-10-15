// Pieces the first screens share: a number card and the result of the nightly ledger check.
import { q, rpc } from '../../lib/api';
import { ledgerBanner, type LedgerStatus } from '../../lib/setup';
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
/** Result of the nightly ledger check (migration 21). Migration 51 (A14, Veda 15 Oct 2026): it says how many blocks were
 *  added since the last full check, so "18 blocks intact" is never read as the whole ledger (app.ledger_status). */
export function LedgerHealth() {
  const { t } = useI18n();
  const last = useAsync(async () => ((await q(supabase.from('ledger_checks').select('*').order('checked_at', { ascending: false }).limit(1))) as LedgerCheck[])[0] ?? null, []);
  const status = useAsync(() => rpc<LedgerStatus>('ledger_status').catch(() => null), []);     // a server before 51: none
  if (!last.data && !status.data) return null;
  const c = last.data;
  if (status.data && status.data.checked_at && (!c || c.ok)) {
    const s = status.data; const b = ledgerBanner(s);
    const vars = { n: s.blocks ?? 0, at: dateTime(s.checked_at), added: s.added_since, seq: c?.first_bad_seq ?? '?', problem: c?.problem ?? '' };
    return b.tone === 'muted' ? <p className="small muted banner" data-testid="ledger-health" data-added={s.added_since}>{t(b.key, vars)}</p>
      : <div className={`alert ${b.tone} banner`} role="alert" data-testid="ledger-health">{t(b.key, vars)}</div>;
  }
  if (!c) return null;
  const stale = Date.now() - new Date(c.checked_at).getTime() > 36 * 3600 * 1000;
  if (c.ok && !stale) return <p className="small muted banner" data-testid="ledger-health">{t('home.ledger_ok', { n: c.blocks, at: dateTime(c.checked_at) })}</p>;
  return <div className={`alert ${c.ok ? 'warn' : 'error'} banner`} role="alert" data-testid="ledger-health">
    {c.ok ? t('home.ledger_stale', { at: dateTime(c.checked_at) }) : t('home.ledger_bad', { seq: c.first_bad_seq ?? '?', problem: c.problem ?? '', at: dateTime(c.checked_at) })}</div>;
}

/** The admin's health page: how many blocks the ledger holds now and how many came after the last full check (A14). */
export function LedgerAddedSince() {
  const { t } = useI18n();
  const s = useAsync(() => rpc<LedgerStatus>('ledger_status').catch(() => null), []);
  if (!s.data || !s.data.checked_at) return null;
  return <p className="small" data-testid="ledger-added-since">{t('led.added_now', { added: s.data.added_since, now: s.data.blocks_now })}</p>;
}
