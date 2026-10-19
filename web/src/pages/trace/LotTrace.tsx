// F14 ledger explorer and journey export for one lot: every origin lot (all sources of a Village Batch included),
// who recorded and who verified each step, QC, flags, evidence fingerprints and ledger blocks.
// The CSV is made on the server since migration 60 (Part C): a shareable copy for anyone who sees the lot, an internal
// copy (names, prices, the raw values) for the scope's people and the client's own login; every download is in the Audit
// log. "Print / save as PDF" prints the shareable content only: a heading, page numbers, no person's name.
// Migration 59 (Veda's brief of 19 Oct 2026): units on every reading (A3), the lab with its accreditation number (A5),
// a step recorded and checked by one person marked (A2), "Practice (old data)" (A8).
import { capturedAt } from '../../engine/values';
import { ForwardPanel } from './Forward';
import { Link, useParams } from 'react-router-dom';
import { rpc } from '../../lib/api';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { exportJourney, journeyCsv, mayInternalCopy, type Copy } from '../../lib/exports';
import { supabase } from '../../lib/supabase';
import { q } from '../../lib/api';
import { dateTime, humanise, kg, shortHash } from '../../lib/format';
import { Badge, ErrorBox, Loading } from '../../shell/ui';

export interface TraceStep {
  id: string; code: string; stage: string; stage_label: string | null; status: string; prev_id: string | null;
  qty_in_kg: number; qty_out_kg: number; grade: string | null;
  payload: Record<string, unknown>; computed: Record<string, unknown>; warnings: string[];
  farmer: { code: string | null; name: string; village: string } | null;
  created_at: string; captured_at?: string | null; created_by: string | null; verified_at: string | null; verified_by: string | null;
  qc: { domestic: string; export: string; readings: Record<string, number>; override: Record<string, unknown> | null } | null;
  seal: { qr_code: string; sealed_at: string; ledger_hash: string; batch_codes: string[] } | null;
  withdrawn?: { reason: string; by: string | null; at: string } | null;                                  // migration 23
  replaces?: { code: string; qty_out_kg: number; reason: string | null; by: string | null; at: string | null } | null;
  flags: { text: string; status: string; at: string }[];
  evidence: { kind: string; sha256: string; at: string }[];
  ledger: { seq: number; event: string; hash: string; prev_hash: string; at: string }[];
  /** migration 59: the lab (A5) and "recorded and checked by one person" (A2) */
  lab?: { name?: string; accreditation_no?: string; report_no?: string; report_date?: string } | null;
  same_person?: boolean;
}
export interface Trace { footprint_id: string; generated_at: string; steps: TraceStep[];
  /** migration 59: each reading's unit (A3); "practice_old_data" for a scope with records of before system batch codes (A8) */
  units?: Record<string, string>; data_note?: string | null }

/** Pure (migration 59, A3): the readings with their units, "moisture 11.8 % · aflatoxin 1.5 ppb". */
export function readingsLine(readings: Record<string, unknown> | null | undefined, units: Record<string, string> | undefined,
                             label: (k: string) => string = (k) => humanise(k.replace(/_(pct|ppb|ppm|kg|mm)$/, ''))): string {
  return Object.entries(readings ?? {}).map(([k, v]) => {
    const u = units?.[k] ?? (k.endsWith('_pct') ? '%' : k.endsWith('_ppb') ? 'ppb' : k.endsWith('_ppm') ? 'ppm' : '');
    return `${label(k)} ${String(v)}${u ? ` ${u}` : ''}`;
  }).join(' · ');
}
/** Pure (migration 59, A5): the lab line, "Gorakhpur Grain Lab (accreditation TC-5521) · report GGL/118 of 15 Oct 2026". */
export const labLine = (l: TraceStep['lab']) => !l?.name ? '' :
  [l.name + (l.accreditation_no ? ` (accreditation ${l.accreditation_no})` : ''), l.report_no ? `report ${l.report_no}${l.report_date ? ` of ${l.report_date}` : ''}` : ''].filter(Boolean).join(' · ');

