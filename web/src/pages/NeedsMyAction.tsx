// "Needs my action" (migration 48, D3; Veda 15 Oct 2026): the first thing on the home screen, for every role, from one
// server answer (app.my_actions): my records returned to me (with the reason), what waits at the stages I hold, farmer
// corrections and new farmers for the Client Manager, requirement lines HR returned with a question, open flags and
// conditions on the scopes I manage. Nothing is counted in the browser.
import { Link } from 'react-router-dom';
import { rpc } from '../lib/api';
import { useAsync } from '../lib/useAsync';
import { useI18n } from '../lib/i18n';
import { dateTime } from '../lib/format';
import type { MyActions } from '../lib/types';

export interface ActionLine { key: string; n: number; text: string; to: string; action: string; detail?: string }

/** Pure: the lines of the block, in the order a person deals with them. */
export function actionLines(a: MyActions, t: (k: string, v?: Record<string, string | number>, f?: string) => string): ActionLine[] {
  const stage = (s: string) => t(`stage.${s}`, undefined, s);
  const out: ActionLine[] = [];
  for (const r of a.returned) out.push({ key: `r-${r.id}`, n: 1, to: `/records/${r.id}`,
    text: t('act.returned', { code: r.code, stage: stage(r.stage), by: r.by ?? '—' }), detail: `“${r.reason}” · ${dateTime(r.at)}`,
    action: t(r.in_place ? 'act.correct' : 'act.withdraw_again') });
  for (const v of a.to_verify) out.push({ key: `v-${v.scope_id}-${v.stage}`, n: Number(v.n), to: `/work/${v.scope_id}/${v.stage}`,
    text: t('act.to_verify', { n: v.n, from: stage(v.from_stage), stage: stage(v.stage) }), detail: v.scope, action: t('act.open') });
  if (a.farmers_to_verify > 0) out.push({ key: 'farmers', n: a.farmers_to_verify, to: '/farmers', text: t('act.farmers', { n: a.farmers_to_verify }), action: t('act.open') });
  if (a.proposals > 0) out.push({ key: 'proposals', n: a.proposals, to: '/farmers', text: t('act.proposals', { n: a.proposals }), action: t('act.open') });
  if (a.requirement_lines > 0) out.push({ key: 'lines', n: a.requirement_lines, to: '/scopes', text: t('act.lines', { n: a.requirement_lines }), action: t('act.open') });
  if (a.conditions > 0) out.push({ key: 'conditions', n: a.conditions, to: '/flags', text: t('act.conditions', { n: a.conditions }), action: t('act.open') });
  if (a.flags > 0) out.push({ key: 'flags', n: a.flags, to: '/flags', text: t('act.flags', { n: a.flags }), action: t('act.open') });
  return out;
}

export function NeedsMyAction({ always = false }: { always?: boolean }) {
  const { t } = useI18n();
  // an older server (before migration 48) has no app.my_actions: the block is simply not shown
  const a = useAsync(() => rpc<MyActions>('my_actions').catch(() => null), []);
  if (!a.data) return null;
  const lines = actionLines(a.data, t);
  const total = lines.reduce((s, l) => s + l.n, 0);
  if (lines.length === 0) return always ? <div className="alert ok" data-testid="needs-action">{t('act.none')}</div> : null;
  return (
    <div className="card queue" data-testid="needs-action">
      <h2>{t('act.title', { n: total })}</h2>
      {lines.map((l) => (
        <div className="queue-row" key={l.key} data-testid="needs-action-line" data-kind={l.key.split('-')[0]}>
          <span>{l.text}{l.detail && <span className="small muted" style={{ display: 'block' }}>{l.detail}</span>}</span>
          <Link className="btn secondary" to={l.to}>{l.action}</Link>
        </div>))}
    </div>
  );
}
