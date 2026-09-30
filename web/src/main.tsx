import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';
import './styles.css';

createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>);

declare const __BUILD_ID__: string;
// The app shell opens with no network after one online visit (public/sw.js). Production builds only: the dev server
// serves unbundled modules that the worker should not cache.
if (import.meta.env.PROD && 'serviceWorker' in navigator) {
  window.addEventListener('load', () => { void navigator.serviceWorker.register(`/sw.js?v=${__BUILD_ID__}`).catch(() => undefined); });
}
