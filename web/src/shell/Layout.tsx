// The frame around every signed-in screen (decision G8 = B, 4 Oct 2026: the prototype's frame).
// On a laptop (from 900 px): a dark top bar (brand, client, scope selector, who, sign out) and a dark side menu in
// sections with pictograms. On a phone: the same elements folded into three single lines (strip, top bar, menu row).
// One <nav aria-label="Main"> in both; only the styling differs, so a link is found the same way at any width.
import { Fragment, type ReactElement } from 'react';
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';
import { useI18n, type Lang } from '../lib/i18n';
import { humanise } from '../lib/format';
import { NO_RIGHTS, type Can, type Role } from '../lib/types';
import { useOutbox } from '../offline/useOutbox';
import { stageIcon } from '../engine/icons';
import { Notices } from './Notices';
import { CrashCard, ErrorBoundary } from './ErrorBoundary';
import { ScopeProvider, shownScope, useScope, useWide, worksInOneScope } from './scope';
import { isClientLogin, myClientAccounts, oversees } from '../lib/rights';
import { rpc } from '../lib/api';
import { useAsync } from '../lib/useAsync';

type Section = 'overview' | 'registry' | 'people' | 'system';
/** What the menu needs to know about the person. `can` comes from the server (identity layer); the role is the summary. */
export interface NavWho { role: Role; can: Can; farmerSlot: boolean; joiner: boolean; employee: boolean; /** not yet marked as joined */ joining?: boolean;
  /** saves waiting on this phone (the outbox) */ outbox?: boolean }
export const NAV: { to: string; key: string; icon: string; section: Section; show: (w: NavWho) => boolean }[] = [
  { to: '/', key: 'nav.home', icon: '📊', section: 'overview', show: () => true },
  { to: '/onboarding', key: 'nav.onboarding', icon: '✅', section: 'overview', show: (w) => w.joiner },
  { to: '/help', key: 'menu.help', icon: '💬', section: 'overview', show: (w) => !!w.joining },   // B5: help for someone not yet joined
  { to: '/farmers', key: 'nav.farmers', icon: '👨‍🌾', section: 'registry', show: (w) => w.role !== 'operator' || w.farmerSlot },
  { to: '/scopes', key: 'nav.scopes', icon: '🎯', section: 'registry', show: (w) => w.role !== 'operator' },
  { to: '/clients', key: 'nav.clients', icon: '🏢', section: 'registry', show: (w) => w.role === 'admin' || w.role === 'state_manager' || w.can.state_lens },   // the State Manager onboards; the admin reads
  { to: '/crops', key: 'nav.crops', icon: '🌿', section: 'registry', show: (w) => w.can.admin || w.can.state_lens },   // the State Manager's; the admin reads
  { to: '/states', key: 'nav.states', icon: '📍', section: 'registry', show: (w) => w.can.admin },
  // People: HR makes them, managers assign them. Two different jobs, two different entries.
  { to: '/hr/requirements', key: 'req.title', icon: '📝', section: 'people', show: (w) => w.can.hr },   // migration 46: first, with its badge
  { to: '/hr', key: 'nav.hr', icon: '🧑‍💼', section: 'people', show: (w) => w.can.hr },
  { to: '/hr/openings', key: 'open.title', icon: '📋', section: 'people', show: (w) => w.can.hr },
  { to: '/people', key: 'nav.people', icon: '👥', section: 'people', show: (w) => w.can.hr || w.can.assign },
  { to: '/state', key: 'nav.state', icon: '🗺', section: 'people', show: (w) => w.can.state_lens },
  { to: '/flags', key: 'nav.flags', icon: '🚩', section: 'system', show: (w) => w.can.assign },
  { to: '/health', key: 'nav.health', icon: '🩺', section: 'system', show: (w) => w.can.state_lens },
  { to: '/system/seats', key: 'nav.seats', icon: '🪑', section: 'system', show: (w) => w.can.admin },
  { to: '/system/ledger', key: 'nav.ledger', icon: '🔗', section: 'system', show: (w) => w.can.admin },
  { to: '/system/audit', key: 'nav.audit', icon: '📜', section: 'system', show: (w) => w.can.audit ?? w.can.hr_admin },
  { to: '/system/safeguards', key: 'nav.safeguards', icon: '🛡', section: 'system', show: (w) => !!w.can.hr_admin },   // migration 45: she decides corrections
  { to: '/guide', key: 'menu.guide', icon: '🧭', section: 'system', show: (w) => !w.joining },   // migration 44: every role's guide
];

