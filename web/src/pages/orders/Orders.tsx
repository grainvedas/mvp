// Migration 70 (Phase 3, release 3 of Veda's combined brief of 19 Oct 2026: Part D). One order drawing on several scopes.
//   /orders            the client orders the person reads (a client account: those with a part in the scopes it
//                      reaches); "New client order" for whoever holds Commercial in one of a client's scopes of a crop
//   /orders/:orderId   one order: its buyer, market, number and one invoice; then one section per scope with its parts
//                      (batch, packs, kilograms, shipments under the order's invoice). The evidence pack of release 4
//                      takes the same sections.
// Every rule is the server's: who makes an order, which batch may be a part, the one invoice, who sees which section and
// which price. Nothing here hides anything the server sent.
import { useMemo, useState, type FormEvent } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { useI18n } from '../../lib/i18n';
import { useAsync, useAction } from '../../lib/useAsync';
import { date, dateTime, kg } from '../../lib/format';
import { Badge, Empty, ErrorBox, Field, Loading } from '../../shell/ui';
import {
  cancelOrder, giText, invoiceOk, kgLine, marketText, newOrder, orderChoices, orderDetail, ordersList, packsText, priceText, setOrderInvoice,
  type OrderChoice, type OrderDetail, type OrderPart,
} from '../../lib/orders';

type T = (key: string, vars?: Record<string, string | number>, fallback?: string) => string;

export function OrdersPage() {
  const { t } = useI18n();
  const [sp] = useSearchParams();
  const client = sp.get('client') ?? undefined;
  const r = useAsync(() => ordersList(client), [client]);
  const [making, setMaking] = useState(sp.get('new') === '1');
  if (r.loading && !r.data) return <Loading />;
  if (!r.data) return <ErrorBox error={r.error} onRetry={r.reload} />;
  const d = r.data;
  return (
    <div data-testid="orders-page">
      <h1>{t('ord.title')}</h1>
      <p className="muted">{t('ord.what')}</p>
      {d.may_make && !making && (
        <p><button type="button" onClick={() => setMaking(true)} data-testid="ord-new-open">{t('ord.new')}</button></p>)}
      {d.may_make && making && <NewOrder onCancel={() => setMaking(false)} preset={{ client: sp.get('client') ?? '', crop: sp.get('crop') ?? '' }} />}
      <div className="card" data-testid="ord-list">
        <h2>{t('ord.list')}</h2>
        {d.orders.length === 0 ? <Empty>{t('ord.none')}</Empty> : (
          <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
            {d.orders.map((o) => (
              <li key={o.id} className="cv-row" data-testid="ord-row">
                <div><Link to={`/orders/${o.id}`}><strong className="mono">{o.code}</strong></Link> · <Badge value={o.status === 'open' ? 'verified' : 'fail'} label={t(`ord.st.${o.status}`)} /></div>
                <div>{o.buyer ?? '—'} · <span className="mono small">{o.order_no}</span>{o.invoice_no && <span className="small"> · {t('ord.invoice')} <span className="mono">{o.invoice_no}</span></span>}</div>
                <div className="small muted">{o.client} · {o.crop} · {marketText(o, t)}</div>
                <div className="small">{t('ord.parts_line', { parts: o.parts, scopes: o.scopes })} · {kgLine(o, t)}</div>
              </li>))}
          </ul>)}
      </div>
    </div>
  );
}

