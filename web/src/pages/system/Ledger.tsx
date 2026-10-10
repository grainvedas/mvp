// The whole ledger, for the admin (read-only). Every block with its number, event, what it is about, who signed it,
// their role, the time, its hash and the hash before it. Filters: event, client, scope, person, and "manager acts on
// records" (supervisory blocks of a record). The export writes the filtered list, asked page by page from the server.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { q, rpc } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { downloadCsv } from '../../lib/csv';
import { useAction, useAsync } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { dateTime, humanise, shortHash } from '../../lib/format';
import { Empty, ErrorBox, Field, Loading } from '../../shell/ui';

export interface LedgerRow {
  seq: number; event: string; created_at: string; hash: string; prev_hash: string | null;
  footprint_id: string | null; record: string | null; stage_type: string | null;
  what: string | null; about: string | null; client: string | null; scope: string | null;
  actor: string | null; actor_name: string | null; actor_role: string | null; actor_summary_role: string | null;
}
export interface LedgerPage { total: number; rows: LedgerRow[]; limit: number; offset: number }

export const LEDGER_EVENTS = ['create', 'verify', 'seal', 'override', 'supervisory', 'close', 'supersede', 'scope_activate', 'evidence'];
const PAGE = 100;

interface Filters { event: string; client: string; scope: string; actor: string; managerActs: boolean }
const none: Filters = { event: '', client: '', scope: '', actor: '', managerActs: false };
const args = (f: Filters, limit: number, offset: number) => ({
  p_event: f.event || null, p_client: f.client || null, p_scope: f.scope || null, p_actor: f.actor || null,
  p_manager_acts: f.managerActs, p_limit: limit, p_offset: offset,
});

/** What the block is about, in words: the record's code, else what the block says it is. */
export function blockSubject(r: LedgerRow, t: (k: string, p?: Record<string, string | number>, fb?: string) => string): string {
  const what = r.what ? t(`ledger.what.${r.what}`, undefined, humanise(r.what)) : '';
  if (r.record) return what ? `${r.record} · ${what}` : r.record;
  return [what, r.about].filter(Boolean).join(' · ') || '—';
}

