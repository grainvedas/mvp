import { test, expect, type Page } from '@playwright/test';
import { apiAs, expectNoSideScroll, signIn, signOut, USERS } from './helpers';
import { hi } from '../src/lib/i18n.hi';

// Migration 34 (Veda, 10 Oct 2026): the admin oversees. On the demo data (seeds 02 to 06): one admin, an HR Admin in
// the seat, a State Manager of Uttar Pradesh, the Client Manager of GrainVeda, six scopes. Phone width (Pixel 7).
const menu = (page: Page) => page.getByRole('navigation', { name: 'Main' });

test('The admin\'s overview: guide and checklist, number cards that open their lists, clients by state, a client and a scope opened read-only', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, USERS.admin);
  await expect(page.getByRole('heading', { name: 'Platform overview' })).toBeVisible();
  await expect(page.getByTestId('role-guide')).toContainText('You do not run stages, farmers, clients or scopes');
  await expect(page.getByTestId('role-guide')).not.toContainText(/override/i);
  // the demo has a state, an HR Admin and a State Manager: the checklist has ticked itself
  await expect(page.getByTestId('setup-checklist')).toContainText('3 of 3 done');
  await expect(page.getByTestId('setup-item')).toHaveCount(3);
  for (const item of await page.getByTestId('setup-item').all()) await expect(item).toHaveAttribute('data-done', 'yes');
  await expectNoSideScroll(page);

  // "Needs attention": the card says exactly what its list adds up to
  const tile = page.getByTestId('ov-tile-attention');
  const total = Number((await tile.locator('.stat-val').textContent())!.trim());
  await tile.click();
  await expect(page.getByTestId('ov-panel-attention')).toBeVisible();
  const n = async (id: string) => Number(((await page.getByTestId(id).textContent())!.match(/(\d+)\s*$/) ?? (await page.getByTestId(id).textContent())!.match(/: (\d+)/))![1]);
  const sum = (await n('att-flags')) + (await n('att-step1')) + (await n('att-step2')) + (await n('att-unstaffed'));
  expect(sum).toBe(total);
  await tile.click();
  await expect(page.getByTestId('ov-panel-attention')).toHaveCount(0);

  await page.getByTestId('ov-tile-clients').click();
  await expect(page.getByTestId('ov-panel-clients').getByRole('row')).not.toHaveCount(0);
  await page.getByTestId('ov-tile-scopes').click();
  // every scope there is (the demo's six and what earlier tests made), as the server lists them for the admin
  const all = ((await (await apiAs(page)).rpc('my_context')).data as { scopes: unknown[] }).scopes.length;
  expect(all).toBeGreaterThanOrEqual(6);
  await expect(page.getByTestId('ov-panel-scopes').locator('li')).toHaveCount(all);

  // clients grouped by state; the state selector narrows them
  await expect(page.locator('.ov-state-name').first()).toBeVisible();
  await page.getByTestId('ov-state').selectOption({ label: 'Assam' });
  await expect(page.locator('.ov-state-name')).toHaveCount(await page.locator('.ov-state-name').count());
  for (const h of await page.locator('.ov-state-name').all()) await expect(h).toHaveText('Assam');
  await page.getByTestId('ov-state').selectOption('');

  // pipeline and volume: a table each, nothing wider than the phone
  await expect(page.getByTestId('ov-pipeline')).toBeVisible();
  await expect(page.getByTestId('ov-vol-state')).toContainText('Uttar Pradesh');
  await expect(page.getByTestId('ov-vol-crop')).toBeVisible();
  await expectNoSideScroll(page);

  // a client, read-only, and back
  const card = page.getByTestId('ov-client').first();
  const name = (await card.locator('strong').first().textContent())!.trim();
  await card.getByTestId('ov-open-client').click();
  await expect(page.getByTestId('readonly-banner')).toContainText(`Viewing ${name} — read-only`);
  await expectNoSideScroll(page);
  // one of its scopes: the scope screen, read-only, its queue counted the same on the card and in the title
  const scopes = page.getByTestId('ov-open-scope');
  if (await scopes.count()) {
    await scopes.first().click();
    await expect(page.getByTestId('readonly-banner')).toContainText('read-only');
    await expect(page.getByRole('link', { name: 'Chain and people' })).toHaveCount(0);
    const stats = page.getByTestId('stats');
    if (await stats.count()) {
      await expect(stats).toContainText('Needs attention');
      await expect(stats).not.toContainText('My action queue');
      const queue = page.getByTestId('action-queue');
      const h2 = queue.locator('h2');
      if (await h2.count()) {
        const card4 = (await stats.locator('.stat').nth(1).locator('.stat-val').textContent())!.trim();
        await expect(h2).toHaveText(`Needs attention (${card4})`);
      }
    }
    await page.getByTestId('readonly-exit').click();
  } else {
    await page.getByTestId('readonly-exit').click();
  }
  await expect(page.getByRole('heading', { name: 'Platform overview' })).toBeVisible();

  // in Hindi
  await page.getByLabel('Language').selectOption('hi');
  await expect(page.getByRole('heading', { name: hi['ov.title'] })).toBeVisible();
  await expect(page.getByTestId('role-guide')).toContainText(hi['guide.admin.1']);
  await expectNoSideScroll(page);
  await page.getByLabel('Language').selectOption('en');
  await signOut(page);
});