/**
 * A role's own sidebar, grouped by the question it answers (Veda, 10 Oct 2026). Only the admin has one so far; another
 * role adopts the same headings by adding its list here, each seeing only its own pages. The admin's:
 *   Watch (how is the business doing?) · Audit (can I trust the data?) · Master data (what does the operation run on?
 *   read-only, States apart) · Access (who can do what?) · Me.
 */
export type Heading = 'watch' | 'audit' | 'master' | 'access' | 'me';
export const HEADINGS: Heading[] = ['watch', 'audit', 'master', 'access', 'me'];
/** The Client Manager's headings (migration 48, D4): Watch · My scopes · Farmers · People · Audit · Me. */
export type CmHeading = 'watch' | 'scopes' | 'farmers' | 'people' | 'audit' | 'me';
export const CM_HEADINGS: CmHeading[] = ['watch', 'scopes', 'farmers', 'people', 'audit', 'me'];
export type Menu = 'admin' | 'state_manager' | 'client_manager';
export interface MenuItem { to: string; key: string; icon: string; show?: (w: NavWho) => boolean }
export const ROLE_MENUS: { admin: Record<Heading, MenuItem[]>; state_manager: Record<Heading, MenuItem[]>; client_manager: Record<CmHeading, MenuItem[]> } = {
  admin: {
    watch: [
      { to: '/', key: 'menu.overview', icon: '📊' },
      { to: '/pipeline', key: 'menu.pipeline', icon: '🔀' },
      { to: '/state', key: 'nav.state', icon: '🗺' },
      { to: '/flags', key: 'nav.flags', icon: '🚩' },
    ],
    audit: [
      { to: '/system/ledger', key: 'nav.ledger', icon: '🔗' },
      { to: '/system/audit', key: 'nav.audit', icon: '📜' },
      { to: '/health', key: 'nav.health', icon: '🩺' },
      { to: '/system/safeguards', key: 'nav.safeguards', icon: '🛡' },   // migration 45
    ],
    master: [                                              // set-up order: states → clients → crops → scopes → farmers
      { to: '/states', key: 'nav.states', icon: '📍' },
      { to: '/clients', key: 'nav.clients', icon: '🏢' },
      { to: '/crops', key: 'menu.crops', icon: '🌿' },
      { to: '/setup', key: 'menu.setup', icon: '🗂' },                      // migration 51: read-only
      { to: '/scopes', key: 'nav.scopes', icon: '🎯' },
      { to: '/farmers', key: 'nav.farmers', icon: '👨‍🌾' },
    ],
    access: [
      { to: '/people', key: 'nav.people', icon: '👥' },
      { to: '/hr/openings', key: 'open.title', icon: '📋' },
      { to: '/system/seats', key: 'nav.seats', icon: '🪑' },
      { to: '/hr', key: 'nav.hr', icon: '🧑‍💼', show: (w) => w.can.hr },     // only while the HR Admin seat is empty
    ],
    me: [
      { to: '/account', key: 'nav.account', icon: '🔑' },
      { to: '/guide', key: 'menu.guide', icon: '🧭' },
      { to: '/help', key: 'menu.help', icon: '💬' },
    ],
  },
  // The State Manager (migration 41, Veda 13 Oct 2026): his own state only. No States, no Health, no State overview (its
  // content is his Overview); Season scopes read-only; the Ledger his state's, read-only.
  state_manager: {
    watch: [
      { to: '/', key: 'menu.overview', icon: '📊' },
      { to: '/pipeline', key: 'menu.pipeline', icon: '🔀' },
      { to: '/flags', key: 'nav.flags', icon: '🚩' },
    ],
    audit: [
      { to: '/system/ledger', key: 'nav.ledger', icon: '🔗' },
    ],
    master: [
      { to: '/clients', key: 'nav.clients', icon: '🏢' },
      { to: '/crops', key: 'menu.crops', icon: '🌿' },
      { to: '/setup', key: 'menu.setup', icon: '🗂' },                      // migration 51: labs, market profiles, places
      { to: '/scopes', key: 'nav.scopes', icon: '🎯' },
      { to: '/farmers', key: 'nav.farmers', icon: '👨‍🌾' },
      { to: '/farmers/register', key: 'menu.farmer_register', icon: '📒' },   // migration 43
    ],
    access: [
      { to: '/people', key: 'nav.people', icon: '👥' },
    ],
    me: [
      { to: '/onboarding', key: 'menu.my_checklist', icon: '✅', show: (w) => w.joiner },   // only while it has open steps
      { to: '/account', key: 'nav.account', icon: '🔑' },
      { to: '/guide', key: 'menu.guide', icon: '🧭' },
      { to: '/help', key: 'menu.help', icon: '💬' },
    ],
  },
  // The Client Manager (migration 48, D4; Veda 15 Oct 2026): his day first, then his scopes (and the stages of the
  // scope in hand), his farmers, his people, his client's ledger, himself.
  client_manager: {
    watch: [
      { to: '/', key: 'nav.home', icon: '📊' },
      { to: '/flags', key: 'nav.flags', icon: '🚩' },
    ],
    scopes: [
      { to: '/scopes', key: 'nav.scopes', icon: '🎯' },
      { to: '/setup', key: 'menu.setup', icon: '🗂' },                      // migration 51: his client's lists
    ],
    farmers: [
      { to: '/farmers', key: 'nav.farmers', icon: '👨‍🌾' },
      { to: '/farmers/new', key: 'home.add_farmer', icon: '➕' },
    ],
    people: [
      { to: '/people', key: 'nav.people', icon: '👥' },
    ],
    audit: [
      { to: '/system/ledger', key: 'nav.ledger', icon: '🔗' },
    ],
    me: [
      { to: '/onboarding', key: 'menu.my_checklist', icon: '✅', show: (w) => w.joiner },
      { to: '/outbox', key: 'nav.outbox', icon: '📥', show: (w) => !!w.outbox },
      { to: '/account', key: 'nav.account', icon: '🔑' },
      { to: '/guide', key: 'menu.guide', icon: '🧭' },
      { to: '/help', key: 'menu.help', icon: '💬' },
    ],
  },
};
/** Each grouped menu's headings, in order. */
export const MENU_HEADINGS: Record<Menu, string[]> = { admin: HEADINGS, state_manager: HEADINGS, client_manager: CM_HEADINGS };

