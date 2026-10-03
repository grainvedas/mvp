// Phase 4 unit checks: no screen shows a raw translation key, the Commercial market gate, the field error log's
// filter, the crash screen, the password rule, the journey export of withdrawn / replacement records.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { en } from '../src/lib/i18n.en';
import { Widget } from '../src/engine/widgets';
import { passwordProblem } from '../src/auth/SetPassword';
import { sessionExpired } from '../src/auth/AuthProvider';
import { daysWaiting } from '../src/pages/admin/Health';
import { TRACE_HEADER, traceRows, type Trace } from '../src/pages/trace/LotTrace';
import type { FieldDef, StageDefinition } from '../src/lib/types';
import defs from './fixtures/stage_definitions.json';

vi.mock('../src/lib/supabase', () => {
  const rpc = vi.fn(async () => ({ data: true, error: null }));
  return { appDb: { rpc }, supabase: { auth: {} }, SUPABASE_URL: 'http://test.local', SUPABASE_ANON_KEY: 'k', configured: true };
});
import { appDb } from '../src/lib/supabase';
import { reportError, resetErrorLogForTests, shouldReport } from '../src/lib/errorLog';
import { CrashCard, ErrorBoundary } from '../src/shell/ErrorBoundary';

const stages = defs as unknown as StageDefinition[];
const rpc = appDb.rpc as unknown as ReturnType<typeof vi.fn>;
afterEach(() => cleanup());

function sourceFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? sourceFiles(p) : /\.tsx?$/.test(n) && !/i18n\.(en|hi)\.ts$/.test(n) ? [p] : [];
  });
}

