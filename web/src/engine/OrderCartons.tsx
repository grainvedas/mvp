// Migration 58 (Veda, 16 Oct 2026: "There should a mechanism to choose packs and in future there will be more than 1
// lakhs packs"; "proceed with 58"): the cartons a sale of packs takes. Left empty, the server sets aside the oldest free
// cartons, then packs of a carton not taken whole; or the person chooses runs of cartons (the buyer asked for those, they
// stand at the front of the store). What is free comes from app.available_cartons, per pack type, in runs; the save
// checks every carton again (app.allocate_units). The value is the list of carton codes chosen.
import { useEffect, useMemo, useState } from 'react';
import { rpc } from '../lib/api';
import { useI18n } from '../lib/i18n';
import { cached } from '../offline/cache';
import { codeRuns, normCode, splitCode } from './PackCodes';

export interface CartonRun { from: string; to: string; cartons: number; packs: number }
export interface FreeCartons { sku_id: string; sku: string; per_carton: number | null; cartons: number; packs: number; runs: CartonRun[] }

/** Pure: the carton codes from one to another of the same batch ("…-C0009" to "…-C0012", or to "12"). */
export function cartonRange(from: string, to: string): string[] | null {
  const a = splitCode(normCode(from));
  const toN = normCode(to);
  const b = /^\d+$/.test(toN) && a ? { stem: a.stem, n: Number(toN), width: a.width } : splitCode(toN);
  if (!a || !b || a.stem !== b.stem || !/-C$/.test(a.stem) || b.n < a.n || b.n - a.n > 5000) return null;
  return Array.from({ length: b.n - a.n + 1 }, (_, i) => `${a.stem}${String(a.n + i).padStart(a.width, '0')}`);
}

/** Pure: which free run a carton code is in (null: not a free carton of this lot). */
export function runOf(code: string, free: FreeCartons[]): { sku: FreeCartons; run: CartonRun } | null {
  const x = splitCode(code);
  if (!x) return null;
  for (const s of free) for (const r of s.runs) {
    const a = splitCode(r.from), b = splitCode(r.to);
    if (a && b && a.stem === x.stem && x.n >= a.n && x.n <= b.n) return { sku: s, run: r };
  }
  return null;
}

/** Pure: the packs in the chosen cartons, per pack type (the last carton of a run may hold fewer: its run says how many). */
export function chosenPacks(codes: string[], free: FreeCartons[]): Map<string, number> {
  const out = new Map<string, number>();
  for (const c of codes) {
    const hit = runOf(c, free);
    if (!hit) continue;
    const per = Number(hit.sku.per_carton ?? 0);
    const last = c === hit.run.to.toUpperCase() ? hit.run.packs - per * (hit.run.cartons - 1) : per;
    out.set(hit.sku.sku_id, (out.get(hit.sku.sku_id) ?? 0) + Math.max(0, last));
  }
  return out;
}

