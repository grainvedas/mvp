// Migration 70 (Phase 3, release 3 of Veda's combined brief: Part D, with item 67's display fixes). The rules are the
// database's (tests/65_client_orders.sql); these hold the screens' side: the orders list and an order's page show what
// the server sent (one section per scope, a price only when it sent one); the new order's form asks what the server
// asks; the Commercial form hides the order's own fields while a client order is chosen and offers only the orders a
// batch fits; a shipment of a part is filled in with the order's invoice; a price with no currency says so (item 67);
// the refusals in plain words; every new word in Hindi.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
import { enPublic } from '../src/lib/i18n.public';
import { plainWords } from '../src/lib/plainErrors';
import { giText, invoiceOk, marketText, packsText, priceText, type OrderDetail, type OpenOrder } from '../src/lib/orders';
import { cvTable } from '../src/lib/clientViews';
import { withValueRules } from '../src/engine/widgets';
import { NAV, ROLE_MENUS, type NavWho } from '../src/shell/Layout';
import { NO_RIGHTS, type FieldDef } from '../src/lib/types';

vi.mock('../src/auth/AuthProvider', async (orig) => ({ ...(await orig<typeof import('../src/auth/AuthProvider')>()), useAuth: () => ({ ctx: null }) }));

const tr = (d: Record<string, string>) => (k: string, v?: Record<string, string | number>, f?: string) => {
  let s = d[k] ?? f ?? k;
  for (const [n, x] of Object.entries(v ?? {})) s = s.replaceAll(`{${n}}`, String(x));
  return s;
};
const T = tr({ ...enPublic, ...en });
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

const head = {
  id: 'o1', code: 'ORD-TCUP-0001', order_no: 'PO-70-1', status: 'open' as const, market: 'domestic' as const, market_code: 'domestic', market_name: 'Domestic',
  destination_country: null, invoice_no: 'INV-70-1', note: null, client_id: 'c1', client: 'Test Client UP', client_code: 'TCUP', crop_id: 'k', crop: 'Kalanamak Rice',
  buyer: 'Delhi Wholesale', buyer_country: 'IN', created_at: '2026-10-27T05:00:00Z', created_by: 'Commercial Manager', cancelled_at: null, cancel_reason: null,
};
const part = (id: string, kgs: number, priced: boolean) => ({
  id, code: `CM-${id}`, status: 'verified', on: '2026-10-27', batch_code: `TCUP-KNM-KH26-B000${id}`, batch: `PK-${id}`, gi_status: 'unknown', farm_verified: true,
  packs: [{ sku_id: 's', name: '1 kg pouch', units: kgs, size_kg: 1 }], qty_kg: kgs, shipped_kg: kgs,
  shipments: [{ id: `S${id}`, code: `SH-${id}`, status: 'verified', invoice_no: 'INV-70-1', qty_kg: kgs, packs: String(kgs), dispatch_date: '2026-10-27', destination: 'Delhi' }],
  ...(priced ? { price_per_kg: 120, currency: 'INR', total_value: 120 * kgs } : {}),
});
const detail = (o: Partial<OrderDetail> = {}): OrderDetail => ({
  ...head, gi_status: 'unknown', farm_verified: true, hidden_parts: 0, qty_kg: 10, shipped_kg: 10, shipped: true, may_edit: false, may_invoice: false, may_cancel: false,
  sections: [
    { scope_id: 'a', scope: 'Kalanamak Rice · KH26 · Nagaon mill', state: 'Assam', season: 'KH26', geography: 'Nagaon mill', parts: [part('2', 4, false)] },
    { scope_id: 'u', scope: 'Kalanamak Rice · KH26 · Basti mill', state: 'Uttar Pradesh', season: 'KH26', geography: 'Basti mill', parts: [part('1', 6, false)] },
  ],
  ...o,
});

