// The farmer's receipt for a lot weighed at the farm gate (migration 52, C1): what was weighed, where, its moisture, and,
// where the scope records it, the price and the payment (the transaction ID only: never an account number). Printed or
// shown on the phone to the farmer. The record itself is the proof; the receipt says what it holds.
import { useMemo } from 'react';
import { Link, useParams } from 'react-router-dom';
import { rpc } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { date, dateTime, kg, num } from '../../lib/format';
import type { FootprintDetail, StageForm } from '../../lib/types';
import { ErrorBox, Loading } from '../../shell/ui';
import { cached } from '../../offline/cache';

export interface LotPayment { footprint_id: string; price_per_quintal: number | null; amount: number | null; status: 'pending' | 'paid';
  mode: 'bank' | 'upi' | 'cash' | null; txn_ref: string | null; updated_at: string }

/** The lot's payment, where the reader may see it (the person who recorded it, the client's Client Manager); else null. */
export async function lotPayment(fp: string): Promise<LotPayment | null> {
  const { data, error } = await supabase.from('lot_payments').select('*').eq('footprint_id', fp).maybeSingle();
  if (error) return null;
  return (data as LotPayment | null) ?? null;
}

export function Receipt() {
  const { id = '' } = useParams();
  const { t } = useI18n();
  const d = useAsync(() => cached(`receipt:${id}`, () => rpc<FootprintDetail>('footprint_detail', { p_fp: id })), [id]);
  const scopeId = d.data?.footprint.scope_id, stage = d.data?.footprint.stage_type;
  const sf = useAsync(() => (scopeId && stage ? cached(`stage_form:${scopeId}:${stage}`, () => rpc<StageForm>('stage_form', { p_scope: scopeId, p_stage: stage })) : Promise.resolve(null)), [scopeId, stage]);
  const pay = useAsync(() => (id ? lotPayment(id) : Promise.resolve(null)), [id]);
  const rows = useMemo(() => {
    if (!d.data) return [];
    const f = d.data.footprint, p = f.payload as Record<string, unknown>, c = (f.computed ?? {}) as Record<string, unknown>;
    const out: [string, string, string][] = [];
    const add = (k: string, label: string, v: string | null | undefined) => { if (v !== null && v !== undefined && v !== '') out.push([k, label, v]); };
    add('gross', t('field.gross_kg'), p.gross_kg !== undefined ? kg(Number(p.gross_kg)) : null);
    add('bags', t('field.bags'), p.bags !== undefined ? num(Number(p.bags), 0) : null);
    add('tare', t('field.tare_kg_per_bag'), p.tare_kg_per_bag !== undefined ? kg(Number(p.tare_kg_per_bag)) : null);
    add('moisture', t('computed.moisture_avg'), c.moisture_avg !== undefined ? `${num(Number(c.moisture_avg), 2)} %` : null);
    add('where', t('rc.where'), c.collection_point === 'farm' ? t('cp.at_farm') : (c.collection_point as string | undefined));
    add('by', t('field.delivered_by'), p.delivered_by ? `${t(`opt.${String(p.delivered_by)}`)}${p.delivered_by === 'agent' && p.agent_name ? ` (${String(p.agent_name)})` : ''}` : null);
    add('condition', t('field.condition'), p.condition ? t(`opt.${String(p.condition)}`) : null);
    add('harvest', t('field.harvest_date'), typeof p.harvest_date === 'string' ? date(p.harvest_date) : null);
    return out;
  }, [d.data, t]);
  if (d.loading) return <Loading />;
  if (d.error || !d.data) return <ErrorBox error={d.error} onRetry={d.reload} />;
  const f = d.data.footprint, fm = d.data.farmer, scope = sf.data?.scope, pm = pay.data;
  if (f.stage_type !== 'procurement') return <div className="alert info">{t('rc.only_procurement')}</div>;
  return (
    <div className="receipt" data-testid="receipt">
      <p className="muted small no-print"><Link to={`/records/${f.id}`}>{f.footprint_code}</Link></p>
      <div className="card stack">
        <h1 style={{ marginBottom: 0 }}>{t('rc.title')}</h1>
        {scope && <p className="small muted" style={{ margin: 0 }}>{scope.client.name} · {scope.crop.name} · {scope.season_code}</p>}
        <dl className="kv">
          <dt>{t('rc.lot')}</dt><dd className="mono" data-testid="receipt-code">{f.footprint_code}</dd>
          <dt>{t('rc.on')}</dt><dd>{f.happened_on ? date(f.happened_on) : dateTime(f.captured_at ?? f.created_at)}</dd>
          {fm && <><dt>{t('record.farmer')}</dt><dd data-testid="receipt-farmer">{fm.name}{fm.farmer_code ? <> <span className="mono">{fm.farmer_code}</span></> : null} · {fm.village}</dd></>}
          {rows.map(([k, label, v]) => <Row key={k} k={k} label={label} v={v} />)}
          <dt>{t('rc.net')}</dt><dd className="big" data-testid="receipt-net">{kg(f.qty_out)}</dd>
          {pm && <>
            {pm.price_per_quintal !== null && <><dt>{t('field.price_per_quintal')}</dt><dd>₹ {num(pm.price_per_quintal, 2)} / {t('rc.quintal')}</dd></>}
            {pm.amount !== null && <><dt>{t('rc.amount')}</dt><dd className="big" data-testid="receipt-amount">₹ {num(pm.amount, 2)}</dd></>}
            <dt>{t('field.payment_status')}</dt><dd data-testid="receipt-paid">{t(`opt.${pm.status}`)}{pm.mode ? ` · ${t(`opt.${pm.mode}`)}` : ''}{pm.txn_ref ? <> · <span className="mono">{pm.txn_ref}</span></> : null}</dd>
          </>}
        </dl>
        {f.status === 'pending' && <p className="small muted">{t('rc.pending_note')}</p>}
        <p className="small muted">{t('rc.note')}</p>
        <div className="row no-print"><button type="button" onClick={() => window.print()} data-testid="receipt-print">{t('rc.print')}</button></div>
      </div>
    </div>);
}

function Row({ k, label, v }: { k: string; label: string; v: string }) {
  return <><dt>{label}</dt><dd data-receipt={k}>{v}</dd></>;
}
