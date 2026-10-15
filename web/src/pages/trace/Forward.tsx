// Migration 52 (A13): the journey both ways. The lot trace goes back to the farmers; this goes forward, from a lot to
// the records built on it, the packs and the seal.
import { Link } from 'react-router-dom';
import { rpc } from '../../lib/api';
import { useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { date, humanise, kg } from '../../lib/format';

/** Migration 52 (A13): where the lot went: the records built on it, to the packs and the seal. For those who see the
 *  whole scope (the server says no to others: then nothing is shown). */
interface ForwardStep { depth: number; from_id: string; id: string; kg_taken: number | null; stage: string; code: string; qty_out_kg: number; on: string | null;
  buyer?: string | null; destination?: string | null; packs?: { n: number; batch: string | null } | null; seal?: { qr_code: string; sealed_at: string } | null }
export function ForwardPanel({ fp }: { fp: string }) {
  const { t } = useI18n();
  const d = useAsync(() => rpc<{ steps: ForwardStep[] }>('lot_forward', { p_fp: fp }).catch(() => null), [fp]);
  const steps = d.data?.steps ?? [];
  if (!steps.length) return null;
  return (
    <div className="card" data-testid="lot-forward">
      <h2>{t('fw.title')}</h2>
      <ol className="small forward">{steps.map((s) => (
        <li key={`${s.from_id}-${s.id}`} style={{ marginLeft: `${Math.min(s.depth - 1, 6) * 12}px` }} data-stage={s.stage}>
          <Link className="mono" to={`/records/${s.id}`}>{s.code}</Link> · {t(`stage.${s.stage}`, undefined, humanise(s.stage))}
          {s.kg_taken !== null && s.kg_taken !== undefined ? ` · ${t('fw.took', { kg: kg(s.kg_taken) })}` : ` · ${kg(s.qty_out_kg)}`}
          {s.on ? ` · ${date(s.on)}` : ''}{s.buyer ? ` · ${s.buyer}` : ''}{s.destination ? ` · ${s.destination}` : ''}
          {s.packs ? ` · ${t('fw.packs', { n: s.packs.n, batch: s.packs.batch ?? '—' })}` : ''}
          {s.seal ? <> · <span data-testid="forward-seal">{t('fw.sealed', { code: s.seal.qr_code })}</span></> : null}
        </li>))}</ol>
    </div>);
}
