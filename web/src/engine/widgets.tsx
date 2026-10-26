// Field widgets for the generic engine. A widget knows a field TYPE, never a stage: stage behaviour comes only from
// stage_definitions.form_schema (execution plan §6, "no stage-specific screen code").
import { useEffect, useState } from 'react';
import type { FieldDef, QualityParam, Farmer, Footprint, IncomingLot } from '../lib/types';
import type { BatchLot } from './offlinePreview';
import { readingValue } from '../lib/crops';
import { supabase } from '../lib/supabase';
import { useI18n } from '../lib/i18n';
import { cached, isNetworkError } from '../offline/cache';
import { gpsProblem, parseGps } from '../lib/setup';
import { rpc } from '../lib/api';
import { PackCodes, codeLines, normCode } from './PackCodes';
import { OrderCartons } from './OrderCartons';
import { ClientOrderPicker } from './ClientOrderPicker';

export type FieldValue = string | boolean | string[] | Record<string, string> | File | null;
export interface WidgetProps {
  field: FieldDef;
  value: FieldValue;
  onChange: (v: FieldValue) => void;
  qualityParams: QualityParam[];
  clientId: string;
  id: string;
  scopeId?: string;
  stageType?: string;
  allowed?: string[];      // select with a gate: only these options are offered
  /** migration 53: the lot this record is made from (QC picks the sample drawn from it) */ sourceId?: string;
  /** migration 54: the scope's state (its labs) and what is on the form so far (the batch's lots of the point chosen) */
  stateId?: string; values?: Record<string, FieldValue>;
  /** migration 57: the record being corrected (its own pack codes are not "shipped already") */ editingId?: string;
}

/** Types this build can render. Anything else shows a notice and blocks save if required. */
export const SUPPORTED = new Set(['number', 'integer', 'number[3]', 'text', 'select', 'date', 'boolean', 'attachment', 'readings', 'farmer',
  'breakdown', 'packets[]', 'footprint[]', 'collection_point', 'gps',
  'mill', 'lab', 'packing_unit', 'qc_sample', 'sku_packs',
  'buyer', 'market_profile', 'order_packs', 'serials', 'order_cartons', 'partner', 'client_order']);   // migration 70: a part of a client order
    // migration 66: "Procured through"   // migration 58: the cartons an order chooses                                // migration 54: Commercial and Shipment                         // migration 53: Milling, QC, Packing   // migration 52: where the lot was weighed, and its GPS

/** Field types that take the whole width of a two-column form (lists, pickers, files, groups of inputs). */
export const FULL_WIDTH = new Set(['number[3]', 'attachment', 'readings', 'farmer', 'breakdown', 'packets[]', 'footprint[]', 'boolean', 'gps',
  'qc_sample', 'sku_packs', 'order_packs', 'serials', 'order_cartons', 'client_order']);

/** Consecutive fields with the same `section` form one block of the form; a registry without sections gives one block. */
export function groupSections(fields: FieldDef[]): { section: string | null; fields: FieldDef[] }[] {
  const out: { section: string | null; fields: FieldDef[] }[] = [];
  for (const f of fields) {
    const sec = f.section ?? null;
    const last = out[out.length - 1];
    if (last && last.section === sec) last.fields.push(f); else out.push({ section: sec, fields: [f] });
  }
  return out;
}

/** What a "document" may be: a photo, or a PDF. */
export const EVIDENCE_ACCEPT = 'image/*,application/pdf';

const limitText = (l: number | [number, number]) => (Array.isArray(l) ? `${l[0]}–${l[1]}` : String(l));

