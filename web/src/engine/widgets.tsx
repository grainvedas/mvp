// Field widgets for the generic engine. A widget knows a field TYPE, never a stage: stage behaviour comes only from
// stage_definitions.form_schema (execution plan §6, "no stage-specific screen code").
import { useEffect, useState } from 'react';
import type { FieldDef, QualityParam, Farmer } from '../lib/types';
import { supabase } from '../lib/supabase';
import { useI18n } from '../lib/i18n';
import { cached } from '../offline/cache';

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
}

/** Types this build can render. Anything else shows a notice and blocks save if required. */
export const SUPPORTED = new Set(['number', 'integer', 'number[3]', 'text', 'select', 'date', 'boolean', 'attachment', 'readings', 'farmer',
  'breakdown', 'packets[]', 'footprint[]']);

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
          {(field.options ?? []).map((o) => <option key={o} value={o}>{t(`opt.${o}`, undefined, o.replace(/_/g, ' '))}</option>)}
        </select>
      );
    case 'boolean':
      return <input id={id} name={field.key} type="checkbox" checked={value === true} onChange={(e) => onChange(e.target.checked)} />;
    case 'attachment':
      return <input id={id} name={field.key} type="file" accept="image/*" capture="environment"
        onChange={(e) => onChange(e.target.files?.[0] ?? null)} />;
    case 'readings': {
      const obj = (value && typeof value === 'object' && !(value instanceof File) && !Array.isArray(value)) ? value as Record<string, string> : {};
      return (
        <div className="stack">
          {p.qualityParams.map((q) => (
            <div key={q.param} className="row">
              <label htmlFor={`${id}-${q.param}`} style={{ flex: '1 1 160px', margin: 0 }}>
                {q.label}{q.unit ? ` (${q.unit})` : ''}
                <span className="hint"> {t('pv.domestic')} {q.operator} {limitText(q.domestic_limit)} · {t('pv.export')} {q.operator} {limitText(q.export_limit)}</span>
              </label>
              <input id={`${id}-${q.param}`} name={`readings.${q.param}`} inputMode="decimal" style={{ flex: '0 0 140px' }}
                value={obj[q.param] ?? ''} onChange={(e) => onChange({ ...obj, [q.param]: e.target.value.replace(',', '.') })} />
            </div>
          ))}
        </div>
      );
    }
    case 'farmer':
      return <FarmerPicker id={id} clientId={p.clientId} value={(value as string) ?? ''} onChange={(v) => onChange(v)} />;
    case 'breakdown':
      return <RowsEditor id={id} value={value} onChange={onChange} cols={[{ key: 'reason', label: t('widget.reason'), numeric: false }, { key: 'kg', label: t('widget.kg'), numeric: true }]} addLabel={t('widget.add_reason')} />;
    case 'packets[]':
      return <RowsEditor id={id} value={value} onChange={onChange} cols={[{ key: 'units', label: t('widget.packets'), numeric: true }, { key: 'size_kg', label: t('widget.size_kg'), numeric: true }]} addLabel={t('widget.add_packet')} />;
    case 'footprint[]':
      return <LotPicker id={id} scopeId={p.scopeId ?? ''} stageType={p.stageType ?? ''} value={Array.isArray(value) ? value as string[] : []} onChange={onChange} />;
    default:
      return <p className="alert info">{t('engine.widget_missing')}</p>;
  }
}

