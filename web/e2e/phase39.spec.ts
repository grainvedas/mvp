// Migration 67 (Phase 3, release 1 of Veda's combined brief: Part A, with Phase 2's B4), on a 527 px screen. The admin
// makes an owner of GrainVeda's own client on its page (Client accounts); the owner signs in, sets its password and
// invites a viewer of the Siddharthnagar scope only; that viewer sees that scope and nothing else, and no stage page.
// The Client Manager sets the scope Hybrid (with its reason) and adds the client's own staff, who then appears in the
// scope's roster pool; back to Managed once that is seen. Every rule is the database's (tests/62_client_accounts.sql).
import { test, expect } from '@playwright/test';
import { signIn, signOut, signInWith, setOwnPassword, expectNoSideScroll, apiAs, freshEmail, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const CLIENT = '00000000-0000-4000-8000-000000000201';
const S = SCOPES.siddharthnagar;
const temp = async (page: import('@playwright/test').Page) =>
  (await page.getByTestId('temp-password').textContent())!.match(/: (Gv-[A-Za-z0-9_-]+) —/)![1];

test('client accounts: the admin\'s owner, the owner\'s viewer of one scope, the Client Manager\'s Hybrid scope and client staff', async ({ page }) => {
  test.setTimeout(300_000);
  const ownerEmail = freshEmail('owner67'); const viewerEmail = freshEmail('viewer67'); const staffEmail = freshEmail('staff67');

  // 1 · the admin makes an owner on the client's page
  await signIn(page, USERS.admin);
  await page.goto(`/clients/${CLIENT}`);
  const card = page.getByTestId('client-accounts');
  await expect(card).toBeVisible();
  await expect(card.getByTestId('ca-row').filter({ hasText: 'Prasaadam Client View' })).toBeVisible();          // the login of before (A3)
  const form = card.getByTestId('ca-new');
  await expect(form.getByTestId('ca-owner-note')).toBeVisible();                                               // the admin makes owners only
  await form.getByLabel('Full name').fill('Prasaadam Owner (e2e)');
  await form.getByLabel('Personal email').fill(ownerEmail);
  await form.getByTestId('ca-create').click();
  await expect(form.getByTestId('temp-password')).toContainText(ownerEmail);
  const ownerPw = await temp(page);
  await expect(card.getByTestId('ca-row').filter({ hasText: 'Prasaadam Owner (e2e)' })).toHaveAttribute('data-kind', 'owner');
  await expectNoSideScroll(page);
  await signOut(page);

  // 2 · the owner: its own password, then a viewer of the Siddharthnagar scope only
  await signInWith(page, ownerEmail, ownerPw);
  await setOwnPassword(page, 'Owner-67-e2e');
  await page.goto(`/clients/${CLIENT}`);
  const oc = page.getByTestId('client-accounts');
  const of = oc.getByTestId('ca-new');
  await of.getByLabel('Full name').fill('Siddharthnagar Desk (e2e)');
  await of.getByLabel('Personal email').fill(viewerEmail);
  await of.getByTestId('ca-reach-pick').selectOption('scopes');
  await of.getByTestId('ca-scopes-pick').getByLabel(/· Siddharthnagar$/).check();
  await of.getByTestId('ca-create').click();
  await expect(of.getByTestId('temp-password')).toContainText(viewerEmail);
  const viewerPw = await temp(page);
  await expect(oc.getByTestId('ca-row').filter({ hasText: 'Siddharthnagar Desk (e2e)' }).getByTestId('ca-reach')).toContainText('Siddharthnagar');
  await expectNoSideScroll(page);
  await signOut(page);

  // 3 · the viewer sees that scope and nothing else of its client; no stage page
  await signInWith(page, viewerEmail, viewerPw);
  await setOwnPassword(page, 'Viewer-67-e2e');
  const v = await apiAs(page);
  const scopes = await v.rows('scopes', 'select=id');
  expect(scopes.map((s) => s.id)).toEqual([S]);
  await page.goto(`/work/${S}/procurement`);
  await expect(page).toHaveURL(/\/$/);                                                                          // sent home: it reads only
  expect((await v.rpc('prepare_client_account', { p_client: CLIENT, p_kind: 'viewer', p_email: 'x@example.test', p_reach: 'scopes', p_scopes: [S] })).ok).toBe(false);
  await signOut(page);

  // 4 · the Client Manager: the scope Hybrid (with a reason); the client's own staff in its roster pool
  await signIn(page, USERS.cm);
  await page.goto(`/scopes/${S}`);
  const sd = page.getByTestId('scope-delivery');
  await sd.getByTestId('sd-model-pick').selectOption('hybrid');
  await sd.getByTestId('sd-why').fill('the client runs its own collection desk (e2e)');
  await sd.getByTestId('sd-save').click();
  await expect(sd.getByTestId('sd-saved')).toBeVisible();
  await expectNoSideScroll(page);
  await page.goto('/people');
  await page.getByRole('tab', { name: /Client logins/ }).click();
  const pf = page.getByRole('form', { name: 'New client login' });
  await pf.getByTestId('ca-kind').selectOption('operator');
  await pf.getByLabel('Full name').fill('Prasaadam Field Staff (e2e)');
  await pf.getByLabel('Personal email').fill(staffEmail);
  await pf.getByTestId('ca-create').click();
  await expect(pf.getByTestId('temp-password')).toContainText(staffEmail);
  const cm = await apiAs(page);
  const pool = (await cm.rpc('roster_pool', { p_scope: S })).data as { name: string }[];
  expect(pool.map((p) => p.name)).toContain('Prasaadam Field Staff (e2e)');
  const managedPool = (await cm.rpc('roster_pool', { p_scope: SCOPES.gorakhpur })).data as { name: string }[] | null;
  expect((managedPool ?? []).map((p) => p.name)).not.toContain('Prasaadam Field Staff (e2e)');                // a Managed scope: never
  await page.goto(`/scopes/${S}`);
  await sd.getByTestId('sd-model-pick').selectOption('managed');
  await sd.getByTestId('sd-why').fill('back to GrainVeda people (e2e done)');
  await sd.getByTestId('sd-save').click();
  await expect(sd.getByTestId('sd-saved')).toBeVisible();
  await signOut(page);
});
