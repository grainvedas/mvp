// Migration 56 (Part F; Veda 16 Oct 2026, "proceed with 56"). A sale or a shipment shared with its buyer: the Client
// Manager (or a manager of the scope) makes a link that lasts 7, 30 or 90 days. The link is shown once (only its
// fingerprint is kept), to copy or send by WhatsApp or email; the list shows every link, its state and each time it was
// opened, and a link is revoked with a reason. The buyer's page shows the lab reports, the export documents, the chain
// and the villages' shares: no price, no farmer's name, nothing of another buyer (app.buyer_content).
// Also here: the scan flags of the Flags page (D6): a pack's code scanned far apart or very often, cleared or confirmed.
import { useState } from 'react';
import { rpc } from '../../lib/api';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { date, dateTime } from '../../lib/format';
import { Badge, ErrorBox, Field, Loading } from '../../shell/ui';

export const LINK_DAYS = [7, 30, 90] as const;
export interface BuyerLink {
  id: string; note: string | null; created_at: string; expires_at: string; revoked_at: string | null; revoke_reason: string | null;
  by: string | null; state: 'active' | 'expired' | 'revoked'; views: number; last_view: string | null;
  log: { at: string; what: 'open' | 'evidence' | 'file' }[];
}

/** Pure: the buyer's address. The token is after the #: no web server ever receives it. */
export const buyerLinkUrl = (origin: string, token: string) => `${origin.replace(/\/+$/, '')}/b#${token}`;
/** Pure: the message sent with the link. */
export const shareMessage = (code: string, url: string, until: string, t: (k: string, v?: Record<string, string | number>) => string) =>
  t('bk.message', { code, url, date: date(until) });