export function Widget(p: WidgetProps) {
  const { t } = useI18n();
  const { field, value, onChange, id } = p;
  switch (field.type) {
    case 'number':
    case 'integer':
      return <input id={id} name={field.key} inputMode={field.type === 'integer' ? 'numeric' : 'decimal'} value={(value as string) ?? ''}
        onChange={(e) => onChange(e.target.value.replace(',', '.'))} required={field.required} autoComplete="off" />;
    case 'number[3]': {
      const arr = Array.isArray(value) ? (value as string[]) : ['', '', ''];
      return (
        <div className="triple">
          {[0, 1, 2].map((i) => (
            <input key={i} id={i === 0 ? id : `${id}-${i}`} name={`${field.key}.${i}`} aria-label={`${field.label} ${i + 1}`} inputMode="decimal"
              value={arr[i] ?? ''} onChange={(e) => { const n = [...arr]; n[i] = e.target.value.replace(',', '.'); onChange(n); }} />
          ))}
        </div>
      );
    }
    case 'text':
      return <input id={id} name={field.key} value={(value as string) ?? ''} onChange={(e) => onChange(e.target.value)} required={field.required} />;
    case 'date':
      return <input id={id} name={field.key} type="date" value={(value as string) ?? ''} onChange={(e) => onChange(e.target.value)} required={field.required} />;
    case 'select':
      return (
        <select id={id} name={field.key} value={(value as string) ?? ''} onChange={(e) => onChange(e.target.value)} required={field.required}>
          <option value="">—</option>
          {(field.options ?? []).filter((o) => !p.allowed || p.allowed.includes(o))
            .map((o) => <option key={o} value={o}>{t(`opt.${o}`, undefined, o.replace(/_/g, ' '))}</option>)}
        </select>
      );
    case 'boolean':
      return <input id={id} name={field.key} type="checkbox" checked={value === true} onChange={(e) => onChange(e.target.checked)} />;
    case 'attachment':
      return field.accept === 'document'
        ? <input id={id} name={field.key} type="file" accept={EVIDENCE_ACCEPT} onChange={(e) => onChange(e.target.files?.[0] ?? null)} />
        : <input id={id} name={field.key} type="file" accept="image/*" capture="environment"
            onChange={(e) => onChange(e.target.files?.[0] ?? null)} />;
    case 'readings': {
      const obj = (value && typeof value === 'object' && !(value instanceof File) && !Array.isArray(value)) ? value as Record<string, string> : {};
      return (
        <div className="stack">
          {p.qualityParams.map((q) => {
            // migration 42: a limit is a number (as before), a grade picked from the crop's list, or yes/no
            const ty = q.type ?? 'number';
            const yn = (x: unknown) => t(x ? 'common.yes' : 'common.no');
            // migration 54: a market profile's own test shows each market's limit (it has no Domestic / Export limit of the crop)
            const hint = q.limits ? q.limits.map((l) => `${l.market} ${l.operator} ${typeof l.limit === 'number' || Array.isArray(l.limit) && typeof l.limit[0] === 'number'
                ? limitText(l.limit as number | [number, number]) : l.limit === null || l.limit === undefined ? '—' : String(l.limit)}`).join(' · ')
              : ty === 'grade'
              ? `${t('pv.domestic')} ${(Array.isArray(q.domestic_pass) ? q.domestic_pass : []).join(', ')} · ${t('pv.export')} ${(Array.isArray(q.export_pass) ? q.export_pass : []).join(', ')}`
              : ty === 'yesno' ? `${t('crops.passes_when')} ${t('pv.domestic')} ${yn(q.domestic_pass)} · ${t('pv.export')} ${yn(q.export_pass)}`
              : `${t('pv.domestic')} ${q.operator} ${limitText(q.domestic_limit)} · ${t('pv.export')} ${q.operator} ${limitText(q.export_limit)}`;
            const cur = obj[q.param] ?? '';
            const ynValue = /^(yes|true)$/i.test(cur) ? 'yes' : /^(no|false)$/i.test(cur) ? 'no' : '';
            return (
              <div key={q.param} className="row">
                <label htmlFor={`${id}-${q.param}`} style={{ flex: '1 1 160px', margin: 0 }}>
                  {q.label}{ty === 'number' && q.unit ? ` (${q.unit})` : ''}
                  <span className="hint"> {hint}</span>
                </label>
                {ty === 'grade'
                  ? <select id={`${id}-${q.param}`} name={`readings.${q.param}`} style={{ flex: '0 0 140px' }} value={cur} onChange={(e) => onChange({ ...obj, [q.param]: e.target.value })}>
                      <option value="">—</option>{(q.options ?? []).map((g) => <option key={g} value={g}>{g}</option>)}</select>
                  : ty === 'yesno'
                  ? <select id={`${id}-${q.param}`} name={`readings.${q.param}`} style={{ flex: '0 0 140px' }} value={ynValue} onChange={(e) => onChange({ ...obj, [q.param]: e.target.value })}>
                      <option value="">—</option><option value="yes">{t('common.yes')}</option><option value="no">{t('common.no')}</option></select>
                  : <input id={`${id}-${q.param}`} name={`readings.${q.param}`} inputMode="decimal" style={{ flex: '0 0 140px' }}
                      value={cur} onChange={(e) => onChange({ ...obj, [q.param]: e.target.value.replace(',', '.') })} />}
              </div>);
          })}
        </div>
      );
    }
    case 'farmer':
      return <FarmerPicker id={id} clientId={p.clientId} scopeId={p.scopeId} value={(value as string) ?? ''} onChange={(v) => onChange(v)} />;
    case 'partner':
      return <PartnerPicker id={id} scopeId={p.scopeId} value={(value as string) ?? ''} onChange={(v) => onChange(v)} />;
    case 'collection_point':
      return <CollectionPointPicker id={id} clientId={p.clientId} value={(value as string) ?? ''} onChange={(v) => onChange(v)} />;
    case 'gps': {
      const g = (value && typeof value === 'object' && !(value instanceof File) && !Array.isArray(value)) ? value as Record<string, string> : {};
      return <GpsField id={id} lat={g.lat ?? ''} lng={g.lng ?? ''} onChange={(lat, lng) => onChange({ lat, lng })} />;
    }
    case 'breakdown':
      return <RowsEditor id={id} value={value} onChange={onChange} cols={[{ key: 'reason', label: t('widget.reason'), numeric: false }, { key: 'kg', label: t('widget.kg'), numeric: true }]} addLabel={t('widget.add_reason')} />;
    case 'packets[]':
      return <RowsEditor id={id} value={value} onChange={onChange} cols={[{ key: 'units', label: t('widget.packets'), numeric: true }, { key: 'size_kg', label: t('widget.size_kg'), numeric: true }]} addLabel={t('widget.add_packet')} />;
    case 'mill':
      return <ListPicker id={id} name={field.key} value={(value as string) ?? ''} onChange={(v) => onChange(v)} cacheKey={`mills:${p.clientId}`}
        load={async () => (await listRows('mills', 'id,name,place,ownership,dedicated_crop_id', 'client_id', p.clientId)).map((m) => ({ id: m.id, label: `${m.name} · ${m.place}` }))} />;
    case 'packing_unit':
      return <ListPicker id={id} name={field.key} value={(value as string) ?? ''} onChange={(v) => onChange(v)} cacheKey={`packing_units:${p.clientId}`}
        load={async () => (await listRows('packing_units', 'id,name,place', 'client_id', p.clientId)).map((m) => ({ id: m.id, label: `${m.name} · ${m.place}` }))} />;
    case 'lab':
      return <ListPicker id={id} name={field.key} value={(value as string) ?? ''} onChange={(v) => onChange(v)} cacheKey={`labs:${p.stateId ?? ''}:${p.clientId}`}
        load={async () => (await labsFor(p.stateId, p.clientId)).map((m) => ({ id: m.id, label: labLabel(m, t) }))} />;
    case 'buyer':
      return <ListPicker id={id} name={field.key} value={(value as string) ?? ''} onChange={(v) => onChange(v)} cacheKey={`buyers:${p.clientId}`}
        load={async () => (await listRows('buyers', 'id,name,country', 'client_id', p.clientId)).map((m) => ({ id: m.id, label: `${m.name} · ${m.country}` }))} />;
    case 'client_order':   // migration 70 (Phase 3, D): a part of an order drawing on several scopes
      return <ClientOrderPicker id={id} scopeId={p.scopeId} sourceId={p.sourceId} value={(value as string) ?? ''} onChange={(v) => onChange(v)} />;
    case 'market_profile':
      return <MarketProfilePicker id={id} sourceId={p.sourceId} value={(value as string) ?? ''} onChange={(v) => onChange(v)} />;
    case 'order_packs':
      return <OrderPacks id={id} sourceId={p.sourceId} value={value} onChange={onChange} />;
    case 'serials': {
      // migration 57: scanned, a range, or typed; each code checked as it comes (engine/PackCodes.tsx)
      const lines = (Array.isArray(p.values?.packs) ? p.values!.packs as unknown as { sku_id: string; units: string }[] : [])
        .map((r) => ({ sku_id: r.sku_id, units: Number(r.units) || 0 }));
      return <PackCodes id={id} name={field.key} sourceId={p.sourceId} editingId={p.editingId} value={typeof value === 'string' ? value : ''}
        onChange={(v) => onChange(v)} packLines={lines} />;
    }
    case 'order_cartons': {
      const lines = (Array.isArray(p.values?.packs) ? p.values!.packs as unknown as { sku_id: string; units: string }[] : [])
        .map((r) => ({ sku_id: r.sku_id, units: Number(r.units) || 0 }));
      return <OrderCartons id={id} sourceId={p.sourceId} editingId={p.editingId} value={Array.isArray(value) ? value as string[] : []}
        onChange={(v) => onChange(v)} packLines={lines} />;
    }
    case 'qc_sample':
      return <SamplePicker id={id} sourceId={p.sourceId} value={(value as string) ?? ''} onChange={(v) => onChange(v)} />;
    case 'sku_packs':
      return <SkuPacks id={id} clientId={p.clientId} value={value} onChange={onChange} />;
    case 'footprint[]':
      return <LotPicker id={id} scopeId={p.scopeId ?? ''} stageType={p.stageType ?? ''} value={Array.isArray(value) ? value as string[] : []} onChange={onChange}
        point={typeof p.values?.collection_point_id === 'string' ? p.values.collection_point_id : ''} />;
    default:
      return <p className="alert info">{t('engine.widget_missing')}</p>;
  }
}

/** The farmer of a farm-gate lot (Veda, 16 Oct: "farmer selection … should be drop down"): his village first, then the
 *  farmer from that village's list. The whole active list (RLS: only this client's farmers, only for procurement /
 *  village batch operators) is kept on the phone, so the farm-gate form works without a network. */
