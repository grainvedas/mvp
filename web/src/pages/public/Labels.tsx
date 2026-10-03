// F11 printable QR labels: an A4 sheet of labels for a sealed lot. The browser's "Print → Save as PDF" makes the PDF,
// so labels print offline at the mill with no server step (execution plan: replaces a server-side PDF function).
import { useEffect, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import QRCode from 'qrcode';
import { useAsync } from '../../lib/useAsync';
import { ErrorBox, Loading } from '../../shell/ui';
import { loadJourney, seasonName } from './journey';
import { useI18n } from '../../lib/i18n';

export function Labels() {
  const { code = '' } = useParams();
  const { t } = useI18n();
  const [search, setSearch] = useSearchParams();
  const n = Math.min(Math.max(Number(search.get('n') ?? 12) || 12, 1), 60);
  const j = useAsync(() => loadJourney(code), [code]);
  const [img, setImg] = useState('');
  const url = `${window.location.origin}/verify/${code}`;
  useEffect(() => { void QRCode.toDataURL(url, { margin: 1, width: 320, errorCorrectionLevel: 'M' }).then(setImg); }, [url]);
  if (j.loading) return <Loading />;
  if (j.error || !j.data) return <ErrorBox error={j.error} />;
  const d = j.data;
  return (
    <div>
      <div className="row no-print" style={{ marginBottom: 12 }}>
        <h1 style={{ margin: 0 }}>{t('labels.title')} · <span className="mono">{code}</span></h1>
        <label className="row" style={{ margin: 0 }}>{t('labels.copies')} <input type="number" min={1} max={60} value={n} style={{ width: 90 }}
          onChange={(e) => setSearch({ n: e.target.value })} /></label>
        <button onClick={() => window.print()}>{t('labels.print_sheet')}</button>
      </div>
      <div className="label-sheet" data-testid="label-sheet">
        {Array.from({ length: n }, (_, i) => (
          <div className="label" key={i}>
            {img && <img src={img} alt={`QR ${code}`} />}
            <div>
              <div className="label-crop">{d.crop.name}</div>
              {d.crop.gi_tag && <div className="label-gi">{d.crop.gi_tag}</div>}
              <div className="label-small">{seasonName(d.season)} · {d.geography}</div>
              {d.batch_codes.length > 0 && <div className="label-small mono">Batch {d.batch_codes.join(', ')}</div>}
              <div className="label-code mono">{code}</div>
              <div className="label-small">Scan to see who grew it and how it was tested</div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