function NewOrder({ onCancel, preset }: { onCancel: () => void; preset: { client: string; crop: string } }) {
  const { t } = useI18n();
  const nav = useNavigate();
  const act = useAction();
  const ch = useAsync(() => orderChoices(), []);
  const [pick, setPick] = useState(preset.client && preset.crop ? `${preset.client}|${preset.crop}` : '');
  const [buyer, setBuyer] = useState('');
  const [market, setMarket] = useState('');
  const [dest, setDest] = useState('');
  const [orderNo, setOrderNo] = useState('');
  const [invoice, setInvoice] = useState('');
  const [note, setNote] = useState('');
  const choices = ch.data ?? [];
  const cur: OrderChoice | undefined = useMemo(() => {
    if (choices.length === 1 && !pick) return choices[0];
    return choices.find((c) => `${c.client_id}|${c.crop_id}` === pick);
  }, [choices, pick]);
  const exportMkt = !!market && market !== 'domestic';
  const problem = !cur ? t('ord.need_client') : !buyer ? t('ord.need_buyer') : !market ? t('ord.need_market')
    : exportMkt && dest.trim().length < 2 ? t('ord.need_destination') : orderNo.trim().length < 2 ? t('ord.need_order_no')
    : invoice.trim() && !invoiceOk(invoice) ? t('ord.invoice_shape') : null;
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (problem || !cur) return;
    void act.run(async () => {
      const r = await newOrder({ client: cur.client_id, crop: cur.crop_id, buyer, market, destination: dest, orderNo, invoiceNo: invoice, note });
      nav(`/orders/${r.id}`);
    });
  };
  if (ch.loading && !ch.data) return <Loading />;
  return (
    <form className="card stack" onSubmit={submit} data-testid="ord-new">
      <h2>{t('ord.new')}</h2>
      <p className="small muted">{t('ord.new_what')}</p>
      {choices.length > 1 && (
        <Field label={t('ord.client_crop')} htmlFor="ord-cc">
          <select id="ord-cc" value={pick} onChange={(e) => { setPick(e.target.value); setBuyer(''); setMarket(''); }} data-testid="ord-cc">
            <option value="">—</option>
            {choices.map((c) => <option key={`${c.client_id}|${c.crop_id}`} value={`${c.client_id}|${c.crop_id}`}>{c.client} · {c.crop}</option>)}
          </select>
        </Field>)}
      {choices.length === 1 && cur && <p><strong>{cur.client}</strong> · {cur.crop}</p>}
      {cur && (<>
        <Field label={t('ord.buyer')} htmlFor="ord-buyer" hint={cur.buyers.length === 0 ? t('ord.no_buyers') : undefined}>
          <select id="ord-buyer" value={buyer} onChange={(e) => setBuyer(e.target.value)} data-testid="ord-buyer">
            <option value="">—</option>
            {cur.buyers.map((b) => <option key={b.id} value={b.id}>{b.name} · {b.country}</option>)}
          </select>
        </Field>
        <Field label={t('ord.market')} htmlFor="ord-market">
          <select id="ord-market" value={market} onChange={(e) => setMarket(e.target.value)} data-testid="ord-market">
            <option value="">—</option>
            {cur.markets.map((m) => <option key={m.code} value={m.code}>{m.code === 'domestic' ? t('exp.mkt.domestic') : `${t('exp.mkt.export')}: ${m.name}`}</option>)}
          </select>
        </Field>
        {exportMkt && (
          <Field label={t('ord.destination')} htmlFor="ord-dest">
            <input id="ord-dest" value={dest} onChange={(e) => setDest(e.target.value)} data-testid="ord-dest" />
          </Field>)}
        <Field label={t('ord.order_no')} htmlFor="ord-no">
          <input id="ord-no" value={orderNo} onChange={(e) => setOrderNo(e.target.value)} data-testid="ord-no" autoComplete="off" />
        </Field>
        <Field label={t('ord.invoice_no')} htmlFor="ord-inv" hint={t('ord.invoice_hint')}>
          <input id="ord-inv" value={invoice} onChange={(e) => setInvoice(e.target.value)} data-testid="ord-inv" autoComplete="off" />
        </Field>
        <Field label={t('ord.note')} htmlFor="ord-note">
          <textarea id="ord-note" rows={2} value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} />
        </Field>
      </>)}
      {problem && cur && <p className="small muted" data-testid="ord-problem">{problem}</p>}
      <ErrorBox error={act.error} />
      <div className="row" style={{ justifyContent: 'flex-start' }}>
        <button type="submit" disabled={!!problem || act.busy} data-testid="ord-save">{t('ord.save')}</button>
        <button type="button" className="secondary" onClick={onCancel}>{t('common.cancel')}</button>
      </div>
    </form>
  );
}

export function OrderPage() {
  const { orderId = '' } = useParams();
  const { t } = useI18n();
  const r = useAsync(() => orderDetail(orderId), [orderId]);
  if (r.loading && !r.data) return <Loading />;
  if (!r.data) return <ErrorBox error={r.error} onRetry={r.reload} />;
  const o = r.data;
  return (
    <div data-testid="order-page">
      <p className="small muted"><Link to="/orders">{t('ord.title')}</Link> · {o.client}</p>
      <h1 className="mono">{o.code}</h1>
      <div className="card" data-testid="ord-head">
        <dl className="kv">
          <dt>{t('ord.status')}</dt><dd><Badge value={o.status === 'open' ? 'verified' : 'fail'} label={t(`ord.st.${o.status}`)} /></dd>
          <dt>{t('ord.client_crop')}</dt><dd>{o.client} · {o.crop}</dd>
          <dt>{t('ord.buyer')}</dt><dd>{o.buyer ?? '—'}{o.buyer_country ? ` · ${o.buyer_country}` : ''}</dd>
          <dt>{t('ord.market')}</dt><dd>{marketText(o, t)}</dd>
          <dt>{t('ord.order_no')}</dt><dd className="mono">{o.order_no}</dd>
          <dt>{t('ord.invoice_no')}</dt><dd data-testid="ord-invoice">{o.invoice_no ? <span className="mono">{o.invoice_no}</span> : <span className="muted">{t('ord.no_invoice')}</span>}
            {o.shipped && <span className="small muted"> · {t('ord.invoice_fixed')}</span>}</dd>
          {o.gi_status && <><dt>{t('ord.gi')}</dt><dd>{giText(o.gi_status, o.farm_verified, t)}</dd></>}
          <dt>{t('ord.kg')}</dt><dd>{kgLine(o, t)}</dd>
          <dt>{t('ord.made')}</dt><dd>{dateTime(o.created_at)}{o.created_by ? ` · ${o.created_by}` : ''}</dd>
          {o.note && <><dt>{t('ord.note')}</dt><dd>{o.note}</dd></>}
          {o.status === 'cancelled' && <><dt>{t('ord.cancelled')}</dt><dd>{o.cancelled_at ? dateTime(o.cancelled_at) : ''}{o.cancel_reason ? ` · “${o.cancel_reason}”` : ''}</dd></>}
        </dl>
        {o.may_invoice && <InvoiceForm o={o} onDone={r.reload} t={t} />}
        {o.may_edit && <p className="small muted" data-testid="ord-how">{t('ord.how_part')}</p>}
      </div>

      <h2>{t('ord.sections')}</h2>
      {o.sections.length === 0 ? <div className="card"><Empty>{t('ord.no_parts')}</Empty></div> : o.sections.map((s) => (
        <div key={s.scope_id} className="card" data-testid="ord-section">
          <h3>{s.scope}</h3>
          <p className="small muted">{[s.geography, s.state].filter(Boolean).join(', ')}</p>
          <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
            {s.parts.map((p) => <PartRow key={p.id} p={p} t={t} />)}
          </ul>
        </div>))}
      {o.hidden_parts > 0 && <p className="small muted" data-testid="ord-hidden">{t('ord.hidden_parts', { n: o.hidden_parts })}</p>}

      {o.may_cancel && <CancelForm o={o} onDone={r.reload} t={t} />}
    </div>
  );
}

