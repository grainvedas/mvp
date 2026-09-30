// F14 ledger explorer and journey export for one lot: every origin lot (all sources of a Village Batch included),
// who recorded and who verified each step, QC, flags, evidence fingerprints and ledger blocks.
// CSV for spreadsheets; "Print / save as PDF" uses the browser's own PDF printer (no extra library, works offline).
import { Link, useParams } from 'react-router-dom';
import { rpc } from '../../lib/api';
import { useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { downloadCsv } from '../../lib/csv';
import { dateTime, humanise, kg, shortHash } from '../../lib/format';
import { Badge, ErrorBox, Loading } from '../../shell/ui';

export interface TraceStep {
  id: string; code: string; stage: string; stage_label: string | null; status: string; prev_id: string | null;
  qty_in_kg: number; qty_out_kg: number; grade: string | null;
  payload: Record<string, unknown>; computed: Record<string, unknown>; warnings: string[];
  farmer: { code: string | null; name: string; village: string } | null;
  created_at: string; created_by: string | null; verified_at: string | null; verified_by: string | null;
  qc: { domestic: string; export: string; readings: Record<string, number>; override: Record<string, unknown> | null } | null;
  seal: { qr_code: string; sealed_at: string; ledger_hash: string; batch_codes: string[] } | null;
  flags: { text: string; status: string; at: string }[];
  evidence: { kind: string; sha256: string; at: string }[];
  ledger: { seq: number; event: string; hash: string; prev_hash: string; at: string }[];
}
export interface Trace { footprint_id: string; generated_at: string; steps: TraceStep[] }

export const TRACE_HEADER = ['step', 'code', 'stage', 'status', 'farmer_id', 'farmer', 'village', 'qty_in_kg', 'qty_out_kg', 'grade',
  'recorded_by', 'recorded_at', 'verified_by', 'verified_at', 'qc_domestic', 'qc_export', 'qc_readings', 'qc_override',
  'qr_code', 'batch_codes', 'flags', 'evidence_sha256', 'ledger_blocks', 'last_block_hash', 'warnings', 'entered_values'];

export function traceRows(tr: Trace) {
  return tr.steps.map((s, i) => [
    i + 1, s.code, s.stage_label ?? humanise(s.stage), s.status, s.farmer?.code, s.farmer?.name, s.farmer?.village,
    s.qty_in_kg, s.qty_out_kg, s.grade, s.created_by, s.created_at, s.verified_by, s.verified_at,
    s.qc?.domestic, s.qc?.export, s.qc ? JSON.stringify(s.qc.readings) : '', s.qc?.override ? JSON.stringify(s.qc.override) : '',
    s.seal?.qr_code, s.seal?.batch_codes.join(' '), s.flags.map((f) => `${f.status}: ${f.text}`).join(' | '),
    s.evidence.map((e) => `${e.kind}:${e.sha256}`).join(' '), s.ledger.map((l) => `${l.seq}:${l.event}`).join(' '),
    s.ledger.at(-1)?.hash, s.warnings.join(' | '), JSON.stringify(s.payload),
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
              <dt>{t('trace.recorded')}</dt><dd>{dateTime(s.created_at)} · {s.created_by ?? '—'}</dd>
              <dt>{t('trace.verified')}</dt><dd>{s.verified_at ? `${dateTime(s.verified_at)} · ${s.verified_by ?? '—'}` : '—'}</dd>
              {s.qc && <><dt>QC</dt><dd>domestic <Badge value={s.qc.domestic} /> · export <Badge value={s.qc.export} />
                {' '}<span className="small">{Object.entries(s.qc.readings ?? {}).map(([k, v]) => `${humanise(k)} ${v}`).join(' · ')}</span>
                {s.qc.override && <> · <Badge value="pending" label="override" /> “{String(s.qc.override.reason ?? '')}”</>}</dd></>}
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
      <p className="small muted">{t('trace.footer')}</p>
    </div>
  );
}
