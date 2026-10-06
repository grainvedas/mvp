import { useEffect } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import { AuthProvider, useAuth } from './auth/AuthProvider';
import { SignIn } from './auth/SignIn';
import { MustSetPassword } from './auth/SetPassword';
import { useI18n } from './lib/i18n';
import { Layout } from './shell/Layout';
import { ErrorBox, Loading } from './shell/ui';
import { Home } from './pages/Home';
import { StagePage } from './engine/StagePage';
import { RecordDetail } from './pages/records/RecordDetail';
import { FarmerForm, FarmerList } from './pages/farmers/Farmers';
import { FarmerImport } from './pages/farmers/FarmerImport';
import { ScopeList, ScopeWizard } from './pages/scopes/Scopes';
import { Clients, Crops, OpenFlags, States } from './pages/admin/Admin';
import { AddJoiner, HrPipeline, JoinerPage, Templates } from './pages/hr/Hr';
import { Checklist, Goals, TaskPage, Welcome } from './pages/onboarding/Onboarding';
import { AssignPage, Directory, ProfilePage, RosterPage, StateOverview } from './pages/people/People';
import { AuditLog, Seats } from './pages/system/System';
import { DailyCode } from './auth/DailyCode';
import { rpc } from './lib/api';
import { Health } from './pages/admin/Health';
import { Account } from './pages/Account';
import { Labels } from './pages/public/Labels';
import { ScopeDashboard } from './pages/dashboard/ScopeDashboard';
import { LotTrace } from './pages/trace/LotTrace';
import { Outbox } from './offline/OutboxPage';

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
        <Route path="work/:scopeId/:stage" element={<StagePage />} />
        <Route path="records/:id" element={<RecordDetail />} />
        <Route path="farmers" element={<FarmerList />} />
        <Route path="farmers/new" element={<FarmerForm />} />
        <Route path="farmers/import" element={<FarmerImport />} />
        <Route path="farmers/:id" element={<FarmerForm />} />
        <Route path="scopes" element={<ScopeList />} />
        <Route path="scopes/new" element={<ScopeWizard />} />
        <Route path="scopes/:id" element={<ScopeWizard />} />
        <Route path="users" element={<Navigate to="/people" replace />} />
        <Route path="onboarding" element={<Checklist />} />
        <Route path="onboarding/task/:id" element={<TaskPage />} />
        <Route path="welcome" element={<Welcome />} />
        <Route path="goals" element={<Goals />} />
        <Route path="hr" element={<HrPipeline />} />
        <Route path="hr/joiners/new" element={<AddJoiner />} />
        <Route path="hr/joiners/:id" element={<JoinerPage />} />
        <Route path="hr/templates" element={<Templates />} />
        <Route path="people" element={<Directory />} />
        <Route path="people/:id" element={<ProfilePage />} />
        <Route path="people/:id/assign" element={<AssignPage />} />
        <Route path="scopes/:id/roster" element={<RosterPage />} />
        <Route path="state" element={<StateOverview />} />
        <Route path="state/:id" element={<StateOverview />} />
        <Route path="system/seats" element={<Seats />} />
        <Route path="system/audit" element={<AuditLog />} />
        <Route path="clients" element={<Clients />} />
        <Route path="states" element={<States />} />
        <Route path="crops" element={<Crops />} />
        <Route path="flags" element={<OpenFlags />} />
        <Route path="labels/:code" element={<Labels />} />
        <Route path="dashboard/:scopeId" element={<ScopeDashboard />} />
        <Route path="trace/:id" element={<LotTrace />} />
        <Route path="outbox" element={<Outbox />} />
        <Route path="account" element={<Account />} />
        <Route path="health" element={<Health />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}

export default function PrivateApp() {
  return <AuthProvider><Private /></AuthProvider>;
}
