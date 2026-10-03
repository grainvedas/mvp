// Entry: the public verify page loads on its own; the staff app is a separate chunk loaded only after sign-in routes.
import { lazy, Suspense } from 'react';
import { BrowserRouter, Route, Routes } from 'react-router-dom';
import { I18nProvider } from './lib/i18n';
import { Loading } from './shell/ui';
import { CrashCard, ErrorBoundary } from './shell/ErrorBoundary';
import { PracticeStrip } from './shell/PracticeStrip';
import { PublicVerify } from './pages/public/PublicVerify';

const PrivateApp = lazy(() => import('./PrivateApp'));

export function App() {
  return (
    <I18nProvider>
      <PracticeStrip />
      <ErrorBoundary fallback={(_e, retry) => <main><CrashCard retry={retry} /></main>}>
        <BrowserRouter>
          <Routes>
            <Route path="/verify/:code" element={<PublicVerify />} />
            <Route path="/*" element={<Suspense fallback={<main><Loading /></main>}><PrivateApp /></Suspense>} />
          </Routes>
        </BrowserRouter>
      </ErrorBoundary>
    </I18nProvider>
  );
}
