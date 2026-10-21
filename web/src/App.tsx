// Entry: the public verify page loads on its own; the staff app is a separate chunk loaded only after sign-in routes.
import { lazy, Suspense } from 'react';
import { BrowserRouter, Route, Routes } from 'react-router-dom';
import { I18nProvider } from './lib/i18n';
import { Loading } from './shell/ui';
import { CrashCard, ErrorBoundary } from './shell/ErrorBoundary';
import { PracticeStrip } from './shell/PracticeStrip';
import { PublicVerify } from './pages/public/PublicVerify';
import { PublicPack } from './pages/public/PublicPack';
import { DocumentVerify } from './pages/public/DocumentVerify';

const PrivateApp = lazy(() => import('./PrivateApp'));
const InvitePage = lazy(() => import('./pages/public/Invite'));
const BuyerView = lazy(() => import('./pages/public/BuyerView'));   // migration 56 (Part F): a buyer's link

export function App() {
  return (
    <I18nProvider>
      <PracticeStrip />
      <ErrorBoundary fallback={(_e, retry) => <main><CrashCard retry={retry} /></main>}>
        <BrowserRouter>
          <Routes>
            <Route path="/verify/:code" element={<PublicVerify />} />
            <Route path="/p/:serial" element={<PublicPack />} />   {/* migration 50: one pack's own QR */}
            <Route path="/d/:ref" element={<DocumentVerify />} />   {/* migration 63 (Part D3): "Verify this document" */}
            <Route path="/invite" element={<Suspense fallback={<main><Loading /></main>}><InvitePage /></Suspense>} />
            <Route path="/b" element={<Suspense fallback={<main><Loading /></main>}><BuyerView /></Suspense>} />
            <Route path="/*" element={<Suspense fallback={<main><Loading /></main>}><PrivateApp /></Suspense>} />
          </Routes>
        </BrowserRouter>
      </ErrorBoundary>
    </I18nProvider>
  );
}