export function LotTrace() {
  const { id = '' } = useParams();
  const { t } = useI18n();
  const d = useAsync(() => rpc<Trace>('lot_trace', { p_fp: id }), [id]);
  // migration 60 (C4): the internal copy only for the scope's people and the client's own login
  const internal = useAsync(async () => {
    const rows = (await q(supabase.from('footprints').select('scope_id').eq('id', id))) as unknown as { scope_id: string }[];
    return rows[0] ? mayInternalCopy(rows[0].scope_id) : false;
  }, [id]);
  const exp = useAction();
  const download = (copy: Copy) => exp.run(async () => journeyCsv(await exportJourney(id, copy), t));
  if (d.loading) return <Loading />;
  if (d.error || !d.data) return <ErrorBox error={d.error} onRetry={d.reload} />;
  const tr = d.data;
  const last = tr.steps.find((s) => s.id === tr.footprint_id) ?? tr.steps.at(-1);
  return (
    <div className="trace">
      <p className="muted small no-print"><Link to={`/records/${tr.footprint_id}`}>{t('trace.back')}</Link></p>
      <div className="print-only trace-print-head" data-testid="trace-print-head">
        <strong>GrainVeda · {t('trace.title', { code: last?.seal?.qr_code ?? last?.code ?? '' })}</strong>
        <span>{t('exp.print_head', { at: dateTime(tr.generated_at) })}</span>
      </div>
      <h1>{t('trace.title', { code: last?.seal?.qr_code ?? last?.code ?? '' })}</h1>
      <p className="muted small">{t('trace.generated', { at: dateTime(tr.generated_at), n: tr.steps.length })}</p>
      {tr.data_note === 'practice_old_data' && <div className="alert warn" data-testid="old-data">{t('scope.old_data')}</div>}
      <div className="row no-print">
        <button onClick={() => download('shareable')} disabled={exp.busy} data-testid="trace-csv">{t('exp.csv_shareable')}</button>
        {internal.data === true && <button className="secondary" onClick={() => download('internal')} disabled={exp.busy} data-testid="trace-csv-internal">{t('exp.csv_internal')}</button>}
        <button className="secondary" onClick={() => window.print()}>{t('trace.pdf')}</button>
      </div>
      {internal.data === true && <p className="small muted no-print" data-testid="trace-copies">{t('exp.copies_note')}</p>}
      <ErrorBox error={exp.error} />
      <ol className="trace-steps" data-testid="trace-steps">
        {tr.steps.map((s) => (
          <li key={s.id} className="card">
            <div className="row"><strong>{s.stage_label ?? humanise(s.stage)}</strong><span className="mono">{s.code}</span><Badge value={s.status} />
              {s.grade && <Badge value="verified" label={`Grade ${s.grade}`} />}</div>
            <dl className="kv">
              {s.farmer && <><dt>{t('trace.farmer')}</dt><dd><span className="no-print">{s.farmer.name} · </span>{s.farmer.village} <span className="mono small">{s.farmer.code}</span></dd></>}
              <dt>{t('trace.qty')}</dt><dd>{kg(s.qty_in_kg)} → {kg(s.qty_out_kg)}</dd>
              <dt>{t('trace.recorded')}</dt><dd>{dateTime(capturedAt(s).at)}<span className="no-print"> · {s.created_by ?? '—'}</span>
                {capturedAt(s).sentLater && <span className="muted small"> · {t('record.sent_later', { at: dateTime(s.created_at) })}</span>}</dd>
              <dt>{t('trace.verified')}</dt><dd>{s.verified_at ? <>{dateTime(s.verified_at)}<span className="no-print"> · {s.verified_by ?? '—'}</span></> : '—'}
                {s.same_person && <span className="muted small" data-testid="trace-same-person"> · {t('ledger.same_person')}</span>}</dd>
              {s.lab?.name && <><dt>{t('trace.lab')}</dt><dd data-testid="trace-lab">{s.lab.name}{s.lab.accreditation_no ? ` · ${t('lab.accreditation', { no: s.lab.accreditation_no })}` : ''}
                {s.lab.report_no ? ` · ${t('bv.report', { no: s.lab.report_no })}` : ''}</dd></>}
              {s.qc && <><dt>{t('stage.qc')}</dt><dd>{t('record.domestic')} <Badge value={s.qc.domestic} /> · {t('record.export')} <Badge value={s.qc.export} />
                {' '}<span className="small" data-testid="trace-readings">{readingsLine(s.qc.readings, tr.units, (k) => t(`qp.${k}`, undefined, humanise(k.replace(/_(pct|ppb|ppm|kg|mm)$/, ''))))}</span>
                {s.qc.override && <> · <Badge value="pending" label="override" /> “{String(s.qc.override.reason ?? '')}”</>}</dd></>}
              {s.withdrawn && <><dt>{t('record.withdrawn')}</dt><dd>{dateTime(s.withdrawn.at)}<span className="no-print"> · {s.withdrawn.by ?? '—'}</span> · “{s.withdrawn.reason}”</dd></>}
              {s.replaces && <><dt>{t('record.replaces')}</dt><dd><span className="mono">{s.replaces.code}</span> ({kg(s.replaces.qty_out_kg)})<span className="no-print"> · {s.replaces.by ?? '—'}</span> · “{s.replaces.reason ?? ''}”</dd></>}
              {s.seal && <><dt>{t('trace.seal')}</dt><dd className="mono">{s.seal.qr_code} {s.seal.batch_codes.length > 0 && `· ${s.seal.batch_codes.join(', ')}`}</dd></>}
              {s.flags.length > 0 && <><dt>{t('record.flags')}</dt><dd>{s.flags.map((f, i) => <div key={i}><Badge value={f.status} /> {f.text}</div>)}</dd></>}
              {s.evidence.length > 0 && <><dt>{t('trace.evidence')}</dt><dd>{s.evidence.map((e, i) => <div key={i} className="small">{humanise(e.kind)} <span className="mono" title={e.sha256}>sha256 {shortHash(e.sha256)}</span></div>)}</dd></>}
              {s.warnings.length > 0 && <><dt>{t('engine.warnings')}</dt><dd>{s.warnings.join(' · ')}</dd></>}
              <dt>{t('record.ledger')}</dt><dd className="small">{s.ledger.map((l) => (
                <div key={l.seq}><span className="num">#{l.seq}</span> {humanise(l.event)} · {dateTime(l.at)} · <span className="mono" title={l.hash}>{shortHash(l.hash)}</span></div>))}</dd>
            </dl>
          </li>
        ))}
      </ol>
      <div className="no-print"><ForwardPanel fp={tr.footprint_id} /></div>
      <p className="small muted">{t('trace.footer')}</p>
    </div>
  );
}
