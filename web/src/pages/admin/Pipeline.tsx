// The pipeline, its own page (brief 2.3 and 3: "Pipeline (own page, short summary on Overview)"). Read only.
//   All active scopes: every stage of their chains in chain order (each stage's average step; the seal last), what was
//   verified and what waits, the quantity verified at each stage (the funnel), the oldest record waiting.
//   One scope: the same from app.pipeline_summary, in that scope's exact chain order.
// No "Records" column (brief 2.4): verified and waiting are the two numbers that mean something.
import { useState } from 'react';
import { Link, Navigate } from 'react-router-dom';
import { useAuth } from '../../auth/AuthProvider';
import { rpc } from '../../lib/api';
import { useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { oversees } from '../../lib/rights';
import { date, kg, num } from '../../lib/format';
import { Empty, ErrorBox, Loading } from '../../shell/ui';
import type { PipeRow } from '../Home';
import type { Overview } from './Overview';
import { Bars } from './charts';

/** One row of the page, whichever source it came from. */
export interface PipeLine { key: string; stage: string; label: string; step: number | null; done: number; pending: number; kg_done: number; kg_waiting: number | null; oldest: string | null }

/** Pure: the overview's rows (all active scopes), already in chain order. */
export const fromOverview = (rows: Overview['pipeline']): PipeLine[] => rows.map((r, i) => ({
  key: r.stage_type, stage: r.stage_type, label: r.label, step: i + 1, done: Number(r.done), pending: Number(r.pending),
  kg_done: Number(r.kg_done ?? 0), kg_waiting: Number(r.kg_pending), oldest: r.oldest_pending,
}));

/** Pure: one scope's rows, in that scope's chain order. */
export const fromScope = (rows: PipeRow[]): PipeLine[] => [...rows].sort((a, b) => Number(a.chain_pos) - Number(b.chain_pos)).map((r) => ({
  key: r.stage, stage: r.stage, label: r.stage, step: Number(r.chain_pos) + 1, done: Number(r.verified), pending: Number(r.pending),
  kg_done: Number(r.kg_out ?? 0), kg_waiting: null, oldest: null,
}));

export function PipelinePage() {
  const { ctx } = useAuth();
  const { t } = useI18n();
  const [scope, setScope] = useState('');
  const live = (ctx?.scopes ?? []).filter((s) => s.status === 'active');
  const all = useAsync(() => (oversees(ctx) ? rpc<Overview>('platform_overview') : Promise.resolve(null)), []);
  const one = useAsync(() => (scope ? rpc<PipeRow[]>('pipeline_summary', { p_scope: scope }) : Promise.resolve(null)), [scope]);
  if (!oversees(ctx)) return <Navigate to="/" replace />;
  const src = scope ? one : all;
  const rows: PipeLine[] | null = scope ? (one.data ? fromScope(one.data) : null) : (all.data ? fromOverview(all.data.pipeline) : null);
  const stage = (r: PipeLine) => t(`stage.${r.stage}`, undefined, r.label);
  return (
    <>
      <div className="band"><div><h1>{t('pipe.title')}</h1><div className="sub">{t('pipe.sub')}</div></div></div>
      <label className="ov-state" style={{ marginBottom: 12 }}>
        <span className="small">{t('pipe.which')}</span>
        <select value={scope} onChange={(e) => setScope(e.target.value)} data-testid="pipe-scope">
          <option value="">{t('pipe.all')}</option>
          {live.map((s) => <option key={s.scope_id} value={s.scope_id}>{s.client_name} · {s.crop_name} · {s.season_code} · {s.geography}</option>)}
        </select>
      </label>
      {!rows ? (src.loading ? <Loading /> : <ErrorBox error={src.error} onRetry={() => void src.reload()} />) : rows.length === 0 ? <Empty>{t('ov.no_pipeline')}</Empty> : (
        <>
          <p className="small muted">{scope ? t('pipe.order_one') : t('pipe.order_all')}</p>
          <div className="ov-grid">
            <div className="card ov-panel" data-testid="pipe-counts">
              <h2>{t('pipe.counts')}</h2>
              <Bars fmt={(v) => num(v, 0)} legend={[t('ov.p_done'), t('ov.p_pending')]}
                rows={rows.map((r) => ({ key: r.key, label: <>{r.step}. {stage(r)}</>, value: r.done, rest: r.pending, title: t('ov.p_title', { p: r.pending, d: r.done }) }))} />
            </div>
            <div className="card ov-panel" data-testid="pipe-funnel">
              <h2>{t('pipe.funnel')}</h2>
              <Bars fmt={(v) => kg(v)} rows={rows.map((r) => ({ key: r.key, label: <>{r.step}. {stage(r)}</>, value: r.kg_done, title: `${stage(r)}: ${kg(r.kg_done)}` }))} />
              <p className="small muted">{t('pipe.funnel_note')}</p>
            </div>
          </div>
          <h2 className="section-title">{t('pipe.table')}</h2>
          <div className="table-wrap" data-testid="pipe-table"><table className="wide">
            <thead><tr><th className="num">{t('pipe.step')}</th><th>{t('home.col_stage')}</th><th className="num">{t('ov.p_done')}</th><th className="num">{t('ov.p_pending')}</th>
              <th className="num">{t('pipe.kg_done')}</th>{!scope && <><th className="num">{t('ov.p_kg')}</th><th>{t('ov.p_oldest')}</th></>}</tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.key} data-testid="pipe-row" data-stage={r.stage}>
                <td className="num">{r.step}</td><td>{stage(r)}</td><td className="num">{num(r.done, 0)}</td><td className="num">{num(r.pending, 0)}</td>
                <td className="num">{kg(r.kg_done)}</td>
                {!scope && <><td className="num">{r.pending > 0 ? kg(r.kg_waiting) : '—'}</td><td>{r.oldest ? date(r.oldest) : '—'}</td></>}
              </tr>))}</tbody>
          </table></div>
          {scope && <p className="small"><Link to={`/dashboard/${scope}`}>{t('dash.open')}</Link></p>}
        </>)}
    </>
  );
}