describe('D · the words of an order', () => {
  it('the market, the GI status, the packs, the invoice shape', () => {
    expect(marketText(head, T)).toBe('Domestic');
    expect(marketText({ market: 'export', market_name: 'EU (Netherlands)', destination_country: 'Netherlands' }, T)).toBe('EU (Netherlands) · Netherlands');
    expect(giText('unknown', true, T)).toBe(`${en['gi.unknown']} · ${en['ord.farm_verified']}`);
    expect(giText('non_gi', false, T)).toBe(`${en['gi.non_gi']} · ${en['ord.not_farm_verified']}`);
    expect(packsText([{ sku_id: 'a', name: '1 kg pouch', units: 6, size_kg: 1 }, { sku_id: 'b', name: '500 g pouch', units: 4, size_kg: 0.5 }])).toBe('6 × 1 kg pouch · 4 × 500 g pouch');
    expect(invoiceOk('INV-70-1')).toBe(true);
    expect(invoiceOk('EXP/70/1')).toBe(true);
    expect(invoiceOk('x')).toBe(false);
    expect(invoiceOk('-INV')).toBe(false);
  });
  it('item 67 (2): a price recorded before the currency was asked says so, on the screen and in the export', () => {
    expect(priceText(220, null, T)).toBe(`220 /kg (${en['cv.currency_unknown']})`);
    expect(priceText(120, 'INR', T)).toBe('120 INR/kg');
    expect(priceText(null, 'INR', T)).toBeNull();
    const x = cvTable({ key: 'orders', columns: ['code', 'price_per_kg', 'currency'], rows: [['CM-1', 220, null], ['CM-2', null, null], ['CM-3', 120, 'INR']] }, T);
    expect(x.rows.map((r) => r[2])).toEqual([en['cv.currency_unknown'], null, 'INR']);
  });
});

describe('D · the Commercial form', () => {
  const f = (key: string, extra: Partial<FieldDef> = {}) => ({ key, type: 'text', label: key, required: false, ...extra }) as FieldDef;
  const form = [f('client_order_id', { type: 'client_order' }), f('buyer_id', { hidden_if_set: 'client_order_id' }), f('market', { hidden_if_set: 'client_order_id' }),
    f('order_no', { hidden_if_set: 'client_order_id' }), f('packs'), f('price_per_kg')];
  it('the order\'s own fields hide while a client order is chosen (the server writes them); packs and price stay', () => {
    expect(withValueRules(form, {}).map((x) => x.key)).toEqual(['client_order_id', 'buyer_id', 'market', 'order_no', 'packs', 'price_per_kg']);
    expect(withValueRules(form, { client_order_id: 'o1' }).map((x) => x.key)).toEqual(['client_order_id', 'packs', 'price_per_kg']);
  });
  it('offers the open orders; one this batch does not fit is shown with why and cannot be chosen', async () => {
    const api = await import('../src/lib/api');
    const open: OpenOrder[] = [{ ...head, fits: true, why: null, parts: 1 },
      { ...head, id: 'o2', code: 'ORD-TCUP-0002', order_no: 'EX-70-1', market: 'export', market_code: 'export', market_name: 'Export', destination_country: 'Netherlands', invoice_no: null, fits: false, why: 'market', parts: 0 }];
    const spy = vi.spyOn(api, 'rpc').mockResolvedValue(open as never);
    const { ClientOrderPicker } = await import('../src/engine/ClientOrderPicker');
    const changed: string[] = [];
    render(<MemoryRouter><ClientOrderPicker id="x" scopeId="s1" sourceId="b1" value="" onChange={(v) => changed.push(v)} /></MemoryRouter>);
    await waitFor(() => expect(screen.getAllByRole('option')).toHaveLength(3));
    expect(spy).toHaveBeenCalledWith('client_orders_open_for', { p_scope: 's1', p_batch: 'b1' });
    const opts = screen.getAllByRole('option') as HTMLOptionElement[];
    expect(opts[2].disabled).toBe(true);
    expect(opts[2].textContent).toContain(en['ord.why.market']);
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'o1' } });
    expect(changed).toEqual(['o1']);
  });
});

