import { useEffect } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import { AuthProvider, useAuth } from './auth/AuthProvider';
import { SignIn } from './auth/SignIn';
import { MustSetPassword } from './auth/SetPassword';
import { registerDictionary, useI18n } from './lib/i18n';
import { en } from './lib/i18n.en';
import { hi } from './lib/i18n.hi';
import { Layout } from './shell/Layout';
import { ErrorBox, Loading } from './shell/ui';
import { isClientLogin } from './lib/rights';
import { Home } from './pages/Home';
import { StagePage } from './engine/StagePage';
import { RecordDetail } from './pages/records/RecordDetail';
import { FarmerForm, FarmerList } from './pages/farmers/Farmers';
import { FarmerPractice } from './pages/farmers/FarmerPractice';
import { FarmerImport } from './pages/farmers/FarmerImport';
import { FarmerRegister } from './pages/farmers/FarmerRegister';
import { ScopeList, ScopeWizard } from './pages/scopes/Scopes';
import { Crops, OpenFlags, States } from './pages/admin/Admin';
import { ClientPage, Clients, NewClient } from './pages/clients/Clients';   // migration 64: the client registry
import { PortfolioPage, ScopeView } from './pages/clients/Portfolio';   // migration 68: what client users see
import { SetupLists } from './pages/setup/SetupLists';
import { AddJoiner, JoinerPage, Templates } from './pages/hr/Hr';
import { ImportJoiners, JoinersList, Openings } from './pages/hr/Scale';
import { Requirements } from './pages/hr/Requirements';
import { HrTeam } from './pages/hr/Geo';
import { Checklist, Goals, TaskPage, Welcome } from './pages/onboarding/Onboarding';
import { AssignPage, Directory, ProfilePage, RosterPage, StateOverview } from './pages/people/People';
import { AuditLog, Seats } from './pages/system/System';
import { Ledger } from './pages/system/Ledger';
import { Safeguards } from './pages/system/Safeguards';
import { DailyCode } from './auth/DailyCode';
import { rpc } from './lib/api';
import { Health } from './pages/admin/Health';
import { Account } from './pages/Account';
import { Labels } from './pages/public/Labels';
import { PackLabels } from './pages/records/PackLabels';
import { Receipt } from './pages/records/Receipt';
import { ScopeDashboard } from './pages/dashboard/ScopeDashboard';
import { LotTrace } from './pages/trace/LotTrace';
import { Outbox } from './offline/OutboxPage';
import { PipelinePage } from './pages/admin/Pipeline';
import { GuideAgain, Help } from './pages/Help';
import type { ReactNode } from 'react';

// The signed-in app's words: the public page loads only its own (lib/i18n.public.ts, FIX_LIST K13).
registerDictionary('en', en);
registerDictionary('hi', hi);

/** The admin's pages (States, Health; migration 41): anyone else goes home. The database refuses them the writes anyway. */
export function AdminOnly({ children }: { children: ReactNode }) {
  const { ctx } = useAuth();
  return ctx?.user?.can?.admin ? <>{children}</> : <Navigate to="/" replace />;
}

/** Migration 59 (B1, Veda's brief of 19 Oct 2026): the client's own login reads only; no stage page opens for it (the
 *  database refuses its writes anyway). */
export function NotForClientLogin({ children }: { children: ReactNode }) {
  const { ctx } = useAuth();
  return isClientLogin(ctx) ? <Navigate to="/" replace /> : <>{children}</>;      // migration 67: the client's own staff work here
}

/** HR's screens open only for HR (and the admin while the HR Admin seat is empty): brief 2.2. Anyone else goes home. */
export function HrOnly({ children, orAdmin }: { children: ReactNode; orAdmin?: boolean }) {
  const { ctx } = useAuth();
  return ctx?.user?.can?.hr || (orAdmin && ctx?.user?.can?.admin) ? <>{children}</> : <Navigate to="/" replace />;
}

