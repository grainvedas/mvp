// Migration 53 (C5): the samples drawn from a lot that goes to Quality Control. On the lot's record and on the QC
// screen where the lot is verified (src/engine/StagePage.tsx): a module of its own, so the stage screen does not load
// the whole record page.
import { useState } from 'react';
import { rpc, q } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { kg, date, todayIST } from '../../lib/format';
import { type Footprint } from '../../lib/types';
import { ErrorBox, Field } from '../../shell/ui';

/** Migration 53 (C5): the samples drawn from a lot that goes to Quality Control: "sent to the lab, awaiting results",
 *  their retained counter-samples, a disposal. Drawn by QC (or a manager): the server decides. */
interface Sample { id: string; code: string; status: 'sent' | 'results_in' | 'disposed'; drawn_on: string; qty_kg: number; lab_name: string | null;
  counter_seal_no: string | null; counter_stored_at: string | null; keep_until: string | null; buyer_seal_no: string | null; buyer_recipient: string | null;
  qc_code: string | null; disposal_note: string | null }
export function SamplesPanel({ f, onChange }: { f: Footprint; onChange?: () => void }) {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const stateId = ctx?.scopes.find((s) => s.scope_id === f.scope_id)?.state_id;   // the labs of the scope's state
  const list = useAsync(() => rpc<Sample[]>('lot_samples', { p_fp: f.id }), [f.id]);
  const labs = useAsync(async () => {
    let r = supabase.from('labs').select('id,name,kind,accreditation_no').eq('active', true);
    if (stateId) r = r.eq('state_id', stateId);
    return (await q(r.order('name'))) as { id: string; name: string; kind: string; accreditation_no: string | null }[];
  }, [stateId]);
  const [open, setOpen] = useState(false);
  const [v, setV] = useState<Record<string, string>>({ drawn_on: todayIST() });
  const [disp, setDisp] = useState<{ id: string; note: string } | null>(null);
  const act = useAction();
  const set = (k: string, x: string) => setV({ ...v, [k]: x });
  const draw = () => act.run(async () => {
    await rpc('draw_sample', { p_fp: f.id, p: { ...v, qty_kg: v.qty_kg ? Number(v.qty_kg) : null } });
    setOpen(false); setV({ drawn_on: todayIST() }); list.reload(); onChange?.();
  });
  const dispose = () => act.run(async () => { await rpc('dispose_sample', { p_sample: disp!.id, p_note: disp!.note }); setDisp(null); list.reload(); onChange?.(); });
  return (
    <div className="card" data-testid="samples-panel">
      <h2>{t('smp.title')}</h2>
      {(list.data ?? []).length === 0 && <p className="small muted">{t('smp.none')}</p>}
      <ul className="small stack" style={{ paddingLeft: 16 }}>{(list.data ?? []).map((s) => (
        <li key={s.id} data-testid="sample-row" data-status={s.status}>
          <strong className="mono">{s.code}</strong> · {t(`smp.st_${s.status}`)}{s.qc_code ? ` (${s.qc_code})` : ''} · {kg(s.qty_kg)} · {date(s.drawn_on)}{s.lab_name ? ` · ${s.lab_name}` : ''}
          {s.counter_seal_no && <div className="muted">{t('smp.counter_line', { seal: s.counter_seal_no, where: s.counter_stored_at ?? '—', until: s.keep_until ? date(s.keep_until) : '—' })}</div>}
          {s.buyer_seal_no && <div className="muted">{t('smp.buyer_line', { seal: s.buyer_seal_no, to: s.buyer_recipient ?? '' })}</div>}
          {s.status === 'disposed' ? <div className="muted">{t('smp.disposed_line', { note: s.disposal_note ?? '' })}</div>
            : <button type="button" className="secondary small" onClick={() => setDisp({ id: s.id, note: '' })} data-testid="sample-dispose">{t('smp.dispose')}</button>}
          {disp?.id === s.id && <div className="stack">
            <Field label={`${t('smp.dispose_note')} *`} htmlFor="smp-note"><input id="smp-note" value={disp.note} onChange={(e) => setDisp({ ...disp, note: e.target.value })} data-testid="sample-dispose-note" /></Field>
            <button onClick={dispose} disabled={act.busy || disp.note.trim().length < 10} data-testid="sample-dispose-save">{t('smp.dispose')}</button></div>}
        </li>))}</ul>
      {!open && <button className="secondary" onClick={() => setOpen(true)} data-testid="sample-draw">{t('smp.draw')}</button>}
      {open && (
        <div className="stack" data-testid="sample-form">
          <Field label={`${t('smp.drawn_on')} *`} htmlFor="smp-on"><input id="smp-on" type="date" max={todayIST()} value={v.drawn_on ?? ''} onChange={(e) => set('drawn_on', e.target.value)} /></Field>
          <Field label={`${t('smp.qty')} *`} htmlFor="smp-qty"><input id="smp-qty" inputMode="decimal" value={v.qty_kg ?? ''} onChange={(e) => set('qty_kg', e.target.value.replace(',', '.'))} data-testid="sample-qty" /></Field>
          <Field label={`${t('smp.lab')} *`} htmlFor="smp-lab"><select id="smp-lab" value={v.lab_id ?? ''} onChange={(e) => set('lab_id', e.target.value)} data-testid="sample-lab">
            <option value="">—</option>{(labs.data ?? []).map((l) => <option key={l.id} value={l.id}>{l.name}{l.kind === 'in_house' ? ` · ${t('opt.in_house')}` : l.accreditation_no ? ` · ${l.accreditation_no}` : ''}</option>)}</select></Field>
          <Field label={`${t('smp.counter_seal')} *`} htmlFor="smp-seal"><input id="smp-seal" value={v.counter_seal_no ?? ''} onChange={(e) => set('counter_seal_no', e.target.value)} data-testid="sample-seal" /></Field>
          <Field label={`${t('smp.counter_where')} *`} htmlFor="smp-where"><input id="smp-where" value={v.counter_stored_at ?? ''} onChange={(e) => set('counter_stored_at', e.target.value)} data-testid="sample-where" /></Field>
          <Field label={t('smp.keep_until')} hint={t('smp.keep_hint')} htmlFor="smp-keep"><input id="smp-keep" type="date" value={v.keep_until ?? ''} onChange={(e) => set('keep_until', e.target.value)} /></Field>
          <Field label={t('smp.buyer_seal')} htmlFor="smp-bseal"><input id="smp-bseal" value={v.buyer_seal_no ?? ''} onChange={(e) => set('buyer_seal_no', e.target.value)} /></Field>
          <Field label={t('smp.buyer_to')} htmlFor="smp-bto"><input id="smp-bto" value={v.buyer_recipient ?? ''} onChange={(e) => set('buyer_recipient', e.target.value)} /></Field>
          <ErrorBox error={act.error} />
          <div className="row"><button onClick={draw} disabled={act.busy || !v.qty_kg} data-testid="sample-save">{t('smp.save')}</button>
            <button className="secondary" onClick={() => setOpen(false)}>{t('common.cancel')}</button></div>
        </div>)}
    </div>);
}
