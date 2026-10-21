// Migration 50 (Part D, G8): the page a pack's own QR opens (/p/<serial>). Before release it says "Packed, not yet
// released" with what the label says; after release the lot's journey, with this pack's dates and the release's status
// (a recall shows on every pack). A void pack says so. Each scan is counted (time, code and the approximate place, nothing
// about the person); a code scanned far apart or very often carries a warning until the client has checked it (migration 56).
// Migration 57: the new look (PublicVerify.tsx), with how often this pack was scanned and where first.
import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { ErrorBox, Loading } from '../../shell/ui';
import { countScan, isExpired, loadPack } from './journey';
import { ExpiredView, JourneyView, PackNotReleased, PublicFrame } from './PublicVerify';

export function PublicPack() {
  const { serial = '' } = useParams();
  const { t } = useI18n();
  const p = useAsync(() => loadPack(serial), [serial]);
  const [scanWarn, setScanWarn] = useState(false);
  useEffect(() => { if (serial) void countScan(serial).then((r) => setScanWarn(r?.copy_warning === true)); }, [serial]);
  const d = p.data;
  const warn = scanWarn || (!!d && !isExpired(d) && d.pack.copy_warning === true);
  return (
    <PublicFrame>
      {p.loading && <Loading />}
      <ErrorBox error={p.error} onRetry={p.reload} />
      {!p.loading && !p.error && !d && <div className="card"><h1>{t('pv.not_found')}</h1><p>{t('pv.pack_not_found', { code: serial })}</p></div>}
      {d && isExpired(d) && <ExpiredView p={d} />}
      {d && !isExpired(d) && d.released && <JourneyView j={d} pack={d.pack} warn={warn} />}
      {d && !isExpired(d) && !d.released && <PackNotReleased p={d} warn={warn} />}
    </PublicFrame>
  );
}
