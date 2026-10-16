// The buyer's page (migration 56, Part F; Veda 16 Oct 2026, "proceed with 56"). A Client Manager shares a sale or a
// shipment with its buyer through a link: `/b#<token>` (after the #, so no web server ever receives the token). The page
// shows the order (its number, the packs, the kilograms; never a price), the shipments' papers, the lab results per
// market with the readings, the export documents and their state, the chain, the villages' shares (no farmer's name),
// the release, and the files the buyer may open (each through the buyer-file function, which signs a two-minute
// download). The evidence pack is a JSON file of the page with the files' SHA-256. Every open, evidence pack and file
// is logged for the Client Manager. A link expires and can be revoked; the page then says only that. Kept apart from the
// way in: a buyer's own sign-in can later open the same page (app.buyer_content).
// Its own chunk (like the invite page): it brings the full dictionaries with it; the public verify page stays small.
import { useEffect, useRef, useState } from 'react';
import { registerDictionary, useI18n } from '../../lib/i18n';
import { en } from '../../lib/i18n.en';
import { hi } from '../../lib/i18n.hi';
import { rpc } from '../../lib/api';
import { SUPABASE_ANON_KEY, SUPABASE_URL } from '../../lib/supabase';
import { date, humanise } from '../../lib/format';
import { Badge, Loading } from '../../shell/ui';
import { PublicFrame } from './PublicVerify';
import { seasonName } from './journey';

registerDictionary('en', en);
registerDictionary('hi', hi);