test('What the admin no longer does is not offered: farmers, clients, crops, scopes, records, HR once the seat is filled; a state is all the admin gives', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, USERS.admin);
  // the HR Admin seat is filled in the demo: no HR · Joiners; the ledger is there
  await expect(menu(page).getByRole('link', { name: /HR · Joiners/ })).toHaveCount(0);
  await expect(menu(page).getByRole('link', { name: 'Ledger' })).toBeVisible();

  await page.goto('/farmers');
  await expect(page.getByTestId('farmers-readonly')).toBeVisible();
  await expect(page.getByRole('link', { name: 'New farmer' })).toHaveCount(0);
  for (const tab of ['Drafts', 'Ready to verify', 'Active']) {
    await page.getByRole('tab', { name: tab, exact: true }).click().catch(() => undefined);
    await expect(page.getByTestId('farmer-step1')).toHaveCount(0);
    await expect(page.getByTestId('farmer-step2')).toHaveCount(0);
    await expect(page.getByTestId('farmer-inactive')).toHaveCount(0);
  }
  await page.goto('/clients');
  await expect(page.getByTestId('clients-readonly')).toBeVisible();
  await expect(page.getByTestId('client-form')).toHaveCount(0);
  await page.goto('/crops');
  await expect(page.getByTestId('crops-readonly')).toBeVisible();
  await expect(page.locator('main').getByRole('button', { name: 'Edit' })).toHaveCount(0);
  await page.goto('/scopes');
  await expect(page.getByTestId('scopes-readonly')).toBeVisible();
  await expect(page.getByRole('link', { name: 'New scope' })).toHaveCount(0);
  await page.locator('main table a').first().click();
  await expect(page.getByTestId('scope-readonly')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Activate scope' })).toHaveCount(0);

  // a record: read, no withdraw, no seal, no evidence
  await page.goto('/system/ledger');
  await page.getByTestId('ledger-event').selectOption('create');
  await page.getByTestId('ledger-row').first().getByRole('link').click();
  await expect(page.getByRole('heading', { name: /Record/ })).toBeVisible();
  await expect(page.getByRole('button', { name: /Withdraw/ })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Activate and seal' })).toHaveCount(0);

  // People: a state is the only thing the admin gives
  await page.goto('/people');
  await page.getByTestId('person-row').filter({ hasText: 'Ravi' }).getByRole('link', { name: /Assign/ }).click();
  await expect(page.getByRole('tab')).toHaveCount(0);
  await expect(page.getByLabel('State', { exact: true })).toBeVisible();
  await page.goto('/people');
  await page.getByRole('tab', { name: /Client logins/ }).or(page.getByRole('button', { name: /Client logins/ })).first().click();
  await expect(page.getByRole('form', { name: 'New client login' })).toHaveCount(0);
  await signOut(page);
});