/** Which grouped menu a person gets, if any: the admin's, the State Manager's, the Client Manager's (migration 48);
 *  everyone else the sectioned one. */
export const groupedMenu = (ctx: Parameters<typeof oversees>[0]): Menu | null =>
  oversees(ctx) ? 'admin' : ctx?.user?.can?.state_manager ? 'state_manager' : myClientAccounts(ctx).length > 0 ? 'client_manager' : null;

/** "Prasaadam Client Manager" → "PC": the first letters of the first two words, as in the prototype's top bar. */
export const initials = (name: string) => name.split(/\s+/).map((w) => w.replace(/[^\p{L}\p{N}]/gu, '')).filter(Boolean).slice(0, 2).map((w) => w[0]).join('').toUpperCase();

/** The word shown beside a person's name: the system role when it is one of the seats, else the summary role. */
export function roleWord(me: { role: Role; system_role?: string; status?: string; external?: boolean; client_account?: { kind: string } | null }, t: (k: string, v?: Record<string, string | number>, f?: string) => string): string {
  if (me.external && me.client_account?.kind) return t(`ca.role.${me.client_account.kind}`);       // migration 67: owner, viewer, client staff
  if (me.system_role && me.system_role !== 'operational' && me.system_role !== 'admin') return t(`sysrole.${me.system_role}`);
  if (!me.external && (me.status === 'invited' || me.status === 'onboarding')) return t('pstatus.onboarding');
  return t(`role.${me.role}`, undefined, humanise(me.role));
}

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
  const can = me?.can ?? { ...NO_RIGHTS, admin: me?.role === 'admin', assign: !!me && ['admin', 'state_manager', 'client_manager'].includes(me.role),
    state_lens: me?.role === 'admin' || me?.role === 'state_manager' };      // a server from before migration 32 sends no `can`
  const who: NavWho | null = me ? { role: me.role, can, farmerSlot, employee: !me.external,
    joiner: !me.external && ((ctx?.onboarding?.open ?? 0) > 0 || me.status === 'invited' || me.status === 'onboarding'),
    joining: !me.external && (me.status === 'invited' || me.status === 'onboarding'), outbox: box.items.length > 0 } : null;
  const visible = NAV.filter((n) => who && n.show(who));
  // HR's badge on Requirements: the new lines of her states (migration 46); read again on each page change
  const reqs = useAsync(() => can.hr ? rpc<{ new: number }>('hr_requirement_counts').catch(() => null) : Promise.resolve(null), [can.hr, pathname]);
  const badges: Record<string, number> = { '/hr/requirements': reqs.data?.new ?? 0 };
  const menu = groupedMenu(ctx);
  const inSection = (s: Section) => visible.filter((n) => n.section === s);
  // The scope the frame shows: the one this page belongs to (a stage page, a scope's dashboard), else the chosen one.
  const shown = shownScope(scopes, current, pathname);
  // Operations: the stages of that scope. Whoever reads it whole gets its chain; whoever holds stages there, those.
  // migration 59 (B1): the client's own login gets no stage pages (it reads its scopes through the dashboard)
  const stages = !shown || !me || isClientLogin(ctx) ? [] : !shown.whole                  // migration 67: the client's own staff get their stages
    ? ctx!.slots.filter((s) => s.scope_id === shown.id).map((s) => s.stage_type)
    : shown.status === 'draft' ? [] : shown.chain;
  const single = worksInOneScope(scopes);                  // only holds stages: one scope at a time, no "Overall"
  const item = (to: string, icon: string, label: string, end = false) => (
    <NavLink key={to} to={to} end={end}><span className="sb-icon" aria-hidden="true">{icon}</span>{label}
      {(badges[to] ?? 0) > 0 && <span className="nav-badge" data-testid="nav-badge" aria-label={t('req.badge', { n: badges[to] })}>{badges[to]}</span>}</NavLink>);
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
              <option value="">{t(single ? 'scope.choose' : 'scope.overall')}</option>
              {scopes.map((s) => <option key={s.id} value={s.id}>{s.label}{s.status === 'draft' ? ` ${t('scope.setup')}` : ''}</option>)}
            </select>
          </label>)}
        <span className="spacer" />
        {me && <span className="small who" data-testid="whoami"><span className="who-name">{me.display_name}</span><span className="who-role"><span className="dot-sep"> · </span>{roleWord(me, t)}</span></span>}
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
        {who && menu ? (
        <nav className="nav" aria-label="Main" data-menu={menu}>
          {MENU_HEADINGS[menu].map((h) => {
            // exact match where another item of the menu lives below this one (Farmers and its register)
            const all = (ROLE_MENUS[menu] as Record<string, MenuItem[]>)[h] ?? [];
            const items = all.filter((m) => !m.show || m.show(who)).map((m) => item(m.to, m.icon, t(m.key), m.to === '/' || all.some((o) => o.to.startsWith(`${m.to}/`))));
            return <Fragment key={h}>
              {items.length > 0 && <div className="sb-section" aria-hidden="true">{t(`menu.${h}`)}{h === 'master' && menu === 'admin' && <span className="sb-hint"> · {t('menu.read_only')}</span>}</div>}
              {items}
              {h === (menu === 'client_manager' ? 'scopes' : 'watch') && stages.length > 0 && section('nav.section_operations', stages.map((s) => item(`/work/${shown!.id}/${s}`, stageIcon(s), t(`stage.${s}`, undefined, humanise(s)))))}
            </Fragment>;
          })}
        </nav>) : (
        <nav className="nav" aria-label="Main">
          {section('nav.section_overview', inSection('overview').map((n) => item(n.to, n.icon, t(n.key), n.to === '/')))}
          {section('nav.section_registry', inSection('registry').map((n) => item(n.to, n.icon, t(n.key))))}
          {section('nav.section_people', inSection('people').map((n) => item(n.to, n.icon, t(n.key), n.to === '/hr')))}
          {section('nav.section_operations', stages.map((s) => item(`/work/${shown!.id}/${s}`, stageIcon(s), t(`stage.${s}`, undefined, humanise(s)))))}
          {section('nav.section_system', inSection('system').map((n) => item(n.to, n.icon, t(n.key))))}
          {section('nav.section_support', [
            ...(box.items.length > 0 || me?.role === 'operator' ? [item('/outbox', '📥', t('nav.outbox'))] : []),
            ...(me ? [item('/account', '🔑', t('nav.account'))] : []),
          ])}
        </nav>)}
        <main>{me && <Notices />}<ErrorBoundary key={pathname} fallback={(_e, retry) => <CrashCard retry={retry} />}><Outlet /></ErrorBoundary></main>
      </div>
    </>
  );
}
