// F13 pipeline view per scope (Client Manager, State Manager, Admin) and the Client View portal: the chain as stage
// dots with quantities, sealed lots with their public page and journey export, the flag/query log, and the season
// season export (made on the server since migration 60, Part C: one Excel file, a shareable or an internal copy), and what happened per day (PRD §9 "per-scope activity metrics", from the ledger).
// Everything is read through RLS: a Client View user sees only their own client's scopes.
import { Link, useParams } from 'react-router-dom';
import { rpc, q } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { exportSeason, mayInternalCopy, seasonXlsx, stageBalance, type Copy, type StageBalance } from '../../lib/exports';
import { date, dateTime, humanise, kg } from '../../lib/format';
import { Badge, Empty, ErrorBox, Loading } from '../../shell/ui';
import { SeasonReport } from './SeasonReport';

export interface PipeRow { stage: string; chain_pos: number; records: number; pending: number; verified: number; kg_out: number; kg_available: number }
interface SealRow { qr_code: string; sealed_at: string; batch_codes: string[]; footprint_id: string;
  footprints: { footprint_code: string; qty_out: number; scope_id: string } }
interface FlagRow { id: string; text: string; status: string; created_at: string; footprint_id: string;
  footprints: { footprint_code: string; stage_type: string; scope_id: string } }
interface ActivityRow { day: string; saved: number; verified: number; sealed: number; supervisory: number }
export function StageDots({ rows, stageLabel }: { rows: PipeRow[]; stageLabel: (s: string) => string }) {
  const { t } = useI18n();
  return (
    <ol className="dots" aria-label="Chain" data-testid="stage-dots">
      {rows.map((p) => (
        <li key={p.stage} className={p.verified > 0 ? 'done' : p.records > 0 ? 'active' : ''}>
          <span className="dot" aria-hidden="true">{p.chain_pos}</span>
          <span className="dot-label">{stageLabel(p.stage)}</span>
          <span className="small num" data-testid="stage-box-figures">{t('dash.stage_box', { n: p.records, kg: kg(p.kg_available) })}</span>
          {p.pending > 0 && <span className="small"><Badge value="pending" label={t('dash.pending_n', { n: p.pending })} /></span>}
        </li>
      ))}
    </ol>
  );
}

/** Migration 61 (E2.5, Veda's brief of 19 Oct 2026): each stage's mass balance. Came in = went on + by-products (with
 *  samples and water) + floor loss (with transit) + closed as floor loss + left; a difference shows in red. */
export function MassBalance({ rows, stageLabel }: { rows: StageBalance[]; stageLabel: (s: string) => string }) {
  const { t } = useI18n();
  // one block per stage (a table of eight columns does not fit a phone): the stage and its verdict, then the figures
  return (
    <ul className="balance" data-testid="mass-balance">
      {rows.map((b) => {
        const n = (k: string, v: number) => t(k, { kg: kg(v) });
        const parts = [
          n('dash.bal_in', b.kg_in), n('dash.bal_on', b.handed_on_kg),
          Number(b.by_products_kg) ? n('dash.bal_byp', b.by_products_kg) : '', Number(b.other_kg) ? n('dash.bal_other', b.other_kg) : '',
          Number(b.floor_loss_kg) ? n('dash.bal_loss', b.floor_loss_kg) : '', Number(b.transit_loss_kg) ? n('dash.bal_transit', b.transit_loss_kg) : '',
          Number(b.closed_kg) ? n('dash.bal_closed', b.closed_kg) : '', Number(b.written_off_kg ?? 0) ? n('dash.bal_written_off', b.written_off_kg ?? 0) : '',
          n('dash.bal_left', b.left_kg),
        ].filter(Boolean);
        return (
          <li key={b.stage} data-testid="balance-row" data-stage={b.stage} data-balanced={b.balanced ? 'yes' : 'no'}>
            <div className="row"><strong>{b.pos}. {stageLabel(b.stage)}</strong>
              {b.balanced ? <Badge value="verified" label={t('exp.s.balanced')} />
                : <strong className="text-danger" data-testid="balance-diff">{t('dash.balance_diff', { kg: kg(b.difference_kg) })}</strong>}</div>
            <div className="small muted num" data-testid="balance-figures">{parts.join(' · ')}</div>
          </li>);
      })}
    </ul>
  );
}