export function BuyerSharePanel({ fp, code }: { fp: string; code: string }) {
  const { t } = useI18n();
  const [rev, setRev] = useState(0);
  const links = useAsync(() => rpc<BuyerLink[]>('buyer_links_of', { p_fp: fp }), [fp, rev]);
  const [form, setForm] = useState<{ days: number; note: string } | null>(null);
  const [made, setMade] = useState<{ url: string; until: string } | null>(null);
  const [copied, setCopied] = useState(false);
  const [revoke, setRevoke] = useState<{ id: string; reason: string } | null>(null);
  const act = useAction();
  const create = () => act.run(async () => {
    const r = await rpc<{ id: string; token: string; expires_at: string }>('create_buyer_link', { p_fp: fp, p_days: form!.days, p_note: form!.note.trim() || null });
    setMade({ url: buyerLinkUrl(window.location.origin, r.token), until: r.expires_at });
    setForm(null); setCopied(false); setRev((x) => x + 1);
  });
  const doRevoke = () => act.run(async () => {
    await rpc('revoke_buyer_link', { p_link: revoke!.id, p_reason: revoke!.reason.trim() });
    setRevoke(null); setRev((x) => x + 1);
  });
  const copy = async () => {
    try { await navigator.clipboard.writeText(made!.url); setCopied(true); } catch { setCopied(false); }
  };
  const msg = made ? shareMessage(code, made.url, made.until, t) : '';
  return (
    <div className="card stack" data-testid="buyer-share">
      <h2>{t('bk.title')}</h2>
      <p className="small muted">{t('bk.what')}</p>
      {made && (
        <div className="alert ok stack" data-testid="bk-made">
          <strong>{t('bk.made', { date: date(made.until) })}</strong>
          <input readOnly value={made.url} aria-label={t('bk.link')} data-testid="bk-url" onFocus={(e) => e.currentTarget.select()} />
          <p className="small">{t('bk.once')}</p>
          <div className="row">
            <button className="secondary" onClick={() => void copy()} data-testid="bk-copy">{copied ? t('bk.copied') : t('bk.copy')}</button>
            <a className="btn secondary" href={`https://wa.me/?text=${encodeURIComponent(msg)}`} target="_blank" rel="noreferrer" data-testid="bk-whatsapp">{t('bk.whatsapp')}</a>
            <a className="btn secondary" href={`mailto:?subject=${encodeURIComponent(t('bk.subject', { code }))}&body=${encodeURIComponent(msg)}`} data-testid="bk-email">{t('bk.email')}</a>
            <button className="secondary" onClick={() => setMade(null)}>{t('bk.done')}</button>
          </div>
        </div>)}
      {!form && !made && <button className="secondary" onClick={() => setForm({ days: 30, note: '' })} data-testid="bk-new">{t('bk.new')}</button>}
      {form && (
        <div className="stack" data-testid="bk-form">
          <Field label={`${t('bk.days')} *`} htmlFor="bl-days">
            <select id="bl-days" value={form.days} onChange={(e) => setForm({ ...form, days: Number(e.target.value) })} data-testid="bk-days">
              {LINK_DAYS.map((d) => <option key={d} value={d}>{t('bk.days_n', { n: d })}</option>)}</select></Field>
          <Field label={t('bk.note')} htmlFor="bl-note" hint={t('bk.note_hint')}>
            <input id="bl-note" value={form.note} maxLength={200} onChange={(e) => setForm({ ...form, note: e.target.value })} data-testid="bk-note" /></Field>
          <ErrorBox error={act.error} />
          <div className="row"><button disabled={act.busy} onClick={() => void create()} data-testid="bk-create">{t('bk.create')}</button>
            <button className="secondary" onClick={() => setForm(null)}>{t('common.cancel')}</button></div>
        </div>)}
      {links.loading && !links.data ? <Loading /> : <ErrorBox error={links.error} onRetry={links.reload} />}
      {!!links.data?.length && (
        <ul className="stack" data-testid="bk-list" style={{ listStyle: 'none', padding: 0 }}>
          {links.data.map((l) => (
            <li key={l.id} className="card small" data-testid="bk-row" data-state={l.state}>
              <div className="row"><Badge value={l.state === 'active' ? 'verified' : l.state === 'revoked' ? 'fail' : 'closed'} label={t(`bk.st_${l.state}`)} />
                <span>{l.note ?? t('bk.no_note')}</span></div>
              <p className="small muted">{t('bk.row', { by: l.by ?? '—', made: date(l.created_at), until: date(l.expires_at) })}
                {' · '}<span data-testid="bk-views">{t('bk.views', { n: l.views })}</span>{l.last_view ? ` · ${t('bk.last', { at: dateTime(l.last_view) })}` : ''}</p>
              {l.state === 'revoked' && <p className="small">{t('bk.revoked_why', { at: dateTime(l.revoked_at!), why: l.revoke_reason ?? '' })}</p>}
              {l.log.length > 0 && <details><summary className="small">{t('bk.log')}</summary>
                <ul className="small" data-testid="bk-log">{l.log.map((v, k) => <li key={k}>{dateTime(v.at)} · {t(`bk.what_${v.what}`)}</li>)}</ul></details>}
              {l.state === 'active' && revoke?.id !== l.id && <button className="secondary small" onClick={() => setRevoke({ id: l.id, reason: '' })} data-testid="bk-revoke">{t('bk.revoke')}</button>}
              {revoke?.id === l.id && (
                <div className="stack">
                  <Field label={`${t('bk.revoke_reason')} *`} htmlFor="bl-why"><input id="bl-why" value={revoke.reason} maxLength={300} data-testid="bk-why"
                    onChange={(e) => setRevoke({ ...revoke, reason: e.target.value })} /></Field>
                  <ErrorBox error={act.error} />
                  <div className="row"><button disabled={act.busy || revoke.reason.trim().length < 5} onClick={() => void doRevoke()} data-testid="bk-revoke-save">{t('bk.revoke')}</button>
                    <button className="secondary" onClick={() => setRevoke(null)}>{t('common.cancel')}</button></div>
                </div>)}
            </li>))}
        </ul>)}
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------------
export interface ScanFlag {
  id: string; serial: string; kind: 'far_apart' | 'many'; status: 'open' | 'cleared' | 'confirmed'; raised_at: string; batch_code: string; scope: string;
  detail: { km?: number; limit_km?: number; places?: { city: string | null; country: string | null; at: string }[]; scans_24h?: number; limit?: number };
  scans: { at: string; city: string | null; region: string | null; country: string | null }[];
}
/** Pure: what a scan flag says. */
export function scanFlagText(f: ScanFlag, t: (k: string, v?: Record<string, string | number>) => string): string {
  if (f.kind === 'many') return t('sf.many', { n: f.detail.scans_24h ?? 0, limit: f.detail.limit ?? 0 });
  const p = (f.detail.places ?? []).map((x) => [x.city, x.country].filter(Boolean).join(', ') || t('sf.unknown_place'));
  return t('sf.far', { km: Math.round(Number(f.detail.km ?? 0)), a: p[0] ?? '—', b: p[1] ?? '—', limit: f.detail.limit_km ?? 0 });
}

/** The Flags page: the packs whose scans look copied (for the managers of their scope; the server lists only those). */
export function ScanFlagsCard() {
  const { t } = useI18n();
  const [rev, setRev] = useState(0);
  const list = useAsync(() => rpc<ScanFlag[]>('scan_flags_list', { p_status: 'open' }).catch(() => [] as ScanFlag[]), [rev]);
  const [open, setOpen] = useState<{ id: string; outcome: 'cleared' | 'confirmed' | ''; reason: string } | null>(null);
  const act = useAction();
  const decide = () => act.run(async () => {
    await rpc('decide_scan_flag', { p_flag: open!.id, p_outcome: open!.outcome, p_reason: open!.reason.trim() });
    setOpen(null); setRev((x) => x + 1);
  });
  if (!list.data?.length) return null;
  return (
    <div className="card stack" data-testid="scan-flags">
      <h2>{t('sf.title', { n: list.data.length })}</h2>
      <p className="small muted">{t('sf.what')}</p>
      {list.data.map((f) => (
        <div key={f.id} className="card small stack" data-testid="sf-row" data-kind={f.kind}>
          <p><strong className="mono">{f.serial}</strong> · {t('pv.batch')} <span className="mono">{f.batch_code}</span> · <span className="muted">{f.scope}</span></p>
          <p data-testid="sf-text">{scanFlagText(f, t)}</p>
          <details><summary className="small">{t('sf.scans', { n: f.scans.length })}</summary>
            <ul className="small" data-testid="sf-scans">{f.scans.map((s, k) => <li key={k}>{dateTime(s.at)} · {[s.city, s.region, s.country].filter(Boolean).join(', ') || t('sf.unknown_place')}</li>)}</ul></details>
          {open?.id !== f.id && <button className="secondary small" onClick={() => setOpen({ id: f.id, outcome: '', reason: '' })} data-testid="sf-decide">{t('sf.decide')}</button>}
          {open?.id === f.id && (
            <div className="stack">
              <Field label={`${t('sf.outcome')} *`} htmlFor="sf-outcome">
                <select id="sf-outcome" value={open.outcome} data-testid="sf-outcome" onChange={(e) => setOpen({ ...open, outcome: e.target.value as 'cleared' | 'confirmed' })}>
                  <option value="">—</option><option value="cleared">{t('sf.cleared')}</option><option value="confirmed">{t('sf.confirmed')}</option></select></Field>
              <Field label={`${t('sf.reason')} *`} htmlFor="sf-reason" hint={t('sf.reason_hint')}>
                <input id="sf-reason" value={open.reason} maxLength={500} data-testid="sf-reason" onChange={(e) => setOpen({ ...open, reason: e.target.value })} /></Field>
              <ErrorBox error={act.error} />
              <div className="row"><button disabled={act.busy || !open.outcome || open.reason.trim().length < 10} onClick={() => void decide()} data-testid="sf-save">{t('sf.save')}</button>
                <button className="secondary" onClick={() => setOpen(null)}>{t('common.cancel')}</button></div>
            </div>)}
        </div>))}
    </div>
  );
}
