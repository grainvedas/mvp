// Migration 50 (G8, Part D): the labels of a packing record = its packs, one label per serial. Each carries its own QR
// (/p/<serial>), the batch, the size, the date packed and the best-before. The browser's "Print → Save as PDF" makes
// the PDF. A second print is a reprint and needs a reason; both are logged by app.print_labels.
// Migration 58 (Veda, 16 Oct: "Carton labels - share suggestion"): where the packs went in cartons, the carton labels too,
// on an A4 sheet of 8 or on a label printer's 100 × 150 mm labels. A carton's QR holds its plain code (for the loaders'
// phones; no page behind it): big, with the code under it, the pack type, how many packs and which (first to last).
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

export interface CartonLabel { code: string; sku: string | null; n: number; first_serial: string; last_serial: string; status: string; packed_on: string | null; best_before: string | null }
export interface CartonSheet { crop: string; gi_tag: string | null; gi_status: string; season: string; geography: string; client: string; batch_code: string | null; cartons: CartonLabel[] }
export type Paper = 'a4_8' | 'label_100x150';
/** The page size each paper prints on (the browser's print dialog takes it from here). */
export const PAPER_PAGE: Record<Paper, string> = { a4_8: 'A4', label_100x150: '100mm 150mm' };

export function PackLabels() {
  const { id = '' } = useParams();
  const { t } = useI18n();
  const d = useAsync(() => rpc<FootprintDetail>('footprint_detail', { p_fp: id }), [id]);
  const cartons = useAsync(() => rpc<CartonSheet>('carton_labels', { p_fp: id }).catch(() => null), [id]);
  const [what, setWhat] = useState<'packs' | 'cartons'>('packs');
  const [paper, setPaper] = useState<Paper>('a4_8');
  const [showCartons, setShowCartons] = useState(false);
  const [why, setWhy] = useState('');
  const [sheet, setSheet] = useState<LabelSheet | null>(null);
  const [page, setPage] = useState(0);
  const act = useAction();
  const make = () => act.run(async () => { setSheet(await rpc<LabelSheet>('print_labels', { p_fp: id, p_reason: why.trim() || null })); setPage(0); });
  if (d.loading) return <Loading />;
  if (d.error || !d.data) return <ErrorBox error={d.error} onRetry={d.reload} />;
  const f = d.data.footprint, p = d.data.packs;
  const reprint = (p?.prints ?? 0) > 0;
  const cs = cartons.data;
  const packedCartons = (cs?.cartons ?? []).filter((c) => c.status === 'packed');
  const opened = (cs?.cartons ?? []).length - packedCartons.length;
  return (
    <div>
      <p className="muted small no-print"><Link to={`/records/${f.id}`}>{f.footprint_code}</Link></p>
      <div className="no-print">
        <h1>{t(what === 'cartons' ? 'pk.carton_labels_title' : 'pk.labels_title')}</h1>
        {!p && <div className="alert info">{t('pk.not_packing')}</div>}
        {p && cs && cs.cartons.length > 0 && (
          <div className="tabs one-row" role="tablist" data-testid="labels-what">
            <button role="tab" aria-selected={what === 'packs'} className={what === 'packs' ? 'active' : ''} onClick={() => setWhat('packs')} data-testid="labels-packs">{t('pk.pack_labels')}</button>
            <button role="tab" aria-selected={what === 'cartons'} className={what === 'cartons' ? 'active' : ''} onClick={() => setWhat('cartons')} data-testid="labels-cartons">
              {t('pk.carton_labels', { n: packedCartons.length })}</button>
          </div>)}
        {p && what === 'cartons' && cs && !showCartons && (
          <div className="card stack" data-testid="cartons-make">
            <p>{t('pk.cartons_line', { batch: cs.batch_code ?? '—', n: packedCartons.length })}</p>
            {opened > 0 && <p className="small muted" data-testid="cartons-opened">{t('pk.cartons_opened', { n: opened })}</p>}
            <Field label={t('pk.paper')} htmlFor="pk-paper">
              <select id="pk-paper" value={paper} onChange={(e) => setPaper(e.target.value as Paper)} data-testid="labels-paper">
                <option value="a4_8">{t('pk.paper_a4_8')}</option><option value="label_100x150">{t('pk.paper_100x150')}</option></select></Field>
            <button onClick={() => setShowCartons(true)} disabled={packedCartons.length === 0} data-testid="cartons-go">{t('pk.cartons_show')}</button>
          </div>)}
        {p && what === 'packs' && !sheet && (
          <div className="card stack" data-testid="labels-make">
            <p>{t('pk.batch_line', { batch: p.batch_code ?? '—', n: p.packed })}{p.packed > 0 ? ` · ${p.best_before ? t('pk.best_before', { date: date(p.best_before) }) : t('pk.best_before_old')}` : ''}</p>
            {reprint && <div className="alert warn" data-testid="reprint-note">{t('pk.reprint_note', { n: p.prints })}</div>}
            {reprint && <Field label={`${t('pk.reprint_why')} *`} htmlFor="pk-why" hint={t('pk.min5')}>
              <input id="pk-why" value={why} maxLength={300} onChange={(e) => setWhy(e.target.value)} data-testid="reprint-why" /></Field>}
            <ErrorBox error={act.error} />
            <button onClick={make} disabled={act.busy || p.packed === 0 || (reprint && why.trim().length < 5)} data-testid="labels-go">
              {t(reprint ? 'pk.reprint' : 'pk.make')}</button>
          </div>)}
      </div>
      {what === 'packs' && sheet && <Sheet sheet={sheet} page={page} setPage={setPage} />}
      {what === 'cartons' && cs && showCartons && <CartonSheetView sheet={cs} cartons={packedCartons} paper={paper} onBack={() => setShowCartons(false)} />}
    </div>
  );
}