export function ScopeDashboard() {
  const { scopeId = '' } = useParams();
  const { t } = useI18n();
  const { ctx } = useAuth();
  const scope = ctx!.scopes.find((s) => s.scope_id === scopeId);
  const stageLabel = (s: string) => t(`stage.${s}`, undefined, humanise(s));
  const pipe = useAsync(() => rpc<PipeRow[]>('pipeline_summary', { p_scope: scopeId }), [scopeId]);
  const seals = useAsync(async () => (await q(supabase.from('qr_seals')
    .select('qr_code,sealed_at,batch_codes,footprint_id,footprints!inner(footprint_code,qty_out,scope_id)')
    .eq('footprints.scope_id', scopeId).order('sealed_at', { ascending: false }))) as unknown as SealRow[], [scopeId]);
  const flags = useAsync(async () => (await q(supabase.from('flags')
    .select('id,text,status,created_at,footprint_id,footprints!inner(footprint_code,stage_type,scope_id)')
    .eq('footprints.scope_id', scopeId).order('created_at', { ascending: false }))) as unknown as FlagRow[], [scopeId]);
  const activity = useAsync(() => rpc<ActivityRow[]>('scope_activity', { p_scope: scopeId, p_days: 14 }), [scopeId]);
  const balance = useAsync(() => stageBalance(scopeId), [scopeId]);
  const exp = useAction();
  // migration 59 (A8): a scope with records of before system batch codes says so here and in its export
  const note = useAsync(async () => ((await q(supabase.from('scopes').select('data_note').eq('id', scopeId))) as unknown as { data_note: string | null }[])[0]?.data_note ?? null, [scopeId]);
  const oldData = note.data === 'practice_old_data';

  // migration 60 (C4): the internal copy (names, prices) only for the scope's people and the client's own login
  const internal = useAsync(() => mayInternalCopy(scopeId), [scopeId]);
  const download = (copy: Copy) => exp.run(async () => seasonXlsx(await exportSeason(scopeId, copy), t));

  return (
    <div>
      <p className="muted small"><Link to="/">{t('nav.home')}</Link>{scope && <> · {scope.client_name}</>}</p>
      <h1>{scope ? `${scope.crop_name} · ${scope.season_code} · ${scope.geography}` : t('dash.title')}</h1>
      {scope && <p><Badge value={scope.status} /></p>}
      {oldData && <div className="alert warn" data-testid="old-data">{t('scope.old_data')}</div>}

      <div className="card">
        <h2>{t('dash.pipeline')}</h2>
        {pipe.loading ? <Loading /> : <ErrorBox error={pipe.error} onRetry={pipe.reload} />}
        {pipe.data && <StageDots rows={pipe.data} stageLabel={stageLabel} />}
        <div className="row no-print">
          <button className="secondary" onClick={() => download('shareable')} disabled={exp.busy} data-testid="season-xlsx">{t('exp.season_shareable')}</button>
          {internal.data === true && <button className="secondary" onClick={() => download('internal')} disabled={exp.busy} data-testid="season-xlsx-internal">{t('exp.season_internal')}</button>}
        </div>
        {internal.data === true && <p className="small muted no-print" data-testid="season-copies">{t('exp.copies_note')}</p>}
        <ErrorBox error={exp.error} />
      </div>

      <div className="card" data-testid="season-report-card">
        <h2>{t('srep.title')}</h2>
        <SeasonReport scopeId={scopeId} onChanged={() => { balance.reload(); flags.reload(); pipe.reload(); }} />
      </div>

      <div className="card">
        <h2>{t('dash.balance')}</h2>
        {balance.loading ? <Loading /> : <ErrorBox error={balance.error} onRetry={balance.reload} />}
        {balance.data && <MassBalance rows={balance.data} stageLabel={stageLabel} />}
        <p className="small muted">{t('exp.s.balance_note')}</p>
      </div>

      <div className="card">
        <h2>{t('dash.sealed')}</h2>
        {seals.loading ? <Loading /> : <ErrorBox error={seals.error} onRetry={seals.reload} />}
        {seals.data?.length === 0 && <Empty />}
        {!!seals.data?.length && <div className="table-wrap"><table data-testid="sealed-lots">
          <thead><tr><th>QR</th><th>{t('dash.lot')}</th><th>{t('dash.kg')}</th><th>{t('dash.sealed_on')}</th><th></th></tr></thead>
          <tbody>{seals.data.map((s) => (
            <tr key={s.qr_code}><td className="mono">{s.qr_code}</td>
              <td><Link className="mono" to={`/records/${s.footprint_id}`}>{s.footprints.footprint_code}</Link>{s.batch_codes.length > 0 && <div className="small muted">{s.batch_codes.join(', ')}</div>}</td>
              <td className="num">{kg(s.footprints.qty_out)}</td><td>{date(s.sealed_at)}</td>
              <td><Link to={`/trace/${s.footprint_id}`}>{t('dash.journey')}</Link> · <Link to={`/verify/${s.qr_code}`}>{t('dash.public')}</Link></td></tr>
          ))}</tbody>
        </table></div>}
      </div>

      <div className="card">
        <h2>{t('dash.activity')}</h2>
        {activity.loading ? <Loading /> : <ErrorBox error={activity.error} onRetry={activity.reload} />}
        {activity.data?.length === 0 && <Empty />}
        {!!activity.data?.length && <div className="table-wrap"><table data-testid="activity">
          <thead><tr><th>{t('dash.day')}</th><th>{t('dash.saved')}</th><th>{t('dash.verified')}</th><th>{t('dash.sealed_n')}</th><th>{t('dash.supervisory')}</th></tr></thead>
          <tbody>{activity.data.map((a) => (
            <tr key={a.day}><td>{date(a.day)}</td><td className="num">{a.saved}</td><td className="num">{a.verified}</td>
              <td className="num">{a.sealed}</td><td className="num">{a.supervisory}</td></tr>
          ))}</tbody>
        </table></div>}
      </div>

      <div className="card">
        <h2>{t('dash.flags')}</h2>
        {flags.loading ? <Loading /> : <ErrorBox error={flags.error} onRetry={flags.reload} />}
        {flags.data?.length === 0 && <Empty />}
        {!!flags.data?.length && <div className="table-wrap"><table data-testid="flag-log">
          <thead><tr><th>{t('dash.lot')}</th><th>{t('record.flags')}</th><th>{t('common.status')}</th><th>{t('dash.raised')}</th></tr></thead>
          <tbody>{flags.data.map((f) => (
            <tr key={f.id}><td><Link className="mono" to={`/records/${f.footprint_id}`}>{f.footprints.footprint_code}</Link> <span className="muted small">{stageLabel(f.footprints.stage_type)}</span></td>
              <td>{f.text}</td><td><Badge value={f.status} /></td><td>{dateTime(f.created_at)}</td></tr>
          ))}</tbody>
        </table></div>}
      </div>
    </div>
  );
}
