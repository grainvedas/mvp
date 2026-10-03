// System health for the admin and State Managers (PRD §9 observability): which system this is, the ledger check
// (nightly result, and "check now"), records waiting longest for the next stage to verify, and the errors operators'
// phones reported (src/lib/errorLog.ts → public.client_errors). Everything is read through RLS.
import { Link } from 'react-router-dom';
import { rpc, q } from '../../lib/api';
import { supabase, SUPABASE_URL } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useEnvironment } from '../../lib/environment';
import { BUILD_ID } from '../../lib/errorLog';
import { dateTime, humanise } from '../../lib/format';
import { Badge, Empty, ErrorBox, Loading } from '../../shell/ui';

interface LedgerCheck { id: number; checked_at: string; ok: boolean; blocks: number; first_bad_seq: number | null; problem: string | null; source: string }
interface Waiting { id: string; footprint_code: string; stage_type: string; scope_id: string; created_at: string }
interface ClientError { id: number; at: string; kind: string; message: string; detail: string | null; path: string | null; build: string | null;
  online: boolean | null; role: string | null; agent: string | null; app_users: { display_name: string } | null }

const DAY = 24 * 3600 * 1000;
export const daysWaiting = (createdAt: string, now = Date.now()) => Math.floor((now - new Date(createdAt).getTime()) / DAY);
const host = (() => { try { return new URL(SUPABASE_URL).host; } catch { return '—'; } })();

export function Health() {
  const { t } = useI18n();
  const env = useEnvironment();
  const checks = useAsync(() => q(supabase.from('ledger_checks').select('*').order('checked_at', { ascending: false }).limit(10)) as Promise<LedgerCheck[]>, []);
  const waiting = useAsync(() => q(supabase.from('footprints').select('id,footprint_code,stage_type,scope_id,created_at')
    .eq('status', 'pending').order('created_at').limit(10)) as Promise<Waiting[]>, []);
  const errors = useAsync(() => q(supabase.from('client_errors')
    .select('id,at,kind,message,detail,path,build,online,role,agent,app_users(display_name)').order('at', { ascending: false }).limit(50)) as unknown as Promise<ClientError[]>, []);
  const act = useAction();
  const checkNow = () => act.run(async () => { await rpc<LedgerCheck>('check_ledger_now'); await checks.reload(); });
  const last = checks.data?.[0];
  return (
    <div>
      <h1>{t('health.title')}</h1>

      <div className="card">
        <h2>{t('health.system')}</h2>
        <dl className="kv" data-testid="health-system">
          <dt>{t('health.environment')}</dt>
          <dd>{env === 'production' ? <Badge value="verified" label={t('health.env_production')} /> : env === 'staging' ? <Badge value="pending" label={t('health.env_staging')} /> : '—'}</dd>
          <dt>{t('health.build')}</dt><dd className="mono">{BUILD_ID}</dd>
          <dt>{t('health.server')}</dt><dd className="mono">{host}</dd>
        </dl>
      </div>

      <div className="card">
        <h2>{t('health.ledger')}</h2>
        {checks.loading ? <Loading /> : <ErrorBox error={checks.error} onRetry={checks.reload} />}
        {last && (last.ok
          ? <div className="alert ok" data-testid="health-ledger">{t('home.ledger_ok', { n: last.blocks, at: dateTime(last.checked_at) })}</div>
          : <div className="alert error" role="alert" data-testid="health-ledger">{t('home.ledger_bad', { seq: last.first_bad_seq ?? '?', problem: last.problem ?? '', at: dateTime(last.checked_at) })}</div>)}
        {checks.data?.length === 0 && <Empty>{t('health.never_checked')}</Empty>}
        <ErrorBox error={act.error} />
        <button className="secondary" onClick={checkNow} disabled={act.busy} data-testid="check-now">{t('health.check_now')}</button>
        {!!checks.data?.length && <div className="table-wrap"><table data-testid="health-checks">
          <thead><tr><th>{t('health.col_when')}</th><th>{t('health.col_source')}</th><th>{t('health.col_blocks')}</th><th>{t('health.col_result')}</th></tr></thead>
          <tbody>{checks.data.map((c) => (
            <tr key={c.id}><td>{dateTime(c.checked_at)}</td><td>{humanise(c.source)}</td><td className="num">{c.blocks}</td>
              <td>{c.ok ? <Badge value="pass" label={t('health.ok')} /> : <><Badge value="fail" label={t('health.failed')} /> #{c.first_bad_seq} {c.problem}</>}</td></tr>
          ))}</tbody>
        </table></div>}
      </div>

      <div className="card">
        <h2>{t('health.waiting')}</h2>
        {waiting.loading ? <Loading /> : <ErrorBox error={waiting.error} onRetry={waiting.reload} />}
        {waiting.data?.length === 0 && <Empty>{t('health.waiting_none')}</Empty>}
        {!!waiting.data?.length && <div className="table-wrap"><table data-testid="health-waiting">
          <thead><tr><th>{t('engine.col_code')}</th><th>{t('home.col_stage')}</th><th>{t('engine.col_recorded')}</th><th>{t('health.col_days')}</th></tr></thead>
          <tbody>{waiting.data.map((w) => (
            <tr key={w.id}><td><Link className="mono" to={`/records/${w.id}`}>{w.footprint_code}</Link></td>
              <td>{t(`stage.${w.stage_type}`, undefined, humanise(w.stage_type))}</td><td>{dateTime(w.created_at)}</td>
              <td className="num">{daysWaiting(w.created_at)}</td></tr>
          ))}</tbody>
        </table></div>}
      </div>

      <div className="card">
        <h2>{t('health.errors')}</h2>
        <p className="muted small">{t('health.errors_hint')}</p>
        {errors.loading ? <Loading /> : <ErrorBox error={errors.error} onRetry={errors.reload} />}
        {errors.data?.length === 0 && <Empty>{t('health.errors_none')}</Empty>}
        {!!errors.data?.length && <div className="table-wrap"><table data-testid="health-errors">
          <thead><tr><th>{t('health.col_when')}</th><th>{t('health.col_who')}</th><th>{t('health.col_kind')}</th><th>{t('health.col_message')}</th><th>{t('health.col_screen')}</th></tr></thead>
          <tbody>{errors.data.map((e) => (
            <tr key={e.id}><td>{dateTime(e.at)}</td>
              <td>{e.app_users?.display_name ?? '—'}<div className="muted small">{e.role ? humanise(e.role) : ''}{e.online === false ? ' · offline' : ''}</div></td>
              <td><Badge value={e.kind === 'sync_refused' ? 'pending' : 'fail'} label={humanise(e.kind)} /></td>
              <td>{e.message}{e.detail && <details className="small"><summary>{t('health.detail')}</summary><pre className="mono small" style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{e.detail}{'\n'}{e.agent ?? ''}</pre></details>}</td>
              <td className="mono small">{e.path}<div className="muted">{e.build}</div></td></tr>
          ))}</tbody>
        </table></div>}
      </div>
    </div>
  );
}