test('The ledger page: every block, filters, manager acts on records, export of the filtered list', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, USERS.admin);
  await page.goto('/system/ledger');
  await expect(page.getByRole('heading', { name: 'Ledger' })).toBeVisible();
  const total = Number((await page.getByTestId('ledger-total').textContent())!.match(/\d+/)![0]);
  expect(total).toBeGreaterThan(0);
  const first = page.getByTestId('ledger-row').first();
  await expect(first.locator('code')).toHaveCount(2);                     // hash and previous hash
  await page.getByTestId('ledger-event').selectOption('seal');
  for (const r of await page.getByTestId('ledger-row').all()) await expect(r).toHaveAttribute('data-event', 'seal');
  const seals = Number((await page.getByTestId('ledger-total').textContent())!.match(/\d+/)![0]);
  expect(seals).toBeLessThan(total);
  await page.getByTestId('ledger-event').selectOption('');
  await page.getByTestId('ledger-manager-acts').check();
  for (const r of await page.getByTestId('ledger-row').all()) await expect(r).toHaveAttribute('data-event', 'supervisory');
  await page.getByTestId('ledger-manager-acts').uncheck();
  // the export: the whole filtered list, one line per block
  await page.getByTestId('ledger-event').selectOption('seal');
  const [download] = await Promise.all([page.waitForEvent('download'), page.getByTestId('ledger-export').click()]);
  const text = await (await import('node:fs/promises')).readFile((await download.path())!, 'utf8');
  const lines = text.replace(/^﻿/, '').trim().split(/\r?\n/);
  expect(lines[0]).toBe('seq,event,record,what,about,client,scope,signed_by,role,time,hash,prev_hash');
  expect(lines.length - 1).toBe(seals);
  await expectNoSideScroll(page);
  await signOut(page);

  // nobody else has it
  await signIn(page, USERS.sm);
  await expect(menu(page).getByRole('link', { name: 'Ledger' })).toHaveCount(0);
  await page.goto('/system/ledger');
  await expect(page.locator('.alert.error')).toContainText(/the whole ledger is for the admin/i);
  await signOut(page);
});

test('A farmer, verified twice: the Client Manager first, then the State Manager of its state by location', async ({ page }) => {
  test.setTimeout(120_000);
  const u = Date.now().toString().slice(-6);
  // a stage person saves a draft only
  await signIn(page, USERS.villageBatch);
  await page.goto('/farmers/new');
  await expect(page.getByTestId('farmers-draft-note')).toBeVisible();
  await expect(page.getByTestId('farmer-save-verify')).toHaveCount(0);
  await signOut(page);

  await signIn(page, USERS.cm);
  await page.goto('/farmers/new');
  await page.getByLabel('Name *', { exact: true }).fill(`Sunita ${u}`);
  await page.getByLabel('Father / husband name *').fill('Shri Ram');
  await page.getByLabel('Village *').fill('Domariaganj');
  await page.getByLabel('District *').fill('Siddharthnagar');
  await expect(page.getByTestId('farmer-state')).toBeVisible();
  await page.getByLabel('Mobile number *').fill(`93${u}52`);
  await page.getByLabel('Land (acres) *').fill('1.5');
  await page.getByTestId('farmer-save-verify').click();
  await expect(page.getByRole('heading', { name: 'Farmers' })).toBeVisible();
  await page.getByRole('tab', { name: 'Ready to verify' }).click();
  const mine = page.getByTestId('farmer-row').filter({ hasText: `Sunita ${u}` });
  await expect(mine).toContainText('Waiting for the State Manager of');
  await signOut(page);

  await signIn(page, USERS.sm);
  await page.goto('/farmers');
  await page.getByLabel('Client').selectOption({ label: 'GrainVeda (Prasaadam trade scope)' });
  await page.getByRole('tab', { name: 'Ready to verify' }).click();
  const row = page.getByTestId('farmer-row').filter({ hasText: `Sunita ${u}` });
  await expect(row).toContainText('Domariaganj, Siddharthnagar');
  await expect(row).toContainText('Verified by Prasaadam Client Manager');
  await row.getByTestId('farmer-step2').click();
  await page.getByRole('tab', { name: 'Active', exact: true }).click();
  await expect(page.getByTestId('farmer-row').filter({ hasText: `Sunita ${u}` })).toContainText(/-F-\d{4}/);
  await signOut(page);
});
