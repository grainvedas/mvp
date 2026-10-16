// Migration 50 (Part D, G8): the page a pack's own QR opens (/p/<serial>). Before release it says "Packed, not yet
// released" with what the label says; after release the lot's journey, with this pack's dates and the release's status
// (a recall shows on every pack). A void pack says so. Each scan is counted (time, code and the approximate place, nothing
// about the person); a code scanned far apart or very often carries a warning until the client has checked it (migration 56).
import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { ErrorBox, Loading } from '../../shell/ui';
import { giLabel } from '../../lib/gi';
import { countScan, loadPack, seasonName, type PackView } from './journey';
import { JourneyView, PublicFrame, pvDate } from './PublicVerify';

export function PublicPack() {
  const { serial = '' } = useParams();
  const { t } = useI18n();
  const p = useAsync(() => loadPack(serial), [serial]);
  const [scanWarn, setScanWarn] = useState(false);
  useEffect(() => { if (serial) void countScan(serial).then((r) => setScanWarn(r?.copy_warning === true)); }, [serial]);
  const d = p.data;
  const warn = scanWarn || d?.pack.copy_warning === true;
  return (
    <PublicFrame>
      {p.loading && <Loading />}
      <ErrorBox error={p.error} onRetry={p.reload} />
      {!p.loading && !p.error && !d && <div className="card"><h1>{t('pv.not_found')}</h1><p>{t('pv.pack_not_found', { code: serial })}</p></div>}
      {d && d.released && <JourneyView j={d} top={<PackBox pack={d.pack} warn={warn} />} />}
      {d && !d.released && (
        <div data-testid="public-pack">
          <PackBox pack={d.pack} warn={warn} />
          <section className="pv-hero card">
            <h1>{d.crop.name}</h1>
            {d.crop.gi_tag && d.gi_status === 'gi' && <p><span className="badge gi">{giLabel(d.crop.gi_tag, t)}</span> {d.crop.origin}</p>}
            <p className="muted">{seasonName(d.season)} · {d.geography}</p>
            {!d.pack.void && <div className="alert info" data-testid="pv-not-released">{t('pv.not_released')}</div>}
          </section>
        </div>
      )}
    </PublicFrame>
  );
}

function PackBox({ pack, warn }: { pack: PackView; warn: boolean }) {
  const { t } = useI18n();
  return (
    <section className="card small" data-testid="pv-pack">
      {warn && !pack.void && <div className="alert warn" role="alert" data-testid="pv-copy-warning">
        {pack.seller ? t('pv.copy_warning', { seller: pack.seller }) : t('pv.copy_warning_plain')}</div>}
      {pack.void && <div className="alert error" role="alert" data-testid="pv-void">{t('pv.pack_void')}</div>}
      <p><strong>{t('pv.pack')}</strong> <span className="mono">{pack.serial}</span> · {Number(pack.size_kg).toLocaleString('en-IN')} kg</p>
      <p>{t('pv.batch')} <span className="mono">{pack.batch_code}</span> · {t('pv.packed_on', { date: pvDate(pack.packed_on) })}
        {pack.best_before ? ` · ${t('pv.best_before', { date: pvDate(pack.best_before) })}` : ''}</p>
    </section>
  );
}
