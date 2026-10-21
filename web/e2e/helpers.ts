import { expect, type Dialog, type Page } from '@playwright/test';
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

/** A fresh mobile number (people may not share one): 9, then nine digits from the clock and chance. */
export const freshPhone = () => `9${String(Date.now() % 1e5).padStart(5, '0')}${String(Math.floor(Math.random() * 1e4)).padStart(4, '0')}`;

/** Fresh identity numbers for a test (migration 37 refuses a PAN, Aadhaar or UAN already on someone's record, and the
 *  stack is shared by every run). The Aadhaar carries a valid check digit. */
const digits = (n: number) => Array.from({ length: n }, () => Math.floor(Math.random() * 10)).join('');
const letters = (n: number) => Array.from({ length: n }, () => String.fromCharCode(65 + Math.floor(Math.random() * 26))).join('');
export const freshPan = () => `${letters(5)}${digits(4)}${letters(1)}`;
export const freshUan = () => `1${digits(11)}`;
export const freshAccount = () => `5${digits(13)}`;
// Verhoeff, as in supabase/functions/id-numbers/handler.ts (that file is not importable from here: Playwright loads it as CommonJS)
const VD = [[0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 2, 3, 4, 0, 6, 7, 8, 9, 5], [2, 3, 4, 0, 1, 7, 8, 9, 5, 6], [3, 4, 0, 1, 2, 8, 9, 5, 6, 7],
  [4, 0, 1, 2, 3, 9, 5, 6, 7, 8], [5, 9, 8, 7, 6, 0, 4, 3, 2, 1], [6, 5, 9, 8, 7, 1, 0, 4, 3, 2], [7, 6, 5, 9, 8, 2, 1, 0, 4, 3],
  [8, 7, 6, 5, 9, 3, 2, 1, 0, 4], [9, 8, 7, 6, 5, 4, 3, 2, 1, 0]];
const VP = [[0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 5, 7, 6, 2, 8, 3, 0, 9, 4], [5, 8, 0, 3, 7, 9, 6, 1, 4, 2], [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
  [9, 4, 5, 3, 1, 2, 6, 8, 7, 0], [4, 2, 8, 6, 5, 7, 3, 9, 0, 1], [2, 7, 9, 3, 8, 0, 6, 4, 1, 5], [7, 0, 4, 6, 9, 1, 3, 2, 5, 8]];
const verhoeffOk = (s: string) => { let c = 0; [...s].reverse().forEach((ch, i) => { c = VD[c][VP[i % 8][Number(ch)]]; }); return c === 0; };
export function freshAadhaar(): string {
  const first = `${2 + Math.floor(Math.random() * 8)}${digits(10)}`;
  for (let d = 0; d <= 9; d++) if (verhoeffOk(first + d)) return first + d;
  throw new Error('no check digit');
}

/** Today as the server counts it (Asia/Kolkata): a join date typed as "today" must be the server's today at any hour. */
export const todayIST = () => new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10);

/**
 * HR's whole act for one person (signed in as HR or the admin): the form, the temporary password shown once, the
 * joiner's own page. Returns the person's id, that password, and what the confirmation said.
 */
