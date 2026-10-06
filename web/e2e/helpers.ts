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
  // identity layer (seed 06): the HR seats, an employee nobody has assigned yet, a joiner on the way in
  hrAdmin: { key: '316', email: 'grainvedas+hradmin@gmail.com' }, hr: { key: '317', email: 'grainvedas+hr@gmail.com' },
  ravi: { key: '318', email: 'grainvedas+ravi@gmail.com' }, meera: { key: '319', email: 'grainvedas+meera@gmail.com' },
} as const;
export const PEOPLE = { ravi: '00000000-0000-4000-8000-000000000318', meera: '00000000-0000-4000-8000-000000000319',
  procurement: '00000000-0000-4000-8000-000000000305', qc: '00000000-0000-4000-8000-000000000306', sorting: '00000000-0000-4000-8000-000000000309' } as const;

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

/** Type a demo person's sign-in and password and press the button; what opens next is for the test to say. */
export async function signInOnly(page: Page, u: Who) {
  await page.goto('/');
  await page.evaluate(() => localStorage.clear());
  await page.goto('/');
  // Email is the first tab since the identity layer (every person HR adds signs in by email); the demo operators
  // of the earlier seeds still have phone logins.
  if (!u.email) await page.getByRole('tab', { name: /Phone/ }).click();
  await page.getByLabel(u.email ? 'Email' : 'Phone').fill(u.email ?? `91${u.phone}`);
  await page.getByLabel('Password').fill(passwords[u.key]);
  await page.getByRole('button', { name: 'Sign in' }).click();
}
export async function signIn(page: Page, u: Who) {
  await signInOnly(page, u);
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
}

/** Sign in with a password the test itself was shown (a new person's temporary password, or one it has just set). */
export async function signInWith(page: Page, signIn: string, password: string) {
  await page.goto('/');
  await page.evaluate(() => localStorage.clear());
  await page.goto('/');
  const byEmail = signIn.includes('@');
  if (!byEmail) await page.getByRole('tab', { name: /Phone/ }).click();
  await page.getByLabel(byEmail ? 'Email' : 'Phone').fill(signIn);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
}

/** A new login starts with the temporary password its creator saw: choose an own one, as the app demands. */
export async function setOwnPassword(page: Page, password: string) {
  await expect(page.getByTestId('must-change')).toBeVisible();
  await page.getByLabel('New password', { exact: true }).fill(password);
  await page.getByLabel('New password again').fill(password);
  await page.getByRole('button', { name: 'Set password' }).click();
  await expect(page.getByTestId('must-change')).toBeHidden();
}

/** A fresh email address for a person a test creates (the stack is shared by every test of a run). */
export const freshEmail = (who: string) => `${who}.${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}@example.test`;

/** Today as the server counts it (Asia/Kolkata): a join date typed as "today" must be the server's today at any hour. */
export const todayIST = () => new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10);

/**
 * HR's whole act for one person (signed in as HR or the admin): the form, the temporary password shown once, the
 * joiner's own page. Returns the person's id, that password, and what the confirmation said.
 */
export async function addJoiner(page: Page, p: { name: string; email: string; type?: string; title?: string; systemRole?: string }) {
  await page.goto('/hr/joiners/new');
  await page.getByLabel('Full name').fill(p.name);
  await page.getByLabel('Join date').fill(todayIST());
  await page.getByLabel('Personal email').fill(p.email);
  if (p.type) await page.getByLabel('Employment type').selectOption(p.type);
  if (p.title) await page.getByLabel('Job title').fill(p.title);
  if (p.systemRole) await page.getByLabel('System role').selectOption(p.systemRole);
  await page.getByRole('button', { name: 'Save and create sign-in' }).click();
  await expect(page.getByTestId('temp-password')).toContainText(p.email);
  const temp = (await page.getByTestId('temp-password').textContent())!.match(/: (Gv-[A-Za-z0-9_-]+) —/)![1];
  const said = await page.getByTestId('joiner-made').innerText();
  await page.getByRole('link', { name: 'Open their page' }).click();
  await expect(page.getByRole('heading', { name: p.name })).toBeVisible();
  const id = new URL(page.url()).pathname.split('/').pop()!;
  return { id, temp, said };
}

