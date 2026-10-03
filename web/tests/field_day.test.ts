// A day in the field, unit level: the login kept on the phone, the token a request is sent with, the copy kept for
// offline work, and what counts as "no connection". The same behaviour is tested end to end against the built app in
// e2e-prod/field_day.spec.ts.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const lib = vi.hoisted(() => ({ getSession: vi.fn(), store: new Map<string, unknown>() }));
vi.mock('@supabase/supabase-js', () => ({
  createClient: vi.fn((_url: string, _key: string, opts?: { accessToken?: unknown }) => (opts?.accessToken
    ? { from: vi.fn(), storage: {}, schema: vi.fn(() => ({ rpc: vi.fn() })) }
    : { auth: { getSession: () => lib.getSession() } })),
}));
// IndexedDB is not in the test browser: the same five calls over a Map.
vi.mock('../src/offline/idb', () => ({
  available: () => true,
  idbGet: async (_s: string, k: string) => lib.store.get(k),
  idbPut: async (_s: string, v: unknown, k: string) => { lib.store.set(k, v); return k; },
  idbClear: async () => { lib.store.clear(); },
  idbDel: async (_s: string, k: string) => { lib.store.delete(k); },
  idbAll: async () => [...lib.store.values()],
}));

import { AUTH_STORAGE_KEY, forgetLogin, keptLogin, tokenRunOut } from '../src/lib/keptLogin';
import { accessToken, renewLogin, RENEW_WAIT_MS, resetRenewalForTests } from '../src/lib/supabase';
import { cached, DEAD_LINK_MS, forgetAll, resetCacheForTests, SLOW_MS } from '../src/offline/cache';
import { AppError, toAppError } from '../src/lib/errors';
import { within } from '../src/lib/api';

const NOW = Date.parse('2026-11-10T06:00:00Z');
const login = (secondsLeft: number, token = 'tok-1', user = 'user-1') => ({
  access_token: token, refresh_token: 'renew-1', token_type: 'bearer', expires_in: 3600,
  expires_at: Math.floor(NOW / 1000) + secondsLeft, user: { id: user } });
const keep = (s: unknown) => localStorage.setItem(AUTH_STORAGE_KEY, JSON.stringify(s));
const online = (v: boolean) => Object.defineProperty(window.navigator, 'onLine', { configurable: true, get: () => v });
const noNetwork = () => new TypeError('Failed to fetch');

beforeEach(() => {
  vi.useFakeTimers({ now: NOW });
  localStorage.clear(); lib.store.clear(); lib.getSession.mockReset(); resetCacheForTests(); resetRenewalForTests(); online(true);
});
afterEach(() => { vi.useRealTimers(); });

describe('the login kept on this phone', () => {
  it('is read from storage, with no network call', () => {
    expect(keptLogin()).toBeNull();
    keep(login(3600));
    expect(keptLogin()?.user.id).toBe('user-1');
    expect(lib.getSession).not.toHaveBeenCalled();
  });
  it('anything that is not a whole login counts as nobody', () => {
    for (const bad of ['not json', 'null', '{}', JSON.stringify({ access_token: 'a', refresh_token: 'r' }),
      JSON.stringify({ access_token: 'a', refresh_token: '', expires_at: 1, user: { id: 'u' } }),
      JSON.stringify({ access_token: 'a', refresh_token: 'r', expires_at: 1, user: {} })]) {
      localStorage.setItem(AUTH_STORAGE_KEY, bad);
      expect(keptLogin(), bad).toBeNull();
    }
  });
  it('a token with under 90 seconds left counts as run out', () => {
    expect(tokenRunOut(login(91), NOW)).toBe(false);
    expect(tokenRunOut(login(89), NOW)).toBe(true);
    expect(tokenRunOut(login(-7200), NOW)).toBe(true);
    expect(tokenRunOut({ expires_at: undefined }, NOW)).toBe(true);
  });
  it('can be removed on this phone without the server', () => {
    keep(login(3600)); forgetLogin();
    expect(keptLogin()).toBeNull();
  });
});