export async function addJoiner(page: Page, p: { name: string; email: string; type?: string; title?: string; systemRole?: string; phone?: string; joinDate?: string;
  baseState?: string; district?: string; openingId?: string }) {
  await page.goto('/hr/joiners/new');
  if (p.openingId) await page.locator('#j-opening').selectOption(p.openingId);
  await page.getByLabel('Full name').fill(p.name);
  await page.getByLabel('Join date').fill(p.joinDate ?? todayIST());
  await page.getByLabel('Personal email').fill(p.email);
  await page.locator('#j-phone').fill(p.phone ?? freshPhone());                    // required since migration 37 (A4)
  if (p.type) await page.getByLabel('Employment type').selectOption(p.type);
  if (p.title) await page.getByLabel('Job title').fill(p.title);
  if (p.systemRole) await page.getByLabel('System role').selectOption(p.systemRole);
  // where the person is based (migration 39): given, or the first state when the form needs one (an HR resource with
  // one state needs none: it is hers)
  const base = page.locator('#j-base');
  // the states are in: two or more choices, or (an HR resource of one state, migration 44 G9) her state as the only one
  await expect.poll(() => base.evaluate((el) => { const o = (el as HTMLSelectElement).options; return o.length >= 2 || (o.length === 1 && o[0].value !== ''); })).toBe(true);
  if (p.baseState) await base.selectOption({ label: p.baseState });
  else if (await base.evaluate((el) => (el as HTMLSelectElement).required && !(el as HTMLSelectElement).value)) await base.selectOption({ index: 1 });
  if (p.district) await page.locator('#j-district').fill(p.district);
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

/** Migration 54 (Veda, 16 Oct: "farmer selection during procurement should be drop down"): the farmer is picked by his
 *  village first, then from that village's farmers. Finds the village the farmer is in. */
export async function pickFarmer(page: Page, farmer: RegExp | string) {
  const re = typeof farmer === 'string' ? new RegExp(farmer) : farmer;
  const village = page.getByTestId('pick-village');
  await expect(village.locator('option').nth(1)).toBeAttached();
  const values = await village.locator('option').evaluateAll((os) => os.map((o) => (o as HTMLOptionElement).value).filter(Boolean));
  for (const v of values) {
    await village.selectOption(v);
    const pick = page.getByTestId('pick-farmer');
    await expect(pick.locator('option').nth(1)).toBeAttached();
    const hit = (await pick.locator('option').allTextContents()).find((l) => re.test(l));
    if (hit) { await pick.selectOption({ label: hit }); await expect(page.getByTestId('farmer-picked')).toBeVisible(); return; }
  }
  throw new Error(`no farmer ${re} in any village`);
}
/** Whether any village offers a farmer of that name (an inactive farmer is not offered at the farm gate). */
export async function farmerOffered(page: Page, farmer: RegExp): Promise<boolean> {
  const village = page.getByTestId('pick-village');
  await expect(village).toBeVisible();
  await expect(village.locator('option').nth(1)).toBeAttached();
  // looked at three times, a second and a half apart: on a busy machine the client's farmers can still be on their way
  // (16 Oct 2026: once "not offered" for a farmer who was)
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) await page.waitForTimeout(1500);
    const values = await village.locator('option').evaluateAll((os) => os.map((o) => (o as HTMLOptionElement).value).filter(Boolean));
    for (const v of values) {
      await village.selectOption(v);
      const pick = page.getByTestId('pick-farmer');
      await expect(pick.locator('option').nth(1)).toBeAttached();
      if ((await pick.locator('option').allTextContents()).some((l) => farmer.test(l))) return true;
    }
  }
  return false;
}

export async function procure(page: Page, scopeId: string, farmer: string, gross: string, bags: string, tare: string, moisture = '11.8') {
  await openSlot(page, 'procurement', scopeId);
  await pickFarmer(page, new RegExp(farmer));
  await page.getByLabel(/Gross weight/).fill(gross);
  await page.getByLabel(/^Bags/).fill(bags);
  await page.getByLabel(/Tare per bag/).fill(tare);
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill(moisture);
  await fillWhere(page);
  return reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?P-\d{4}/);
}

/** Migration 52 (C1): where the lot was weighed, its GPS and who delivered it, as an operator at the farm gate fills them
 *  (a scope made from now on asks them; the demo scopes do not, and take them all the same). */
export async function fillWhere(page: Page, where = 'farm', gps: [string, string] = ['27.21', '82.95'], by = 'farmer') {
  if (!(await page.getByTestId('where').count())) return;
  await page.getByTestId('where').selectOption(where);
  await page.getByTestId('gps-lat').fill(gps[0]);
  await page.getByTestId('gps-lng').fill(gps[1]);
  await page.getByLabel(/^Delivered by/).selectOption(by);
}

