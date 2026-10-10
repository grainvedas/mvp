// Help (brief 3, ME: "Help (support + 'Report a problem', reuse Health 'Problems reported by phones')").
//   Who helps you, by role, in plain words · Report a problem: what a person writes lands in the admin's Health page,
//   in the same list as the problems phones report on their own (app.report_client_error, kind 'report', migration 35).
// "My guide" (/guide) shows the role guide again on the first screen and goes there.
import { useState } from 'react';
import { Link, Navigate } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { rpc } from '../lib/api';
import { BUILD_ID } from '../lib/errorLog';
import { useI18n } from '../lib/i18n';
import { oversees } from '../lib/rights';
import { useAction } from '../lib/useAsync';
import { ErrorBox } from '../shell/ui';
import { showGuideAgain } from '../shell/RoleGuide';
import type { MyContext } from '../lib/types';

/** Pure: which help text a person reads (admin, HR Admin, HR, everyone else). */
export function helpRole(ctx: MyContext | null | undefined): 'admin' | 'hr_admin' | 'hr' | 'any' {
  if (oversees(ctx)) return 'admin';
  const sr = ctx?.user?.system_role;
  if (sr === 'hr_admin') return 'hr_admin';
  if (sr === 'hr_resource') return 'hr';
  return 'any';
}

export function Help() {
  const { ctx } = useAuth();
  const { t } = useI18n();
  const who = helpRole(ctx);
  const [text, setText] = useState('');
  const [sent, setSent] = useState(false);
  const act = useAction();
  const lines: string[] = [];
  for (let i = 1; i <= 6; i++) { const l = t(`help.${who}.${i}`, undefined, ''); if (!l) break; lines.push(l); }
  const send = () => act.run(async () => {
    const ok = await rpc<boolean>('report_client_error', {
      p_kind: 'report', p_message: text.trim().slice(0, 500), p_detail: null, p_path: window.location.pathname,
      p_build: BUILD_ID, p_online: navigator.onLine, p_agent: navigator.userAgent.slice(0, 300),
    });
    if (ok === false) throw new Error(t('help.not_sent'));
    setText(''); setSent(true);
  });
  return (
    <>
      <h1><span aria-hidden="true">💬 </span>{t('help.title')}</h1>
      <div className="card" data-testid="help-who">
        <h2>{t('help.who')}</h2>
        <ul className="guide-list">{lines.map((l) => <li key={l}>{l}</li>)}</ul>
        {who === 'admin' && <p className="small"><Link to="/guide" data-testid="help-guide">{t('menu.guide')}</Link></p>}
      </div>
      <div className="card" data-testid="help-report">
        <h2>{t('help.report')}</h2>
        <p className="small muted">{who === 'admin' ? t('help.report_admin') : t('help.report_hint')}</p>
        <label>{t('help.what')}
          <textarea rows={4} maxLength={500} value={text} onChange={(e) => { setText(e.target.value); setSent(false); }} data-testid="help-text" />
        </label>
        <ErrorBox error={act.error} />
        {sent && <div className="alert ok" role="status" data-testid="help-sent">{who === 'admin' ? t('help.sent_admin') : t('help.sent')}</div>}
        <button onClick={send} disabled={act.busy || text.trim().length < 5} data-testid="help-send">{t('help.send')}</button>
        {who === 'admin' && <p className="small"><Link to="/health">{t('help.to_health')}</Link></p>}
      </div>
    </>
  );
}

/** "My guide": shows the role guide again and opens the first screen, where it is. */
export function GuideAgain() {
  const { ctx } = useAuth();
  showGuideAgain(oversees(ctx) ? 'admin' : ctx?.user?.role ?? '');
  return <Navigate to="/" replace />;
}
