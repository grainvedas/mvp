// F14 ledger explorer and journey export for one lot: every origin lot (all sources of a Village Batch included),
// who recorded and who verified each step, QC, flags, evidence fingerprints and ledger blocks.
// CSV for spreadsheets; "Print / save as PDF" uses the browser's own PDF printer (no extra library, works offline).
// Migration 59 (Veda's brief of 19 Oct 2026): units on every reading (A3), the lab with its accreditation number (A5),
// a step recorded and checked by one person marked (A2), "Practice (old data)" (A8).
import { capturedAt } from '../../engine/values';
import { ForwardPanel } from './Forward';
import { Link, useParams } from 'react-router-dom';
import { rpc } from '../../lib/api';
import { useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { downloadCsv } from '../../lib/csv';
import { dateTime, humanise, istStamp, kg, shortHash } from '../../lib/format';
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

export const TRACE_HEADER = ['step', 'code', 'stage', 'status', 'farmer_id', 'farmer', 'village', 'qty_in_kg', 'qty_out_kg', 'grade',
  'recorded_by', 'recorded_at', 'verified_by', 'verified_at', 'qc_domestic', 'qc_export', 'qc_readings', 'qc_override',
  'qr_code', 'batch_codes', 'flags', 'evidence_sha256', 'ledger_blocks', 'last_block_hash', 'warnings', 'entered_values',
  'withdrawn', 'replaces', 'received_by_server_at', 'lab', 'same_person', 'data_note'];   // the last three: migration 59

export function traceRows(tr: Trace) {
  return tr.steps.map((s, i) => [
    i + 1, s.code, s.stage_label ?? humanise(s.stage), s.status, s.farmer?.code, s.farmer?.name, s.farmer?.village,
    s.qty_in_kg, s.qty_out_kg, s.grade, s.created_by, istStamp(s.captured_at ?? s.created_at), s.verified_by, istStamp(s.verified_at),
    s.qc?.domestic, s.qc?.export, s.qc ? readingsLine(s.qc.readings, tr.units) : '', s.qc?.override ? JSON.stringify(s.qc.override) : '',
    s.seal?.qr_code, s.seal?.batch_codes.join(' '), s.flags.map((f) => `${f.status}: ${f.text}`).join(' | '),
    s.evidence.map((e) => `${e.kind}:${e.sha256}`).join(' '), s.ledger.map((l) => `${l.seq}:${l.event}`).join(' '),
    s.ledger.at(-1)?.hash, s.warnings.join(' | '), JSON.stringify(s.payload),
    s.withdrawn ? `${istStamp(s.withdrawn.at)} · ${s.withdrawn.by ?? ''}: ${s.withdrawn.reason}` : '',
    s.replaces ? `${s.replaces.code} (${s.replaces.qty_out_kg} kg) withdrawn by ${s.replaces.by ?? ''}: ${s.replaces.reason ?? ''}` : '',
    istStamp(s.created_at),          // recorded_at is the time on the phone; this is when the server received it (times in IST: Veda, 15 Oct)
    labLine(s.lab), s.same_person ? 'recorded and checked by the same person' : '', tr.data_note === 'practice_old_data' ? 'Practice (old data)' : '',
  ]);
}

export function LotTrace() {
  const { id = '' } = useParams();
  const { t } = useI18n();
  const d = useAsync(() => rpc<Trace>('lot_trace', { p_fp: id }), [id]);
  if (d.loading) return <Loading />;
  if (d.error || !d.data) return <ErrorBox error={d.error} onRetry={d.reload} />;
  const tr = d.data;
  const last = tr.steps.find((s) => s.id === tr.footprint_id) ?? tr.steps.at(-1);
  const name = `grainveda-journey-${last?.seal?.qr_code ?? last?.code ?? 'lot'}`;
  return (
    <div className="trace">
      <p className="muted small no-print"><Link to={`/records/${tr.footprint_id}`}>{t('trace.back')}</Link></p>
      <h1>{t('trace.title', { code: last?.seal?.qr_code ?? last?.code ?? '' })}</h1>
      <p className="muted small">{t('trace.generated', { at: dateTime(tr.generated_at), n: tr.steps.length })}</p>
      {tr.data_note === 'practice_old_data' && <div className="alert warn" data-testid="old-data">{t('scope.old_data')}</div>}
      <div className="row no-print">
        <button onClick={() => downloadCsv(`${name}.csv`, TRACE_HEADER, traceRows(tr))} data-testid="trace-csv">{t('trace.csv')}</button>
        <button className="secondary" onClick={() => window.print()}>{t('trace.pdf')}</button>
      </div>
      <ol className="trace-steps" data-testid="trace-steps">
        {tr.steps.map((s) => (
          <li key={s.id} className="card">
            <div className="row"><strong>{s.stage_label ?? humanise(s.stage)}</strong><span className="mono">{s.code}</span><Badge value={s.status} />
              {s.grade && <Badge value="verified" label={`Grade ${s.grade}`} />}</div>
            <dl className="kv">
              {s.farmer && <><dt>{t('trace.farmer')}</dt><dd>{s.farmer.name} · {s.farmer.village} <span className="mono small">{s.farmer.code}</span></dd></>}
              <dt>{t('trace.qty')}</dt><dd>{kg(s.qty_in_kg)} → {kg(s.qty_out_kg)}</dd>
              <dt>{t('trace.recorded')}</dt><dd>{dateTime(capturedAt(s).at)} · {s.created_by ?? '—'}
                {capturedAt(s).sentLater && <span className="muted small"> · {t('record.sent_later', { at: dateTime(s.created_at) })}</span>}</dd>
              <dt>{t('trace.verified')}</dt><dd>{s.verified_at ? `${dateTime(s.verified_at)} · ${s.verified_by ?? '—'}` : '—'}
                {s.same_person && <span className="muted small" data-testid="trace-same-person"> · {t('ledger.same_person')}</span>}</dd>
              {s.lab?.name && <><dt>{t('trace.lab')}</dt><dd data-testid="trace-lab">{s.lab.name}{s.lab.accreditation_no ? ` · ${t('lab.accreditation', { no: s.lab.accreditation_no })}` : ''}
                {s.lab.report_no ? ` · ${t('bv.report', { no: s.lab.report_no })}` : ''}</dd></>}
              {s.qc && <><dt>{t('stage.qc')}</dt><dd>{t('record.domestic')} <Badge value={s.qc.domestic} /> · {t('record.export')} <Badge value={s.qc.export} />
                {' '}<span className="small" data-testid="trace-readings">{readingsLine(s.qc.readings, tr.units, (k) => t(`qp.${k}`, undefined, humanise(k.replace(/_(pct|ppb|ppm|kg|mm)$/, ''))))}</span>
                {s.qc.override && <> · <Badge value="pending" label="override" /> “{String(s.qc.override.reason ?? '')}”</>}</dd></>}
              {s.withdrawn && <><dt>{t('record.withdrawn')}</dt><dd>{dateTime(s.withdrawn.at)} · {s.withdrawn.by ?? '—'} · “{s.withdrawn.reason}”</dd></>}
              {s.replaces && <><dt>{t('record.replaces')}</dt><dd><span className="mono">{s.replaces.code}</span> ({kg(s.replaces.qty_out_kg)}) · {s.replaces.by ?? '—'} · “{s.replaces.reason ?? ''}”</dd></>}
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
      <ForwardPanel fp={tr.footprint_id} />
      <p className="small muted">{t('trace.footer')}</p>
    </div>
  );
}
