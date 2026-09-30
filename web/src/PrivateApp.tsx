import { Navigate, Route, Routes } from 'react-router-dom';
import { AuthProvider, useAuth } from './auth/AuthProvider';
import { SignIn } from './auth/SignIn';
import { useI18n } from './lib/i18n';
import { Layout } from './shell/Layout';
import { ErrorBox, Loading } from './shell/ui';
import { Home } from './pages/Home';
import { StagePage } from './engine/StagePage';
import { RecordDetail } from './pages/records/RecordDetail';
import { FarmerForm, FarmerList } from './pages/farmers/Farmers';
import { FarmerImport } from './pages/farmers/FarmerImport';
import { ScopeList, ScopeWizard } from './pages/scopes/Scopes';
import { Clients, Crops, OpenFlags, States, Users } from './pages/admin/Admin';
import { Labels } from './pages/public/Labels';
import { ScopeDashboard } from './pages/dashboard/ScopeDashboard';
import { LotTrace } from './pages/trace/LotTrace';
import { Outbox } from './offline/OutboxPage';

function Private() {
  const { session, ctx, loading, error, signOut } = useAuth();
  const { t } = useI18n();
  if (loading) return <main><Loading /></main>;
  if (!session) return <SignIn />;
  if (error) return <main><ErrorBox error={error} /></main>;
  if (!ctx?.user) return <main><div className="card"><p>{t('signin.no_role')}</p><button onClick={() => void signOut()}>{t('nav.signout')}</button></div></main>;
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
        <Route path="users" element={<Users />} />
        <Route path="clients" element={<Clients />} />
        <Route path="states" element={<States />} />
        <Route path="crops" element={<Crops />} />
        <Route path="flags" element={<OpenFlags />} />
        <Route path="labels/:code" element={<Labels />} />
        <Route path="dashboard/:scopeId" element={<ScopeDashboard />} />
        <Route path="trace/:id" element={<LotTrace />} />
        <Route path="outbox" element={<Outbox />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}



export default function PrivateApp() {
  return <AuthProvider><Private /></AuthProvider>;
}