export async function recordQc(page: Page, scopeId: string, from: string, moisture: string, sample = '1') {
  await openSlot(page, 'qc', scopeId);
  await verifyIncoming(page, from);
  await page.getByRole('button', { name: /Record Quality Control/ }).click();
  await page.getByLabel(/Sample drawn/).fill(sample);
  await page.getByLabel(/^Moisture \(%\)/).fill(moisture);
  await page.getByLabel(/^Broken grains/).fill('2');
  await page.getByLabel(/^Foreign matter/).fill('0.2');
  return reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?QC-\d{4}/);
}

/** Migration 50 (C5): the lab report a new scope asks for: the lab, its number, today's date and the file. */
export async function fillLabReport(page: Page, tag: string) {
  await page.getByLabel('Lab *', { exact: true }).fill(`Lab ${tag}`);
  await page.getByLabel('Report number *', { exact: true }).fill(`R-${tag}-${Date.now() % 100000}`);
  await page.getByLabel('Report date *', { exact: true }).fill(todayIST());
  await page.getByLabel('Lab report (PDF or photo) *', { exact: true })
    .setInputFiles({ name: 'report.pdf', mimeType: 'application/pdf', buffer: Buffer.from(`%PDF-1.4\n% lab report ${tag} ${Date.now()}\n%%EOF\n`) });
}

export async function sealLot(page: Page, scopeId: string, from: string) {
  await openSlot(page, 'qr_activation', scopeId);
  await verifyIncoming(page, from);
  await page.getByTestId('release-read').check();   // migration 50 (G9): the summary is read first
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
      // a query that names its columns keeps them (since migration 59 app_users' email and phone are not readable)
      const r = await call('GET', `${table}?${/(^|&)select=/.test(query) ? query : `select=*${query ? `&${query}` : ''}`}`);
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
    /** A crop's good farming practice list, set as the State Manager would (migration 47's test); put it back afterwards. */
    setCropGap: async (cropId: string, items: unknown[]) => {
      const r = await raw('PATCH', `crops?id=eq.${cropId}`, { gap_items: items });
      if (!r.ok) throw new Error(`the crop's practices could not be set: ${r.status} ${await r.text()}`);
    },
    /** Any of a crop's fields, set as its State Manager would (migration 49: its GI area, its thresholds); put back afterwards. */
    setCrop: async (cropId: string, patch: Record<string, unknown>) => {
      const r = await raw('PATCH', `crops?id=eq.${cropId}`, patch);
      if (!r.ok) throw new Error(`the crop could not be set: ${r.status} ${await r.text()}`);
    },
    /** A farmer record as a seed or an import by another client's people would leave it (the farmer register's duplicate). */
    seedFarmer: async (row: Record<string, unknown>) => {
      const r = await raw('POST', 'farmers', row, { prefer: 'return=representation' });
      if (!r.ok) throw new Error(`the farmer could not be seeded: ${r.status} ${await r.text()}`);
      return ((await r.json()) as { id: string }[])[0].id;
    },
  };
}

/**
 * "Mark as joined" through the gate (migration 38, brief G1): statutory steps still open are first recorded as received
 * on paper (flagged), other open steps need a reason (flagged). On a joiner's page, as HR (or the admin on the HR Admin's).
 */
export async function markJoined(page: Page, reason = 'Joined on the day, papers follow') {
  const button = page.getByTestId('activate');
  await expect(button).toBeVisible();
  const paper = page.locator('[data-testid^="on-paper-"]');
  const note = (d: Dialog) => void d.accept('Original seen on paper');
  page.on('dialog', note);
  try {
    while (await page.getByTestId('gate-statutory').isVisible()) {
      const n = await paper.count();
      await paper.first().click();
      await expect(paper).toHaveCount(n - 1);
    }
  } finally { page.off('dialog', note); }
  if (await button.count() === 0) return;                     // the last open step was the paper one: joined already
  if (await page.getByTestId('gate-reason').isVisible()) await page.getByTestId('gate-why').fill(reason);
  await button.click();
  await expect(button).toHaveCount(0);
}

/** Migration 51 (Part B): the farmer's district from the state's list (a select where the state has one, typed where it
 *  has none), then the village, then the farm's GPS (typed; `null` leaves it empty). */