describe('D · an order\'s page', () => {
  it('one section per scope, one invoice; no price unless the server sent one; nothing to change for a reader', async () => {
    const api = await import('../src/lib/api');
    const spy = vi.spyOn(api, 'rpc').mockResolvedValue(detail() as never);
    const { OrderPage } = await import('../src/pages/orders/Orders');
    render(<MemoryRouter initialEntries={['/orders/o1']}><Routes><Route path="/orders/:orderId" element={<OrderPage />} /></Routes></MemoryRouter>);
    await waitFor(() => expect(screen.getAllByTestId('ord-section')).toHaveLength(2));
    expect(spy).toHaveBeenCalledWith('client_order_detail', { p_order: 'o1' });
    expect(screen.getByTestId('ord-invoice').textContent).toContain('INV-70-1');
    expect(screen.getByTestId('ord-invoice').textContent).toContain(en['ord.invoice_fixed']);
    const [assam, up] = screen.getAllByTestId('ord-section');
    expect(within(assam).getByText('Kalanamak Rice · KH26 · Nagaon mill')).toBeTruthy();
    expect(within(up).getByText(/TCUP-KNM-KH26-B0001/)).toBeTruthy();
    expect(screen.queryByTestId('ord-price')).toBeNull();
    expect(screen.queryByTestId('ord-invoice-form')).toBeNull();
    expect(screen.queryByTestId('ord-cancel')).toBeNull();
    expect(screen.queryByTestId('ord-how')).toBeNull();
  });
  it('a reader of one scope: his section, his price, and "more parts in scopes you do not see"', async () => {
    const api = await import('../src/lib/api');
    vi.spyOn(api, 'rpc').mockResolvedValue(detail({ hidden_parts: 1, may_edit: true, sections: [
      { scope_id: 'u', scope: 'Kalanamak Rice · KH26 · Basti mill', state: 'Uttar Pradesh', season: 'KH26', geography: 'Basti mill', parts: [part('1', 6, true)] }] }) as never);
    const { OrderPage } = await import('../src/pages/orders/Orders');
    render(<MemoryRouter initialEntries={['/orders/o1']}><Routes><Route path="/orders/:orderId" element={<OrderPage />} /></Routes></MemoryRouter>);
    await waitFor(() => expect(screen.getAllByTestId('ord-section')).toHaveLength(1));
    expect(screen.getByTestId('ord-price').textContent).toContain('120 INR/kg');
    expect(screen.getByTestId('ord-hidden').textContent).toBe(T('ord.hidden_parts', { n: 1 }));
    expect(screen.getByTestId('ord-how')).toBeTruthy();
  });
  it('an order with no part yet: its invoice set, then cancelled with a reason', async () => {
    const api = await import('../src/lib/api');
    const spy = vi.spyOn(api, 'rpc').mockImplementation(((fn: string) => fn === 'client_order_detail'
      ? Promise.resolve(detail({ sections: [], invoice_no: null, shipped: false, qty_kg: 0, shipped_kg: 0, may_edit: true, may_invoice: true, may_cancel: true }))
      : Promise.resolve({})) as never);
    const { OrderPage } = await import('../src/pages/orders/Orders');
    render(<MemoryRouter initialEntries={['/orders/o1']}><Routes><Route path="/orders/:orderId" element={<OrderPage />} /></Routes></MemoryRouter>);
    await waitFor(() => expect(screen.getByTestId('ord-invoice-form')).toBeTruthy());
    fireEvent.change(screen.getByTestId('ord-inv2'), { target: { value: 'INV-70-9' } });
    fireEvent.click(screen.getByTestId('ord-inv-save'));
    await waitFor(() => expect(spy).toHaveBeenCalledWith('client_order_invoice', { p_order: 'o1', p_invoice_no: 'INV-70-9' }));
    expect((screen.getByTestId('ord-cancel-go') as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(screen.getByTestId('ord-why'), { target: { value: 'buyer withdrew the order' } });
    fireEvent.click(screen.getByTestId('ord-cancel-go'));
    await waitFor(() => expect(spy).toHaveBeenCalledWith('client_order_cancel', { p_order: 'o1', p_reason: 'buyer withdrew the order' }));
  });
});

describe('D · the list and the new order', () => {
  it('lists the orders; whoever may make one gets the form, which asks what the server asks', async () => {
    const api = await import('../src/lib/api');
    const spy = vi.spyOn(api, 'rpc').mockImplementation(((fn: string) => {
      if (fn === 'client_orders_list') return Promise.resolve({ may_make: true, orders: [{ ...head, parts: 2, scopes: 2, qty_kg: 10, shipped_kg: 10 }] });
      if (fn === 'client_order_choices') return Promise.resolve([{ client_id: 'c1', client: 'Test Client UP', client_code: 'TCUP', crop_id: 'k', crop: 'Kalanamak Rice',
        buyers: [{ id: 'b1', name: 'Delhi Wholesale', country: 'IN' }, { id: 'b2', name: 'Rotterdam Rice BV', country: 'NL' }],
        markets: [{ code: 'domestic', name: 'Domestic' }, { code: 'export', name: 'EU' }] }]);
      if (fn === 'client_order_new') return Promise.resolve({ id: 'o9', code: 'ORD-TCUP-0009' });
      return Promise.resolve(null);
    }) as never);
    const { OrdersPage } = await import('../src/pages/orders/Orders');
    render(<MemoryRouter initialEntries={['/orders']}><Routes><Route path="/orders" element={<OrdersPage />} /><Route path="/orders/:id" element={<p>opened</p>} /></Routes></MemoryRouter>);
    await waitFor(() => expect(screen.getAllByTestId('ord-row')).toHaveLength(1));
    expect(screen.getByTestId('ord-row').textContent).toContain(T('ord.parts_line', { parts: 2, scopes: 2 }));
    fireEvent.click(screen.getByTestId('ord-new-open'));
    await waitFor(() => expect(screen.getByTestId('ord-buyer')).toBeTruthy());
    expect((screen.getByTestId('ord-save') as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(screen.getByTestId('ord-buyer'), { target: { value: 'b2' } });
    fireEvent.change(screen.getByTestId('ord-market'), { target: { value: 'export' } });
    fireEvent.change(screen.getByTestId('ord-no'), { target: { value: 'EX-70-1' } });
    expect(screen.getByTestId('ord-problem').textContent).toBe(en['ord.need_destination']);
    fireEvent.change(screen.getByTestId('ord-dest'), { target: { value: 'Netherlands' } });
    fireEvent.click(screen.getByTestId('ord-save'));
    await waitFor(() => expect(spy).toHaveBeenCalledWith('client_order_new', { p_client: 'c1', p_crop: 'k', p_buyer: 'b2', p_market_code: 'export',
      p_destination: 'Netherlands', p_order_no: 'EX-70-1', p_invoice_no: null, p_note: null }));
    await waitFor(() => expect(screen.getByText('opened')).toBeTruthy());
  });
  it('a client account reads orders; client staff do not; the managers have it in their menus', () => {
    const who = (o: Partial<NavWho>): NavWho => ({ role: 'operator', can: NO_RIGHTS, farmerSlot: false, joiner: false, employee: true, ...o });
    const shown = (w: NavWho) => NAV.filter((n) => n.show(w)).map((n) => n.to);
    expect(shown(who({ orders: true }))).toContain('/orders');
    expect(shown(who({}))).not.toContain('/orders');
    expect(ROLE_MENUS.admin.watch.map((m) => m.to)).toContain('/orders');
    expect(ROLE_MENUS.state_manager.watch.map((m) => m.to)).toContain('/orders');
    expect(ROLE_MENUS.client_manager.scopes.map((m) => m.to)).toContain('/orders');
  });
});

describe('the database\'s words, in plain words; Hindi for every new word', () => {
  it('the refusals', () => {
    expect(plainWords('commercial: every batch of client order ORD-TCUP-0001 has the same GI status and farm-verified status (the order: GI not confirmed, farm-verified; this batch: non-GI, not farm-verified)', T))
      .toBe(T('err.ord_gi', { code: 'ORD-TCUP-0001', order: 'GI not confirmed, farm-verified', batch: 'non-GI, not farm-verified' }));
    expect(plainWords('shipment: client order ORD-TCUP-0001 has one invoice, INV-70-1', T)).toBe(T('err.ord_one_invoice', { code: 'ORD-TCUP-0001', invoice: 'INV-70-1' }));
    expect(plainWords('shipment: client order ORD-TCUP-0002 has no invoice number yet: it is set on the order first (one invoice per order)', T)).toBe(T('err.ord_no_invoice', { code: 'ORD-TCUP-0002' }));
    expect(plainWords('commercial: this batch has not passed QC for the market of client order ORD-TCUP-0002 (nor carries the client\'s written acceptance)', T)).toBe(T('err.ord_market', { code: 'ORD-TCUP-0002' }));
    expect(plainWords('commercial: the client is not Active in this scope\'s state: no part of client order ORD-TCUP-0003 here', T)).toBe(T('err.ord_state', { code: 'ORD-TCUP-0003' }));
    expect(plainWords('client order ORD-TCUP-0001: the invoice is fixed once a part has shipped (INV-70-1)', T)).toBe(T('err.ord_invoice_fixed', { code: 'ORD-TCUP-0001', invoice: 'INV-70-1' }));
    expect(plainWords('client order ORD-TCUP-0001 has parts: it is cancelled only while it has none', T)).toBe(T('err.ord_has_parts', { code: 'ORD-TCUP-0001' }));
    expect(plainWords('you may not make an order for this client and crop (you hold Commercial in none of its active scopes of that crop, where the client is Active)', T)).toBe(en['err.ord_not_allowed']);
    expect(plainWords('client order: the buyer is not one of this client\'s active buyers', T)).toBe(en['err.co_buyer_client']);
    expect(plainWords('commercial: client order ORD-TCUP-0005 was cancelled', T)).toBe(T('err.ord_cancelled', { code: 'ORD-TCUP-0005' }));
  });
  it('Hindi for every new word', () => {
    const keys = Object.keys(en).filter((x) => x.startsWith('ord.') || x.startsWith('err.ord_') || x.startsWith('audit.client_order_') || ['audit.order_no', 'audit.invoice_no', 'nav.orders', 'pick.client_order', 'field.commercial.client_order_id',
      'computed.client_order', 'cv.t.client_orders', 'cv.client_orders_what', 'cv.part_of', 'cv.c.client_order', 'cv.c.invoice_no', 'cv.c.parts', 'cv.currency_unknown',
      'cv.price_line_nocur'].includes(x));
    expect(keys.length).toBeGreaterThan(85);
    for (const k of keys) expect(hi[k], k).toBeTruthy();
  });
});
