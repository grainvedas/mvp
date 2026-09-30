// S17 record detail · S16 QC override · S18 flags · S20 entry to "correct a pending record"
import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import QRCode from 'qrcode';
import { rpc, q, sha256Hex } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync, useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { useAuth } from '../../auth/AuthProvider';
import { kg, dateTime, humanise, num, shortHash } from '../../lib/format';
import { isManager, type FootprintDetail } from '../../lib/types';
import { Badge, ErrorBox, Loading, Field } from '../../shell/ui';

export function RecordDetail() {
  const { id = '' } = useParams();
  const { t } = useI18n();
  const { ctx } = useAuth();
  const me = ctx!.user!;
  const d = useAsync(() => rpc<FootprintDetail>('footprint_detail', { p_fp: id }), [id]);
  if (d.loading) return <Loading />;
  if (d.error || !d.data) return <ErrorBox error={d.error} onRetry={d.reload} />;
  const r = d.data, f = r.footprint;
  const canCorrect = f.status === 'pending' && (f.created_by === me.id || isManager(me.role));
  return (
    <div>
      <p className="muted small"><Link to={`/work/${f.scope_id}/${f.stage_type}`}>{r.stage_label}</Link></p>
      <h1 className="mono">{t('record.title', { code: f.footprint_code })}</h1>
      <div className="card">
        <div className="row"><Badge value={f.status} />{f.lot_closed && <Badge value="closed" label="Lot closed" />}{f.grade && <Badge value="verified" label={`Grade ${f.grade}`} />}</div>
        <dl className="kv" style={{ marginTop: 12 }}>
          <dt>Stage</dt><dd>{r.stage_label}</dd>
          {r.farmer && <><dt>Farmer</dt><dd>{r.farmer.name} <span className="mono">{r.farmer.farmer_code}</span> · {r.farmer.village}</dd></>}
          {r.prev && <><dt>Came from</dt><dd><Link className="mono" to={`/records/${r.prev.id}`}>{r.prev.footprint_code}</Link> ({humanise(r.prev.stage_type)})</dd></>}
          <dt>Quantity in</dt><dd>{kg(f.qty_in)}</dd>
          <dt>Quantity out</dt><dd className="big">{kg(f.qty_out)}</dd>
          <dt>Still available</dt><dd>{kg(r.available_kg)}</dd>
          {Object.entries(f.computed ?? {}).map(([k, v]) => <Kv key={k} k={humanise(k)} v={typeof v === 'object' ? JSON.stringify(v) : num(v as number, 3)} />)}
          <dt>Recorded</dt><dd>{dateTime(f.created_at)} · {r.created_by_name ?? '—'}</dd>
          <dt>Verified</dt><dd>{f.verified_at ? `${dateTime(f.verified_at)} · ${r.verified_by_name ?? '—'}` : '—'}</dd>
          <dt>Market verdict</dt><dd>domestic <Badge value={r.market_verdict.domestic} /> · export <Badge value={r.market_verdict.export} />{r.market_verdict.overridden && <> <Badge value="pending" label="overridden" /></>}</dd>
        </dl>
        {f.warnings?.length > 0 && <div className="alert warn">{f.warnings.join(' · ')}</div>}
        <details><summary>Entered values</summary><pre className="small mono">{JSON.stringify(f.payload, null, 2)}</pre></details>
        <div className="row">
          {canCorrect && <Link className="btn secondary" to={`/work/${f.scope_id}/${f.stage_type}?edit=${f.id}`}>{t('record.edit_pending')}</Link>}
          {me.role !== 'operator' && <Link className="btn secondary" to={`/trace/${f.id}`} data-testid="trace-link">{t('record.trace')}</Link>}
        </div>
      </div>
      {r.qc && <QcPanel detail={r} onChange={d.reload} canOverride={isManager(me.role)} />}
      {r.seal && <SealPanel code={r.seal.qr_code} hash={r.seal.ledger_hash} batch={r.seal.batch_codes} />}
      {r.attachments.length > 0 && <Attachments detail={r} />}
      <Flags detail={r} onChange={d.reload} canResolve={isManager(me.role)} canRaise={me.role !== 'client_view'} />
      <div className="card">
        <h2>{t('record.ledger')}</h2>
        <div className="table-wrap"><table>
          <thead><tr><th>#</th><th>Event</th><th>By</th><th>When</th><th>Hash</th></tr></thead>
          <tbody>{r.ledger.map((l) => (
            <tr key={l.seq}><td className="num">{l.seq}</td><td>{humanise(l.event)}</td><td>{l.actor_name ?? '—'}</td><td>{dateTime(l.created_at)}</td>
              <td className="mono small" title={l.hash}>{shortHash(l.hash)}</td></tr>
          ))}</tbody>
        </table></div>
      </div>
    </div>
  );
}

function Kv({ k, v }: { k: string; v: string }) { return <><dt>{k}</dt><dd>{v}</dd></>; }

