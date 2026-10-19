// Migration 59 (B2, Veda's brief of 19 Oct 2026): the client's own login gets no "Needs action" (it acts on nothing).
// Instead: what it is waiting on GrainVeda for (records not yet checked, samples at the lab) and the open flags. Read
// only, no buttons, no links into stage pages.
import { rpc } from '../lib/api';
import { useAsync } from '../lib/useAsync';
import { useI18n } from '../lib/i18n';
import { dateTime, humanise } from '../lib/format';
import { ErrorBox, Loading } from '../shell/ui';

export interface ClientWaitingData {
  pending: { code: string; stage: string; scope_id: string; since: string }[];
  lab_hold: { code: string; scope_id: string; drawn_on: string; lot: string | null }[];
  open_flags: { text: string; kind: string | null; at: string; code: string; scope_id: string }[];
}

/** Pure: the pending records counted per stage, in the order they first appear. */
export function pendingByStage(rows: ClientWaitingData['pending']): { stage: string; n: number }[] {
  const out: { stage: string; n: number }[] = [];
  for (const r of rows) { const x = out.find((o) => o.stage === r.stage); if (x) x.n += 1; else out.push({ stage: r.stage, n: 1 }); }
  return out;
}

export function useClientWaiting(scopeId?: string | null) {
  return useAsync(() => rpc<ClientWaitingData>('client_waiting', scopeId ? { p_scope: scopeId } : {}), [scopeId ?? '']);
}

export function ClientWaitingCards({ scopeId }: { scopeId?: string | null }) {
  const { t } = useI18n();
  const w = useClientWaiting(scopeId);
  if (w.loading && !w.data) return <Loading />;
  if (w.error) return <ErrorBox error={w.error} onRetry={w.reload} />;
  const d = w.data!;
  const stages = pendingByStage(d.pending);
  return (
    <>
      <div className="card" data-testid="client-waiting">
        <h2>{t('cw.title')}</h2>
        {d.pending.length === 0 && d.lab_hold.length === 0 ? <p className="muted">{t('cw.nothing')}</p> : (
          <ul className="sys-checks">
            {stages.map((s) => <li key={s.stage} data-testid="cw-pending">{t('cw.pending_at', { n: s.n, stage: t(`stage.${s.stage}`, undefined, humanise(s.stage)) })}</li>)}
            {d.lab_hold.length > 0 && <li data-testid="cw-lab">{t('cw.lab_hold', { n: d.lab_hold.length })}
              <span className="muted small"> ({d.lab_hold.map((x) => x.lot ?? x.code).join(', ')})</span></li>}
          </ul>)}
        <p className="small muted">{t('cw.note')}</p>
      </div>
      <div className="card" data-testid="client-flags">
        <h2>{t('cw.flags_title', { n: d.open_flags.length })}</h2>
        {d.open_flags.length === 0 ? <p className="muted">{t('cw.no_flags')}</p> : (
          <ul>{d.open_flags.map((f, i) => <li key={i}><span className="mono">{f.code}</span> · {f.text} <span className="muted small">· {dateTime(f.at)}</span></li>)}</ul>)}
      </div>
    </>
  );
}