describe('the token a request is sent with', () => {
  it('nobody signed in: none (the public key is used, as for the public verify page)', async () => {
    await expect(accessToken()).resolves.toBeNull();
    expect(lib.getSession).not.toHaveBeenCalled();
  });
  it('a fresh token: that one, nothing is renewed', async () => {
    keep(login(3600));
    await expect(accessToken()).resolves.toBe('tok-1');
    expect(lib.getSession).not.toHaveBeenCalled();
  });
  it('hour over, browser says no network: the request is not sent and no renewal is tried', async () => {
    keep(login(-7200)); online(false);
    await expect(accessToken()).rejects.toThrow('Failed to fetch');
    expect(lib.getSession).not.toHaveBeenCalled();
  });
  it('hour over, renewal works: the new token', async () => {
    keep(login(-7200));
    lib.getSession.mockImplementation(async () => { keep(login(3600, 'tok-2')); return { data: { session: {} }, error: null }; });
    await expect(accessToken()).resolves.toBe('tok-2');
  });
  it('hour over, renewal fails: the request is not sent. It never falls back to the public key', async () => {
    keep(login(-7200));
    lib.getSession.mockResolvedValue({ data: { session: null }, error: noNetwork() });
    const answer = await accessToken().then((v) => ({ sent: v }), (e: Error) => ({ refused: e.message }));
    expect(answer).toEqual({ refused: 'Failed to fetch' });
    expect(toAppError(noNetwork()).kind).toBe('network');   // which every screen and the outbox treat as "no connection"
  });
  it('hour over, the server ended the login during the renewal: still not sent', async () => {
    keep(login(-7200));
    lib.getSession.mockImplementation(async () => { forgetLogin(); return { data: { session: null }, error: new Error('Invalid Refresh Token') }; });
    await expect(accessToken()).rejects.toThrow('Failed to fetch');
    expect(keptLogin()).toBeNull();
  });
  it('a renewal that does not answer is waited for 8 seconds, not for as long as the library retries', async () => {
    keep(login(-7200));
    lib.getSession.mockReturnValue(new Promise(() => { /* never */ }));
    let outcome = 'waiting';
    void accessToken().then(() => { outcome = 'sent'; }, () => { outcome = 'not sent'; });
    await vi.advanceTimersByTimeAsync(RENEW_WAIT_MS - 100);
    expect(outcome).toBe('waiting');
    await vi.advanceTimersByTimeAsync(200);
    expect(outcome).toBe('not sent');
    // while that renewal is still under way, the next request does not wait again
    let second = 'waiting';
    void accessToken().then(() => { second = 'sent'; }, () => { second = 'not sent'; });
    await vi.advanceTimersByTimeAsync(1);
    expect(second).toBe('not sent');
    expect(lib.getSession).toHaveBeenCalledTimes(1);
  });
  it('requests made at the same moment share one renewal', async () => {
    keep(login(-7200));
    lib.getSession.mockImplementation(async () => { keep(login(3600, 'tok-2')); return { data: { session: {} }, error: null }; });
    await expect(Promise.all([accessToken(), accessToken(), renewLogin()])).resolves.toEqual(['tok-2', 'tok-2', true]);
    expect(lib.getSession).toHaveBeenCalledTimes(1);
  });
});