function Private() {
  const { session, ctx, loading, error, signOut, refresh } = useAuth();
  const { t } = useI18n();
  // First sign-in of an invited joiner: onboarding begins (the server moves invited → onboarding, once).
  const invited = ctx?.user?.status === 'invited' && !ctx.needs_daily_code;
  useEffect(() => { if (invited) void rpc('mark_first_login').then(() => refresh(), () => undefined); }, [invited, refresh]);
  if (loading) return <main><Loading /></main>;
  if (!session) return <SignIn />;
  // e.g. the very first start after signing in, with the network gone: nothing is kept on the phone yet
  if (error) return <main><ErrorBox error={error} onRetry={() => void refresh()} /></main>;
  if (!ctx?.user) return <main><div className="card" data-testid="no-access"><p>{t('signin.no_role')}</p><button onClick={() => void signOut()}>{t('nav.signout')}</button></div></main>;
  // The once-a-day sign-in code (switched off unless the admin turned it on): until today's is entered, nothing else opens.
  if (ctx.needs_daily_code) return <DailyCode />;
  // A login made by HR still has the temporary password HR saw: own password first.
  if (session.user.user_metadata?.must_change_password === true) return <MustSetPassword />;
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Home />} />
        <Route path="work/:scopeId/:stage" element={<NotForClientLogin><StagePage /></NotForClientLogin>} />
        <Route path="records/:id" element={<RecordDetail />} />
        <Route path="records/:id/labels" element={<PackLabels />} />   {/* migration 50: one label per pack */}
        <Route path="records/:id/receipt" element={<Receipt />} />   {/* migration 52: the farmer's receipt */}
        <Route path="farmers" element={<FarmerList />} />
        <Route path="farmers/new" element={<FarmerForm />} />
        <Route path="farmers/import" element={<FarmerImport />} />
        <Route path="farmers/register" element={<FarmerRegister />} />
        <Route path="farmers/:id" element={<FarmerForm />} />
        <Route path="farmers/:id/practice" element={<FarmerPractice />} />   {/* migration 47 */}
        <Route path="scopes" element={<ScopeList />} />
        <Route path="scopes/new" element={<ScopeWizard />} />
        <Route path="scopes/:id" element={<ScopeWizard />} />
        <Route path="users" element={<Navigate to="/people" replace />} />
        <Route path="onboarding" element={<Checklist />} />
        <Route path="onboarding/task/:id" element={<TaskPage />} />
        <Route path="welcome" element={<Welcome />} />
        <Route path="goals" element={<Goals />} />
        <Route path="hr" element={<HrOnly><JoinersList /></HrOnly>} />
        <Route path="hr/requirements" element={<HrOnly><Requirements /></HrOnly>} />   {/* migration 46 */}
        <Route path="hr/openings" element={<HrOnly orAdmin><Openings /></HrOnly>} />
        <Route path="hr/import" element={<HrOnly><ImportJoiners /></HrOnly>} />
        <Route path="hr/joiners/new" element={<HrOnly><AddJoiner /></HrOnly>} />
        <Route path="hr/joiners/:id" element={<HrOnly orAdmin><JoinerPage /></HrOnly>} />
        <Route path="hr/templates" element={<HrOnly><Templates /></HrOnly>} />
        <Route path="hr/team" element={<HrOnly><HrTeam /></HrOnly>} />
        <Route path="people" element={<Directory />} />
        <Route path="people/:id" element={<ProfilePage />} />
        <Route path="people/:id/assign" element={<AssignPage />} />
        <Route path="scopes/:id/roster" element={<RosterPage />} />
        <Route path="state" element={<StateOverview />} />
        <Route path="state/:id" element={<StateOverview />} />
        <Route path="system/seats" element={<Seats />} />
        <Route path="system/audit" element={<AuditLog />} />
        <Route path="system/ledger" element={<Ledger />} />
        <Route path="system/safeguards" element={<Safeguards />} />   {/* migration 45: the server decides who reads it */}
        <Route path="clients" element={<Clients />} />
        <Route path="clients/new" element={<NewClient />} />
        <Route path="clients/:id" element={<ClientPage />} />
        <Route path="portfolio" element={<PortfolioPage />} />   {/* migration 68: what client users see */}
        <Route path="portfolio/scope/:scopeId" element={<ScopeView />} />
        <Route path="portfolio/:clientId" element={<PortfolioPage />} />
        <Route path="states" element={<AdminOnly><States /></AdminOnly>} />
        <Route path="crops" element={<Crops />} />
        <Route path="setup" element={<SetupLists />} />   {/* migration 51: the set-up lists (Part B) */}
        <Route path="flags" element={<OpenFlags />} />
        <Route path="labels/:code" element={<Labels />} />
        <Route path="dashboard/:scopeId" element={<ScopeDashboard />} />
        <Route path="trace/:id" element={<LotTrace />} />
        <Route path="outbox" element={<Outbox />} />
        <Route path="account" element={<Account />} />
        <Route path="health" element={<AdminOnly><Health /></AdminOnly>} />
        <Route path="pipeline" element={<PipelinePage />} />
        <Route path="help" element={<Help />} />
        <Route path="guide" element={<GuideAgain />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}

export default function PrivateApp() {
  return <AuthProvider><Private /></AuthProvider>;
}
