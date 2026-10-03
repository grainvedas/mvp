// A screen that throws while drawing shows a plain message instead of a blank page, and the problem is reported to
// the admin's Health page (src/lib/errorLog.ts). Around the whole app (App.tsx) and around each routed screen
// (Layout.tsx, keyed by path, so the menu keeps working and moving to another screen clears the message).
import { Component, type ErrorInfo, type ReactNode } from 'react';
import { reportError } from '../lib/errorLog';
import { useI18n } from '../lib/i18n';

// A tab left open across a deploy asks for a file of the old build that the host no longer serves.
const STALE_BUILD = /dynamically imported module|Importing a module script failed|ChunkLoadError|Unable to preload CSS/i;
const RELOADED = 'grainveda-reloaded';

interface Props { children: ReactNode; fallback: (error: Error, retry: () => void) => ReactNode }

export class ErrorBoundary extends Component<Props, { error: Error | null }> {
  state: { error: Error | null } = { error: null };
  static getDerivedStateFromError(error: Error) { return { error }; }
  componentDidCatch(error: Error, info: ErrorInfo) {
    if (STALE_BUILD.test(error.message)) {
      try {
        if (!sessionStorage.getItem(RELOADED)) { sessionStorage.setItem(RELOADED, '1'); window.location.reload(); return; }   // once
      } catch { /* no session storage: show the message */ }
    }
    reportError('boundary', error.message, `${error.stack ?? ''}\n${info.componentStack ?? ''}`);
  }
  render() {
    return this.state.error ? this.props.fallback(this.state.error, () => this.setState({ error: null })) : this.props.children;
  }
}

export function CrashCard({ retry }: { retry: () => void }) {
  const { t } = useI18n();
  return (
    <div className="card" role="alert" data-testid="crash">
      <h1>{t('crash.title')}</h1>
      <p>{t('crash.body')}</p>
      <div className="row">
        <button onClick={retry}>{t('common.retry')}</button>
        <button className="secondary" onClick={() => window.location.assign('/')}>{t('nav.home')}</button>
      </div>
    </div>
  );
}
