// Migration 72 (Phase 3, release 5, Part E3): the "Showcase page" card on a client's portfolio. Its owner approves the
// page (nothing is public before) and may unpublish it with a reason; an own-brand client's page, which has no owner,
// the admin. The client's other people and GrainVeda's read its state and a preview. Once published: the badge and the
// snippet to put on the client's own site. Every rule is the server's; the buttons show what app.showcase_of says.
import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useI18n } from '../../lib/i18n';
import { useAsync, useAction } from '../../lib/useAsync';
import { dateTime, date } from '../../lib/format';
import { ErrorBox, Loading } from '../../shell/ui';
import { publishShowcase, showcaseOf, unpublishShowcase } from '../../lib/showcase';
import { badgeSnippet, badgeSvg, type BadgeLang } from '../../lib/badge';
import { ShowcaseView } from '../public/Showcase';
import { useAuth } from '../../auth/AuthProvider';

export function ShowcaseCard({ clientId }: { clientId: string }) {
  const { t, lang } = useI18n();
  const s = useAsync(() => showcaseOf(clientId), [clientId]);
  const act = useAction();
  const [panel, setPanel] = useState<'none' | 'publish' | 'unpublish'>('none');
  const [why, setWhy] = useState('');
  const [copied, setCopied] = useState(false);
  if (s.loading && !s.data) return <div className="card"><Loading /></div>;
  if (!s.data) return null;                                      // a reader who may not see it: no card
  const x = s.data;
  const p = x.preview;
  const bl: BadgeLang = lang === 'hi' ? 'hi' : 'en';
  const snippet = badgeSnippet(window.location.origin, x.code, p.name, bl);
  const badge = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(badgeSvg({ status: p.verification?.status ?? 'none', name: p.name, code: x.code,
    ended_on: p.verification?.ended_on, own_brand: p.own_brand }, bl))}`;
  const copy = async () => { try { await navigator.clipboard.writeText(snippet); setCopied(true); } catch { setCopied(false); } };
  return (
    <div className="card stack" data-testid="showcase-card" data-status={x.status}>
      <h2>{t('scw.title')}</h2>
      <p className="small muted">{t('scw.what')}</p>
      <p data-testid="sh-status">{x.status === 'published' ? t('scw.published', { at: dateTime(x.published_at), by: x.published_by ?? '—' })
        : x.status === 'unpublished' ? t('scw.unpublished', { at: dateTime(x.unpublished_at), by: x.unpublished_by ?? '—', why: x.unpublish_reason ?? '' })
        : t('scw.never')}</p>
      <div className="row">
        {x.status === 'published' && <a href={`/verified/${encodeURIComponent(x.code)}`} target="_blank" rel="noopener" data-testid="sh-open">{t('scw.open')}</a>}
        <Link to={`/portfolio/showcase/${x.client_id}`} data-testid="sh-preview">{t('scw.preview')}</Link>
      </div>
      {x.live_until && <p className="small" data-testid="sh-live-until">{t('scw.live_until', { date: date(x.live_until) })}</p>}
      {x.may_publish && (panel === 'publish'
        ? <div className="stack" data-testid="sh-publish-confirm"><p className="small">{t('scw.publish_note')}</p>
            <div className="row"><button disabled={act.busy} data-testid="sh-publish-go" onClick={() => void act.run(async () => { await publishShowcase(clientId); setPanel('none'); s.reload(); })}>{t('scw.publish_go')}</button>
              <button className="secondary" onClick={() => setPanel('none')}>{t('common.cancel')}</button></div></div>
        : <button onClick={() => setPanel('publish')} data-testid="sh-publish">{t('scw.publish')}</button>)}
      {x.may_unpublish && (panel === 'unpublish'
        ? <div className="stack" data-testid="sh-unpublish-panel">
            <label className="stack small">{t('scw.why')}<textarea rows={2} maxLength={300} value={why} onChange={(e) => setWhy(e.target.value)} data-testid="sh-why" /></label>
            <div className="row"><button className="danger" disabled={act.busy || why.trim().length < 5} data-testid="sh-unpublish-go"
              onClick={() => void act.run(async () => { await unpublishShowcase(clientId, why.trim()); setPanel('none'); setWhy(''); s.reload(); })}>{t('scw.unpublish_go')}</button>
              <button className="secondary" onClick={() => setPanel('none')}>{t('common.cancel')}</button></div></div>
        : <button className="secondary" onClick={() => setPanel('unpublish')} data-testid="sh-unpublish">{t('scw.unpublish')}</button>)}
      {x.status === 'published' && (
        <div className="stack" data-testid="sh-badge">
          <h3>{t('scw.badge')}</h3>
          <img src={badge} alt={t('scw.badge')} width={240} height={64} data-testid="sh-badge-img" />
          <label className="stack small">{t('scw.snippet')}
            <textarea readOnly rows={4} value={snippet} data-testid="sh-snippet" style={{ fontFamily: 'monospace', fontSize: 12 }} onFocus={(e) => e.currentTarget.select()} /></label>
          <div className="row"><button type="button" className="secondary small" onClick={() => void copy()} data-testid="sh-copy">{t('scw.copy')}</button>
            {copied && <span className="small" role="status">{t('scw.copied')}</span>}</div>
          <p className="small muted">{t('scw.badge_note')}</p>
        </div>)}
      <ErrorBox error={act.error} />
    </div>
  );
}

/** /portfolio/showcase/:clientId: the page as it would be (or is) public, for those who may read it. */
export function ShowcasePreviewPage() {
  const { clientId = '' } = useParams();
  const { t } = useI18n();
  const { ctx } = useAuth();
  const s = useAsync(() => showcaseOf(clientId), [clientId]);
  const back = ctx?.user?.client_account?.client_id === clientId ? '/portfolio' : `/portfolio/${clientId}`;
  if (s.loading && !s.data) return <Loading />;
  if (!s.data) return <ErrorBox error={s.error} onRetry={s.reload} />;
  return (
    <div data-testid="showcase-preview">
      <p className="small muted"><Link to={back}>{t('cv.title')}</Link></p>
      <ShowcaseView d={s.data.preview} preview={s.data.status !== 'published'} />
    </div>
  );
}
