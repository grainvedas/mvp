import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';
import { BUILD_ID, installErrorLog } from './lib/errorLog';
import './styles.css';

installErrorLog();
createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>);

// The app shell opens with no network after one online visit (public/sw.js). Production builds only: the dev server
// serves unbundled modules that the worker should not cache.
if (import.meta.env.PROD && 'serviceWorker' in navigator) {
  window.addEventListener('load', () => { void navigator.serviceWorker.register(`/sw.js?v=${BUILD_ID}`).catch(() => undefined); });
}