export function Ledger() {
  const { t } = useI18n();
  const [f, setF] = useState<Filters>(none);
  const [offset, setOffset] = useState(0);
  const set = (p: Partial<Filters>) => { setF((x) => ({ ...x, ...p })); setOffset(0); };
  const clients = useAsync(() => q(supabase.from('clients').select('id,name').order('name')) as Promise<{ id: string; name: string }[]>, []);
  const scopes = useAsync(() => q(supabase.from('scopes').select('id,client_id,season_code,geography,crops(name)').order('created_at')) as unknown as Promise<{ id: string; client_id: string; season_code: string; geography: string; crops: { name: string } | null }[]>, []);
  const people = useAsync(() => q(supabase.from('app_users').select('id,display_name').order('display_name')) as Promise<{ id: string; display_name: string }[]>, []);
  const page = useAsync(() => rpc<LedgerPage>('ledger_page', args(f, PAGE, offset)), [f, offset]);
  const exp = useAction();

  const exportCsv = () => void exp.run(async () => {
    const all: LedgerRow[] = [];
    for (let off = 0; ; off += 500) {
      const p = await rpc<LedgerPage>('ledger_page', args(f, 500, off));
      all.push(...p.rows);
      if (p.rows.length < 500 || all.length >= p.total) break;
    }
    downloadCsv(`ledger-${new Date().toISOString().slice(0, 10)}.csv`,
      ['seq', 'event', 'record', 'what', 'about', 'client', 'scope', 'signed_by', 'role', 'time', 'hash', 'prev_hash'],
      all.map((r) => [r.seq, r.event, r.record, r.what, r.about, r.client, r.scope, r.actor_name, r.actor_role, r.created_at, r.hash, r.prev_hash]));
  });

  const scopeList = (scopes.data ?? []).filter((s) => !f.client || s.client_id === f.client);
  const d = page.data;
  return (
    <div style={{ maxWidth: 1100 }}>
      <div className="page-hd"><h1><span aria-hidden="true">🔗 </span>{t('ledger.title')}</h1><div className="sub">{t('ledger.sub')}</div></div>
      <div className="filters" data-testid="ledger-filters">
          <Field label={t('ledger.f_event')} htmlFor="lf-event">
            <select id="lf-event" value={f.event} onChange={(e) => set({ event: e.target.value })} data-testid="ledger-event">
              <option value="">{t('ledger.any')}</option>
              {LEDGER_EVENTS.map((e) => <option key={e} value={e}>{t(`event.${e}`, undefined, humanise(e))}</option>)}
            </select>
          </Field>
          <Field label={t('ledger.f_client')} htmlFor="lf-client">
            <select id="lf-client" value={f.client} onChange={(e) => set({ client: e.target.value, scope: '' })} data-testid="ledger-client">
              <option value="">{t('ledger.any')}</option>
              {(clients.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </Field>
          <Field label={t('ledger.f_scope')} htmlFor="lf-scope">
            <select id="lf-scope" value={f.scope} onChange={(e) => set({ scope: e.target.value })} data-testid="ledger-scope">
              <option value="">{t('ledger.any')}</option>
              {scopeList.map((s) => <option key={s.id} value={s.id}>{`${s.crops?.name ?? ''} · ${s.season_code} · ${s.geography}`}</option>)}
            </select>
          </Field>
          <Field label={t('ledger.f_person')} htmlFor="lf-person">
            <select id="lf-person" value={f.actor} onChange={(e) => set({ actor: e.target.value })} data-testid="ledger-person">
              <option value="">{t('ledger.any')}</option>
              {(people.data ?? []).map((p) => <option key={p.id} value={p.id}>{p.display_name}</option>)}
            </select>
          </Field>
        <label className="check"><input type="checkbox" checked={f.managerActs} onChange={(e) => set({ managerActs: e.target.checked })} data-testid="ledger-manager-acts" />{t('ledger.manager_acts')}</label>
      </div>
      {f.managerActs && <p className="small muted">{t('ledger.manager_acts_hint')}</p>}

      {page.loading && !d ? <Loading /> : <ErrorBox error={page.error} onRetry={() => void page.reload()} />}
      {d && (
        <>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8, margin: '8px 0', flexWrap: 'wrap' }}>
            <span className="small" data-testid="ledger-total">{t('ledger.count', { n: d.total })}</span>
            <span>
              <button className="secondary" onClick={exportCsv} disabled={exp.busy || d.total === 0} data-testid="ledger-export">{exp.busy ? t('ledger.exporting') : t('ledger.export')}</button>
            </span>
          </div>
          <ErrorBox error={exp.error} />
          {d.rows.length === 0 ? <Empty>{t('ledger.none')}</Empty> : (
            <div className="table-wrap">
              <table className="wide" data-testid="ledger-table">
                <thead><tr>
                  <th>#</th><th>{t('record.ledger_event')}</th><th>{t('ledger.c_record')}</th><th>{t('ledger.c_signed')}</th>
                  <th>{t('ledger.c_role')}</th><th>{t('record.ledger_when')}</th><th>{t('record.ledger_hash')}</th><th>{t('ledger.c_prev')}</th>
                </tr></thead>
                <tbody>{d.rows.map((r) => (
                  <tr key={r.seq} data-testid="ledger-row" data-event={r.event}>
                    <td className="num">{r.seq}</td>
                    <td>{t(`event.${r.event}`, undefined, humanise(r.event))}</td>
                    <td>
                      {r.footprint_id ? <Link to={`/records/${r.footprint_id}`}>{blockSubject(r, t)}</Link> : blockSubject(r, t)}
                      {(r.client || r.scope) && <div className="small muted">{[r.client, r.scope].filter(Boolean).join(' · ')}</div>}
                    </td>
                    <td>{r.actor_name ?? t('ledger.system')}</td>
                    <td>{r.actor_role ? t(`sysrole.${r.actor_role}`, undefined, humanise(r.actor_role)) : '—'}</td>
                    <td>{dateTime(r.created_at)}</td>
                    <td><code title={r.hash}>{shortHash(r.hash)}</code></td>
                    <td><code title={r.prev_hash ?? ''}>{shortHash(r.prev_hash)}</code></td>
                  </tr>))}</tbody>
              </table>
            </div>)}
          {d.total > PAGE && (
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8, marginTop: 8 }}>
              <button className="secondary" disabled={offset === 0} onClick={() => setOffset(Math.max(0, offset - PAGE))} data-testid="ledger-newer">{t('ledger.newer')}</button>
              <span className="small">{t('ledger.range', { from: offset + 1, to: Math.min(offset + PAGE, d.total), n: d.total })}</span>
              <button className="secondary" disabled={offset + PAGE >= d.total} onClick={() => setOffset(offset + PAGE)} data-testid="ledger-older">{t('ledger.older')}</button>
            </div>)}
        </>)}
    </div>
  );
}
