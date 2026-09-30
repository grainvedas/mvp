import { Link } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { useI18n } from '../lib/i18n';
import { rpc, q } from '../lib/api';
import { supabase } from '../lib/supabase';
import { useAsync } from '../lib/useAsync';
import type { Slot, ScopeSummary } from '../lib/types';
import { Empty, Badge } from '../shell/ui';
import { kg, humanise, dateTime } from '../lib/format';

export function Home() {
  const { ctx } = useAuth();
  const { t } = useI18n();
  const me = ctx!.user!;
  return (
    <div>
      <h1>{t('home.hello', { name: me.display_name })}</h1>
      {['admin', 'state_manager', 'client_manager'].includes(me.role) && <LedgerHealth />}
      {ctx!.slots.length > 0 && (
        <>
          <h2>{t('home.your_stages')}</h2>
          <div className="grid">{ctx!.slots.map((s) => <SlotCard key={`${s.scope_id}-${s.stage_type}`} slot={s} />)}</div>
        </>
      )}
      {me.role === 'operator' && ctx!.slots.length === 0 && <Empty>{t('home.no_slots')}</Empty>}
      {me.role !== 'operator' && (
        <>
          <h2>{t('home.scopes')}</h2>
          {ctx!.scopes.length === 0 ? <Empty /> : <div className="stack">{ctx!.scopes.map((s) => <ScopeCard key={s.scope_id} scope={s} />)}</div>}
        </>
      )}
    </div>
  );
}

function SlotCard({ slot }: { slot: Slot }) {
  const { t } = useI18n();
  const first = slot.chain[0] === slot.stage_type;
  const inc = useAsync(() => first ? Promise.resolve([]) : rpc<unknown[]>('incoming_records', { p_scope: slot.scope_id, p_stage: slot.stage_type }),
    [slot.scope_id, slot.stage_type]);
  return (
    <Link className="card tile" to={`/work/${slot.scope_id}/${slot.stage_type}`} data-testid={`slot-${slot.stage_type}`}>
      <strong>{t(`stage.${slot.stage_type}`, undefined, slot.stage_label)}</strong>
      <div className="muted small">{slot.scope_label}</div>
      <div className="small">{slot.client_name}</div>
      {!first && inc.data && <div style={{ marginTop: 8 }}><Badge value={inc.data.length ? 'pending' : 'draft'} label={t('home.incoming', { n: inc.data.length })} /></div>}
    </Link>
  );
}

interface PipeRow { stage: string; chain_pos: number; records: number; pending: number; verified: number; kg_out: number; kg_available: number }
function ScopeCard({ scope }: { scope: ScopeSummary }) {
  const { t } = useI18n();
  const pipe = useAsync(() => scope.status === 'draft' ? Promise.resolve([] as PipeRow[]) : rpc<PipeRow[]>('pipeline_summary', { p_scope: scope.scope_id }), [scope.scope_id]);
  return (
    <div className="card">
      <div className="row"><strong>{scope.crop_name} · {scope.season_code} · {scope.geography}</strong><Badge value={scope.status} /><span className="muted small">{scope.client_name}</span>
        <span className="spacer" style={{ flex: 1 }} />
        {scope.status !== 'draft' && <Link to={`/dashboard/${scope.scope_id}`} data-testid="dashboard-link">{t('dash.open')}</Link>}
        {scope.status === 'draft' && <Link to={`/scopes/${scope.scope_id}`}>{t('common.open')}</Link>}</div>
      {pipe.data && pipe.data.length > 0 && (
        <div className="table-wrap"><table>
          <thead><tr><th>{t('home.col_stage')}</th><th>{t('home.col_records')}</th><th>{t('home.col_pending')}</th><th>{t('home.col_out')}</th><th>{t('home.col_available')}</th><th></th></tr></thead>
          <tbody>{pipe.data.map((p) => (
            <tr key={p.stage}><td>{p.chain_pos}. {t(`stage.${p.stage}`, undefined, humanise(p.stage))}</td><td className="num">{p.records}</td><td className="num">{p.pending}</td>
              <td className="num">{kg(p.kg_out)}</td><td className="num">{kg(p.kg_available)}</td>
              <td><Link to={`/work/${scope.scope_id}/${p.stage}`}>{t('home.view')}</Link></td></tr>
          ))}</tbody>
        </table></div>
      )}
    </div>
  );
}

interface LedgerCheck { checked_at: string; ok: boolean; blocks: number; first_bad_seq: number | null; problem: string | null; source: string }
/** Result of the nightly ledger check (migration 21). Silent while it is recent and clean. */
function LedgerHealth() {
  const { t } = useI18n();
  const last = useAsync(async () => ((await q(supabase.from('ledger_checks').select('*').order('checked_at', { ascending: false }).limit(1))) as LedgerCheck[])[0] ?? null, []);
  if (!last.data) return null;
  const c = last.data;
  const stale = Date.now() - new Date(c.checked_at).getTime() > 36 * 3600 * 1000;
  if (c.ok && !stale) return <p className="small muted banner" data-testid="ledger-health">{t('home.ledger_ok', { n: c.blocks, at: dateTime(c.checked_at) })}</p>;
  return <div className={`alert ${c.ok ? 'warn' : 'error'} banner`} role="alert" data-testid="ledger-health">
    {c.ok ? t('home.ledger_stale', { at: dateTime(c.checked_at) }) : t('home.ledger_bad', { seq: c.first_bad_seq ?? '?', problem: c.problem ?? '', at: dateTime(c.checked_at) })}</div>;
}
