// HR by geography (migration 39, Veda 12 Oct 2026), on a 527 px screen as HR may use it. Imran (HR resource) works for
// Uttar Pradesh (seed 07); Asha is the HR Admin. A joiner based in Assam is out of Imran's reach until Asha gives him
// Assam on HR · Team; the base location is on the profile; nobody in HR is offered a seat. Also the fault found on the
// way: the Add joiner form's opening reached nobody (create-user dropped it); now the joiner page shows it.
import { test, expect } from '@playwright/test';
import { signIn, signOut, addJoiner, freshEmail, apiAs, expectNoSideScroll, USERS } from './helpers';
import { hi } from '../src/lib/i18n.hi';

test.use({ viewport: { width: 527, height: 900 } });
const u = String(Date.now()).slice(-6);

test('HR by geography: an HR resource works for her states; the HR Admin gives them; HR holds no seat; a base location for everyone', async ({ page }) => {
  test.setTimeout(240_000);
  // 1. Asha (HR Admin) adds a joiner based in Assam, district Nagaon
  await signIn(page, USERS.hrAdmin);
  const asName = `Geo Assam ${u}`;
  const as = await addJoiner(page, { name: asName, email: freshEmail('geoas'), type: 'contract', baseState: 'Assam', district: 'Nagaon' });
  await expect(page.getByTestId('base-location-text')).toHaveText('Assam · Nagaon');
  await expectNoSideScroll(page);
  // the HR Admin sees every state: no "you work for" line
  await page.goto('/hr');
  await expect(page.getByTestId('hr-scope')).toHaveCount(0);
  await signOut(page);

  // 2. Imran (Uttar Pradesh) does not see her, and adds people only for his state
  await signIn(page, USERS.hr);
  await page.goto('/hr');
  await expect(page.getByTestId('hr-scope')).toContainText('You work for: Uttar Pradesh');
  await page.locator('#jf-q').fill(asName);
  await expect(page.getByTestId('pipeline-row')).toHaveCount(0);
  await page.goto(`/hr/joiners/${as.id}`);
  await expect(page.getByRole('heading', { name: asName })).toHaveCount(0);
  await page.goto('/hr/joiners/new');
  await expect(page.locator('#j-base option')).toHaveText(['Uttar Pradesh', 'Uttar Pradesh']);   // the default (his one state), and it
  // the opening chosen on the form reaches the joiner (the fault of 12 Oct: create-user dropped it)
  const api = await apiAs(page);
  const opening = (await api.rpc('save_opening', { p: { state_id: '00000000-0000-4000-8000-000000000001', role: 'operator', stage: 'qc',
    positions: 2, scope_id: '00000000-0000-4000-8000-000000000401', title: `Geo test ${u}` } })).data as { id: string; code: string };
  const upName = `Geo UP ${u}`;
  const up = await addJoiner(page, { name: upName, email: freshEmail('geoup'), type: 'contract', district: 'Basti', openingId: opening.id });
  await expect(page.getByTestId('base-location-text')).toHaveText('Uttar Pradesh · Basti');
  const org = (await api.rows('employee_org', `employee_id=eq.${up.id}`))[0];
  expect(org).toMatchObject({ opening_id: opening.id, intended_role: 'operator', intended_stage: 'qc', base_district: 'Basti' });
  // Hindi, on the phone
  await page.goto('/hr');
  await page.getByLabel('Language').selectOption('hi');
  await expect(page.getByTestId('hr-scope')).toContainText(hi['geo.you_work_for'].split('{states}')[0].trim());
  await expectNoSideScroll(page);
  await page.getByLabel('Language').selectOption('en');
  await signOut(page);

  // 3. Asha gives Imran Assam on HR · Team; he reaches the Assam joiner; she takes it back
  await signIn(page, USERS.hrAdmin);
  await page.goto('/hr/team');
  const imran = page.locator('[data-testid="hr-person"][data-name="Imran (HR)"]');
  await expect(imran.getByTestId('hr-state-Uttar Pradesh')).toBeChecked();
  await imran.getByTestId('hr-state-Assam').check();
  await imran.getByTestId('hr-states-save').click();
  await expect(imran.getByTestId('hr-states-save')).toBeDisabled();
  await expectNoSideScroll(page);
  await signOut(page);
  await signIn(page, USERS.hr);
  await page.goto(`/hr/joiners/${as.id}`);
  await expect(page.getByRole('heading', { name: asName })).toBeVisible();
  await page.goto('/hr');
  await expect(page.getByTestId('hr-scope')).toContainText('Assam, Uttar Pradesh');
  await signOut(page);
  await signIn(page, USERS.hrAdmin);
  await page.goto('/hr/team');
  await imran.getByTestId('hr-state-Assam').uncheck();
  await imran.getByTestId('hr-states-save').click();
  await expect(imran.getByTestId('hr-states-save')).toBeDisabled();
  // HR holds no seat: Imran's profile offers no assignment; his states are shown
  await page.goto('/people/00000000-0000-4000-8000-000000000317');
  await expect(page.getByTestId('give-assignment')).toHaveCount(0);
  await expect(page.getByTestId('hr-states-line')).toContainText('Uttar Pradesh');
  // the base location is changed by HR of the state, and logged
  await page.goto(`/people/${up.id}`);
  await page.getByTestId('base-edit').click();
  await page.locator(`#bd-${up.id}`).fill('Gorakhpur');
  await page.getByTestId('base-save').click();
  await expect(page.getByTestId('base-location-text')).toHaveText('Uttar Pradesh · Gorakhpur');
  await page.goto('/system/audit');
  await page.getByTestId('audit-action').selectOption('base_location_set');
  await expect(page.getByTestId('audit-line').first()).toContainText(upName);
  await signOut(page);
});