export function villageGroups(all: Pick<Farmer, 'village'>[]): { key: string; village: string; n: number }[] {
  const m = new Map<string, { key: string; village: string; n: number }>();
  for (const f of all) {
    const key = (f.village ?? '').toLowerCase().replace(/[^a-z]/g, '') || '-';            // app.norm_place: one village, however written
    const g = m.get(key);
    if (g) { g.n += 1; if ((f.village ?? '') < g.village) g.village = f.village ?? ''; } else m.set(key, { key, village: f.village ?? '', n: 1 });
  }
  return [...m.values()].sort((a, b) => a.village.localeCompare(b.village));
}
function FarmerPicker({ id, clientId, scopeId, value, onChange }: { id: string; clientId: string; scopeId?: string; value: string; onChange: (v: string) => void }) {
  const { t } = useI18n();
  const [all, setAll] = useState<Farmer[]>([]);
  const [loaded, setLoaded] = useState(false);   // migration 56: "no farmer yet" only once the list has come
  const [village, setVillage] = useState('');
  const [picked, setPicked] = useState<Farmer | null>(null);
  // migration 66 (Part E2): "show ABFPO members": the scope's sourcing partners and which of this client's farmers belong to each
  const [partners, setPartners] = useState<Partner[]>([]);
  const [members, setMembers] = useState<{ farmer_id: string; entity_id: string }[]>([]);
  const [member, setMember] = useState('');
  useEffect(() => {
    if (!scopeId) return;
    let live = true;
    void cached(`partners:${scopeId}`, () => rpc<Partner[]>('scope_partners', { p_scope: scopeId })).then((l) => { if (live) setPartners(l); }).catch(() => undefined);
    void cached(`members:${scopeId}`, () => rpc<{ farmer_id: string; entity_id: string }[]>('scope_farmer_members', { p_scope: scopeId }))
      .then((l) => { if (live) setMembers(l); }).catch(() => undefined);
    return () => { live = false; };
  }, [scopeId]);
  useEffect(() => {
    let live = true;
    void cached(`farmers:${clientId}`, async () => {
      const { data, error } = await supabase.from('farmers').select('id,farmer_code,name,village,district,phone,status,client_id')
        .eq('client_id', clientId).eq('status', 'active').order('name').limit(5000);
      if (error) throw error;
      return (data ?? []) as Farmer[];
    }).then((l) => { if (live) { setAll(l); setLoaded(true); } }).catch(() => { if (live) setLoaded(true); });
    return () => { live = false; };
  }, [clientId]);
  useEffect(() => { if (value && picked?.id !== value) setPicked(all.find((f) => f.id === value) ?? null); }, [value, picked?.id, all]);
  const memberOf = new Set(members.filter((m) => m.entity_id === member).map((m) => m.farmer_id));
  const shown = member ? all.filter((f) => memberOf.has(f.id)) : all;
  const withMembers = partners.filter((x) => members.some((m) => m.entity_id === x.entity_id));
  const groups = villageGroups(shown);
  const vk = village || (groups.length === 1 ? groups[0].key : '');
  const inVillage = shown.filter((f) => ((f.village ?? '').toLowerCase().replace(/[^a-z]/g, '') || '-') === vk);
  if (picked && value) {
    return (
      <div className="stack">
        <div className="row" data-testid="farmer-picked">
          <strong>{picked.name}</strong> <span className="mono">{picked.farmer_code}</span> <span className="muted">{picked.village}</span>
          <button type="button" className="secondary" onClick={() => { setPicked(null); onChange(''); }}>{t('widget.change')}</button>
        </div>
        {scopeId && <FarmerCard farmerId={picked.id} scopeId={scopeId} />}
      </div>
    );
  }
  return (
    <div className="stack">
      {withMembers.length > 0 && <select aria-label={t('widget.members_of')} value={member} data-testid="pick-member"
        onChange={(e) => { setMember(e.target.value); setVillage(''); }}>
        <option value="">{t('widget.all_farmers')}</option>
        {withMembers.map((x) => <option key={x.entity_id} value={x.entity_id}>{t('widget.members_of_x', { name: x.name })}</option>)}
      </select>}
      <select id={id} aria-label={t('widget.farmer_village')} value={vk} onChange={(e) => setVillage(e.target.value)} data-testid="pick-village">
        <option value="">{t('widget.farmer_village')}</option>
        {groups.map((g) => <option key={g.key} value={g.key}>{g.village} ({g.n})</option>)}
      </select>
      {vk && <select aria-label={t('widget.active_farmers')} value="" data-testid="pick-farmer"
        onChange={(e) => { const f = inVillage.find((x) => x.id === e.target.value); if (f) { setPicked(f); onChange(f.id); } }}>
        <option value="">{t('widget.farmer_pick')}</option>
        {inVillage.map((f) => <option key={f.id} value={f.id}>{f.name} · {f.farmer_code}</option>)}
      </select>}
      {groups.length === 0 && (loaded ? <p className="small muted" data-testid="no-farmers">{t('widget.no_farmers')}</p>
        : <p className="small muted" data-testid="farmers-loading">{t('widget.farmers_loading')}</p>)}
    </div>
  );
}

/** migration 66 (Part E3): one of the scope's sourcing partners (app.scope_partners), pre-filled when it has just one. */
interface Partner { entity_id: string; name: string; named_publicly: boolean }
function PartnerPicker({ id, scopeId, value, onChange }: { id: string; scopeId?: string; value: string; onChange: (v: string) => void }) {
  const { t } = useI18n();
  const [opts, setOpts] = useState<Partner[] | null>(null);
  useEffect(() => {
    if (!scopeId) { setOpts([]); return; }
    let live = true;
    void cached(`partners:${scopeId}`, () => rpc<Partner[]>('scope_partners', { p_scope: scopeId }))
      .then((l) => { if (live) setOpts(l); }).catch(() => { if (live) setOpts([]); });
    return () => { live = false; };
  }, [scopeId]);
  useEffect(() => { if (opts && opts.length === 1 && !value) onChange(opts[0].entity_id); }, [opts, value, onChange]);
  if (opts && !opts.length) return <p className="small muted" id={id} data-testid="no-partner">{t('widget.no_partner')}</p>;
  return (
    <select id={id} name="procured_through" value={value} onChange={(e) => onChange(e.target.value)} data-testid="pick-procured_through">
      <option value="">{t('widget.direct_from_farmer')}</option>
      {(opts ?? []).map((o) => <option key={o.entity_id} value={o.entity_id}>{o.name}</option>)}
    </select>);
}

type Row = Record<string, string>;
function RowsEditor({ id, value, onChange, cols, addLabel }: {
  id: string; value: FieldValue; onChange: (v: FieldValue) => void;
  cols: { key: string; label: string; numeric: boolean }[]; addLabel: string;
}) {
  const { t } = useI18n();
  const rows: Row[] = Array.isArray(value) ? (value as unknown as Row[]) : [];
  const set = (next: Row[]) => onChange(next as unknown as FieldValue);
  const blank = () => Object.fromEntries(cols.map((c) => [c.key, ''])) as Row;
  const list = rows.length ? rows : [blank()];
  return (
    <div className="stack" id={id}>
      {list.map((r, i) => (
        <div key={i} className="row">
          {cols.map((c) => (
            <input key={c.key} aria-label={`${c.label} ${i + 1}`} placeholder={c.label} inputMode={c.numeric ? 'decimal' : 'text'}
              style={{ flex: c.numeric ? '0 0 120px' : '1 1 160px', width: 'auto' }} value={r[c.key] ?? ''}
              onChange={(e) => { const n = list.map((x) => ({ ...x })); n[i][c.key] = c.numeric ? e.target.value.replace(',', '.') : e.target.value; set(n); }} />
          ))}
          {list.length > 1 && <button type="button" className="secondary" aria-label={t('widget.remove_row', { n: i + 1 })} onClick={() => set(list.filter((_, j) => j !== i))}>✕</button>}
        </div>
      ))}
      <button type="button" className="secondary" onClick={() => set([...list, blank()])}>{addLabel}</button>
    </div>
  );
}