function CartonSheetView({ sheet, cartons, paper, onBack }: { sheet: CartonSheet; cartons: CartonLabel[]; paper: Paper; onBack: () => void }) {
  const { t } = useI18n();
  const [page, setPage] = useState(0);
  const total = cartons.length;
  const { from, to } = sheetRange(page, total);
  const shown = cartons.slice(from, to);
  const [img, setImg] = useState<Record<string, string>>({});
  useEffect(() => {
    let live = true;
    void (async () => {
      const out: Record<string, string> = {};
      for (const c of shown) out[c.code] = await QRCode.toDataURL(c.code, { margin: 1, width: 360, errorCorrectionLevel: 'M' });
      if (live) setImg(out);
    })();
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sheet, from, to]);
  const pages = Math.ceil(total / LABELS_PER_SHEET);
  const tail = (s: string) => s.slice(s.lastIndexOf('-') + 1);
  return (
    <>
      <style>{`@media print { @page { size: ${PAPER_PAGE[paper]}; margin: ${paper === 'a4_8' ? '6mm' : '0'}; } }`}</style>
      <div className="row no-print" style={{ marginBottom: 12 }}>
        <span data-testid="labels-range">{t('pk.range', { from: total ? from + 1 : 0, to, n: total })}</span>
        {pages > 1 && <><button className="secondary" disabled={page === 0} onClick={() => setPage(page - 1)}>{t('common.back')}</button>
          <button className="secondary" disabled={page >= pages - 1} onClick={() => setPage(page + 1)}>{t('pk.next')}</button></>}
        <button className="secondary" onClick={onBack}>{t('pk.paper_change')}</button>
        <button onClick={() => window.print()} data-testid="labels-print">{t('labels.print_sheet')}</button>
      </div>
      <div className={`carton-sheet ${paper}`} data-testid="carton-sheet" data-paper={paper}>
        {shown.map((c) => (
          <div className="carton-label" key={c.code} data-testid="carton-label">
            {img[c.code] && <img src={img[c.code]} alt={`QR ${c.code}`} />}
            <div className="cl-text">
              <div className="cl-code mono">{c.code}</div>
              <div className="cl-big">{t('pk.carton_n', { n: c.n })}{c.sku ? ` · ${c.sku}` : ''}</div>
              <div className="cl-small mono">{t('pk.carton_range', { from: tail(c.first_serial), to: tail(c.last_serial) })}</div>
              <div className="cl-small">{sheet.crop}{sheet.gi_tag && sheet.gi_status === 'gi' ? ` · ${giLabel(sheet.gi_tag, t)}` : ''} · {seasonName(sheet.season)}</div>
              {c.packed_on && <div className="cl-small">{t('pk.packed_on', { date: date(c.packed_on) })}{c.best_before ? ` · ${t('pk.best_before', { date: date(c.best_before) })}` : ''}</div>}
              <div className="cl-small">{sheet.client}</div>
            </div>
          </div>
        ))}
      </div>
    </>
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
              <div className="label-small">{pk.best_before ? t('pk.best_before', { date: date(pk.best_before) }) : t('pk.best_before_old')}</div>
              <div className="label-code mono">{pk.serial}</div>
              <div className="label-small">{t('pk.scan')}</div>
            </div>
          </div>
        ))}
      </div>
    </>
  );
}