export async function fillFarmerPlace(page: Page, district: string, village: string, gps: [string, string] | null = ['27.21', '82.95'], block?: string) {
  await page.getByTestId('farmer-district').waitFor({ timeout: 5_000 }).catch(() => undefined);
  const d = page.locator('#farmer-district');
  if (await d.evaluate((el) => el.tagName) === 'SELECT') await d.selectOption(district); else await d.fill(district);
  // migration 54 (Veda, 16 Oct: "list only"): where the state has a list, the block and the village are picked from it
  const v = page.locator('#farmer-village');
  if (await v.evaluate((el) => el.tagName) === 'SELECT') {
    if (block) { await expect(page.locator('#farmer-block option', { hasText: block }).first()).toBeAttached(); await page.locator('#farmer-block').selectOption({ label: block }); }
    await expect(v.locator('option', { hasText: village }).first()).toBeAttached();
    await v.selectOption({ label: village });
  } else {
    if (block) await page.getByTestId('farmer-block').fill(block);
    await v.fill(village);
  }
  if (gps) { await page.getByTestId('farmer-lat').fill(gps[0]); await page.getByTestId('farmer-lng').fill(gps[1]); }
}

/** Migration 54: a block and a village added to the state's list (Set-up lists, Places), as the Client Manager adds them
 *  before a farmer of that village is registered. A block already there is chosen. */
export async function addPlace(page: Page, district: string, block: string, village: string) {
  await page.goto('/setup?tab=places');
  await page.getByTestId('set-district').selectOption(district);
  const blocks = page.getByTestId('set-blocks');
  if (!(await blocks.getByRole('button', { name: block, exact: true }).count())) {
    await page.getByTestId('set-new-block').fill(block);
    await page.getByTestId('set-add-block').click();
  }
  await page.getByTestId('set-blocks').getByRole('button', { name: block, exact: true }).click();
  await page.getByTestId('set-new-village').fill(village);
  await page.getByTestId('set-add-village').click();
  await expect(page.getByTestId('set-villages')).toContainText(village);
}

/** Migration 51 (A15): a pool option reads "<name>" for a free person and "<name> · <work on other scopes>" for one
 *  already busy; pick the person by the name the option starts with. */
export async function pickFromPool(page: Page, select: string, name: string) {
  const sel = page.getByLabel(select);
  const esc = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const opt = sel.locator('option').filter({ hasText: new RegExp(`^${esc}( · |$)`) }).first();
  await expect(opt).toBeAttached();
  await sel.selectOption((await opt.getAttribute('value'))!);
}

// ── migration 64 (Phase 2, release 1): the client registry ─────────────────────────────────────────────────────────────
/** A fake, format-valid PAN for a company (4th letter C), different each run: ZZZC + a letter + 4 digits + a letter. */
export function fakePan(seed = Date.now()): string {
  const L = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  const n = String(seed).slice(-4).padStart(4, '0');
  return `ZZZC${L[Math.floor(seed / 10000) % L.length]}${n}${L[Math.floor(seed / 7) % L.length]}`;
}
/** A one-page PDF to upload as a client's document (the store checks only that it is a PDF). */
export const TINY_PDF = Buffer.from('%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Count 1/Kids[3 0 R]>>endobj 3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n');

/**
 * THROUGH THE API, as the signed-in State Manager: a client made with its PAN and taken through Gates 1–3 in his state
 * (the documents uploaded to the client-docs store), the KYC ticked and its first Active requested. The admin's approval
 * is the caller's (approveClient, signed in as the admin). The screens are e2e/phase36's; this is for tests that need an
 * Active client to start from. Returns the client's id and its code (made by the system).
 */
