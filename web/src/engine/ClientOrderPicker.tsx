// Migration 70 (Phase 3, Part D): "Part of a client order" on the Commercial form. The open orders of this scope's client
// and crop that sell to a market of this scope; each says whether this batch may join it (the server's own check:
// app.client_orders_open_for) and, when not, why. While an order is chosen the order's buyer, market and number are its
// own (the form hides those fields; the server writes them). The server checks the part again when it is saved.
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { useI18n } from '../lib/i18n';
import { cached } from '../offline/cache';
import { marketText, openOrdersFor, type OpenOrder } from '../lib/orders';

export function ClientOrderPicker({ id, scopeId, sourceId, value, onChange }: {
  id: string; scopeId?: string; sourceId?: string; value: string; onChange: (v: string) => void;
}) {
  const { t } = useI18n();
  const [rows, setRows] = useState<OpenOrder[] | null>(null);
  useEffect(() => {
    if (!scopeId) { setRows([]); return; }
    let live = true;
    void cached(`open_orders:${scopeId}:${sourceId ?? ''}`, () => openOrdersFor(scopeId, sourceId))
      .then((r) => { if (live) setRows(r); }).catch(() => { if (live) setRows([]); });
    return () => { live = false; };
  }, [scopeId, sourceId]);
  const cur = rows?.find((o) => o.id === value);
  const why = (o: OpenOrder) => (o.why ? ` (${t(`ord.why.${o.why}`)})` : '');
  return (
    <div className="stack" data-testid="pick-client-order">
      <select id={id} name="client_order_id" value={value} onChange={(e) => onChange(e.target.value)}>
        <option value="">{t('ord.pick_none')}</option>
        {(rows ?? []).map((o) => (
          <option key={o.id} value={o.id} disabled={!o.fits && o.id !== value}>
            {o.code} · {o.buyer ?? '—'} · {o.order_no}{why(o)}
          </option>))}
      </select>
      {cur && (
        <p className="small" data-testid="client-order-chosen">
          {t('ord.pick_chosen', { buyer: cur.buyer ?? '—', market: marketText(cur, t), no: cur.order_no })}
          {cur.invoice_no ? ` · ${t('ord.invoice')} ${cur.invoice_no}` : ` · ${t('ord.no_invoice')}`}
        </p>)}
      {rows && rows.length === 0 && <p className="small muted">{t('ord.pick_empty')}</p>}
      <p className="small"><Link to="/orders?new=1">{t('ord.pick_new')}</Link></p>
    </div>
  );
}
