// Field error log (PRD §9 observability "error tracking"): what goes wrong on an operator's phone reaches the admin's
// Health page through app.report_client_error (migration 23). No third-party service: nothing leaves the project.
//   - never throws, never blocks: reporting must not be able to break the app
//   - the same message is sent once per page load, 20 reports per load at most (the server also limits per hour)
//   - "no network" is not an error here: the outbox owns that case
//   - a report made with no connection waits on the phone (20 at most) and is sent when the network is back
import { appDb } from './supabase';

declare const __BUILD_ID__: string;
export const BUILD_ID: string = typeof __BUILD_ID__ === 'string' ? __BUILD_ID__ : 'dev';

export type ErrorKind = 'error' | 'rejection' | 'boundary' | 'sync_refused';
interface Report {
  id: string; kind: ErrorKind; message: string; detail: string | null;
  path: string; build: string; online: boolean; agent: string; at: string;
}

const NOISE = /Failed to fetch|NetworkError|Load failed|network request failed|AbortError|The user aborted|ResizeObserver loop|^Script error\.?$|JWT expired|Auth session missing|Invalid Refresh Token/i;
const KEY = 'grainveda-errlog';
const MAX_PER_LOAD = 20;
const MAX_WAITING = 20;
const seen = new Set<string>();
let sent = 0;

/** Decides whether a problem is worth a report. Pure apart from the per-page-load memory. */
export function shouldReport(kind: ErrorKind, message: string): boolean {
  const msg = message.trim();
  if (!msg) return false;
  if (kind !== 'sync_refused' && NOISE.test(msg)) return false;
  const key = `${kind}:${msg}`;
  if (seen.has(key) || sent >= MAX_PER_LOAD) return false;
  seen.add(key); sent++;
  return true;
}
/** Tests only. */
export function resetErrorLogForTests() { seen.clear(); sent = 0; }

function waiting(): Report[] {
  try { const v = JSON.parse(localStorage.getItem(KEY) ?? '[]'); return Array.isArray(v) ? v as Report[] : []; } catch { return []; }
}
function keep(list: Report[]) {
  try { if (list.length) localStorage.setItem(KEY, JSON.stringify(list.slice(-MAX_WAITING))); else localStorage.removeItem(KEY); } catch { /* storage full or blocked */ }
}

async function send(r: Report, late = false): Promise<'sent' | 'retry' | 'drop'> {
  try {
    const { error } = await appDb.rpc('report_client_error', {
      p_kind: r.kind, p_message: r.message,
      p_detail: late ? `[happened ${r.at}, sent later] ${r.detail ?? ''}` : r.detail,
      p_path: r.path, p_build: r.build, p_online: r.online, p_agent: r.agent,
    });
    if (!error) return 'sent';
    return NOISE.test(error.message ?? '') ? 'retry' : 'drop';       // refused (signed out, older database): do not keep it
  } catch { return 'retry'; }
}

let flushing = false;
/** Sends what waited on the phone. Stops at the first report that still cannot be sent. */
export async function flushErrorLog(): Promise<void> {
  if (flushing) return;
  flushing = true;
  try {
    for (const r of waiting()) {
      if ((await send(r, true)) === 'retry') break;
      keep(waiting().filter((x) => x.id !== r.id));
    }
  } finally { flushing = false; }
}

export function reportError(kind: ErrorKind, message: unknown, detail?: unknown): void {
  try {
    const msg = String(message ?? '').trim().slice(0, 500);
    if (!shouldReport(kind, msg)) return;
    const r: Report = {
      id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`, kind, message: msg,
      detail: detail === undefined || detail === null ? null : String(detail).slice(0, 2000),
      path: window.location.pathname, build: BUILD_ID, online: navigator.onLine, agent: navigator.userAgent.slice(0, 300),
      at: new Date().toISOString(),
    };
    void send(r).then((res) => { if (res === 'retry') keep([...waiting(), r]); }, () => undefined);
  } catch { /* reporting never breaks the app */ }
}

let installed = false;
/** Uncaught errors and unhandled promise rejections anywhere in the app. Call once at start. */
export function installErrorLog(): void {
  if (installed || typeof window === 'undefined') return;
  installed = true;
  window.addEventListener('error', (e) => {
    reportError('error', e.message || String(e.error ?? ''), (e.error as Error | undefined)?.stack ?? `${e.filename}:${e.lineno}:${e.colno}`);
  });
  window.addEventListener('unhandledrejection', (e) => {
    const r = e.reason as { message?: string; stack?: string } | string | null | undefined;
    reportError('rejection', typeof r === 'string' ? r : r?.message ?? String(r), typeof r === 'string' ? undefined : r?.stack);
  });
  window.addEventListener('online', () => { void flushErrorLog(); });
  void flushErrorLog();
}
