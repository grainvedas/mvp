import { expect, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const pwFile = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '.env.demo-logins.stack');
const passwords: Record<string, string> = Object.fromEntries(
  readFileSync(pwFile, 'utf8').split(/\r?\n/).map((l) => l.match(/^DEMO_(\d{3})_PASSWORD=(.+)$/)).filter(Boolean).map((m) => [m![1], m![2]]));

export const USERS = {
  admin: { key: '301', email: 'grainvedas+admin@gmail.com' },
  sm: { key: '302', email: 'grainvedas+statemanager@gmail.com' },
  cm: { key: '303', email: 'grainvedas+clientmanager@gmail.com' },
  view: { key: '304', email: 'grainvedas+clientview@gmail.com' },
  procurement: { key: '305', phone: '0000000005' },
  qc: { key: '306', phone: '0000000006' },
  qr: { key: '307', phone: '0000000007' },
  lotInward: { key: '313', phone: '0000000013' },
} as const;

export async function signIn(page: Page, u: { key: string; email?: string; phone?: string }) {
  await page.goto('/');
  await page.evaluate(() => localStorage.clear());
  await page.goto('/');
  if (u.email) await page.getByRole('tab', { name: /Manager/ }).click();
  await page.getByLabel(u.email ? 'Email' : 'Phone').fill(u.email ?? `91${u.phone}`);
  await page.getByLabel('Password').fill(passwords[u.key]);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
}

export async function signOut(page: Page) {
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
}

/** Phones: nothing may be wider than the screen (a wide element zooms the page out and breaks taps near the edges). */
export async function expectNoSideScroll(page: Page) {
  await expect.poll(() => page.evaluate(() => window.innerWidth - document.documentElement.clientWidth)).toBe(0);
}