function QcPanel({ detail, onChange, canOverride }: { detail: FootprintDetail; onChange: () => void; canOverride: boolean }) {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const qc = detail.qc!;
  const [reason, setReason] = useState('');
  const act = useAction();
  const override = () => act.run(async () => {
    await q(supabase.from('qc_verdicts').update({ override: { market: 'export', reason, authoriser: ctx!.user!.id } })
      .eq('footprint_id', detail.footprint.id).select());
    onChange();
  });
  return (
    <div className="card">
      <h2>Quality control</h2>
      <p>Domestic <Badge value={qc.domestic_verdict} /> · Export <Badge value={qc.export_verdict} /> <span className="muted small">(derived from the readings; nobody sets them by hand)</span></p>
      <div className="table-wrap"><table>
        <thead><tr><th>Parameter</th><th>Reading</th><th>Domestic</th><th>Export</th></tr></thead>
        <tbody>{qc.judged.map((j) => <tr key={j.param}><td>{humanise(j.param)}</td><td className="num">{num(j.value)}</td>
          <td><Badge value={j.domestic} /></td><td><Badge value={j.export} /></td></tr>)}</tbody>
      </table></div>
      {qc.override && <div className="alert warn">Override: {String(qc.override.market)} · “{String(qc.override.reason)}” · {dateTime(String(qc.override.at))}</div>}
      {canOverride && !qc.override && qc.export_verdict === 'fail' && (
        <div className="stack">
          <h3>{t('record.override')}</h3>
          <Field label={t('record.override_reason')} htmlFor="ov-reason"><textarea id="ov-reason" value={reason} onChange={(e) => setReason(e.target.value)} rows={2} /></Field>
          <ErrorBox error={act.error} />
          <button className="danger" disabled={!reason.trim() || act.busy} onClick={override}>{t('record.override')}</button>
        </div>
      )}
    </div>
  );
}

function SealPanel({ code, hash, batch }: { code: string; hash: string; batch: string[] }) {
  const [img, setImg] = useState('');
  useEffect(() => { void QRCode.toDataURL(`${window.location.origin}/verify/${code}`, { margin: 1, width: 360 }).then(setImg); }, [code]);
  return (
    <div className="card">
      <h2>Sealed</h2>
      <div className="qr">{img && <img src={img} alt={`QR code ${code}`} />}<div>
        <p className="big mono">{code}</p>
        <p className="small">Ledger hash <span className="mono">{shortHash(hash)}</span></p>
        {batch.length > 0 && <p className="small">Batch codes: {batch.join(', ')}</p>}
        <div className="row"><Link className="btn" to={`/labels/${code}`}>Print labels</Link>
        <Link className="btn secondary" to={`/verify/${code}`}>Public verify page</Link></div>
      </div></div>
    </div>
  );
}

function Attachments({ detail }: { detail: FootprintDetail }) {
  const { t } = useI18n();
  const [urls, setUrls] = useState<Record<string, string>>({});
  const [check, setCheck] = useState<Record<string, 'ok' | 'bad' | 'missing'>>({});
  useEffect(() => {
    let live = true;
    // Hash check on retrieval (PRD §9 Evidence): re-hash the stored file and compare with the SHA-256 in the record.
    detail.attachments.forEach(async (a) => {
      const { data } = await supabase.storage.from('evidence').createSignedUrl(a.storage_path, 600);
      if (!live) return;
      if (!data?.signedUrl) { setCheck((c) => ({ ...c, [a.id]: 'missing' })); return; }
      setUrls((u) => ({ ...u, [a.id]: data.signedUrl }));
      try {
        const blob = await (await fetch(data.signedUrl)).blob();
        const h = await sha256Hex(blob);
        if (live) setCheck((c) => ({ ...c, [a.id]: h === a.sha256 ? 'ok' : 'bad' }));
      } catch { if (live) setCheck((c) => ({ ...c, [a.id]: 'missing' })); }
    });
    return () => { live = false; };
  }, [detail.attachments]);
  return (
    <div className="card">
      <h2>{t('record.evidence')}</h2>
      <ul>{detail.attachments.map((a) => (
        <li key={a.id}>{urls[a.id] ? <a href={urls[a.id]} target="_blank" rel="noreferrer">{humanise(a.kind)}</a> : humanise(a.kind)}
          {' '}<span className="mono small" title={a.sha256}>sha256 {shortHash(a.sha256)}</span> · {dateTime(a.created_at)}
          {' '}{check[a.id] === 'ok' && <Badge value="verified" label={t('record.hash_ok')} />}
          {check[a.id] === 'bad' && <Badge value="fail" label={t('record.hash_bad')} />}
          {check[a.id] === 'missing' && <Badge value="pending" label={t('record.hash_missing')} />}</li>
      ))}</ul>
    </div>
  );
}

function Flags({ detail, onChange, canResolve, canRaise }: { detail: FootprintDetail; onChange: () => void; canResolve: boolean; canRaise: boolean }) {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const [text, setText] = useState('');
  const act = useAction();
  const raise = () => act.run(async () => {
    await q(supabase.from('flags').insert({ footprint_id: detail.footprint.id, raised_by: ctx!.user!.id, text: text.trim() }).select());
    setText(''); onChange();
  });
  const setStatus = (id: string, status: string) => act.run(async () => { await q(supabase.from('flags').update({ status }).eq('id', id).select()); onChange(); });
  return (
    <div className="card">
      <h2>{t('record.flags')}</h2>
      {detail.flags.length === 0 && <p className="muted">No flags.</p>}
      <ul>{detail.flags.map((f) => (
        <li key={f.id} className="row"><Badge value={f.status} /> {f.text} <span className="muted small">— {f.raised_by_name ?? '—'}, {dateTime(f.created_at)}</span>
          {canResolve && f.status === 'open' && <><button className="secondary" onClick={() => setStatus(f.id, 'resolved')}>{t('record.resolve')}</button>
            <button className="secondary" onClick={() => setStatus(f.id, 'dismissed')}>{t('record.dismiss')}</button></>}</li>
      ))}</ul>
      {canRaise && (
        <div className="row">
          <input aria-label={t('record.raise_flag')} placeholder={t('record.raise_flag')} value={text} onChange={(e) => setText(e.target.value)} style={{ flex: 1 }} />
          <button className="secondary" disabled={!text.trim() || act.busy} onClick={raise}>{t('record.raise_flag')}</button>
        </div>
      )}
      <ErrorBox error={act.error} />
    </div>
  );
}
