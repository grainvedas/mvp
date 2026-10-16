// Migration 55 (C3; Veda 16 Oct 2026): a lot in the warehouse, on its record page. How long it has been stored, the bags
// in and out, the inspections (every N days, set by the scope's Client Manager) and when the next is due. The person
// holding the Warehouse stage (or a manager of the scope) records an inspection; bags out are recorded by the Warehouse,
// the stage that takes the lot, or a manager. The server checks each of these again.
import { useState } from 'react';
import { rpc } from '../../lib/api';
import { useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { date, todayIST } from '../../lib/format';
import type { Footprint, InspectionCondition, WarehouseInfo } from '../../lib/types';
import { ErrorBox, Field } from '../../shell/ui';

export const INSPECTION_CONDITIONS: InspectionCondition[] = ['good', 'minor', 'significant', 'pest'];

/** Pure: what the panel says of the next inspection (the server's state, in the reader's words). */
export function inspectionLine(w: WarehouseInfo, t: (k: string, v?: Record<string, string | number>) => string): string {
  const i = w.inspection;
  if (!i) return '';
  if (i.state === 'done') return t('wp.state_done');
  return t(`wp.state_${i.state}`, { date: date(i.next_due), n: i.interval_days });
}

export function WarehousePanel({ f, w, mayInspect, mayMove, onDone }: {
  f: Footprint; w: WarehouseInfo; mayInspect: boolean; mayMove: boolean; onDone: () => void;
}) {
  const { t } = useI18n();
  const today = todayIST();
  const from = f.happened_on ?? f.created_at.slice(0, 10);
  const open = f.status === 'pending' || f.status === 'verified';
  const left = w.bags_in === null ? null : Math.max(0, w.bags_in - w.bags_out);
  const [insp, setInsp] = useState<{ on: string; condition: InspectionCondition | ''; note: string } | null>(null);
  const [out, setOut] = useState<{ on: string; bags: string; note: string } | null>(null);
  const act = useAction();
  const state = w.inspection?.state ?? 'done';
  const saveInspection = () => act.run(async () => {
    await rpc('record_inspection', { p_fp: f.id, p_on: insp!.on, p_condition: insp!.condition, p_note: insp!.note.trim() || null });
    setInsp(null); onDone();
  });
  const saveBags = () => act.run(async () => {
    await rpc('record_bags_out', { p_fp: f.id, p_bags: Number(out!.bags), p_on: out!.on, p_note: out!.note.trim() || null });
    setOut(null); onDone();
  });
  const bagsOk = out !== null && /^[1-9][0-9]*$/.test(out.bags) && (left === null || Number(out.bags) <= left);
  const noteOk = insp !== null && insp.condition !== '' && (insp.condition === 'good' || insp.note.trim().length >= 5);
  return (
    <div className="card stack" data-testid="warehouse-panel" data-state={state}>
      <h2>{t('wp.title')}</h2>
      <dl className="kv">
        <dt>{t('wp.days')}</dt><dd className="big" data-testid="wp-days">{t('wp.days_n', { n: w.days })}</dd>
        {w.bags_in !== null && <><dt>{t('wp.bags')}</dt><dd data-testid="wp-bags">{t('wp.bags_n', { in: w.bags_in, out: w.bags_out, left: left ?? 0 })}</dd></>}
        {w.inspection && <><dt>{t('wp.next')}</dt><dd data-testid="wp-next">
          <span className={`badge ${state === 'overdue' ? 'fail' : state === 'due' ? 'pending' : state === 'done' ? 'closed' : 'verified'}`} data-testid="wp-badge">{t(`wp.badge_${state}`)}</span>{' '}
          {inspectionLine(w, t)}</dd></>}
      </dl>
      <h3>{t('wp.inspections')}</h3>
      {w.inspections.length === 0 ? <p className="small muted">{t('wp.none')}</p> : (
        <ul className="sys-checks" data-testid="wp-inspections">{w.inspections.map((i, k) => (
          <li key={k} className={i.condition === 'good' ? 'ok' : 'not'}>
            <span aria-hidden="true">{i.condition === 'good' ? '✓' : '!'}</span> {date(i.on)} · {t(`insp.${i.condition}`)}{i.note ? ` (“${i.note}”)` : ''} · {i.by ?? '—'}
          </li>))}</ul>)}
      {mayInspect && open && state !== 'done' && !insp && <button className="secondary" data-testid="wp-inspect"
        onClick={() => setInsp({ on: today, condition: '', note: '' })}>{t('wp.record')}</button>}
      {insp && (
        <div className="stack" data-testid="wp-inspect-form">
          <Field label={`${t('wp.date')} *`} htmlFor="wp-on"><input id="wp-on" type="date" min={from} max={today} value={insp.on} onChange={(e) => setInsp({ ...insp, on: e.target.value })} /></Field>
          <Field label={`${t('wp.condition')} *`} htmlFor="wp-cond"><select id="wp-cond" value={insp.condition} data-testid="wp-cond"
            onChange={(e) => setInsp({ ...insp, condition: e.target.value as InspectionCondition })}>
            <option value="">—</option>{INSPECTION_CONDITIONS.map((c) => <option key={c} value={c}>{t(`insp.${c}`)}</option>)}</select></Field>
          <Field label={`${t('wp.note')}${insp.condition && insp.condition !== 'good' ? ' *' : ''}`} htmlFor="wp-note">
            <input id="wp-note" value={insp.note} maxLength={300} data-testid="wp-note" onChange={(e) => setInsp({ ...insp, note: e.target.value })} /></Field>
          {insp.condition !== '' && insp.condition !== 'good' && <p className="hint">{t('wp.note_hint')}</p>}
          <ErrorBox error={act.error} />
          <div className="row"><button disabled={act.busy || !noteOk || !insp.on} onClick={() => void saveInspection()} data-testid="wp-inspect-save">{t('wp.save_inspection')}</button>
            <button className="secondary" onClick={() => setInsp(null)}>{t('common.cancel')}</button></div>
        </div>)}
      {w.bags_in !== null && <>
        <h3>{t('wp.moves')}</h3>
        {w.moves.length === 0 ? <p className="small muted">{t('wp.no_moves')}</p> : (
          <ul data-testid="wp-moves">{w.moves.map((m, k) => <li key={k}>{date(m.on)} · {t('wp.moved_n', { n: m.bags })}{m.note ? ` (“${m.note}”)` : ''} · {m.by ?? '—'}</li>)}</ul>)}
        {mayMove && open && (left ?? 1) > 0 && !out && <button className="secondary" data-testid="wp-out"
          onClick={() => setOut({ on: today, bags: '', note: '' })}>{t('wp.record_out')}</button>}
        {out && (
          <div className="stack" data-testid="wp-out-form">
            <Field label={`${t('wp.bags_out')} *`} htmlFor="wp-bags" hint={left === null ? undefined : t('wp.left_n', { n: left })}>
              <input id="wp-bags" inputMode="numeric" value={out.bags} data-testid="wp-bags-n" onChange={(e) => setOut({ ...out, bags: e.target.value.replace(/[^0-9]/g, '') })} /></Field>
            <Field label={`${t('wp.date')} *`} htmlFor="wp-out-on"><input id="wp-out-on" type="date" min={from} max={today} value={out.on} onChange={(e) => setOut({ ...out, on: e.target.value })} /></Field>
            <Field label={t('wp.out_note')} htmlFor="wp-out-note"><input id="wp-out-note" value={out.note} maxLength={300} onChange={(e) => setOut({ ...out, note: e.target.value })} /></Field>
            <ErrorBox error={act.error} />
            <div className="row"><button disabled={act.busy || !bagsOk || !out.on} onClick={() => void saveBags()} data-testid="wp-out-save">{t('wp.save_out')}</button>
              <button className="secondary" onClick={() => setOut(null)}>{t('common.cancel')}</button></div>
          </div>)}
      </>}
    </div>);
}
