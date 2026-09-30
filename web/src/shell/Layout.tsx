import { NavLink, Outlet } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { useI18n, type Lang } from '../lib/i18n';
import { humanise } from '../lib/format';
import type { Role } from '../lib/types';
import { useOutbox } from '../offline/useOutbox';
import { forgetAll } from '../offline/cache';

const NAV: { to: string; key: string; roles: Role[] | 'farmer-slot' }[] = [
  { to: '/', key: 'nav.home', roles: ['admin', 'state_manager', 'client_manager', 'client_view', 'operator'] },
  { to: '/states', key: 'nav.states', roles: ['admin'] },
  { to: '/clients', key: 'nav.clients', roles: ['admin', 'state_manager'] },
  { to: '/crops', key: 'nav.crops', roles: ['admin'] },
  { to: '/scopes', key: 'nav.scopes', roles: ['admin', 'state_manager', 'client_manager', 'client_view'] },
  { to: '/farmers', key: 'nav.farmers', roles: 'farmer-slot' },
  { to: '/users', key: 'nav.users', roles: ['admin', 'state_manager', 'client_manager'] },
  { to: '/flags', key: 'nav.flags', roles: ['admin', 'state_manager', 'client_manager'] },
];

export function Layout() {
  const { ctx, signOut } = useAuth();
  const { t, lang, setLang } = useI18n();
  const me = ctx?.user;
  const box = useOutbox({ autoSync: true });
  const pending = box.waiting + box.failed;
  const leave = async () => {
    if (pending > 0 && !window.confirm(t('outbox.signout_warning', { n: pending }))) return;
    await forgetAll();
    await signOut();
  };
  const farmerSlot = !!ctx?.slots.some((s) => s.stage_type === 'procurement' || s.stage_type === 'village_batch');
  const visible = NAV.filter((n) => me && (n.roles === 'farmer-slot'
    ? me.role !== 'operator' || farmerSlot
    : n.roles.includes(me.role)));
  return (
    <>
      <header className="topbar">
        <a className="brand" href="/"><img src="/icon.svg" alt="" width={28} height={28} />{t('app.name')}</a>
        <span className="spacer" />
        {me && <span className="small hide-mobile" data-testid="whoami">{me.display_name} · {humanise(me.role)}</span>}
        <select aria-label="Language" value={lang} onChange={(e) => setLang(e.target.value as Lang)} style={{ width: 'auto' }}>
          <option value="en">English</option>
          <option value="hi">हिन्दी</option>
        </select>
        {(!box.online || pending > 0) && <NavLink to="/outbox" className={`net${box.online ? '' : ' off'}`} data-testid="net-badge">
          {[!box.online && t('outbox.badge_offline'), box.waiting > 0 && t('outbox.badge', { n: box.waiting }),
            box.failed > 0 && t('outbox.badge_failed', { n: box.failed })].filter(Boolean).join(' · ')}</NavLink>}
        <button className="secondary" onClick={() => void leave()}>{t('nav.signout')}</button>
      </header>
      <nav className="nav" aria-label="Main">
        {visible.map((n) => <NavLink key={n.to} to={n.to} end={n.to === '/'}>{t(n.key)}</NavLink>)}
        {(box.items.length > 0 || me?.role === 'operator') && <NavLink to="/outbox">{t('nav.outbox')}</NavLink>}
      </nav>
      <main><Outlet /></main>
    </>
  );
}
