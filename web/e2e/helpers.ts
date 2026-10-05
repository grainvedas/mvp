import { expect, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { dirname, isAbsolute, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { supabaseConfig } from '../../scripts/lib/env.mjs';

// Which system the suite talks to:
//   local stack (default)  ENV_FILE=.env.stack   GV_LOGINS_FILE=.env.demo-logins.stack
//   staging (acceptance)   ENV_FILE=.env.local   GV_LOGINS_FILE=.env.demo-logins        (playwright.acceptance.config.ts)
// Both files are git-ignored. Passwords are read here and typed into the sign-in form; they are never printed.
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
process.env.ENV_FILE ??= '.env.stack';
const loginsFile = process.env.GV_LOGINS_FILE ?? '.env.demo-logins.stack';
const pwFile = isAbsolute(loginsFile) ? loginsFile : join(ROOT, loginsFile);
const passwords: Record<string, string> = Object.fromEntries(
  readFileSync(pwFile, 'utf8').split(/\r?\n/).map((l) => l.match(/^DEMO_(\d{3})_PASSWORD=(.+)$/)).filter(Boolean).map((m) => [m![1], m![2]]));

export interface Who { key: string; email?: string; phone?: string }
const op = (key: string, n: string): Who => ({ key, phone: `00000000${n}` });

export const USERS = {
  admin: { key: '301', email: 'grainvedas+admin@gmail.com' },
  sm: { key: '302', email: 'grainvedas+statemanager@gmail.com' },
  cm: { key: '303', email: 'grainvedas+clientmanager@gmail.com' },
  view: { key: '304', email: 'grainvedas+clientview@gmail.com' },
  procurement: op('305', '05'), qc: op('306', '06'), qr: op('307', '07'), mill: op('308', '08'), sorting: op('309', '09'),
  grading: op('310', '10'), commercial: op('311', '11'), otherClient: op('312', '12'), lotInward: op('313', '13'),
  shipment: op('314', '14'), villageBatch: op('315', '15'),
} as const;

/** Demo scopes (seeds 02, 04, 05): fixed ids, so a test names the scope and not a label that another scope's label contains. */
const scope = (n: string) => `00000000-0000-4000-8000-0000000004${n}`;
export const SCOPES = {
  siddharthnagar: scope('01'),   // T1  procurement → QC → QR
  gorakhpur: scope('02'),        // T2  procurement → sorting → grading → QC → QR
  basti: scope('03'),            // T3  procurement → QC → milling → commercial → QR
  gorakhpurMandi: scope('04'),   //     lot inward → QC → QR
  bastiMill: scope('05'),        // T4  procurement → QC → milling → packing → commercial → shipment → QR
  bansiBatch: scope('06'),       //     procurement → village batch → QC → QR
} as const;

export async function signIn(page: Page, u: Who) {
  await page.goto('/');
  await page.evaluate(() => localStorage.clear());
  await page.goto('/');
  if (u.email) await page.getByRole('tab', { name: /Email/ }).click();
  await page.getByLabel(u.email ? 'Email' : 'Phone').fill(u.email ?? `91${u.phone}`);
  await page.getByLabel('Password').fill(passwords[u.key]);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
}

/** Sign in with a password the test itself was shown (a new user's temporary password, or one it has just set). */
export async function signInWith(page: Page, phone: string, password: string) {
  await page.goto('/');
  await page.evaluate(() => localStorage.clear());
  await page.goto('/');
  await page.getByLabel('Phone').fill(phone);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
}

export async function signOut(page: Page) {
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
}

/** Phones: nothing may be wider than the screen (a wide element zooms the page out and breaks taps near the edges). */
export async function expectNoSideScroll(page: Page) {
  await expect.poll(() => page.evaluate(() => window.innerWidth - document.documentElement.clientWidth)).toBe(0);
}

/** Open one of my stages from the home screen, by scope id. */
export async function openSlot(page: Page, stage: string, scopeId: string) {
  await page.locator(`[data-testid="slot-${stage}"][data-scope="${scopeId}"]`).click();
  await page.getByRole('tablist').waitFor();
  await expectNoSideScroll(page);
}

export async function verifyIncoming(page: Page, code: string) {
  await page.getByTestId('incoming-row').filter({ hasText: code }).click();
  for (const box of await page.getByRole('checkbox').all()) await box.check();
  await page.getByRole('button', { name: 'Verify this lot' }).click();
  await expect(page.locator('.alert.ok', { hasText: 'Verified' })).toBeVisible();
}

export async function reviewAndSave(page: Page, code: RegExp) {
  await expect(page.getByTestId('preview-ok')).toBeVisible();
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  await expect(page.getByTestId('saved')).toBeVisible();
  return (await page.getByTestId('saved').textContent())!.match(code)![0];
}

export async function procure(page: Page, scopeId: string, farmer: string, gross: string, bags: string, tare: string, moisture = '11.8') {
  await openSlot(page, 'procurement', scopeId);
  await page.getByPlaceholder('Name, Farmer ID, phone or village').fill(farmer.split(' ')[0]);
  await page.getByRole('button', { name: new RegExp(farmer) }).click();
  await page.getByLabel(/Gross weight/).fill(gross);
  await page.getByLabel(/^Bags/).fill(bags);
  await page.getByLabel(/Tare per bag/).fill(tare);
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill(moisture);
  return reviewAndSave(page, /PRSDM-KNM-KH26-P-\d{4}/);
}

export async function recordQc(page: Page, scopeId: string, from: string, moisture: string, sample = '1') {
  await openSlot(page, 'qc', scopeId);
  await verifyIncoming(page, from);
  await page.getByRole('button', { name: /Record Quality Control/ }).click();
  await page.getByLabel(/Sample drawn/).fill(sample);
  await page.getByLabel(/^Moisture \(%\)/).fill(moisture);
  await page.getByLabel(/^Broken grains/).fill('2');
  await page.getByLabel(/^Foreign matter/).fill('0.2');
  return reviewAndSave(page, /PRSDM-KNM-KH26-QC-\d{4}/);
}

export async function sealLot(page: Page, scopeId: string, from: string) {
  await openSlot(page, 'qr_activation', scopeId);
  await verifyIncoming(page, from);
  await page.getByRole('button', { name: 'Activate and seal' }).click();
  return (await page.getByTestId('sealed').textContent())!.match(/GV-[0-9A-F]{12}/)![0];
}

/**
 * The database's own answer for the person signed in on this page: the same REST API the app uses, with that person's
 * token, bypassing the screens (PRD §9 "direct API calls outside role are rejected"). Nothing is read with a service key.
 */
export async function apiAs(page: Page) {
  const cfg = supabaseConfig();
  const token = await page.evaluate(() => (JSON.parse(localStorage.getItem('grainveda-auth') ?? '{}') as { access_token?: string }).access_token ?? '');
  if (!token) throw new Error('nobody is signed in on this page');
  const call = async (method: string, path: string, body?: unknown, profile = 'public') => {
    const res = await fetch(`${cfg.url}/rest/v1/${path}`, {
      method,
      headers: { apikey: cfg.anon, authorization: `Bearer ${token}`, 'content-type': 'application/json', prefer: 'return=representation',
        'accept-profile': profile, 'content-profile': profile },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let data: unknown = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text; }
    return { status: res.status, ok: res.ok, data };
  };
  const storage = async (method: string, path: string, body?: string | Buffer, contentType = 'application/json') => {
    const res = await fetch(`${cfg.url}/storage/v1/${path}`, { method,
      headers: { apikey: cfg.anon, authorization: `Bearer ${token}`, 'content-type': contentType }, body });
    return { status: res.status, ok: res.ok, text: await res.text() };
  };
  return {
    /** Supabase Storage as this person: ask for a signed URL of a stored file, or try to upload one. */
    signedUrl: (path: string) => storage('POST', `object/sign/evidence/${path}`, JSON.stringify({ expiresIn: 60 })),
    upload: (path: string, bytes: Buffer, type: string) => storage('POST', `object/evidence/${path}`, bytes, type),
    rows: async (table: string, query = '') => {
      const r = await call('GET', `${table}?select=*${query ? `&${query}` : ''}`);
      if (!r.ok) throw new Error(`reading ${table} failed: ${r.status} ${JSON.stringify(r.data)}`);
      return r.data as Record<string, unknown>[];
    },
    insert: (table: string, row: unknown) => call('POST', table, row),
    update: (table: string, query: string, patch: unknown) => call('PATCH', `${table}?${query}`, patch),
    rpc: (fn: string, args: unknown = {}) => call('POST', `rpc/${fn}`, args, 'app'),
  };
}

export const refusal = (r: { data: unknown }) => String((r.data as { message?: string } | null)?.message ?? JSON.stringify(r.data));