export async function signOut(page: Page) {
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
}

/** Phones: nothing may be wider than the screen (a wide element zooms the page out and breaks taps near the edges). */
export async function expectNoSideScroll(page: Page) {
  await expect.poll(() => page.evaluate(() => window.innerWidth - document.documentElement.clientWidth)).toBe(0);
}

/**
 * Open one of my stages from the home screen, by scope id. A person who holds stages in several scopes works in one
 * at a time (identity layer): after signing in they pick where they are working, and change it with one tap.
 */
export async function openSlot(page: Page, stage: string, scopeId: string) {
  const card = page.locator(`[data-testid="slot-${stage}"][data-scope="${scopeId}"]`);
  const pick = page.locator(`[data-testid="pick-scope"][data-scope="${scopeId}"]`);
  const change = page.getByTestId('change-scope');
  if (!/\/$/.test(new URL(page.url()).pathname)) await page.goto('/');
  await expect(card.or(pick).or(change).first()).toBeVisible();
  if (!(await card.isVisible())) {
    if (!(await pick.isVisible())) await change.click();
    await pick.click();
  }
  await card.click();
  await page.getByRole('tablist').waitFor();
  await expectNoSideScroll(page);
}

/** The demo scopes by the place a person reads on the screen. */
const PLACES: Record<string, string> = { Siddharthnagar: SCOPES.siddharthnagar, Gorakhpur: SCOPES.gorakhpur, Basti: SCOPES.basti,
  'Gorakhpur mandi': SCOPES.gorakhpurMandi, 'Basti mill': SCOPES.bastiMill, 'Bansi batch': SCOPES.bansiBatch };
/** Open one of my stages by the place's name (the older tests name places, not ids). */
export async function openSlotAt(page: Page, stage: string, place: string) {
  if (!PLACES[place]) throw new Error(`no demo scope is called "${place}"`);
  await openSlot(page, stage, PLACES[place]);
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
    /** The same question of any store (the private HR documents are in `hr-docs`). */
    signedUrlIn: (bucket: string, path: string) => storage('POST', `object/sign/${bucket}/${path}`, JSON.stringify({ expiresIn: 60 })),
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

/**
 * LOCAL STACK ONLY. The once-a-day sign-in code cannot be switched on from the screen while the demo operators sign in
 * by phone (the switch refuses, and a test shows that). To show the code screen itself, the switch is set the way a
 * database owner would set it, and put back. Null on any system that is not the local stack: nothing here may touch
 * staging or production, where the code stays off.
 */
export function localStack() {
  const cfg = supabaseConfig();
  const outbox = (cfg.env as Record<string, string | undefined>).MAIL_OUTBOX_URL;
  if (!/^http:\/\/(127\.0\.0\.1|localhost)[:/]/.test(cfg.url) || !cfg.service || !outbox) return null;
  const raw = (method: string, path: string, body?: unknown, extra: Record<string, string> = {}) => fetch(`${cfg.url}/rest/v1/${path}`, { method,
    headers: { apikey: cfg.service!, authorization: `Bearer ${cfg.service}`, 'content-type': 'application/json', ...extra }, body: body === undefined ? undefined : JSON.stringify(body) });
  return {
    signInCode: async (on: boolean) => {
      const r = await raw('POST', 'app_meta', { key: 'daily_code', value: on ? 'on' : 'off' }, { prefer: 'resolution=merge-duplicates' });
      if (!r.ok) throw new Error(`the sign-in code switch could not be set: ${r.status}`);
    },
    forgetCodes: async () => { await raw('DELETE', 'daily_code_passes?day=gte.2000-01-01'); await raw('DELETE', 'daily_codes?issued_at=gte.2000-01-01'); },
    /** The code in the latest message to this address (the local mail stand-in keeps what was "sent"). */
    codeFor: async (email: string) => {
      const box = (await (await fetch(`${outbox}?to=${encodeURIComponent(email)}`)).json()) as { subject: string }[];
      return /(\d{6}) is your GrainVeda sign-in code/.exec(box.at(-1)?.subject ?? '')?.[1] ?? null;
    },
    emptyOutbox: () => fetch(outbox, { method: 'DELETE' }),
  };
}
