// The frame around every signed-in screen (decision G8 = B, 4 Oct 2026: the prototype's frame).
// On a laptop (from 900 px): a dark top bar (brand, client, scope selector, who, sign out) and a dark side menu in
// sections with pictograms. On a phone: the same elements folded into three single lines (strip, top bar, menu row).
// One <nav aria-label="Main"> in both; only the styling differs, so a link is found the same way at any width.
import type { ReactElement } from 'react';
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { useI18n, type Lang } from '../lib/i18n';
import { humanise } from '../lib/format';
import type { Role } from '../lib/types';
import { useOutbox } from '../offline/useOutbox';
import { stageIcon } from '../engine/icons';
import { CrashCard, ErrorBoundary } from './ErrorBoundary';
import { ScopeProvider, shownScope, useScope, useWide } from './scope';

type Section = 'overview' | 'registry' | 'system';
const NAV: { to: string; key: string; icon: string; section: Section; roles: Role[] | 'farmer-slot' }[] = [
  { to: '/', key: 'nav.home', icon: '📊', section: 'overview', roles: ['admin', 'state_manager', 'client_manager', 'client_view', 'operator'] },
  { to: '/farmers', key: 'nav.farmers', icon: '👨‍🌾', section: 'registry', roles: 'farmer-slot' },
  { to: '/scopes', key: 'nav.scopes', icon: '🎯', section: 'registry', roles: ['admin', 'state_manager', 'client_manager', 'client_view'] },
  { to: '/users', key: 'nav.users', icon: '👤', section: 'registry', roles: ['admin', 'state_manager', 'client_manager'] },
  { to: '/clients', key: 'nav.clients', icon: '🏢', section: 'registry', roles: ['admin', 'state_manager'] },
  { to: '/crops', key: 'nav.crops', icon: '🌿', section: 'registry', roles: ['admin'] },
  { to: '/states', key: 'nav.states', icon: '📍', section: 'registry', roles: ['admin'] },
  { to: '/flags', key: 'nav.flags', icon: '🚩', section: 'system', roles: ['admin', 'state_manager', 'client_manager'] },
  { to: '/health', key: 'nav.health', icon: '🩺', section: 'system', roles: ['admin', 'state_manager'] },
];

/** "Prasaadam Client Manager" → "PC": the first letters of the first two words, as in the prototype's top bar. */
export const initials = (name: string) => name.split(/\s+/).map((w) => w.replace(/[^\p{L}\p{N}]/gu, '')).filter(Boolean).slice(0, 2).map((w) => w[0]).join('').toUpperCase();

export function Layout() {
  return <ScopeProvider><Frame /></ScopeProvider>;
}