describe('the copy kept on the phone for offline work', () => {
  beforeEach(() => keep(login(3600)));
  it('the server answers: its answer, and it is kept', async () => {
    await expect(cached('form', async () => 'v1')).resolves.toBe('v1');
    expect(lib.store.get('user-1:form')).toMatchObject({ v: 'v1' });
  });
  it('no network: the kept copy; nothing kept: the error', async () => {
    await cached('form', async () => 'v1');
    await expect(cached('form', async () => { throw noNetwork(); })).resolves.toBe('v1');
    await expect(cached('other', async () => { throw noNetwork(); })).rejects.toThrow('Failed to fetch');
  });
  it('is found again after the hour is over (the key is the person, not the token)', async () => {
    await cached('form', async () => 'v1');
    keep(login(-7200));
    await expect(cached('form', async () => { throw noNetwork(); })).resolves.toBe('v1');
  });
  it('the server refuses: that is the answer, the kept copy is not shown instead', async () => {
    await cached('form', async () => 'v1');
    const refusal = new AppError('no access to this scope', '42501', 'permission');
    await expect(cached('form', async () => { throw refusal; })).rejects.toBe(refusal);
  });
  it('one person never gets another person\'s copy', async () => {
    await cached('form', async () => 'for user 1');
    keep(login(3600, 'tok-9', 'user-2'));
    await expect(cached('form', async () => { throw noNetwork(); })).rejects.toThrow('Failed to fetch');
  });
  it('a dead link: the kept copy after 8 s, then at once for the next screens, until an answer arrives', async () => {
    await cached('form', async () => 'kept');
    await cached('farmers', async () => 'kept farmers');
    const never = () => new Promise<string>(() => { /* taken, never answered */ });
    let got: string | undefined;
    void cached('form', never).then((v) => { got = v; });
    await vi.advanceTimersByTimeAsync(SLOW_MS - 100);
    expect(got).toBeUndefined();
    await vi.advanceTimersByTimeAsync(200);
    expect(got).toBe('kept');
    let next: string | undefined;
    void cached('farmers', never).then((v) => { next = v; });
    await vi.advanceTimersByTimeAsync(1);
    expect(next).toBe('kept farmers');                      // no second wait
    await expect(cached('form', async () => 'fresh')).resolves.toBe('kept');   // still remembered as dead for this call…
    await vi.advanceTimersByTimeAsync(1);
    await expect(cached('form', async () => 'fresher')).resolves.toBe('fresher');   // …but that answer ended it
    expect(DEAD_LINK_MS).toBeGreaterThan(SLOW_MS);
  });
  it('a dead link and nothing kept: keeps waiting for the server', async () => {
    let answer: (v: string) => void = () => undefined;
    let got: string | undefined;
    void cached('form', () => new Promise<string>((r) => { answer = r; })).then((v) => { got = v; });
    await vi.advanceTimersByTimeAsync(SLOW_MS + 5000);
    expect(got).toBeUndefined();
    answer('late'); await vi.advanceTimersByTimeAsync(1);
    expect(got).toBe('late');
  });
  it('an answer that arrives after signing out is not kept', async () => {
    let answer: (v: string) => void = () => undefined;
    const p = cached('form', () => new Promise<string>((r) => { answer = r; }));
    forgetLogin(); await forgetAll();
    answer('late'); await p;
    expect(lib.store.size).toBe(0);
  });
});

describe('what counts as "no connection"', () => {
  it('a failed, stopped or timed-out request', () => {
    for (const e of [new TypeError('Failed to fetch'), { message: 'TypeError: Failed to fetch', code: '' }, { message: 'TypeError: Load failed' },
      { message: 'AbortError: signal is aborted without reason', code: '' }, Object.assign(new Error('The operation was aborted.'), { name: 'AbortError' }),
      { message: 'TimeoutError: signal timed out' }]) expect(toAppError(e).kind, JSON.stringify(e)).toBe('network');
  });
  it('never an answer from the database, whatever its words', () => {
    expect(toAppError({ code: '23514', message: 'milling: network of mills not allowed' }).kind).toBe('rule');
    expect(toAppError({ code: '25P02', message: 'current transaction is aborted, commands ignored until end of transaction block' }).kind).toBe('other');
    expect(toAppError({ code: '42501', message: 'permission denied for table footprints' }).kind).toBe('permission');
  });
  it('never a fault in the app itself: it must be shown, not kept on the phone as if the network had dropped', () => {
    expect(toAppError(new TypeError("Cannot read properties of undefined (reading 'qty_out')")).kind).toBe('other');
  });
  it('an expired or invalid token is "sign in again", and the outbox keeps the save', () => {
    expect(toAppError({ code: 'PGRST301', message: 'JWT expired' }).kind).toBe('session');
    expect(toAppError({ code: 'PGRST303', message: 'JWT expired' }).kind).toBe('session');
  });
  it('within(): a request with no answer in time is given up as "no connection"; an answer in time is passed on', async () => {
    const slow = within(8000, new Promise<string>(() => { /* never */ })).then(() => 'answered', (e) => toAppError(e).kind);
    await vi.advanceTimersByTimeAsync(8001);
    await expect(slow).resolves.toBe('network');
    await expect(within(8000, Promise.resolve('ok'))).resolves.toBe('ok');
    const refusal = new AppError('qty exceeds available', '23514', 'rule');
    await expect(within(8000, Promise.reject(refusal))).rejects.toBe(refusal);
  });
});
