// "Saved on this phone": what is waiting to sync, what the database refused (with its reason), and what went through.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useI18n } from '../lib/i18n';
import { useAuth } from '../auth/AuthProvider';
import { dateTime } from '../lib/format';
import { Badge, Empty } from '../shell/ui';
import { clearSynced, discard } from './outbox';
import { useOutbox } from './useOutbox';

export function Outbox() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const box = useOutbox();
  const [busy, setBusy] = useState(false);
  const [confirm, setConfirm] = useState<string | null>(null);
  const [result, setResult] = useState<string | null>(null);
  const syncNow = async () => {
    setBusy(true);
    try { const r = await box.sync(); setResult(t('outbox.result', { synced: r.synced, failed: r.failed, left: r.left })); }
    finally { setBusy(false); }
  };
  const open = box.items.filter((i) => i.state !== 'synced');
  return (
    <div>
      <h1>{t('outbox.title')}</h1>
      <p className="muted">{box.online ? t('outbox.online') : t('outbox.offline')}</p>
      <div className="row">
        <button onClick={syncNow} disabled={!box.online || busy || box.waiting === 0} data-testid="sync-now">{t('outbox.sync', { n: box.waiting })}</button>
        {box.synced.length > 0 && <button className="secondary" onClick={() => void clearSynced(ctx!.user!.id)}>{t('outbox.clear')}</button>}
      </div>
      {result && <div className="alert info" data-testid="sync-result">{result}</div>}

      {open.length === 0 && <Empty>{t('outbox.empty')}</Empty>}
      {open.length > 0 && <div className="card table-wrap"><table data-testid="outbox-open">
        <thead><tr><th>#</th><th>{t('outbox.what')}</th><th>{t('common.status')}</th></tr></thead>
        <tbody>{open.map((i, n) => (
          <tr key={i.id}>
            <td className="num">{n + 1}</td>
            <td><strong>{t(`stage.${i.stage_type}`, undefined, i.stage_label)}</strong> · {i.summary}
              <div className="small muted">{i.scope_label} · {dateTime(i.captured_at)}</div>
              {i.state === 'failed' && i.error && <div className="alert error small">{i.error}</div>}
              {i.state !== 'failed' && i.note && <div className="alert warn small">{i.note === 'photo' ? t('outbox.photo_waiting', { code: i.footprint_code ?? '' })
                : i.note === 'session' ? t('outbox.sign_in_again') : t('outbox.retrying')}</div>}
              {/* the two actions sit under the reason: beside it they squeezed the text into a column a word wide on a phone */}
              {i.state === 'failed' && <div className="row" style={{ marginTop: 8 }}>
              <Link className="btn secondary" to={`/work/${i.scope_id}/${i.stage_type}?draft=${i.id}`}>{t('outbox.fix')}</Link>
              {confirm === i.id
                ? <button className="danger" onClick={() => { void discard(i.id); setConfirm(null); }}>{t('outbox.discard_sure')}</button>
                : <button className="secondary" onClick={() => setConfirm(i.id)}>{t('outbox.discard')}</button>}
            </div>}</td>
            <td><Badge value={i.state === 'failed' ? 'fail' : 'pending'} label={t(`outbox.state_${i.state}`)} /></td>
          </tr>
        ))}</tbody>
      </table></div>}

      {box.synced.length > 0 && <>
        <h2>{t('outbox.done')}</h2>
        <div className="card table-wrap"><table data-testid="outbox-synced">
          <thead><tr><th>{t('outbox.what')}</th><th>{t('outbox.code')}</th><th>{t('outbox.synced_at')}</th></tr></thead>
          <tbody>{box.synced.map((i) => (
            <tr key={i.id}><td>{t(`stage.${i.stage_type}`, undefined, i.stage_label)} · {i.summary}
              {i.photo_error && <div className="alert warn small">{t('engine.photo_failed', { reason: i.photo_error })}</div>}</td>
              <td className="mono"><Link to={`/records/${i.footprint_id}`}>{i.footprint_code}</Link></td><td>{dateTime(i.synced_at)}</td></tr>
          ))}</tbody>
        </table></div>
      </>}
    </div>
  );
}