/** The lots waiting at a stage (app.incoming_lots, migration 49), kept on the phone; a server before migration 49: the
 *  older list. One loader for the stage's list of waiting lots and the Collection Batch's picker (one copy offline). */
export function loadIncomingLots(scopeId: string, stageType: string): Promise<IncomingLot[]> {
  return cached(`incoming_lots:${scopeId}:${stageType}`,
    () => rpc<IncomingLot[]>('incoming_lots', { p_scope: scopeId, p_stage: stageType }).catch(async (e) => {
      if (isNetworkError(e)) throw e;
      return (await rpc<Footprint[]>('incoming_records', { p_scope: scopeId, p_stage: stageType }))
        .map((r) => ({ ...r, available_kg: r.qty_out, returned: false, maker_name: null, made_by_me: false, gi_status: 'unknown', farmer_count: 0 }) as IncomingLot);
    }));
}

/** The lots the Collection Batch picker last showed, for the offline mirror of the batch (offlinePreview). */
export const KNOWN_LOTS = new Map<string, BatchLot>();
const pointOf = (l: IncomingLot) => String((l.payload as Record<string, unknown>)?.collection_point_id ?? '');

/** The Collection Batch (migration 52, C2): the verified lots, by the place they were weighed. A batch is the lots of one
 *  place; choosing lots of two places is said at once (the save refuses it too). */
