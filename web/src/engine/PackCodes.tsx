// Migration 57 (Veda, 16 Oct 2026: "Pack codes loaded (scan or type, one per line) - share suggestion to improve";
// "rest all ok and proceed with 57"): the codes of the packs loaded on a shipment, domestic or export.
//   - the camera keeps scanning (each pack beeps and appears), where the phone's browser can read QR codes;
//   - a range ("from 002-0009 to 002-0010"), and "all N packs of batch X" when the order takes all that is left of it;
//   - typing or pasting stays;
//   - each code is checked as it comes against the order's packs (app.order_pack_codes, kept on the phone):
//     already shipped (and on which shipment), not this order's batch, void, scanned twice; each problem can be removed;
//   - the count per pack type against the packs shipped on the same form.
// The value stays the text of codes, one per line, as before: the server checks every code again when it saves.
import { useEffect, useMemo, useRef, useState } from 'react';
import { rpc } from '../lib/api';
import { useI18n } from '../lib/i18n';
import { cached } from '../offline/cache';

export interface PackCode { serial: string; sku_id: string | null; sku: string | null; size_kg: number; void: boolean; shipped_in: string | null }
export type CodeStatus = 'ok' | 'twice' | 'other' | 'void' | 'shipped';
export interface CheckedCode { code: string; status: CodeStatus; sku_id: string | null; shipped_in?: string | null }