export async function onboardClient(page: Page, o: { name: string; tradeName?: string; clientType?: string; pan?: string; stateId?: string; cropId?: string; exports?: boolean }) {
  const api = await apiAs(page);
  const cfg = supabaseConfig();
  const token = await page.evaluate(() => (JSON.parse(localStorage.getItem('grainveda-auth') ?? '{}') as { access_token?: string }).access_token ?? '');
  const pan = o.pan ?? fakePan();
  // the demo's Uttar Pradesh and Kalanamak rice by default (on a fresh system their ids are new: found by name)
  const state = o.stateId ?? String((await api.rows('states', 'select=id&name=eq.Uttar%20Pradesh'))[0]?.id ?? '00000000-0000-4000-8000-000000000001');
  const crop = o.cropId ?? String((await api.rows('crops', 'select=id&name=ilike.Kalanamak*&order=created_at.asc&limit=1'))[0]?.id ?? '00000000-0000-4000-8000-000000000101');
  const ok = (r: { ok: boolean; data: unknown }, what: string) => { if (!r.ok) throw new Error(`${what}: ${refusal(r)}`); return r.data as Record<string, unknown>; };
  const made = ok(await api.rpc('create_client', { p: { pan, entity_type: 'company', legal_name: o.name, trade_name: o.tradeName ?? null, client_type: o.clientType ?? 'exporter', state_id: state,
    contact: { name: 'Test Contact', designation: 'Director', phone: '9000000099', email: 'contact@client.test' },
    crops_of_interest: [crop] } }), 'create_client');
  const id = String(made.client_id);
  const doc = async (kind: string, meta: Record<string, unknown> = {}) => {
    const path = `${id}/${crypto.randomUUID()}.pdf`;
    const up = await fetch(`${cfg.url}/storage/v1/object/client-docs/${path}`, { method: 'POST',
      headers: { apikey: cfg.anon, authorization: `Bearer ${token}`, 'content-type': 'application/pdf' }, body: TINY_PDF });
    if (!up.ok) throw new Error(`upload ${kind}: ${up.status} ${await up.text()}`);
    const sha = (await import('node:crypto')).createHash('sha256').update(TINY_PDF).digest('hex');
    ok(await api.rpc('add_client_document', { p_client: id, p_state: state, p_kind: kind, p_path: path, p_sha256: sha, p_bytes: TINY_PDF.length,
      p_file_name: `${kind}.pdf`, p_meta: meta }), `document ${kind}`);
  };
  const gst = (await api.rows('states', `select=gst_code&id=eq.${state}`))[0]?.gst_code ?? '09';
  ok(await api.rpc('save_client_details', { p_client: id, p_state: state, p: { gstin: `${gst}${pan}1Z5`,
    reg_office: { address: '1 Test Road', city: 'Gorakhpur', state: 'Uttar Pradesh' }, reg_number: 'U01100UP2025PTC123456',
    signatory: { name: 'Test Signatory', designation: 'Director' }, billing: { contact: 'Accounts', email: 'accounts@client.test' },
    ...(o.exports === false ? {} : { iec: pan, rcmc: { number: 'RCMC/TEST/0001', expires_on: '2030-03-31' } }) } }), 'details');
  await doc('diagnostic_order', { signed_on: '2026-10-01', amount: 10000 });
  await doc('incorporation');
  ok(await api.rpc('client_move', { p_client: id, p_state: state, p_to: 'diagnostic' }), 'to Diagnostic');
  await doc('msa', { signed_on: '2026-10-01', term_end: '2029-09-30' });
  await doc('consent_addendum', { signed_on: '2026-10-01' });
  await doc('signatory_authority');
  if (o.exports !== false) { await doc('iec'); await doc('rcmc', { expires_on: '2030-03-31' }); }
  ok(await api.rpc('client_kyc', { p_client: id, p_state: state }), 'KYC');
  ok(await api.rpc('client_move', { p_client: id, p_state: state, p_to: 'active' }), 'request Active');
  const code = String((await api.rows('clients', `select=code&id=eq.${id}`))[0]?.code ?? '');
  return { id, code, pan };
}
/** As the signed-in admin: approve a client's first Active in a state. */
export async function approveClient(page: Page, clientId: string, stateId?: string) {
  const api = await apiAs(page);
  stateId ??= String((await api.rows('states', 'select=id&name=eq.Uttar%20Pradesh'))[0]?.id ?? '00000000-0000-4000-8000-000000000001');
  const r = await api.rpc('decide_client_activation', { p_client: clientId, p_state: stateId, p_approve: true, p_reason: null });
  if (!r.ok) throw new Error(`approve: ${refusal(r)}`);
}