function LotPicker({ id, scopeId, stageType, value, onChange, point }: { id: string; scopeId: string; stageType: string; value: string[]; onChange: (v: FieldValue) => void;
  /** migration 54: the collection point the batch names (its lots only) */ point?: string }) {
  const { t } = useI18n();
  const [lots, setLots] = useState<IncomingLot[] | null>(null);
  const [names, setNames] = useState<Record<string, { name: string; village: string; farmer_code?: string }>>({});
  // migration 56 (Veda, 16 Oct 2026: "there will be many lots per farmer per village"): a village, a search, all shown
  const [fVillage, setFVillage] = useState('');
  const [fText, setFText] = useState('');
  useEffect(() => {
    if (!scopeId || !stageType) return;
    let live = true;
    loadIncomingLots(scopeId, stageType).then(async (r) => {
      const verified = r.filter((x) => x.status === 'verified');
      if (!live) return;
      setLots(verified);
      const ids = [...new Set(verified.map((x) => x.farmer_id).filter(Boolean) as string[])];
      const nm = ids.length ? await cached(`lot_farmers:${scopeId}:${stageType}`, async () => {
        const { data, error } = await supabase.from('farmers').select('id,name,village,farmer_code').in('id', ids);
        if (error) throw error;
        return Object.fromEntries(((data ?? []) as { id: string; name: string; village: string; farmer_code: string }[])
          .map((f) => [f.id, { name: f.name, village: f.village, farmer_code: f.farmer_code }]));
      }).catch(() => ({} as Record<string, { name: string; village: string; farmer_code?: string }>)) : {};
      if (!live) return;
      setNames(nm);
      for (const l of verified) {
        const c = (l.computed ?? {}) as Record<string, unknown>;
        KNOWN_LOTS.set(l.id, { id: l.id, code: l.footprint_code, qty: Number(l.qty_out), point: pointOf(l),
          point_name: typeof c.collection_point === 'string' && c.collection_point !== 'farm' ? c.collection_point : null,
          village: l.farmer_id ? nm[l.farmer_id]?.village ?? null : null, farmer_id: l.farmer_id,
          moisture_avg: typeof c.moisture_avg === 'number' ? c.moisture_avg : c.moisture_avg ? Number(c.moisture_avg) : null, gi_status: l.gi_status ?? 'unknown' });
      }
    }).catch(() => { if (live) setLots([]); });
    return () => { live = false; };
  }, [scopeId, stageType]);
  // migration 54: a lot ticked at another point than the one named is let go (the batch is the lots of its point)
  useEffect(() => {
    if (!point || !lots) return;
    const keep = value.filter((x) => lots.some((l) => l.id === x && pointOf(l) === point));
    if (keep.length !== value.length) onChange(keep);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [point, lots]);
  if (lots === null) return <p className="small muted" id={id}>{t('common.loading', undefined, '…')}</p>;
  if (!lots.length) return <p className="alert info" id={id}>{t('widget.no_lots')}</p>;
  const atPoint = point ? lots.filter((l) => pointOf(l) === point) : lots;
  if (!atPoint.length) return <p className="alert info" id={id} data-testid="batch-none-here">{t('cb.none_at_point')}</p>;
  const villages = lotVillages(atPoint, names);
  const shown = filterLots(atPoint, names, fVillage, fText);
  const shownIds = new Set(shown.map((l) => l.id));
  const hiddenChosen = value.filter((x) => atPoint.some((l) => l.id === x) && !shownIds.has(x)).length;
  const allShown = shown.length > 0 && shown.every((l) => value.includes(l.id));
  const groups = new Map<string, IncomingLot[]>();
  for (const l of shown) groups.set(pointOf(l), [...(groups.get(pointOf(l)) ?? []), l]);
  const title = (key: string, l: IncomingLot) => {
    const c = (l.computed ?? {}) as Record<string, unknown>;
    return key === 'farm' ? t('cp.at_farm') : key === '' ? t('cb.no_place') : typeof c.collection_point === 'string' ? c.collection_point : t('cp.a_point');
  };
  const chosenPlaces = new Set(lots.filter((l) => value.includes(l.id)).map(pointOf));
  return (
    <div id={id} className="stack" data-testid="batch-lots">
      {chosenPlaces.size > 1 && <div className="alert warn" role="alert" data-testid="batch-two-places">{t('cb.one_place')}</div>}
      {atPoint.length > 1 && (
        <div className="stack" data-testid="batch-filter">
          <div className="lot-filters">{/* migration 57 (G22): on two rows on a small phone (the boxes were cut) */}
            {villages.length > 1 && <select aria-label={t('cb.f_village')} value={fVillage} onChange={(e) => setFVillage(e.target.value)} data-testid="batch-f-village">
              <option value="">{t('cb.f_all_villages', { n: atPoint.length })}</option>
              {villages.map((v) => <option key={v.key} value={v.key}>{v.village} ({v.n})</option>)}
            </select>}
            <input type="search" aria-label={t('cb.f_search')} placeholder={t('cb.f_search')} value={fText} onChange={(e) => setFText(e.target.value)}
              data-testid="batch-f-text" />
          </div>
          <div className="row">
            <span className="small muted" data-testid="batch-f-count">{t('cb.f_shown', { n: shown.length, of: atPoint.length, chosen: value.filter((x) => atPoint.some((l) => l.id === x)).length })}</span>
            {shown.length > 0 && <button type="button" className="secondary small" data-testid="batch-f-all"
              onClick={() => onChange(allShown ? value.filter((x) => !shownIds.has(x)) : [...new Set([...value, ...shown.map((l) => l.id)])])}>
              {allShown ? t('cb.f_none_shown') : t('cb.f_all_shown', { n: shown.length })}</button>}
          </div>
          {hiddenChosen > 0 && <p className="small muted" data-testid="batch-f-hidden">{t('cb.f_hidden', { n: hiddenChosen })}</p>}
        </div>)}
      {shown.length === 0 && <p className="small muted" data-testid="batch-f-none">{t('cb.f_none')}</p>}
      {[...groups.entries()].map(([key, ls], gi) => {
        const all = ls.every((l) => value.includes(l.id));
        const here = new Set(ls.map((l) => l.id));
        const placeLots = atPoint.filter((l) => pointOf(l) === key).map((l) => l.id);
        return (
          <fieldset key={key || 'none'} className="stack" data-testid={`batch-place-${gi}`} data-place={key}>
            <legend className="small"><strong>{title(key, ls[0])}</strong> · {t('cb.n_lots', { n: ls.length })} · {kgText(ls.reduce((a, l) => a + Number(l.qty_out), 0))}</legend>
            <button type="button" className="secondary small" data-testid={`batch-place-all-${gi}`}
              onClick={() => onChange(all ? value.filter((x) => !here.has(x)) : [...new Set([...value.filter((x) => placeLots.includes(x)), ...here])])}>
              {all ? t('cb.none_here') : t('cb.all_here')}</button>
            {ls.map((l) => {
              const f = l.farmer_id ? names[l.farmer_id] : undefined;
              return (
                <label key={l.id} className="check">
                  <input type="checkbox" checked={value.includes(l.id)} onChange={(e) => onChange(e.target.checked ? [...value, l.id] : value.filter((x) => x !== l.id))} />
                  <span><span className="mono">{l.footprint_code}</span> · {kgText(Number(l.qty_out))}{f ? ` · ${f.name}, ${f.village}` : ''}
                    {l.gi_status && l.gi_status !== 'unknown' && <> · <span className={`badge ${l.gi_status === 'gi' ? 'gi' : 'draft'}`} data-gi={l.gi_status}>{t(`gi.${l.gi_status}`)}</span></>}</span>
                </label>);
            })}
          </fieldset>);
      })}
    </div>
  );
}
const kgText = (n: number) => `${n.toLocaleString('en-IN', { maximumFractionDigits: 1 })} kg`;

export type LotNames = Record<string, { name: string; village: string; farmer_code?: string }>;
/** Migration 57 (G22): the farmer and village of each lot waiting at a stage (RLS: the client's farmers the person may
 *  see), kept on the phone like the batch form's. */
export function useLotNames(scopeId: string, stageType: string, lots: Pick<IncomingLot, 'farmer_id'>[] | null): LotNames {
  const [names, setNames] = useState<LotNames>({});
  const key = lots ? [...new Set(lots.map((l) => l.farmer_id).filter(Boolean) as string[])].sort().join(',') : '';
  useEffect(() => {
    if (!key) { setNames({}); return; }
    let live = true;
    const ids = key.split(',');
    void cached(`lot_farmers_all:${scopeId}:${stageType}`, async () => {
      const { data, error } = await supabase.from('farmers').select('id,name,village,farmer_code').in('id', ids);
      if (error) throw error;
      return Object.fromEntries(((data ?? []) as { id: string; name: string; village: string; farmer_code: string }[])
        .map((f) => [f.id, { name: f.name, village: f.village, farmer_code: f.farmer_code }])) as LotNames;
    }).then((n) => { if (live) setNames(n); }).catch(() => { /* the cards show without the farmer */ });
    return () => { live = false; };
  }, [scopeId, stageType, key]);
  return names;
}
const villageKey = (v: string | null | undefined) => (v ?? '').trim().toLowerCase().replace(/\s+/g, ' ');
/** Pure (migration 56): the villages of the lots, with how many lots each, by name. */
export function lotVillages(lots: Pick<IncomingLot, 'farmer_id'>[], names: LotNames): { key: string; village: string; n: number }[] {
  const m = new Map<string, { key: string; village: string; n: number }>();
  for (const l of lots) {
    const v = l.farmer_id ? names[l.farmer_id]?.village ?? '' : '';
    const key = villageKey(v) || '-';
    const g = m.get(key);
    if (g) g.n += 1; else m.set(key, { key, village: v || '—', n: 1 });
  }
  return [...m.values()].sort((a, b) => a.village.localeCompare(b.village));
}
/** Pure (migration 56): the lots of a village (its key, or all) whose code, farmer's name or farmer's code has the text. */
export function filterLots<L extends Pick<IncomingLot, 'farmer_id' | 'footprint_code'>>(lots: L[], names: LotNames, village: string, text: string): L[] {
  const q = text.trim().toLowerCase();
  return lots.filter((l) => {
    const f = l.farmer_id ? names[l.farmer_id] : undefined;
    if (village && (villageKey(f?.village) || '-') !== village) return false;
    if (!q) return true;
    return [l.footprint_code, f?.name, f?.farmer_code].some((x) => (x ?? '').toLowerCase().includes(q));
  });
}

/** Field values → payload (numbers parsed) and column values. Attachments are returned separately. */
export function buildPayload(fields: FieldDef[], values: Record<string, FieldValue>) {
  const payload: Record<string, unknown> = {};
  const columns: Record<string, unknown> = {};
  const files: { field: FieldDef; file: File }[] = [];
  const toNum = (s: unknown) => (s === '' || s === undefined || s === null ? undefined : Number(s));
  for (const f of fields) {
    const v = values[f.key];
    if (f.type === 'attachment') { if (v instanceof File) files.push({ field: f, file: v }); continue; }
    if (v === undefined || v === null || v === '') continue;
    let out: unknown = v;
    if (f.type === 'number' || f.type === 'integer') out = toNum(v);
    else if (f.type === 'number[3]') {
      const arr = (v as string[]).map(toNum);
      if (arr.some((x) => x === undefined)) continue;
      out = arr;
    } else if (f.type === 'sku_packs') {
      // migration 53: packs from the client's pack list: the pack, how many, its own size (kg)
      const rows = (v as unknown as Record<string, string>[]).filter((r) => r.sku_id && r.units);
      if (!rows.length) continue;
      out = rows.map((r) => ({ sku_id: r.sku_id, units: toNum(r.units), size_kg: toNum(r.size_kg) }));
    } else if (f.type === 'order_packs') {
      // migration 54: the packs of an order by type (the kilograms are the server's)
      const rows = (v as unknown as Record<string, string>[]).filter((r) => r.sku_id && r.units && Number(r.units) > 0);
      if (!rows.length) continue;
      out = rows.map((r) => ({ sku_id: r.sku_id, units: toNum(r.units) }));
    } else if (f.type === 'order_cartons') {
      // migration 58: the carton codes chosen (none: the server sets aside the oldest free ones)
      const codes = [...new Set((Array.isArray(v) ? v as string[] : []).map(normCode).filter(Boolean))];
      if (!codes.length) continue;
      out = codes;
    } else if (f.type === 'serials') {
      const lines = codeLines(String(v));     // pack codes are capitals (the server reads them so); migration 57: a pack page's address gives its code
      if (!lines.length) continue;
      out = lines;
    } else if (f.type === 'breakdown' || f.type === 'packets[]') {
      const rows = (v as unknown as Record<string, string>[]).filter((r) => Object.values(r).some((x) => x !== ''));
      if (!rows.length) continue;
      out = rows.map((r) => Object.fromEntries(Object.entries(r).map(([k, x]) => [k, k === 'reason' ? x : toNum(x)])));
    } else if (f.type === 'gps') {
      // migration 52: the point goes into the payload as two numbers
      const g = v as Record<string, string>;
      const lat = toNum(g?.lat), lng = toNum(g?.lng);
      if (lat !== undefined && lng !== undefined && Number.isFinite(lat) && Number.isFinite(lng)) { payload.gps_lat = lat; payload.gps_lng = lng; }
      continue;
    } else if (f.type === 'footprint[]') {
      const ids = v as string[];
      if (!ids.length) continue;
      out = ids;
      if ((f as FieldDef & { sets_prev?: boolean }).sets_prev) columns.prev_footprint_id = ids[0];
    } else if (f.type === 'readings') {
      // a number stays a number; yes/no a boolean; a grade its text (migration 42: typed limits)
      const o: Record<string, number | boolean | string> = {};
      for (const [k, s] of Object.entries(v as Record<string, string>)) { const x = readingValue(String(s ?? '')); if (x !== undefined && !(typeof x === 'number' && Number.isNaN(x))) o[k] = x; }
      out = o;
    }
    if (f.column) columns[f.key] = out; else payload[f.key] = out;
  }
  return { payload, columns, files };
}

/** Migration 50: a field marked `required_when` is required where the scope's setting of that name is on (the lab
 *  report where the scope asks for it). The database asks the same (app.reconcile); this keeps the form honest. */
export function withScopeRules(fields: FieldDef[], scope: object): FieldDef[] {
  const on = (k: string) => (scope as Record<string, unknown>)[k] === true;
  // migration 52: a field marked `shown_when` is on the form only where the scope's setting is on (price and payment)
  return fields.filter((f) => (!f.shown_when || on(f.shown_when)) && (!f.hidden_when || !on(f.hidden_when)))   // migration 53: hidden_when
    .map((f) => (f.required_when && on(f.required_when) ? { ...f, required: true } : f));
}

/** Migration 54: fields that follow the lot this record is made from. `for_market` is on the form only for an order of
 *  that market (Shipment: the domestic papers or the export papers); `with_packs` only where the lot has packs by type
 *  (packed from the client's pack list) and the scope asks the details, `hidden_when_packs` the kilograms instead. */
export function withLotRules(fields: FieldDef[], lot: { market?: string | null; packs: boolean; packed?: boolean }): FieldDef[] {
  return fields.filter((f) => (!f.for_market || !lot.market || f.for_market === lot.market)
    && (!f.with_packs || lot.packs) && (!f.hidden_when_packs || !lot.packs) && (!f.when_packed || lot.packed === true))
    // migration 62 (E2.1): every shipment of a packed lot says which packs it carries
    .map((f) => (f.when_packed && lot.packed ? { ...f, required: true } : f));
}

/** Migration 55: a field marked `shown_if` is on the form only while another field of the form has that value (a
 *  domestic order does not show the export market, the destination country or the Incoterms). */
export function withValueRules(fields: FieldDef[], values: Record<string, unknown>): FieldDef[] {
  return fields.filter((f) => !f.shown_if || Object.entries(f.shown_if).every(([k, v]) => values[k] === v))
    // migration 70: the order's own fields (buyer, market, number) hide while a client order is chosen: the server writes them
    .filter((f) => !f.hidden_if_set || !values[f.hidden_if_set]);
}

/** The pack codes typed or scanned, one per line (or separated by commas or spaces), in the order given. */
export const serialLines = (s: string) => s.split(/[\s,;]+/).map((x) => x.trim()).filter(Boolean);

/** Required files not chosen yet (by label): a new record only (a correction keeps the files it has). */
export function missingFiles(fields: FieldDef[], values: Record<string, FieldValue>): string[] {
  return fields.filter((f) => f.required && f.type === 'attachment' && !(values[f.key] instanceof File)).map((f) => f.label);
}

/** Required fields that are still empty (by label). */
export function missingRequired(fields: FieldDef[], values: Record<string, FieldValue>): string[] {
  return fields.filter((f) => f.required && f.type !== 'attachment').filter((f) => {
    const v = values[f.key];
    if (f.type === 'number[3]') return !Array.isArray(v) || (v as string[]).filter((x) => x !== '' && x !== undefined).length < 3;
    if (f.type === 'readings') return !v || Object.values(v as Record<string, string>).every((x) => x === '');
    if (f.type === 'packets[]') return !Array.isArray(v) || !(v as unknown as Record<string, string>[]).some((r) => r.units && r.size_kg);
    if (f.type === 'sku_packs') return !Array.isArray(v) || !(v as unknown as Record<string, string>[]).some((r) => r.sku_id && r.units);
    if (f.type === 'footprint[]') return !Array.isArray(v) || (v as string[]).length === 0;
    if (f.type === 'order_packs') return !Array.isArray(v) || !(v as unknown as Record<string, string>[]).some((r) => r.sku_id && Number(r.units) > 0);
    if (f.type === 'serials') return serialLines(String(v ?? '')).length === 0;
    if (f.type === 'gps') { const g = v as Record<string, string> | null; return !g || !String(g.lat ?? '').trim() || !String(g.lng ?? '').trim(); }
    return v === undefined || v === null || v === '';
  }).map((f) => f.label);
}

export const PREFILL_FROM_SOURCE = ['input_kg', 'qty_kg', 'stored_kg', 'shipped_kg', 'declared_kg'];   // migration 55: what the Warehouse was sent

// ---------------------------------------------------------------------------------------------------------------------
// Migration 52 (C1): where the lot was weighed, its GPS, the farmer card
// ---------------------------------------------------------------------------------------------------------------------
interface PointRow { id: string; name: string; kind: string; village: string | null; district: string }
/** A collection point of the client (kept on the phone, so the farm-gate form works without a network), or "At the farm". */
function CollectionPointPicker({ id, clientId, value, onChange }: { id: string; clientId: string; value: string; onChange: (v: string) => void }) {
  const { t } = useI18n();
  const [points, setPoints] = useState<PointRow[]>([]);
  useEffect(() => {
    let live = true;
    void cached(`collection_points:${clientId}`, async () => {
      const { data, error } = await supabase.from('collection_points').select('id,name,kind,village,district').eq('client_id', clientId).eq('active', true).order('name');
      if (error) throw error;
      return (data ?? []) as PointRow[];
    }).then((l) => { if (live) setPoints(l); }).catch(() => undefined);
    return () => { live = false; };
  }, [clientId]);
  return (
    <select id={id} name="collection_point_id" value={value} onChange={(e) => onChange(e.target.value)} data-testid="where">
      <option value="">—</option>
      <option value="farm">{t('cp.at_farm')}</option>
      {points.map((p) => <option key={p.id} value={p.id}>{p.name}{p.village ? ` · ${p.village}` : ''}</option>)}
    </select>);
}

/** The GPS of where the lot was weighed: taken from the phone when the form opens (it works without signal), else typed.
 *  A pair pasted into the first box ("27.21, 82.95") fills both; typing goes into one box at a time (found on staging,
 *  15 Oct: a pair typed key by key was split too early). */
export function GpsField({ id, lat, lng, onChange, auto = true }: { id: string; lat: string; lng: string; onChange: (lat: string, lng: string) => void; auto?: boolean }) {
  const { t } = useI18n();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  // `quiet`: the point taken by itself when the form opens says nothing when the phone gives none (asked or not, the
  // operator can press the button or type the numbers)
  const take = (quiet = false) => {
    if (!navigator.geolocation) { if (!quiet) setErr(t('fl.gps_none')); return; }
    setBusy(true); setErr(null);
    navigator.geolocation.getCurrentPosition(
      (pos) => { setBusy(false); onChange(pos.coords.latitude.toFixed(6), pos.coords.longitude.toFixed(6)); },
      () => { setBusy(false); if (!quiet) setErr(t('fl.gps_denied')); }, { enableHighAccuracy: true, timeout: 20000, maximumAge: 60000 });
  };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { if (auto && !lat && !lng && navigator.geolocation) take(true); }, []);
  const problem = gpsProblem(lat, lng);
  return (
    <div className="stack" data-testid="gps-field">
      <div className="row wrap">
        <button type="button" className="secondary" onClick={() => take()} disabled={busy} data-testid="gps-here">{busy ? t('fl.gps_taking') : t('fl.gps_here')}</button>
        <input id={id} aria-label={t('fl.lat')} placeholder={t('fl.lat')} inputMode="decimal" value={lat} style={{ flex: '1 1 110px', width: 'auto' }} data-testid="gps-lat"
          onChange={(e) => onChange(e.target.value, lng)}
          onPaste={(e) => { const both = parseGps(e.clipboardData.getData('text')); if (both) { e.preventDefault(); onChange(String(both.lat), String(both.lng)); } }}
          onBlur={() => { const both = parseGps(lat); if (both) onChange(String(both.lat), String(both.lng)); }} />
        <input aria-label={t('fl.lng')} placeholder={t('fl.lng')} inputMode="decimal" value={lng} style={{ flex: '1 1 110px', width: 'auto' }} data-testid="gps-lng"
          onChange={(e) => onChange(lat, e.target.value)} />
      </div>
      {problem && <div className="small" style={{ color: 'var(--red)' }}>{t(problem)}</div>}
      {err && <div className="small" style={{ color: 'var(--warn)' }}>{err}</div>}
    </div>);
}