/** Pure: a code as scanned or typed: a pack page's address (…/p/<code>) gives its code; capitals, no spaces. */
export function normCode(raw: string): string {
  const s = raw.trim();
  const m = s.match(/\/p\/([^/?#\s]+)/i);
  return decodeURIComponent(m ? m[1] : s).trim().toUpperCase();
}
/** Pure: the codes of a text, one per line (or separated by commas or spaces), normalised, in the order given. */
export const codeLines = (s: string) => s.split(/[\s,;]+/).map(normCode).filter(Boolean);

/** Pure: each code checked against the order's packs. A code given twice is "twice" the second time. */
export function checkCodes(codes: string[], packs: PackCode[] | null): CheckedCode[] {
  const by = new Map((packs ?? []).map((p) => [p.serial.toUpperCase(), p]));
  const seen = new Set<string>();
  return codes.map((code) => {
    const p = by.get(code);
    const twice = seen.has(code); seen.add(code);
    if (twice) return { code, status: 'twice', sku_id: p?.sku_id ?? null };
    if (!packs) return { code, status: 'ok', sku_id: null };                    // nothing to check against yet: the save checks
    if (!p) return { code, status: 'other', sku_id: null };
    if (p.void) return { code, status: 'void', sku_id: p.sku_id };
    if (p.shipped_in) return { code, status: 'shipped', sku_id: p.sku_id, shipped_in: p.shipped_in };
    return { code, status: 'ok', sku_id: p.sku_id };
  });
}

/** Pure: a code's batch part and number (TCUP-2026-KNM-001-0040 → TCUP-2026-KNM-001-, 40, width 4). */
export function splitCode(code: string): { stem: string; n: number; width: number } | null {
  const m = code.match(/^(.*?)(\d+)$/);
  return m ? { stem: m[1], n: Number(m[2]), width: m[2].length } : null;
}

/** Pure: the order's packs between two codes of one batch (both given in full, or the second as its number only). */
export function rangeCodes(from: string, to: string, packs: PackCode[]): string[] | null {
  const a = splitCode(normCode(from));
  const toN = normCode(to);
  const b = /^\d+$/.test(toN) && a ? { stem: a.stem, n: Number(toN), width: a.width } : splitCode(toN);
  if (!a || !b || a.stem !== b.stem || b.n < a.n || b.n - a.n > 5000) return null;
  return packs.map((p) => p.serial.toUpperCase()).filter((s) => { const x = splitCode(s); return !!x && x.stem === a.stem && x.n >= a.n && x.n <= b.n; }).sort();
}

/** Pure: the good codes in runs of one batch and consecutive numbers, for a short list ("0001 … 0030 · 30"). */
export function codeRuns(codes: string[]): { from: string; to: string; n: number }[] {
  const sorted = [...new Set(codes)].sort();
  const runs: { from: string; to: string; n: number }[] = [];
  for (const c of sorted) {
    const last = runs[runs.length - 1];
    const x = splitCode(c), y = last ? splitCode(last.to) : null;
    if (last && x && y && x.stem === y.stem && x.n === y.n + 1) { last.to = c; last.n += 1; } else runs.push({ from: c, to: c, n: 1 });
  }
  return runs;
}

/** Pure: per pack type, the good codes against the packs shipped on the form. */
export function perSku(checked: CheckedCode[], lines: { sku_id: string; units: number }[], packs: PackCode[] | null) {
  const name = (id: string) => packs?.find((p) => p.sku_id === id)?.sku ?? '';
  return lines.filter((l) => l.units > 0).map((l) => {
    const n = checked.filter((c) => c.status === 'ok' && c.sku_id === l.sku_id).length;
    return { sku_id: l.sku_id, name: name(l.sku_id), n, of: l.units };
  });
}

function beep() {
  try {
    const W = window as unknown as { AudioContext?: typeof AudioContext; webkitAudioContext?: typeof AudioContext };
    const Ctx = W.AudioContext ?? W.webkitAudioContext;
    if (Ctx) { const a = new Ctx(); const o = a.createOscillator(); o.frequency.value = 880; o.connect(a.destination); o.start(); o.stop(a.currentTime + 0.08); setTimeout(() => void a.close(), 300); }
    navigator.vibrate?.(40);
  } catch { /* a scan without a sound */ }
}

interface Detector { detect(src: CanvasImageSource): Promise<{ rawValue: string }[]> }
const canScan = () => typeof window !== 'undefined' && 'BarcodeDetector' in window && !!navigator.mediaDevices?.getUserMedia;

export function PackCodes({ id, name, sourceId, editingId, value, onChange, packLines }: {
  id: string; name: string; sourceId?: string; editingId?: string; value: string; onChange: (v: string) => void;
  /** the "Packs shipped" field of the same form: units per pack type */ packLines: { sku_id: string; units: number }[];
}) {
  const { t } = useI18n();
  const [packs, setPacks] = useState<PackCode[] | null>(null);
  const [unchecked, setUnchecked] = useState(false);
  // where the browser cannot read QR codes (an iPhone, a computer), the typing box is open from the start
  const [mode, setMode] = useState<'none' | 'range' | 'type' | 'camera'>(() => (canScan() ? 'none' : 'type'));
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [last, setLast] = useState<string>('');
  const [camErr, setCamErr] = useState('');
  useEffect(() => {
    if (!sourceId) return;
    let live = true;
    setUnchecked(false);
    void cached(`order_pack_codes:${sourceId}:${editingId ?? ''}`, () => rpc<PackCode[]>('order_pack_codes', { p_fp: sourceId, ...(editingId ? { p_except: editingId } : {}) }))
      .then((r) => { if (live) setPacks(r ?? []); }).catch(() => { if (live) { setPacks(null); setUnchecked(true); } });
    return () => { live = false; };
  }, [sourceId, editingId]);

  const codes = useMemo(() => codeLines(value ?? ''), [value]);
  const checked = useMemo(() => checkCodes(codes, packs), [codes, packs]);
  const good = checked.filter((c) => c.status === 'ok');
  const bad = checked.filter((c) => c.status !== 'ok');
  const wanted = packLines.reduce((a, l) => a + (l.units > 0 ? l.units : 0), 0);
  const skus = perSku(checked, packLines, packs);
  const valueRef = useRef(value); valueRef.current = value;
  const add = (more: string[]) => {
    const have = new Set(codeLines(valueRef.current ?? ''));
    const fresh = more.map(normCode).filter((c) => c && !have.has(c));
    if (fresh.length) onChange([...codeLines(valueRef.current ?? ''), ...fresh].join('\n'));
    return fresh.length;
  };
  const removeAt = (i: number) => onChange(codes.filter((_, k) => k !== i).join('\n'));

  // the camera: keeps reading until stopped; a code read again within two seconds is the same pack still in view
  const video = useRef<HTMLVideoElement>(null);
  useEffect(() => {
    if (mode !== 'camera') return;
    let stream: MediaStream | null = null; let timer: ReturnType<typeof setInterval> | undefined; let stop = false;
    const recent = new Map<string, number>();
    void (async () => {
      try {
        const D = (window as unknown as { BarcodeDetector: new (o: { formats: string[] }) => Detector }).BarcodeDetector;
        const det = new D({ formats: ['qr_code'] });
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false });
        if (stop || !video.current) { stream.getTracks().forEach((x) => x.stop()); return; }
        video.current.srcObject = stream; await video.current.play();
        timer = setInterval(() => {
          if (!video.current || video.current.readyState < 2) return;
          void det.detect(video.current).then((rs) => {
            for (const r of rs) {
              const c = normCode(r.rawValue); const now = Date.now();
              if (!c || (recent.get(c) ?? 0) > now - 2000) continue;
              recent.set(c, now);
              const n = add([c]); setLast(c);
              if (n) beep();
            }
          }).catch(() => undefined);
        }, 250);
      } catch (e) {
        setCamErr((e as { name?: string })?.name === 'NotAllowedError' ? t('pc.camera_denied') : t('pc.no_camera'));
        setMode('none');
      }
    })();
    return () => { stop = true; if (timer) clearInterval(timer); stream?.getTracks().forEach((x) => x.stop()); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode]);

  const range = mode === 'range' && packs && from && to ? rangeCodes(from, to, packs) : null;
  const rangeChecked = range ? checkCodes([...codes, ...range], packs).slice(codes.length) : [];
  const rangeOk = rangeChecked.filter((c) => c.status === 'ok').length;
  // the whole rest of a batch: offered when the order takes exactly what is left of a pack type
  const wholeBatch = packs ? skus.map((s) => {
    const free = packs.filter((p) => p.sku_id === s.sku_id && !p.void && !p.shipped_in).map((p) => p.serial.toUpperCase());
    const missing = free.filter((c) => !codes.includes(c));
    return free.length > 0 && free.length === s.of && missing.length > 0 ? { sku: s.name, codes: missing, n: free.length } : null;
  }).filter(Boolean) as { sku: string; codes: string[]; n: number }[] : [];
  const batchOf = (c: string) => splitCode(c)?.stem.replace(/-$/, '') ?? '';
  const stLabel = (c: CheckedCode) => c.status === 'shipped' ? t('pc.st_shipped', { code: c.shipped_in ?? '' }) : t(`pc.st_${c.status}`);

  return (
    <div className="stack pack-codes" id={id} data-testid="pack-codes">
      {wanted > 0 && (
        <div className="pc-progress" data-testid="pc-progress">
          <div className="pc-big"><b>{good.length}</b> {t('pc.of_packs', { m: wanted })}</div>
          <div className="pc-bar"><span style={{ width: `${Math.min(100, Math.round((good.length / Math.max(1, wanted)) * 100))}%` }} /></div>
          {skus.map((s) => (
            <div className="pc-sku" key={s.sku_id} data-testid="pc-sku">
              <span>{s.name || t('pc.a_type')}</span>
              <span className={`badge ${s.n === s.of ? 'verified' : 'pending'}`}>{t('pc.n_of', { n: s.n, m: s.of })}{s.n < s.of ? ` · ${t('pc.short', { n: s.of - s.n })}` : s.n > s.of ? ` · ${t('pc.over', { n: s.n - s.of })}` : ''}</span>
            </div>))}
        </div>)}
      <span className="small muted" data-testid="serials-count">{t('ship.codes_n', { n: codes.length })}</span>

      <div className="pc-actions">
        {canScan() && (mode === 'camera'
          ? <button type="button" className="secondary" onClick={() => setMode('none')} data-testid="pc-scan-stop">{t('pc.scan_stop')}</button>
          : <button type="button" onClick={() => { setCamErr(''); setMode('camera'); }} data-testid="pc-scan">{t('pc.scan')}</button>)}
        <button type="button" className={mode === 'range' ? '' : 'secondary'} onClick={() => setMode(mode === 'range' ? 'none' : 'range')} data-testid="pc-range">{t('pc.range')}</button>
        <button type="button" className={mode === 'type' ? '' : 'secondary'} onClick={() => setMode(mode === 'type' ? 'none' : 'type')} data-testid="pc-type">{t('pc.type')}</button>
      </div>
      {!canScan() && <p className="small muted" data-testid="pc-no-camera">{t('pc.no_camera')}</p>}
      {camErr && <p className="small" role="alert">{camErr}</p>}
      {mode === 'camera' && (
        <div className="pc-camera"><video ref={video} muted playsInline aria-label={t('pc.scan')} />
          <p className="small">{t('pc.scan_hint')}{last ? ` · ${t('pc.last', { code: last })}` : ''}</p></div>)}
      {mode === 'range' && (
        <div className="pc-range" data-testid="pc-range-box">
          <div className="lot-filters">
            <label>{t('pc.from')}<input value={from} onChange={(e) => setFrom(e.target.value)} className="mono" autoComplete="off" spellCheck={false} data-testid="pc-from"
              placeholder={packs?.find((p) => !p.void && !p.shipped_in && !codes.includes(p.serial.toUpperCase()))?.serial ?? ''} /></label>
            <label>{t('pc.to')}<input value={to} onChange={(e) => setTo(e.target.value)} className="mono" autoComplete="off" spellCheck={false} data-testid="pc-to" /></label>
          </div>
          {from && to && (range === null
            ? <p className="small" data-testid="pc-range-bad">{t('pc.range_bad')}</p>
            : <><p className="small" data-testid="pc-range-n">{t('pc.range_n', { n: range.length, ok: rangeOk })}</p>
                <button type="button" disabled={rangeOk === 0} data-testid="pc-range-add"
                  onClick={() => { add(rangeChecked.filter((c) => c.status === 'ok').map((c) => c.code)); setFrom(''); setTo(''); }}>{t('pc.add_n', { n: rangeOk })}</button></>)}
        </div>)}
      {wholeBatch.map((w) => (
        <button type="button" className="secondary" key={w.sku} data-testid="pc-whole" onClick={() => add(w.codes)}>
          {t('pc.add_batch', { n: w.n, batch: batchOf(w.codes[0]) })}</button>))}
      {mode === 'type' && (
        <textarea id={`${id}-text`} name={name} rows={5} value={value ?? ''} onChange={(e) => onChange(e.target.value)} autoComplete="off"
          spellCheck={false} className="mono" data-testid="serials" aria-label={t('pc.type')} />)}
      {unchecked && <p className="small muted" data-testid="pc-unchecked">{t('pc.unchecked')}</p>}

      {codes.length > 0 && (
        <div className="pc-list" data-testid="pc-list">
          {codeRuns(good.map((c) => c.code)).map((r) => (
            <div className="pc-row" key={r.from} data-testid="pc-run">
              <span className="mono small">{r.from === r.to ? r.from : `${r.from} … ${splitCode(r.to)?.n.toString().padStart(splitCode(r.to)!.width, '0')}`}</span>
              <span className="badge verified">{r.n === 1 ? t('pc.ok') : t('pc.ok_run', { n: r.n })}</span>
            </div>))}
          {bad.map((c) => {
            const i = checked.indexOf(c);
            return (
              <div className={`pc-row bad ${c.status}`} key={`${c.code}-${i}`} data-testid="pc-bad" data-status={c.status}>
                <span className="stack" style={{ gap: 4 }}><span className="mono small">{c.code}</span>
                  <span className={`badge ${c.status === 'twice' ? 'draft' : c.status === 'other' ? 'pending' : 'fail'}`}>{stLabel(c)}</span></span>
                <button type="button" className="secondary small" onClick={() => removeAt(i)} aria-label={`${t('pc.remove')}: ${c.code}`}>{t('pc.remove')}</button>
              </div>);
          })}
        </div>)}
      {bad.length > 0 && <p className="small" data-testid="pc-fix">{t('pc.fix_n', { n: bad.length })}</p>}
    </div>
  );
}
