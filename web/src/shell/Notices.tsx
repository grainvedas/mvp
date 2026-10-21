// Migration 65 (Phase 2, release 2, Part C and D): what a person is told — "ABC Exim added in Uttarakhand by …", a client
// suspended, ended or returned, a renewal uploaded by a client's own login. Above every signed-in screen, the unread ones
// only (at most three, the newest first); "Mark as read" marks the ones shown. A server from before migration 65 has no
// notifications: nothing is shown.
import { Link, useLocation } from 'react-router-dom';
import { useI18n } from '../lib/i18n';
import { useAsync, useAction } from '../lib/useAsync';
import { dateTime } from '../lib/format';
import { myNotifications, noticeText, readNotifications, type Notice } from '../lib/clients';

export function Notices() {
  const { t } = useI18n();
  const { pathname } = useLocation();
  const list = useAsync(() => myNotifications().catch(() => [] as Notice[]), [pathname]);
  const act = useAction();
  const unread = (list.data ?? []).filter((n) => !n.read);
  if (!unread.length) return null;
  const shown = unread.slice(0, 3);
  return (
    <div className="alert info notices" role="status" data-testid="notices">
      <ul style={{ listStyle: 'none', padding: 0, margin: 0 }}>{shown.map((n) => (
        <li key={n.id} data-testid="notice" data-kind={n.kind}>
          {n.client_id ? <Link to={`/clients/${n.client_id}`}>{noticeText(n, t)}</Link> : noticeText(n, t)}
          <span className="small muted"> · {dateTime(n.created_at)}</span>
        </li>))}</ul>
      {unread.length > shown.length && <p className="small" style={{ margin: '4px 0 0' }}>{t('note.more', { n: unread.length - shown.length })}</p>}
      <button type="button" className="secondary small-btn" disabled={act.busy} data-testid="notices-read"
        onClick={() => void act.run(async () => { await readNotifications(shown.map((n) => n.id)); list.reload(); })}>{t('note.mark_read')}</button>
    </div>
  );
}