/** Pure: the token from the address (`#<token>`), or null. */
export function buyerToken(hash: string): string | null {
  const v = hash.replace(/^#/, '').replace(/^t=/, '');
  return /^[0-9a-f]{48}$/.test(v) ? v : null;
}

export interface BuyerContent {
  kind: 'commercial' | 'shipment'; code: string; generated_at: string; seller: string;
  crop: { name: string; gi_tag: string | null; origin: string | null }; season: string; gi_status: 'gi' | 'non_gi' | 'unknown';
  order: { code: string; order_no: string | null; buyer: string | null; buyer_country: string | null; market: string | null; market_name: string | null;
    destination_country: string | null; packs: { name: string; units: number; size_kg: number }[] | null; kg: number; on: string | null };
  shipments: { code: string; on: string | null; destination: string | null; invoice_no: string | null; market: string | null; vehicle_no: string | null;
    transporter: string | null; lr_no: string | null; container_no: string | null; seal_no: string | null; shipping_bill_no: string | null; vessel: string | null;
    port_loading: string | null; port_discharge: string | null; bl_no: string | null; kg: number; pack_codes: number | null;
    delivery: { on: string; received_kg: number; note: string | null } | null }[];
  lab: { code: string; on: string | null; lab: string | null; report_no: string | null; report_date: string | null; readings: Record<string, number> | null;
    domestic: string; export: string; released_on_acceptance: boolean; markets: { name: string; verdict: string; failed: string[] }[] }[];
  documents: { doc: string; status: string; note: string | null }[];
  chain: { stage: string; code: string; on: string | null; verified: boolean }[];
  origin: { villages: { village: string; district: string; share_pct: number }[]; farmers: number; shares_note: string };
  release: { status: string; reason?: string | null } | null; qr_code: string | null;
  files: { id: string; label: string; record: string; sha256: string; at: string }[];
}
type View = { state: 'loading' } | { state: 'gone' } | { state: 'error' } | { state: 'ok'; expires_at: string; content: BuyerContent };

/** Pure: a reading with its unit, from its key (moisture_pct 12.5 → "12.5 %", aflatoxin_ppb 1.5 → "1.5 ppb"). */
export function readingText(key: string, v: number): string {
  const unit = key.endsWith('_pct') ? ' %' : key.endsWith('_ppb') ? ' ppb' : key.endsWith('_ppm') ? ' ppm' : '';
  return `${v}${unit}`;
}

/** Pure: the evidence pack: the page as data, with each file's SHA-256 so a downloaded file can be checked. */
export function evidencePack(c: BuyerContent, expires: string): string {
  return JSON.stringify({ evidence_pack: 'GrainVeda', made: new Date().toISOString(), link_expires: expires, ...c,
    files: c.files.map((f) => ({ label: f.label, record: f.record, sha256: f.sha256, added: f.at })) }, null, 2);
}

async function fileUrl(token: string, file: string): Promise<{ url?: string; problem?: string }> {
  const r = await fetch(`${SUPABASE_URL}/functions/v1/buyer-file`, { method: 'POST', cache: 'no-store',
    headers: { apikey: SUPABASE_ANON_KEY, authorization: `Bearer ${SUPABASE_ANON_KEY}`, 'content-type': 'application/json' },
    body: JSON.stringify({ token, file }) });
  return (await r.json().catch(() => ({ problem: 'link' }))) as { url?: string; problem?: string };
}

export default function BuyerView() {
  const { t } = useI18n();
  const [token] = useState(() => buyerToken(window.location.hash));
  const [v, setV] = useState<View>({ state: token ? 'loading' : 'gone' });
  const [fileMsg, setFileMsg] = useState<Record<string, string>>({});
  const asked = useRef(false);   // each open is logged once (React's development mode runs an effect twice)
  useEffect(() => {
    if (!token || asked.current) return;
    asked.current = true;
    rpc<{ ok: boolean; expires_at?: string; content?: BuyerContent }>('buyer_view', { p_token: token })
      .then((r) => setV(r.ok && r.content && r.expires_at ? { state: 'ok', expires_at: r.expires_at, content: r.content } : { state: 'gone' }))
      .catch(() => setV({ state: 'error' }));
  }, [token]);
  if (v.state === 'loading') return <PublicFrame><Loading /></PublicFrame>;
  if (v.state !== 'ok') return (
    <PublicFrame><div className="card" data-testid="bv-gone"><h1>{t(v.state === 'error' ? 'bv.error_title' : 'bv.gone_title')}</h1>
      <p>{t(v.state === 'error' ? 'bv.error' : 'bv.gone')}</p></div></PublicFrame>);
  const c = v.content;
  const openFile = async (id: string) => {
    setFileMsg((m) => ({ ...m, [id]: t('common.loading') }));
    const r = await fileUrl(token!, id).catch(() => ({ problem: 'link' } as { url?: string; problem?: string }));
    if (r.url) { window.open(r.url, '_blank'); setFileMsg((m) => ({ ...m, [id]: '' })); }
    else setFileMsg((m) => ({ ...m, [id]: t(r.problem === 'file' ? 'bv.file_gone' : 'bv.gone') }));
  };
  const download = () => {
    const blob = new Blob([evidencePack(c, v.expires_at)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob); a.download = `evidence-${c.code}.json`;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    void rpc('buyer_log', { p_token: token, p_what: 'evidence' }).catch(() => undefined);
  };
  const o = c.order;
  return (
    <PublicFrame>
      <div className="stack" data-testid="buyer-view">
        <section className="card">
          <p className="small muted">{t('bv.for_buyer', { seller: c.seller })}</p>
          <h1>{c.crop.name}</h1>
          {c.crop.gi_tag && c.gi_status === 'gi' && <p><span className="badge gi">{c.crop.gi_tag}</span> {c.crop.origin}</p>}
          <p className="muted">{seasonName(c.season)} · <span className="mono">{c.code}</span></p>
          <p className="small muted" data-testid="bv-expires">{t('bv.expires', { date: date(v.expires_at) })}</p>
          {c.release && c.release.status !== 'active' && <div className="alert error" role="alert" data-testid="bv-release">{t(`bv.release_${c.release.status}`)}{c.release.reason ? ` (“${c.release.reason}”)` : ''}</div>}
        </section>
        <section className="card" data-testid="bv-order">
          <h2>{t('bv.order')}</h2>
          <dl className="kv">
            {o.order_no && <><dt>{t('bv.order_no')}</dt><dd className="mono">{o.order_no}</dd></>}
            {o.buyer && <><dt>{t('bv.buyer')}</dt><dd>{o.buyer}{o.buyer_country ? ` · ${o.buyer_country}` : ''}</dd></>}
            <dt>{t('bv.market')}</dt><dd>{o.market === 'export' ? `${t('bv.export')}${o.market_name ? ` · ${o.market_name}` : ''}` : t('bv.domestic')}</dd>
            {o.destination_country && <><dt>{t('bv.destination')}</dt><dd>{o.destination_country}</dd></>}
            <dt>{t('bv.quantity')}</dt><dd className="big">{Number(o.kg).toLocaleString('en-IN')} kg</dd>
            {o.packs?.length ? <><dt>{t('bv.packs')}</dt><dd>{o.packs.map((p) => `${p.units} × ${p.name}`).join(', ')}</dd></> : null}
            {o.on && <><dt>{t('bv.on')}</dt><dd>{date(o.on)}</dd></>}
          </dl>
        </section>
        {c.shipments.map((s) => (
          <section className="card" key={s.code} data-testid="bv-shipment">
            <h2>{t('bv.shipment')} <span className="mono small">{s.code}</span></h2>
            <dl className="kv">
              {s.on && <><dt>{t('bv.dispatched')}</dt><dd>{date(s.on)}</dd></>}
              {s.destination && <><dt>{t('bv.to')}</dt><dd>{s.destination}</dd></>}
              <dt>{t('bv.quantity')}</dt><dd>{Number(s.kg).toLocaleString('en-IN')} kg{s.pack_codes ? ` · ${t('bv.pack_codes', { n: s.pack_codes })}` : ''}</dd>
              {([['invoice_no', s.invoice_no], ['container_no', s.container_no], ['seal_no', s.seal_no], ['shipping_bill_no', s.shipping_bill_no],
                 ['vessel', s.vessel], ['port_loading', s.port_loading], ['port_discharge', s.port_discharge], ['bl_no', s.bl_no],
                 ['vehicle_no', s.vehicle_no], ['transporter', s.transporter], ['lr_no', s.lr_no]] as const).filter(([, x]) => x).map(([k, x]) => (
                <span key={k} style={{ display: 'contents' }}><dt>{t(`bv.${k}`)}</dt><dd className="mono">{x}</dd></span>))}
              {s.delivery && <><dt>{t('bv.delivered')}</dt><dd>{date(s.delivery.on)} · {Number(s.delivery.received_kg).toLocaleString('en-IN')} kg</dd></>}
            </dl>
          </section>))}
        {c.lab.length > 0 && (
          <section className="card" data-testid="bv-lab">
            <h2>{t('bv.lab')}</h2>
            {c.lab.map((l) => (
              <div key={l.code} className="stack">
                <p className="small muted">{[l.lab, l.report_no ? t('bv.report', { no: l.report_no }) : null, date(l.report_date ?? l.on ?? '')].filter(Boolean).join(' · ')}</p>
                <ul data-testid="bv-markets">{l.markets.map((m) => <li key={m.name}>{m.name}: <Badge value={m.verdict} />{m.failed.length ? ` (${m.failed.join(', ')})` : ''}</li>)}</ul>
                {l.released_on_acceptance && <p className="small">{t('bv.on_acceptance')}</p>}
                {l.readings && <div className="table-wrap"><table><tbody>{Object.entries(l.readings).map(([k, x]) => (
                  <tr key={k}><td>{t(`qp.${k}`, undefined, humanise(k.replace(/_(pct|ppb|ppm)$/, '')))}</td><td className="mono">{readingText(k, x)}</td></tr>))}</tbody></table></div>}
              </div>))}
          </section>)}
        {c.documents.length > 0 && (
          <section className="card" data-testid="bv-docs">
            <h2>{t('bv.documents')}</h2>
            <ul>{c.documents.map((d) => <li key={d.doc}>{d.doc}: <Badge value={d.status === 'received' ? 'verified' : d.status === 'not_required' ? 'closed' : 'pending'} label={t(`bv.doc_${d.status}`, undefined, d.status)} />{d.note ? ` (“${d.note}”)` : ''}</li>)}</ul>
          </section>)}
        <section className="card" data-testid="bv-origin">
          <h2>{t('bv.origin')}</h2>
          <p>{t('bv.farmers', { n: c.origin.farmers })}</p>
          <ul>{c.origin.villages.map((x) => <li key={`${x.village}-${x.district}`}>{x.village}, {x.district}: <strong>{x.share_pct} %</strong></li>)}</ul>
          <p className="small muted">{t('bv.shares_note')}</p>
        </section>
        <section className="card" data-testid="bv-chain">
          <h2>{t('bv.chain')}</h2>
          <ol>{c.chain.map((x) => <li key={x.code}>{t(`stage.${x.stage}`, undefined, x.stage)} · <span className="mono small">{x.code}</span>{x.on ? ` · ${date(x.on)}` : ''}{x.verified ? ` · ${t('bv.checked')}` : ''}</li>)}</ol>
          {c.qr_code && <p><a href={`/verify/${encodeURIComponent(c.qr_code)}`} data-testid="bv-public">{t('bv.public_page')}</a></p>}
        </section>
        <section className="card stack" data-testid="bv-files">
          <h2>{t('bv.files')}</h2>
          {c.files.length === 0 ? <p className="small muted">{t('bv.no_files')}</p> : c.files.map((f) => (
            <div key={f.id} className="row" data-testid="bv-file">
              <span>{t(`bv.file_${f.label}`, undefined, f.label)} · <span className="mono small">{f.record}</span></span>
              <button className="secondary small" onClick={() => void openFile(f.id)} data-testid="bv-open">{t('bv.open')}</button>
              {fileMsg[f.id] && <span className="small muted">{fileMsg[f.id]}</span>}
            </div>))}
          <button onClick={download} data-testid="bv-evidence">{t('bv.evidence')}</button>
          <p className="small muted">{t('bv.evidence_note')}</p>
        </section>
      </div>
    </PublicFrame>
  );
}
