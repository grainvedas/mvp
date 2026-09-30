// F13 pipeline view per scope (Client Manager, State Manager, Admin) and the Client View portal: the chain as stage
// dots with quantities, sealed lots with their public page and journey export, the flag/query log, and the season
// summary as CSV (F14). Everything is read through RLS: a Client View user sees only their own client's scopes.
import { Link, useParams } from 'react-router-dom';
import { rpc, q } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { downloadCsv } from '../../lib/csv';
import { date, dateTime, humanise, kg } from '../../lib/format';
import { Badge, Empty, ErrorBox, Loading } from '../../shell/ui';

export interface PipeRow { stage: string; chain_pos: number; records: number; pending: number; verified: number; kg_out: number; kg_available: number }
interface SealRow { qr_code: string; sealed_at: string; batch_codes: string[]; footprint_id: string;
  footprints: { footprint_code: string; qty_out: number; scope_id: string } }
interface FlagRow { id: string; text: string; status: string; created_at: string; footprint_id: string;
  footprints: { footprint_code: string; stage_type: string; scope_id: string } }
interface SeasonRow { footprint_code: string; stage_type: string; status: string; qty_in: number; qty_out: number; grade: string | null;
  lot_closed: boolean; warnings: string[]; created_at: string; verified_at: string | null; farmer_id: string | null; payload: Record<string, unknown> }

export function StageDots({ rows, stageLabel }: { rows: PipeRow[]; stageLabel: (s: string) => string }) {
  return (
    <ol className="dots" aria-label="Chain" data-testid="stage-dots">
      {rows.map((p) => (
        <li key={p.stage} className={p.verified > 0 ? 'done' : p.records > 0 ? 'active' : ''}>
          <span className="dot" aria-hidden="true">{p.chain_pos}</span>
          <span className="dot-label">{stageLabel(p.stage)}</span>
          <span className="small num">{p.records} · {kg(p.kg_available)}</span>
          {p.pending > 0 && <span className="small"><Badge value="pending" label={`${p.pending} pending`} /></span>}
        </li>
      ))}
    </ol>
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
  const exp = useAction();

  const exportSeason = () => exp.run(async () => {
    const rows = (await q(supabase.from('footprints')
      .select('footprint_code,stage_type,status,qty_in,qty_out,grade,lot_closed,warnings,created_at,verified_at,farmer_id,payload')
      .eq('scope_id', scopeId).order('created_at'))) as SeasonRow[];
    const fids = [...new Set(rows.map((r) => r.farmer_id).filter(Boolean))] as string[];
    const farmers = fids.length ? (await q(supabase.from('farmers').select('id,farmer_code,name,village').in('id', fids))) as
      { id: string; farmer_code: string | null; name: string; village: string }[] : [];
    const fm = new Map(farmers.map((f) => [f.id, f]));
    const header = ['code', 'stage', 'status', 'qty_in_kg', 'qty_out_kg', 'grade', 'lot_closed', 'farmer_id', 'farmer', 'village',
      'batch_code', 'buyer', 'market', 'created_at', 'verified_at', 'warnings'];
    const body = rows.map((r) => {
      const f = r.farmer_id ? fm.get(r.farmer_id) : undefined;
      return [r.footprint_code, r.stage_type, r.status, r.qty_in, r.qty_out, r.grade, r.lot_closed, f?.farmer_code, f?.name, f?.village,
        r.payload.batch_code as string, r.payload.buyer as string, r.payload.market as string, r.created_at, r.verified_at, r.warnings.join(' | ')];
    });
    const summary = (pipe.data ?? []).map((p) => [`SUMMARY ${p.chain_pos}`, p.stage, `${p.records} records, ${p.pending} pending`,
      null, p.kg_out, null, null, null, null, null, null, null, null, null, null, `available ${p.kg_available} kg`]);
    downloadCsv(`grainveda-season-${scope?.season_code ?? ''}-${(scope?.geography ?? 'scope').replace(/\W+/g, '-')}.csv`, header, [...summary, ...body]);
  });

  return (
    <div>
      <p className="muted small"><Link to="/">{t('nav.home')}</Link>{scope && <> · {scope.client_name}</>}</p>
      <h1>{scope ? `${scope.crop_name} · ${scope.season_code} · ${scope.geography}` : t('dash.title')}</h1>
      {scope && <p><Badge value={scope.status} /></p>}

      <div className="card">
        <h2>{t('dash.pipeline')}</h2>
        {pipe.loading ? <Loading /> : <ErrorBox error={pipe.error} onRetry={pipe.reload} />}
        {pipe.data && <StageDots rows={pipe.data} stageLabel={stageLabel} />}
        <div className="row no-print">
          <button className="secondary" onClick={exportSeason} disabled={exp.busy} data-testid="season-csv">{t('dash.season_csv')}</button>
        </div>
        <ErrorBox error={exp.error} />
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