interface FarmerCardData { gi_land_acres: number | null; sold_kg: number; expected_kg: number | null; gap: { required: string[]; optional: string[] };
  gi_area: 'inside' | 'outside' | 'unknown' | 'non_gi_crop'; has_gps: boolean }
/** The farmer card (C1): GI land, sold this season against what his GI land should give, practice, GI area. */
function FarmerCard({ farmerId, scopeId }: { farmerId: string; scopeId: string }) {
  const { t } = useI18n();
  const [c, setC] = useState<FarmerCardData | null>(null);
  useEffect(() => {
    let live = true;
    void cached(`farmer_card:${farmerId}:${scopeId}`, () => rpc<FarmerCardData>('farmer_card', { p_farmer: farmerId, p_scope: scopeId }))
      .then((r) => { if (live) setC(r); }).catch(() => undefined);
    return () => { live = false; };
  }, [farmerId, scopeId]);
  if (!c) return null;
  const n = (x: number | null) => (x === null || x === undefined ? '—' : Number(x).toLocaleString('en-IN', { maximumFractionDigits: 1 }));
  const over = c.expected_kg !== null && c.sold_kg > c.expected_kg;
  return (
    <div className="card sub-card small" data-testid="farmer-card" data-gi={c.gi_area}>
      <div>{c.gi_land_acres === null || c.gi_land_acres === undefined ? t('fc.gi_land_none') : t('fc.gi_land', { n: n(c.gi_land_acres) })} · {c.expected_kg === null || c.expected_kg === undefined
        ? t('fc.sold_only', { sold: n(c.sold_kg) }) : t('fc.sold', { sold: n(c.sold_kg), expected: n(c.expected_kg) })}</div>
      <div>{c.gap.required.length ? <span style={{ color: 'var(--red)' }}>{t('fc.gap_open', { what: c.gap.required.join(', ') })}</span>
        : c.gap.optional.length ? t('fc.gap_optional', { what: c.gap.optional.join(', ') }) : t('fc.gap_done')}</div>
      <div data-testid="farmer-card-gi">{t(`fc.gi_${c.gi_area}`)}{over ? ` · ${t('fc.above_yield')}` : ''}</div>
    </div>);
}