function PartRow({ p, t }: { p: OrderPart; t: T }) {
  const price = priceText(p.price_per_kg, p.currency, t);
  return (
    <li data-testid="ord-part">
      <div><Link to={`/records/${p.id}`} className="mono">{p.code}</Link> · <Badge value={p.status} /></div>
      <div className="small">{t('ord.batch')} <span className="mono">{p.batch_code ?? p.batch ?? '—'}</span> · {giText(p.gi_status, p.farm_verified, t)}</div>
      <div className="small">{packsText(p.packs)} · {kg(p.qty_kg)}{price && <span data-testid="ord-price"> · {price}</span>}</div>
      {p.shipments.length === 0 ? <div className="small muted">{t('ord.not_shipped')}</div> : p.shipments.map((sh) => (
        <div key={sh.id} className="small muted">
          <Link to={`/records/${sh.id}`} className="mono">{sh.code}</Link> · <Badge value={sh.status} /> · {t('ord.invoice')} <span className="mono">{sh.invoice_no ?? '—'}</span>
          {' · '}{kg(sh.qty_kg)}{sh.dispatch_date ? ` · ${date(sh.dispatch_date)}` : ''}
        </div>))}
    </li>
  );
}

function InvoiceForm({ o, onDone, t }: { o: OrderDetail; onDone: () => void; t: T }) {
  const act = useAction();
  const [v, setV] = useState(o.invoice_no ?? '');
  const ok = invoiceOk(v) && v.trim() !== (o.invoice_no ?? '');
  return (
    <form className="stack" onSubmit={(e) => { e.preventDefault(); if (ok) void act.run(async () => { await setOrderInvoice(o.id, v); onDone(); }); }} data-testid="ord-invoice-form">
      <Field label={o.invoice_no ? t('ord.invoice_change') : t('ord.invoice_set')} htmlFor="ord-inv2" hint={t('ord.invoice_hint')}>
        <input id="ord-inv2" value={v} onChange={(e) => setV(e.target.value)} autoComplete="off" data-testid="ord-inv2" />
      </Field>
      <ErrorBox error={act.error} />
      <div className="row" style={{ justifyContent: 'flex-start' }}>
        <button type="submit" className="secondary" disabled={!ok || act.busy} data-testid="ord-inv-save">{t('ord.invoice_save')}</button>
      </div>
    </form>
  );
}

function CancelForm({ o, onDone, t }: { o: OrderDetail; onDone: () => void; t: T }) {
  const act = useAction();
  const [why, setWhy] = useState('');
  const ok = why.trim().length >= 10;
  return (
    <form className="card stack" onSubmit={(e) => { e.preventDefault(); if (ok) void act.run(async () => { await cancelOrder(o.id, why); onDone(); }); }} data-testid="ord-cancel">
      <h2>{t('ord.cancel')}</h2>
      <p className="small muted">{t('ord.cancel_what')}</p>
      <Field label={t('ord.cancel_why')} htmlFor="ord-why">
        <textarea id="ord-why" rows={2} value={why} maxLength={500} onChange={(e) => setWhy(e.target.value)} data-testid="ord-why" />
      </Field>
      <ErrorBox error={act.error} />
      <div className="row" style={{ justifyContent: 'flex-start' }}>
        <button type="submit" className="danger" disabled={!ok || act.busy} data-testid="ord-cancel-go">{t('ord.cancel_go')}</button>
      </div>
    </form>
  );
}