function Frame() {
  const { ctx, signOut } = useAuth();
  const { t, lang, setLang } = useI18n();
  const { pathname } = useLocation();
  const navigate = useNavigate();
  const { scopes, current, choose } = useScope();
  const wide = useWide();                                 // the selector is in the top bar on a laptop, on the first screen on a phone
  const me = ctx?.user;
  const box = useOutbox({ autoSync: true });
  const pending = box.waiting + box.failed;
  const leave = async () => {
    if (pending > 0 && !window.confirm(t('outbox.signout_warning', { n: pending }))) return;
    // Signing in needs the network; signing out does not. Say so before someone locks themselves out at the farm gate.
    if (!box.online && !window.confirm(t('outbox.signout_offline'))) return;
    await signOut();                                       // also forgets what was kept on this phone for offline work
  };
  const farmerSlot = !!ctx?.slots.some((s) => s.stage_type === 'procurement' || s.stage_type === 'village_batch');
  const visible = NAV.filter((n) => me && (n.roles === 'farmer-slot'
    ? me.role !== 'operator' || farmerSlot
    : n.roles.includes(me.role)));
  const inSection = (s: Section) => visible.filter((n) => n.section === s);
  // The scope the frame shows: the one this page belongs to (a stage page, a scope's dashboard), else the chosen one.
  const shown = shownScope(scopes, current, pathname);
  // Operations: the stages of that scope. A manager or viewer gets its whole chain, an operator the stages held there.
  const stages = !shown || !me ? [] : me.role === 'operator'
    ? ctx!.slots.filter((s) => s.scope_id === shown.id).map((s) => s.stage_type)
    : shown.status === 'draft' ? [] : shown.chain;
  const item = (to: string, icon: string, label: string, end = false) => (
    <NavLink key={to} to={to} end={end}><span className="sb-icon" aria-hidden="true">{icon}</span>{label}</NavLink>);
  const section = (key: string, items: ReactElement[]) => items.length === 0 ? null : (
    <>
      <div className="sb-section" aria-hidden="true">{t(key)}</div>
      {items}
    </>);
  const pick = (id: string) => { choose(id === '' ? null : id); navigate('/'); };
  const context = me?.client_name ?? (scopes.length > 0 && new Set(scopes.map((s) => s.client_name)).size === 1 ? scopes[0].client_name : t('app.tagline'));
  return (
    <>
      <header className="topbar">
        <a className="brand" href="/" aria-label={t('app.name')}><img src="/icon.svg" alt="" width={28} height={28} /><span className="brand-name">{t('app.name')}</span></a>
        <span className="tb-sep" aria-hidden="true" />
        <span className="tb-context" data-testid="tb-context">{context}</span>
        {wide && scopes.length > 1 && (
          <label className="tb-scope">{t('scope.label')}
            <select aria-label={t('scope.choose')} value={shown?.id ?? ''} onChange={(e) => pick(e.target.value)} data-testid="scope-switcher">
              <option value="">{t('scope.overall')}</option>
              {scopes.map((s) => <option key={s.id} value={s.id}>{s.label}{s.status === 'draft' ? ` ${t('scope.setup')}` : ''}</option>)}
            </select>
          </label>)}
        <span className="spacer" />
        {me && <span className="small who" data-testid="whoami"><span className="who-name">{me.display_name}</span><span className="who-role"><span className="dot-sep"> · </span>{t(`role.${me.role}`, undefined, humanise(me.role))}</span></span>}
        {me && <NavLink to="/account" className="tb-av" aria-label={t('nav.account')} title={t('nav.account')}>{initials(me.display_name)}</NavLink>}
        <select aria-label="Language" value={lang} onChange={(e) => setLang(e.target.value as Lang)} style={{ width: 'auto' }}>
          <option value="en">English</option>
          <option value="hi">हिन्दी</option>
        </select>
        {(!box.online || pending > 0) && <NavLink to="/outbox" className={`net${box.online ? '' : ' off'}`} data-testid="net-badge">
          {[!box.online && t('outbox.badge_offline'), box.waiting > 0 && t('outbox.badge', { n: box.waiting }),
            box.failed > 0 && t('outbox.badge_failed', { n: box.failed })].filter(Boolean).join(' · ')}</NavLink>}
        <button className="secondary" onClick={() => void leave()}>{t('nav.signout')}</button>
      </header>
      <div className="frame">
        <nav className="nav" aria-label="Main">
          {section('nav.section_overview', inSection('overview').map((n) => item(n.to, n.icon, t(n.key), n.to === '/')))}
          {section('nav.section_registry', inSection('registry').map((n) => item(n.to, n.icon, t(n.key))))}
          {section('nav.section_operations', stages.map((s) => item(`/work/${shown!.id}/${s}`, stageIcon(s), t(`stage.${s}`, undefined, humanise(s)))))}
          {section('nav.section_system', inSection('system').map((n) => item(n.to, n.icon, t(n.key))))}
          {section('nav.section_support', [
            ...(box.items.length > 0 || me?.role === 'operator' ? [item('/outbox', '📥', t('nav.outbox'))] : []),
            ...(me ? [item('/account', '🔑', t('nav.account'))] : []),
          ])}
        </nav>
        <main><ErrorBoundary key={pathname} fallback={(_e, retry) => <CrashCard retry={retry} />}><Outlet /></ErrorBoundary></main>
      </div>
    </>
  );
}
