// Migration 70 (Phase 3, release 3 of Veda's combined brief of 19 Oct 2026: Part D). One order drawing on several scopes.
// A client order holds the buyer, the market, the order number and ONE invoice number; each scope's Commercial person
// records its part, from a batch of its own, on the usual Commercial form ("Part of a client order"). The server makes
// every rule (app.client_order_new, app.reconcile through app.order_part_payload and app.order_shipment_payload) and
// decides who reads what (each reader sees the sections of the scopes he reaches; prices only where he may).
import { rpc } from './api';
import { kg, num } from './format';

type T = (key: string, vars?: Record<string, string | number>, fallback?: string) => string;

export interface OrderHead {
  id: string; code: string; order_no: string; status: 'open' | 'cancelled'; market: 'domestic' | 'export'; market_code: string;
  market_name: string | null; destination_country: string | null; invoice_no: string | null; note: string | null;
  client_id: string; client: string; client_code: string | null; crop_id: string; crop: string;
  buyer: string | null; buyer_country: string | null; created_at: string; created_by: string | null;
  cancelled_at: string | null; cancel_reason: string | null;
}
export interface OrderListRow extends OrderHead { parts: number; scopes: number; qty_kg: number; shipped_kg: number }
export interface OrderShipment { id: string; code: string; status: string; invoice_no: string | null; qty_kg: number; packs: string | null;
  dispatch_date: string | null; destination: string | null }
export interface OrderPart {
  id: string; code: string; status: string; on: string; batch_code: string | null; batch: string | null;
  gi_status: string; farm_verified: boolean; packs: { sku_id: string; name: string; units: number; size_kg: number }[];
  qty_kg: number; shipped_kg: number; shipments: OrderShipment[];
  price_per_kg?: number | null; currency?: string | null; total_value?: number | null;
}
export interface OrderSection { scope_id: string; scope: string; state: string; season: string; geography: string; parts: OrderPart[] }
export interface OrderDetail extends OrderHead {
  gi_status: string | null; farm_verified: boolean | null; sections: OrderSection[]; hidden_parts: number;
  qty_kg: number; shipped_kg: number; shipped: boolean; may_edit: boolean; may_invoice: boolean; may_cancel: boolean;
}
export interface OrderChoice { client_id: string; client: string; client_code: string | null; crop_id: string; crop: string;
  buyers: { id: string; name: string; country: string }[]; markets: { code: string; name: string }[] }
export interface OpenOrder extends OrderHead { fits: boolean; why: 'state' | 'market' | 'gi' | null; parts: number }

export const ordersList = (client?: string) => rpc<{ orders: OrderListRow[]; may_make: boolean }>('client_orders_list', client ? { p_client: client } : {});
export const orderDetail = (id: string) => rpc<OrderDetail>('client_order_detail', { p_order: id });
export const orderChoices = () => rpc<OrderChoice[]>('client_order_choices', {});
export const newOrder = (o: { client: string; crop: string; buyer: string; market: string; destination: string; orderNo: string; invoiceNo: string; note: string }) =>
  rpc<{ id: string; code: string }>('client_order_new', { p_client: o.client, p_crop: o.crop, p_buyer: o.buyer, p_market_code: o.market,
    p_destination: o.market === 'domestic' ? null : o.destination.trim(), p_order_no: o.orderNo.trim(),
    p_invoice_no: o.invoiceNo.trim() || null, p_note: o.note.trim() || null });
export const setOrderInvoice = (id: string, invoice: string) => rpc<{ invoice_no: string }>('client_order_invoice', { p_order: id, p_invoice_no: invoice.trim() });
export const cancelOrder = (id: string, reason: string) => rpc<{ status: string }>('client_order_cancel', { p_order: id, p_reason: reason.trim() });
export const openOrdersFor = (scope: string, batch?: string | null) => rpc<OpenOrder[]>('client_orders_open_for', { p_scope: scope, p_batch: batch ?? null });
export const orderOfPart = (part: string) => rpc<{ id: string; code: string; order_no: string; invoice_no: string | null; status: string } | null>('order_of_part', { p_fp: part });

/** Pure: what the client checks on an invoice number before the server does (2 to 40 letters, digits, / . _ - or spaces). */
export const invoiceOk = (s: string) => /^[A-Za-z0-9][A-Za-z0-9/._ -]{1,39}$/.test(s.trim());

/** Pure: an order's market in words (an export market by its profile's name, with the destination). */
export function marketText(o: Pick<OrderHead, 'market' | 'market_name' | 'destination_country'>, t: T): string {
  if (o.market === 'domestic') return t('exp.mkt.domestic', undefined, 'Domestic');
  return [o.market_name ?? t('exp.mkt.export', undefined, 'Export'), o.destination_country].filter(Boolean).join(' · ');
}

/** Pure: a batch's GI status and farm-verified status in words. */
export const giText = (gi: string | null | undefined, fv: boolean | null | undefined, t: T) =>
  `${t(`gi.${gi ?? 'unknown'}`, undefined, gi ?? '—')} · ${t(fv ? 'ord.farm_verified' : 'ord.not_farm_verified')}`;

/** Pure: a price as it is recorded (item 67: an order recorded before the currency was asked says so, never "220 /kg"). */
export function priceText(price: number | null | undefined, currency: string | null | undefined, t: T): string | null {
  if (price === null || price === undefined) return null;
  return currency ? `${num(price)} ${currency}/kg` : `${num(price)} /kg (${t('cv.currency_unknown')})`;
}

/** Pure: an order's packs in words ("6 × 1 kg pouch · 4 × 500 g pouch"). */
export const packsText = (p: OrderPart['packs']) => p.length ? p.map((x) => `${num(x.units, 0)} × ${x.name}`).join(' · ') : '—';

/** Pure: the kilograms of an order in a line ("10 kg sold, 6 kg shipped"). */
export const kgLine = (o: { qty_kg: number; shipped_kg: number }, t: T) => t('ord.kg_line', { kg: kg(o.qty_kg), shipped: kg(o.shipped_kg) });