function FarmerPicker({ id, clientId, value, onChange }: { id: string; clientId: string; value: string; onChange: (v: string) => void }) {
  const { t } = useI18n();
  const [q, setQ] = useState('');
  const [all, setAll] = useState<Farmer[]>([]);
  const [picked, setPicked] = useState<Farmer | null>(null);
  // The whole active list (RLS: only this client's farmers, only for procurement / village batch operators) is kept on
  // the phone so the farm-gate form works without a network; searching is local.
  useEffect(() => {
    let live = true;
    void cached(`farmers:${clientId}`, async () => {
      const { data, error } = await supabase.from('farmers').select('id,farmer_code,name,village,district,phone,status,client_id')
        .eq('client_id', clientId).eq('status', 'active').order('name').limit(5000);
      if (error) throw error;
      return (data ?? []) as Farmer[];
    }).then((l) => { if (live) setAll(l); }).catch(() => undefined);
    return () => { live = false; };
  }, [clientId]);
  useEffect(() => { if (value && picked?.id !== value) setPicked(all.find((f) => f.id === value) ?? null); }, [value, picked?.id, all]);
  const s = q.trim().toLowerCase(), digits = s.replace(/[^0-9]/g, '');
  const list = (s ? all.filter((f) => f.name.toLowerCase().includes(s) || (f.farmer_code ?? '').toLowerCase().includes(s)
    || f.village.toLowerCase().includes(s) || (digits.length >= 3 && (f.phone ?? '').includes(digits))) : all).slice(0, 20);
  if (picked && value) {
    return (
      <div className="row" data-testid="farmer-picked">
        <strong>{picked.name}</strong> <span className="mono">{picked.farmer_code}</span> <span className="muted">{picked.village}</span>
        <button type="button" className="secondary" onClick={() => { setPicked(null); onChange(''); }}>{t('widget.change')}</button>
      </div>
    );
  }
  return (
    <div>
      <input id={id} placeholder={t('widget.farmer_search')} value={q} onChange={(e) => setQ(e.target.value)} autoComplete="off" />
      <ul style={{ listStyle: 'none', padding: 0, margin: '6px 0 0' }} role="listbox" aria-label={t('widget.active_farmers')}>
        {list.map((f) => (
          <li key={f.id}>
            <button type="button" className="secondary" style={{ width: '100%', justifyContent: 'flex-start', marginBottom: 4 }}
              onClick={() => { setPicked(f); onChange(f.id); }}>
              {f.name} · <span className="mono">{f.farmer_code}</span> · {f.village}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

type Row = Record<string, string>;
function RowsEditor({ id, value, onChange, cols, addLabel }: {
  id: string; value: FieldValue; onChange: (v: FieldValue) => void;
  cols: { key: string; label: string; numeric: boolean }[]; addLabel: string;
}) {
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
          {list.length > 1 && <button type="button" className="secondary" aria-label={`Remove row ${i + 1}`} onClick={() => set(list.filter((_, j) => j !== i))}>✕</button>}
        </div>
      ))}
      <button type="button" className="secondary" onClick={() => set([...list, blank()])}>{addLabel}</button>
    </div>
  );
}

interface LotRow { id: string; footprint_code: string; qty_out: number; status: string; farmer_id: string | null }
function LotPicker({ id, scopeId, stageType, value, onChange }: { id: string; scopeId: string; stageType: string; value: string[]; onChange: (v: FieldValue) => void }) {
  const { t } = useI18n();
  const [lots, setLots] = useState<LotRow[]>([]);
  const [names, setNames] = useState<Record<string, string>>({});
  useEffect(() => {
    if (!scopeId || !stageType) return;
    import('../lib/api').then(({ rpc }) => cached(`incoming:${scopeId}:${stageType}`, () => rpc<LotRow[]>('incoming_records', { p_scope: scopeId, p_stage: stageType })))
      .then((r) => {
        const verified = r.filter((x) => x.status === 'verified');
        setLots(verified);
        const ids = verified.map((x) => x.farmer_id).filter(Boolean) as string[];
        if (ids.length) supabase.from('farmers').select('id,name,village').in('id', ids)
          .then(({ data }) => setNames(Object.fromEntries((data ?? []).map((f: { id: string; name: string; village: string }) => [f.id, `${f.name}, ${f.village}`]))));
      }).catch(() => setLots([]));
  }, [scopeId, stageType]);
  if (!lots.length) return <p className="alert info" id={id}>{t('widget.no_lots')}</p>;
  return (
    <div id={id} className="stack">
      {lots.map((l) => (
        <label key={l.id} className="check">
          <input type="checkbox" checked={value.includes(l.id)} onChange={(e) => onChange(e.target.checked ? [...value, l.id] : value.filter((x) => x !== l.id))} />
          <span><span className="mono">{l.footprint_code}</span> · {Number(l.qty_out).toLocaleString('en-IN')} kg{l.farmer_id && names[l.farmer_id] ? ` · ${names[l.farmer_id]}` : ''}</span>
        </label>
      ))}
    </div>
  );
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
    } else if (f.type === 'breakdown' || f.type === 'packets[]') {
      const rows = (v as unknown as Record<string, string>[]).filter((r) => Object.values(r).some((x) => x !== ''));
      if (!rows.length) continue;
      out = rows.map((r) => Object.fromEntries(Object.entries(r).map(([k, x]) => [k, k === 'reason' ? x : toNum(x)])));
    } else if (f.type === 'footprint[]') {
      const ids = v as string[];
      if (!ids.length) continue;
      out = ids;
      if ((f as FieldDef & { sets_prev?: boolean }).sets_prev) columns.prev_footprint_id = ids[0];
    } else if (f.type === 'readings') {
      const o: Record<string, number> = {};
      for (const [k, s] of Object.entries(v as Record<string, string>)) { const n = toNum(s); if (n !== undefined && !Number.isNaN(n)) o[k] = n; }
      out = o;
    }
    if (f.column) columns[f.key] = out; else payload[f.key] = out;
  }
  return { payload, columns, files };
}

/** Required fields that are still empty (by label). */
export function missingRequired(fields: FieldDef[], values: Record<string, FieldValue>): string[] {
  return fields.filter((f) => f.required && f.type !== 'attachment').filter((f) => {
    const v = values[f.key];
    if (f.type === 'number[3]') return !Array.isArray(v) || (v as string[]).filter((x) => x !== '' && x !== undefined).length < 3;
    if (f.type === 'readings') return !v || Object.values(v as Record<string, string>).every((x) => x === '');
    if (f.type === 'packets[]') return !Array.isArray(v) || !(v as unknown as Record<string, string>[]).some((r) => r.units && r.size_kg);
    if (f.type === 'footprint[]') return !Array.isArray(v) || (v as string[]).length === 0;
    return v === undefined || v === null || v === '';
  }).map((f) => f.label);
}

export const PREFILL_FROM_SOURCE = ['input_kg', 'qty_kg', 'stored_kg', 'shipped_kg'];
