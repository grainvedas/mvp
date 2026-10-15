// Migration 50 (G8, Part D): the labels of a packing record = its packs, one label per serial. Each carries its own QR
// (/p/<serial>), the batch, the size, the date packed and the best-before. The browser's "Print → Save as PDF" makes
// the PDF. A second print is a reprint and needs a reason; both are logged by app.print_labels.
import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import QRCode from 'qrcode';
import { rpc } from '../../lib/api';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { date, kg } from '../../lib/format';
import { giLabel } from '../../lib/gi';
import type { FootprintDetail, LabelSheet } from '../../lib/types';
import { ErrorBox, Field, Loading } from '../../shell/ui';
import { seasonName } from '../public/journey';

/** Labels shown (and printed) at a time: a phone makes the QR codes itself, and a sheet of thousands would hang it. */
export const LABELS_PER_SHEET = 120;
/** Pure: the page of labels [from, to) for sheet n (0-based) of `total`. */
export const sheetRange = (n: number, total: number) => {
  const pages = Math.max(1, Math.ceil(total / LABELS_PER_SHEET));
  const from = Math.min(Math.max(n, 0), pages - 1) * LABELS_PER_SHEET;
  return { from, to: Math.min(from + LABELS_PER_SHEET, total) };
};
export const packUrl = (origin: string, serial: string) => `${origin}/p/${encodeURIComponent(serial)}`;

export function PackLabels() {
  const { id = '' } = useParams();
  const { t } = useI18n();
  const d = useAsync(() => rpc<FootprintDetail>('footprint_detail', { p_fp: id }), [id]);
  const [why, setWhy] = useState('');
  const [sheet, setSheet] = useState<LabelSheet | null>(null);
  const [page, setPage] = useState(0);
  const act = useAction();
  const make = () => act.run(async () => { setSheet(await rpc<LabelSheet>('print_labels', { p_fp: id, p_reason: why.trim() || null })); setPage(0); });
  if (d.loading) return <Loading />;
  if (d.error || !d.data) return <ErrorBox error={d.error} onRetry={d.reload} />;
  const f = d.data.footprint, p = d.data.packs;
  const reprint = (p?.prints ?? 0) > 0;
  return (
    <div>
      <p className="muted small no-print"><Link to={`/records/${f.id}`}>{f.footprint_code}</Link></p>
      <div className="no-print">
        <h1>{t('pk.labels_title')}</h1>
        {!p && <div className="alert info">{t('pk.not_packing')}</div>}
        {p && !sheet && (
          <div className="card stack" data-testid="labels-make">
            <p>{t('pk.batch_line', { batch: p.batch_code ?? '—', n: p.packed })}{p.best_before ? ` · ${t('pk.best_before', { date: date(p.best_before) })}` : ''}</p>
            {reprint && <div className="alert warn" data-testid="reprint-note">{t('pk.reprint_note', { n: p.prints })}</div>}
            {reprint && <Field label={`${t('pk.reprint_why')} *`} htmlFor="pk-why" hint={t('pk.min5')}>
              <input id="pk-why" value={why} maxLength={300} onChange={(e) => setWhy(e.target.value)} data-testid="reprint-why" /></Field>}
            <ErrorBox error={act.error} />
            <button onClick={make} disabled={act.busy || p.packed === 0 || (reprint && why.trim().length < 5)} data-testid="labels-go">
              {t(reprint ? 'pk.reprint' : 'pk.make')}</button>
          </div>)}
      </div>
      {sheet && <Sheet sheet={sheet} page={page} setPage={setPage} />}
    </div>
  );
}

function Sheet({ sheet, page, setPage }: { sheet: LabelSheet; page: number; setPage: (n: number) => void }) {
  const { t } = useI18n();
  const total = sheet.packs.length;
  const { from, to } = sheetRange(page, total);
  const shown = sheet.packs.slice(from, to);
  const [img, setImg] = useState<Record<string, string>>({});
  useEffect(() => {
    let live = true;
    void (async () => {
      const out: Record<string, string> = {};
      for (const pk of shown) out[pk.serial] = await QRCode.toDataURL(packUrl(window.location.origin, pk.serial), { margin: 1, width: 240, errorCorrectionLevel: 'M' });
      if (live) setImg(out);
    })();
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sheet, from, to]);
  const pages = Math.ceil(total / LABELS_PER_SHEET);
  return (
    <>
      <div className="row no-print" style={{ marginBottom: 12 }}>
        <span data-testid="labels-range">{t('pk.range', { from: total ? from + 1 : 0, to, n: total })}</span>
        {pages > 1 && <><button className="secondary" disabled={page === 0} onClick={() => setPage(page - 1)}>{t('common.back')}</button>
          <button className="secondary" disabled={page >= pages - 1} onClick={() => setPage(page + 1)}>{t('pk.next')}</button></>}
        <button onClick={() => window.print()} data-testid="labels-print">{t('labels.print_sheet')}</button>
      </div>
      <div className="label-sheet" data-testid="label-sheet">
        {shown.map((pk) => (
          <div className="label" key={pk.serial} data-testid="pack-label">
            {img[pk.serial] && <img src={img[pk.serial]} alt={`QR ${pk.serial}`} />}
            <div>
              <div className="label-crop">{sheet.crop}</div>
              {sheet.gi_tag && sheet.gi_status === 'gi' && <div className="label-gi">{giLabel(sheet.gi_tag, t)}</div>}
              <div className="label-small">{seasonName(sheet.season)} · {sheet.geography}</div>
              <div className="label-small">{kg(pk.size_kg)} · {t('pk.packed_on', { date: date(pk.packed_on) })}</div>
              {pk.best_before && <div className="label-small">{t('pk.best_before', { date: date(pk.best_before) })}</div>}
              <div className="label-code mono">{pk.serial}</div>
              <div className="label-small">{t('pk.scan')}</div>
            </div>
          </div>
        ))}
      </div>
    </>
  );
}