export function OrderCartons({ id, sourceId, editingId, value, onChange, packLines }: {
  id: string; sourceId?: string; editingId?: string; value: string[]; onChange: (v: string[]) => void;
  /** the "Packs sold" field of the same form: units per pack type */ packLines: { sku_id: string; units: number }[];
}) {
  const { t } = useI18n();
  const [free, setFree] = useState<FreeCartons[] | null>(null);
  const [failed, setFailed] = useState(false);
  const [choose, setChoose] = useState(value.length > 0);
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  useEffect(() => {
    if (!sourceId) { setFree([]); return; }
    let live = true;
    void cached(`available_cartons:${sourceId}:${editingId ?? ''}`, () => rpc<FreeCartons[]>('available_cartons', { p_packing: sourceId, ...(editingId ? { p_except: editingId } : {}) }))
      .then((r) => { if (live) setFree(r ?? []); }).catch(() => { if (live) { setFree([]); setFailed(true); } });
    return () => { live = false; };
  }, [sourceId, editingId]);
  const codes = useMemo(() => [...new Set(value.map(normCode).filter(Boolean))], [value]);
  if (free === null) return <p className="small muted" id={id}>{t('common.loading', undefined, '…')}</p>;
  if (failed) return <p className="small muted" id={id} data-testid="oc-unchecked">{t('oc.unchecked')}</p>;
  if (!free.length) return <p className="small muted" id={id} data-testid="oc-none">{t('oc.none')}</p>;
  const packs = chosenPacks(codes, free);
  const bad = codes.filter((c) => !runOf(c, free));
  const range = from && to ? cartonRange(from, to) : null;
  const rangeFree = range ? range.filter((c) => runOf(c, free) && !codes.includes(c)) : [];
  const add = (more: string[]) => onChange([...codes, ...more.filter((c) => !codes.includes(c))]);
  const removeRun = (r: { from: string; to: string }) => onChange(codes.filter((c) => c < r.from || c > r.to));
  return (
    <div className="stack order-cartons" id={id} data-testid="order-cartons">
      {free.map((s) => {
        const want = packLines.find((l) => l.sku_id === s.sku_id)?.units ?? 0;
        const got = packs.get(s.sku_id) ?? 0;
        return (
          <div key={s.sku_id} className="oc-sku" data-testid="oc-sku">
            <div className="row wrap"><strong>{s.sku}</strong>
              <span className="small muted">{t('oc.free', { n: s.cartons, packs: s.packs, per: Number(s.per_carton ?? 0) })}</span></div>
            <div className="oc-runs">{s.runs.map((r) => (
              <button type="button" key={r.from} className="secondary small oc-run" data-testid="oc-run" disabled={!choose}
                onClick={() => { setFrom(r.from); setTo(r.to); }} aria-label={t('oc.run_aria', { from: r.from, to: r.to })}>
                <span className="mono">{r.from === r.to ? r.from.slice(-5) : `${r.from.slice(-5)} – ${r.to.slice(-5)}`}</span> · {t('oc.run_n', { n: r.cartons })}
              </button>))}</div>
            {choose && got > 0 && (
              <span className={`small ${got > want ? '' : 'muted'}`} style={got > want ? { color: 'var(--red)' } : undefined} data-testid="oc-sku-n">
                {got > want ? t('oc.over', { packs: got, want }) : t('oc.chosen_packs', { packs: got, want })}</span>)}
          </div>);
      })}
      <label className="check">
        <input type="checkbox" checked={choose} data-testid="oc-choose"
          onChange={(e) => { setChoose(e.target.checked); if (!e.target.checked) onChange([]); }} />
        {t('oc.choose')}
      </label>
      {!choose && <p className="small muted" data-testid="oc-oldest">{t('oc.oldest')}</p>}
      {choose && (
        <div className="stack" data-testid="oc-pick">
          <div className="lot-filters">
            <label>{t('oc.from')}<input value={from} onChange={(e) => setFrom(e.target.value)} className="mono" autoComplete="off" spellCheck={false} data-testid="oc-from" /></label>
            <label>{t('oc.to')}<input value={to} onChange={(e) => setTo(e.target.value)} className="mono" autoComplete="off" spellCheck={false} data-testid="oc-to" /></label>
          </div>
          {from && to && (range === null
            ? <p className="small" data-testid="oc-range-bad">{t('oc.range_bad')}</p>
            : <button type="button" disabled={rangeFree.length === 0} data-testid="oc-add" onClick={() => { add(rangeFree); setFrom(''); setTo(''); }}>
                {t('oc.add_n', { n: rangeFree.length })}</button>)}
          {codes.length > 0 && (
            <div className="pc-list" data-testid="oc-list">
              {codeRuns(codes.filter((c) => !bad.includes(c))).map((r) => (
                <div className="pc-row" key={r.from} data-testid="oc-chosen">
                  <span className="mono small">{r.from === r.to ? r.from : `${r.from} … ${r.to.slice(-4)}`}</span>
                  <span className="row" style={{ gap: 6 }}><span className="badge verified">{t('oc.run_n', { n: r.n })}</span>
                    <button type="button" className="secondary small" onClick={() => removeRun(r)} aria-label={`${t('pc.remove')}: ${r.from}`}>{t('pc.remove')}</button></span>
                </div>))}
              {bad.map((c) => (
                <div className="pc-row bad other" key={c} data-testid="oc-bad">
                  <span className="stack" style={{ gap: 4 }}><span className="mono small">{c}</span><span className="badge pending">{t('oc.not_free')}</span></span>
                  <button type="button" className="secondary small" onClick={() => onChange(codes.filter((x) => x !== c))}>{t('pc.remove')}</button>
                </div>))}
            </div>)}
        </div>)}
    </div>);
}