describe('translations', () => {
  it('every key the screens ask for exists in English (so no screen can show a raw key)', () => {
    const missing: string[] = [];
    for (const file of sourceFiles(join(__dirname, '..', 'src'))) {
      const src = readFileSync(file, 'utf8');
      // t('a.b'), t("a.b"), and keys passed by name: submitKey="a.b" / key: 'a.b' in the nav table
      const keys = [...src.matchAll(/\bt\(\s*['"]([a-z_0-9]+\.[A-Za-z_0-9.]+)['"]/g), ...src.matchAll(/\b(?:key|submitKey)\s*[:=]\s*\{?['"]([a-z_0-9]+\.[a-z_0-9.]+)['"]/g)]
        .map((m) => m[1]);
      // t(cond ? 'a.b' : 'c.d')
      for (const m of src.matchAll(/\bt\(([^()]*\?[^()]*:[^()]*)\)/g)) for (const k of m[1].matchAll(/['"]([a-z_0-9]+\.[a-z_0-9.]+)['"]/g)) keys.push(k[1]);
      for (const k of keys) if (!(k in en)) missing.push(`${file.replace(/.*\/src\//, 'src/')}: ${k}`);
    }
    expect(missing).toEqual([]);
  });
});

describe('operator screens speak the reader\'s language', () => {
  // PRD §9: "UI in English and Hindi for operator screens". The dictionary tests prove every key has Hindi; this one
  // proves the screens an operator sees do not carry words of their own that bypass the dictionary. A heuristic: plain
  // words between two tags, and words in the attributes a person sees or hears.
  const OPERATOR_SCREENS = ['auth', 'engine', 'offline', 'shell', 'pages/Home.tsx', 'pages/Account.tsx', 'pages/records', 'pages/farmers',
    'pages/public', 'App.tsx', 'PrivateApp.tsx'];
  const ALLOWED = new Set([
    'GrainVeda', 'English',                                  // the brand; the language's own name in the switch
    'Language', 'Main', 'Steps',                             // names of three page regions for screen readers (and the tests' hooks)
    'Scan to see who grew it and how it was tested', 'Batch',   // printed on the pack label itself, not a screen
  ]);
  it('no plain English text or label outside the translation table', () => {
    const src = join(__dirname, '..', 'src');
    const files = OPERATOR_SCREENS.flatMap((p) => (p.endsWith('.tsx') ? [join(src, p)] : sourceFiles(join(src, p)))).filter((f) => f.endsWith('.tsx'));
    expect(files.length).toBeGreaterThan(15);
    const found: string[] = [];
    for (const file of files) {
      readFileSync(file, 'utf8').split('\n').forEach((raw, n) => {
        if (/^\s*(\/\/|\*|\/\*)/.test(raw)) return;
        const line = raw.replace(/\/\/.*$/, '');
        const hits = [
          ...[...line.matchAll(/(?<!=)>([^<>{}()=;'"`&|?]*[A-Za-z]{2,}[^<>{}()=;'"`&|?]*)</g)].map((m) => m[1]),
          ...[...line.matchAll(/\b(?:placeholder|title|label|hint|alt|aria-label)=(?:"([^"]*)"|\{`([^`]*)`\}|\{'([^']*)'\})/g)]
            .map((m) => (m[1] ?? m[2] ?? m[3] ?? '').replace(/\$\{[^}]*\}/g, '')),
        ].map((x) => x.trim()).filter((x) => /[A-Za-z]{2,}/.test(x));
        for (const h of hits) if (!ALLOWED.has(h) && !/^QR( code)?$/.test(h)) found.push(`${file.replace(/.*\/src\//, 'src/')}:${n + 1}: ${h}`);
      });
    }
    expect(found).toEqual([]);
  });
});

describe('Commercial market gate (PRD §12 T3)', () => {
  const market = stages.find((s) => s.stage_type === 'commercial')!.form_schema.find((f) => f.key === 'market') as FieldDef;
  const options = (allowed?: string[]) => {
    const { container } = render(<Widget id="m" field={market} value="" onChange={() => {}} qualityParams={[]} clientId="c" allowed={allowed} />);
    return [...container.querySelectorAll('option')].map((o) => o.getAttribute('value')).filter(Boolean);
  };
  it('the stage definition marks the market field as gated on the lab verdict', () => expect(market.gate).toBe('market_verdict'));
  it('a domestic-only lot is not offered for export', () => expect(options(['domestic'])).toEqual(['domestic']));
  it('an export-passed (or overridden) lot is offered both', () => expect(options(['domestic', 'export'])).toEqual(['domestic', 'export']));
  it('until the server has answered, nothing is hidden (the database still refuses a wrong sale)', () => expect(options(undefined)).toEqual(['domestic', 'export']));
});

describe('field error log', () => {
  beforeEach(() => { resetErrorLogForTests(); rpc.mockClear(); localStorage.clear(); });
  it('ignores "no network" and browser noise, reports real errors once', () => {
    expect(shouldReport('rejection', 'TypeError: Failed to fetch')).toBe(false);
    expect(shouldReport('error', 'ResizeObserver loop completed with undelivered notifications.')).toBe(false);
    expect(shouldReport('error', 'Script error.')).toBe(false);
    expect(shouldReport('error', '   ')).toBe(false);
    expect(shouldReport('error', "Cannot read properties of undefined (reading 'qty_out')")).toBe(true);
    expect(shouldReport('error', "Cannot read properties of undefined (reading 'qty_out')")).toBe(false);      // same message again
  });
  it('a refused sync is always worth a report, whatever its words', () => {
    expect(shouldReport('sync_refused', 'Milling: network of mills not allowed')).toBe(true);
  });
  it('stops after 20 reports per page load (a looping screen)', () => {
    const accepted = Array.from({ length: 30 }, (_, i) => shouldReport('error', `boom ${i}`)).filter(Boolean).length;
    expect(accepted).toBe(20);
  });
  it('sends kind, message, screen, build and connection state to the server', async () => {
    reportError('boundary', 'x is not a function', 'stack…');
    await vi.waitFor(() => expect(rpc).toHaveBeenCalledTimes(1));
    expect(rpc.mock.calls[0][0]).toBe('report_client_error');
    expect(rpc.mock.calls[0][1]).toMatchObject({ p_kind: 'boundary', p_message: 'x is not a function', p_detail: 'stack…', p_path: '/', p_online: true });
  });
  it('a report made with no connection waits on the phone', async () => {
    rpc.mockResolvedValueOnce({ data: null, error: { message: 'TypeError: Failed to fetch' } });
    reportError('error', 'offline crash');
    await vi.waitFor(() => expect(JSON.parse(localStorage.getItem('grainveda-errlog') ?? '[]')).toHaveLength(1));
  });
  it('never throws, even if the server call does', () => {
    rpc.mockRejectedValueOnce(new Error('down'));
    expect(() => reportError('error', 'whatever')).not.toThrow();
  });
});

describe('crash screen', () => {
  beforeEach(() => { resetErrorLogForTests(); rpc.mockClear(); });
  it('a screen that throws shows the message instead of a blank page, and reports it', async () => {
    const Broken = (): never => { throw new Error('qty_out of undefined'); };
    const quiet = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    render(<ErrorBoundary fallback={(_e, retry) => <CrashCard retry={retry} />}><Broken /></ErrorBoundary>);
    quiet.mockRestore();
    expect(screen.getByTestId('crash').textContent).toContain('This screen stopped working');
    await vi.waitFor(() => expect(rpc).toHaveBeenCalled());
    expect(rpc.mock.calls[0][1]).toMatchObject({ p_kind: 'boundary', p_message: 'qty_out of undefined' });
  });
});

describe('own password', () => {
  it('at least 8 characters, typed the same twice', () => {
    expect(passwordProblem('short', 'short')).toBe('short');
    expect(passwordProblem('long-enough', 'long-enoug')).toBe('mismatch');
    expect(passwordProblem('long-enough', 'long-enough')).toBeNull();
  });
});

describe('session length (PRD §9: 12 h on web for managers, 30 days on the operator\'s phone)', () => {
  const now = Date.parse('2026-11-10T12:00:00Z');
  const ago = (h: number) => new Date(now - h * 3600_000).toISOString();
  it('a manager is signed out 12 hours after signing in', () => {
    expect(sessionExpired('client_manager', ago(11.9), now)).toBe(false);
    expect(sessionExpired('client_manager', ago(12.1), now)).toBe(true);
    expect(sessionExpired('admin', ago(13), now)).toBe(true);
    expect(sessionExpired('client_view', ago(13), now)).toBe(true);
  });
  it('an operator stays signed in for 30 days', () => {
    expect(sessionExpired('operator', ago(24 * 29), now)).toBe(false);
    expect(sessionExpired('operator', ago(24 * 31), now)).toBe(true);
  });
  it('an unknown sign-in time never signs anyone out', () => expect(sessionExpired('admin', undefined, now)).toBe(false));
});

describe('health page', () => {
  it('counts whole days a record has waited', () => {
    const now = Date.parse('2026-11-10T12:00:00Z');
    expect(daysWaiting('2026-11-10T09:00:00Z', now)).toBe(0);
    expect(daysWaiting('2026-11-07T11:00:00Z', now)).toBe(3);
  });
});

describe('journey export', () => {
  const step = { id: '1', code: 'PRSDM-KNM-KH26-M-0002', stage: 'milling', stage_label: 'Milling', status: 'verified', prev_id: null,
    qty_in_kg: 119, qty_out_kg: 90, grade: null, payload: {}, computed: {}, warnings: [], farmer: null, created_at: 'a', created_by: 'Mill',
    verified_at: null, verified_by: null, qc: null, seal: null, flags: [], evidence: [], ledger: [] };
  it('a replacement names what it replaces and why; a withdrawn record says who withdrew it', () => {
    const tr: Trace = { footprint_id: '1', generated_at: 'now', steps: [
      { ...step, replaces: { code: 'PRSDM-KNM-KH26-M-0001', qty_out_kg: 80, reason: 'bran typed as 30, was 20', by: 'Client Manager', at: 't' } },
      { ...step, id: '0', status: 'superseded', withdrawn: { reason: 'bran typed as 30, was 20', by: 'Client Manager', at: 't' } },
    ] };
    const rows = traceRows(tr);
    expect(rows[0]).toHaveLength(TRACE_HEADER.length);
    expect(rows[0][TRACE_HEADER.indexOf('replaces')]).toBe('PRSDM-KNM-KH26-M-0001 (80 kg) withdrawn by Client Manager: bran typed as 30, was 20');
    expect(rows[1][TRACE_HEADER.indexOf('withdrawn')]).toBe('t · Client Manager: bran typed as 30, was 20');
  });
  it('an ordinary step leaves both columns empty (older servers do not send the keys)', () => {
    const rows = traceRows({ footprint_id: '1', generated_at: 'now', steps: [step] });
    expect(rows[0][TRACE_HEADER.indexOf('withdrawn')]).toBe('');
    expect(rows[0][TRACE_HEADER.indexOf('replaces')]).toBe('');
  });
});