// ---------------------------------------------------------------------------------------------------------------------
// Migration 53 (C4–C6): the mill, the packing unit and the lab from the lists; the sample drawn first; packs from the
// client's pack list. Each list is kept on the phone (a form opened once works without a network).
// ---------------------------------------------------------------------------------------------------------------------
async function listRows(table: string, cols: string, col: string | null, val: string | null): Promise<Record<string, string>[]> {
  let qy = supabase.from(table).select(cols).eq('active', true).order('name');
  if (col && val) qy = qy.eq(col, val);
  const { data, error } = await qy;
  if (error) throw error;
  return (data ?? []) as unknown as Record<string, string>[];
}
function ListPicker({ id, name, value, onChange, cacheKey, load }: { id: string; name: string; value: string; onChange: (v: string) => void;
  cacheKey: string; load: () => Promise<{ id: string; label: string }[]> }) {
  const [opts, setOpts] = useState<{ id: string; label: string }[]>([]);
  useEffect(() => {
    let live = true;
    void cached(cacheKey, load).then((l) => { if (live) setOpts(l); }).catch(() => undefined);
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cacheKey]);
  return (
    <select id={id} name={name} value={value} onChange={(e) => onChange(e.target.value)} data-testid={`pick-${name}`}>
      <option value="">—</option>
      {opts.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
    </select>);
}

interface SampleRow { id: string; code: string; status: string; qty_kg: number; drawn_on: string; lab_name: string | null }
function SamplePicker({ id, sourceId, value, onChange }: { id: string; sourceId?: string; value: string; onChange: (v: string) => void }) {
  const { t } = useI18n();
  const [rows, setRows] = useState<SampleRow[] | null>(null);
  useEffect(() => {
    if (!sourceId) { setRows([]); return; }
    let live = true;
    void cached(`samples:${sourceId}`, () => rpc<SampleRow[]>('lot_samples', { p_fp: sourceId }))
      .then((r) => { if (live) setRows(r.filter((x) => x.status === 'sent' || x.id === value)); }).catch(() => { if (live) setRows([]); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sourceId]);
  if (rows && !rows.length) return <p className="alert info" id={id} data-testid="no-samples">{t('smp.none_to_pick')}</p>;
  return (
    <select id={id} name="sample_ref" value={value} onChange={(e) => onChange(e.target.value)} data-testid="pick-sample">
      <option value="">—</option>
      {(rows ?? []).map((r) => <option key={r.id} value={r.id}>{r.code} · {Number(r.qty_kg).toLocaleString('en-IN')} kg{r.lab_name ? ` · ${r.lab_name}` : ''}</option>)}
    </select>);
}

interface SkuRow { id: string; size: number; unit: string; material: string; market: string }
export const skuKg = (s: { size: number; unit: string }) => (s.unit === 'g' ? Number(s.size) / 1000 : Number(s.size));
function SkuPacks({ id, clientId, value, onChange }: { id: string; clientId: string; value: FieldValue; onChange: (v: FieldValue) => void }) {
  const { t } = useI18n();
  const [skus, setSkus] = useState<SkuRow[]>([]);
  useEffect(() => {
    let live = true;
    void cached(`pack_skus:${clientId}`, async () => {
      const { data, error } = await supabase.from('pack_skus').select('id,size,unit,material,market').eq('client_id', clientId).eq('active', true).order('size');
      if (error) throw error;
      return (data ?? []) as SkuRow[];
    }).then((l) => { if (live) setSkus(l); }).catch(() => undefined);
    return () => { live = false; };
  }, [clientId]);
  type R = { sku_id: string; units: string; size_kg: string };
  const rows: R[] = Array.isArray(value) ? (value as unknown as R[]) : [];
  const list = rows.length ? rows : [{ sku_id: '', units: '', size_kg: '' }];
  const set = (n: R[]) => onChange(n as unknown as FieldValue);
  const name = (s: SkuRow) => `${s.size} ${s.unit} · ${t(`mat.${s.material}`, undefined, s.material)}${s.market === 'export' ? ` · ${t('opt.export', undefined, 'export')}` : ''}`;
  if (!skus.length) return <p className="alert info" id={id} data-testid="no-skus">{t('pk.no_skus')}</p>;
  return (
    <div className="stack" id={id} data-testid="sku-packs">
      {list.map((r, i) => (
        <div key={i} className="row">
          <select aria-label={`${t('pk.pack')} ${i + 1}`} value={r.sku_id} style={{ flex: '1 1 160px', width: 'auto' }} data-testid={`sku-${i}`}
            onChange={(e) => { const s = skus.find((x) => x.id === e.target.value); const n = list.map((x) => ({ ...x }));
              n[i] = { ...n[i], sku_id: e.target.value, size_kg: s ? String(skuKg(s)) : '' }; set(n); }}>
            <option value="">—</option>{skus.map((s) => <option key={s.id} value={s.id}>{name(s)}</option>)}</select>
          <input aria-label={`${t('widget.packets')} ${i + 1}`} placeholder={t('widget.packets')} inputMode="numeric" style={{ flex: '0 0 110px', width: 'auto' }}
            value={r.units} data-testid={`sku-units-${i}`}
            onChange={(e) => { const n = list.map((x) => ({ ...x })); n[i].units = e.target.value.replace(/[^0-9]/g, ''); set(n); }} />
          {list.length > 1 && <button type="button" className="secondary" aria-label={t('widget.remove_row', { n: i + 1 })} onClick={() => set(list.filter((_, j) => j !== i))}>✕</button>}
        </div>))}
      <button type="button" className="secondary" onClick={() => set([...list, { sku_id: '', units: '', size_kg: '' }])}>{t('widget.add_packet')}</button>
    </div>);
}

// ---------------------------------------------------------------------------------------------------------------------
// Migration 54 (C7, C8; Veda 16 Oct): the labs of the scope's state and of the client; the buyer's market profile; the
// packs of an order by type, from what is left
// ---------------------------------------------------------------------------------------------------------------------
export interface LabRow { id: string; name: string; kind: string; accreditation_no: string | null; client_id: string | null }
/** The labs a lab record or a sample may name: the state's own (kept by its State Manager) and the client's (kept by its
 *  Client Manager), as app.lab_for_scope decides. */
export async function labsFor(stateId: string | undefined, clientId: string): Promise<LabRow[]> {
  let qy = supabase.from('labs').select('id,name,kind,accreditation_no,client_id').eq('active', true);
  qy = stateId ? qy.or(`and(client_id.is.null,state_id.eq.${stateId}),client_id.eq.${clientId}`) : qy.or(`client_id.is.null,client_id.eq.${clientId}`);
  const { data, error } = await qy.order('name');
  if (error) throw error;
  return (data ?? []) as LabRow[];
}
export const labLabel = (m: LabRow, t: (k: string, v?: Record<string, string | number>, f?: string) => string) =>
  `${m.name}${m.kind === 'in_house' ? ` · ${t('opt.in_house')}` : m.accreditation_no ? ` · ${m.accreditation_no}` : ''}${m.client_id ? ` · ${t('lab.client_own')}` : ''}`;

interface ProfileVerdict { code: string; name: string; verdict: string }
function MarketProfilePicker({ id, sourceId, value, onChange }: { id: string; sourceId?: string; value: string; onChange: (v: string) => void }) {
  const { t } = useI18n();
  const [rows, setRows] = useState<ProfileVerdict[]>([]);
  useEffect(() => {
    if (!sourceId) return;
    let live = true;
    void cached(`lot_markets:${sourceId}`, () => rpc<{ profiles?: ProfileVerdict[] }>('lot_markets', { p_fp: sourceId }))
      .then((r) => { if (live) setRows((r.profiles ?? []).filter((x) => x.code !== 'domestic')); }).catch(() => undefined);
    return () => { live = false; };
  }, [sourceId]);
  return (
    <select id={id} name="market_code" value={value} onChange={(e) => onChange(e.target.value)} data-testid="pick-market_code">
      <option value="">—</option>
      {rows.map((r) => <option key={r.code} value={r.code}>{r.name} · {t(`pv.v_${r.verdict}`, undefined, r.verdict)}</option>)}
    </select>);
}

export interface PackLeft { sku_id: string; name: string; size_kg: number; market: string; units: number; left: number }
/** The packs of an order (Commercial: from the packing batch; Shipment: from the order), one line per pack type, with
 *  what is left of each; the kilograms follow from the packs (the server works them out the same way). */
function OrderPacks({ id, sourceId, value, onChange }: { id: string; sourceId?: string; value: FieldValue; onChange: (v: FieldValue) => void }) {
  const { t } = useI18n();
  const [left, setLeft] = useState<PackLeft[] | null>(null);
  useEffect(() => {
    if (!sourceId) { setLeft([]); return; }
    let live = true;
    void cached(`packs_left:${sourceId}`, () => rpc<PackLeft[]>('packs_left', { p_fp: sourceId }))
      .then((r) => { if (live) setLeft(r); }).catch(() => { if (live) setLeft([]); });
    return () => { live = false; };
  }, [sourceId]);
  type R = { sku_id: string; units: string };
  const rows: R[] = Array.isArray(value) ? (value as unknown as R[]) : [];
  const units = (sku: string) => rows.find((r) => r.sku_id === sku)?.units ?? '';
  const set = (sku: string, u: string) => onChange([...rows.filter((r) => r.sku_id !== sku), ...(u ? [{ sku_id: sku, units: u }] : [])] as unknown as FieldValue);
  if (left === null) return <p className="small muted" id={id}>{t('common.loading', undefined, '…')}</p>;
  if (!left.length) return <p className="alert info" id={id} data-testid="no-packs-left">{t('ord.no_packs')}</p>;
  const kgs = rows.reduce((a, r) => a + (Number(r.units) || 0) * Number(left.find((l) => l.sku_id === r.sku_id)?.size_kg ?? 0), 0);
  return (
    <div className="stack" id={id} data-testid="order-packs">
      {left.map((l, i) => {
        const over = Number(units(l.sku_id)) > Number(l.left);
        return (
          <div key={l.sku_id} className="row" data-testid={`order-line-${i}`}>
            <label htmlFor={`${id}-${i}`} style={{ flex: '1 1 160px', margin: 0 }}>{l.name}<span className="hint"> {t('ord.left', { n: Number(l.left) })}</span></label>
            <input id={`${id}-${i}`} inputMode="numeric" style={{ flex: '0 0 110px', width: 'auto' }} value={units(l.sku_id)} placeholder="0"
              disabled={Number(l.left) <= 0 && !units(l.sku_id)} data-testid={`order-units-${i}`} aria-invalid={over}
              onChange={(e) => set(l.sku_id, e.target.value.replace(/[^0-9]/g, ''))} />
            {over && <span className="small" style={{ color: 'var(--red)' }}>{t('ord.over', { n: Number(l.left) })}</span>}
          </div>);
      })}
      <span className="small muted" data-testid="order-kg">{t('ord.total', { kg: kgText(kgs) })}</span>
    </div>);
}
