// Migration 64 (Phase 2, release 1 of Veda's combined brief: the client registry), on a 527 px screen. Ram (State
// Manager, Uttar Pradesh) registers "ABC Exim" PAN first and takes it through the three gates on the screens: a GSTIN of
// another state refused in plain words, the documents uploaded, Diagnostic, the KYC tick, the first Active asked of the
// admin, who approves it from the Overview. Typing the same PAN again: "Already registered with GrainVeda". A client
// registered before the registry shows "PAN pending" (and GrainVeda's own brand says so); its PAN is typed once. The
// Client Manager reads his client's record without its files; the client's own login reads its company only.
// Every rule is the database's (tests/59_client_registry.sql).
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, fakePan, TINY_PDF, USERS } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const card = (page: Page) => page.getByTestId('client-state-card').filter({ hasText: 'Uttar Pradesh' });
const item = (page: Page, key: string) => card(page).locator(`[data-testid="gate-item"][data-key="${key}"]`);

async function upload(page: Page, kind: string, meta: Record<string, string> = {}) {
  const f = page.getByTestId('doc-upload');
  await f.getByLabel('Document').selectOption({ label: kind });
  for (const [label, value] of Object.entries(meta)) await f.getByLabel(label).fill(value);
  await f.getByLabel(/^File/).setInputFiles({ name: `${kind}.pdf`, mimeType: 'application/pdf', buffer: TINY_PDF });
  await f.getByTestId('doc-save').click();
  await expect(page.getByTestId('doc').filter({ hasText: kind }).first()).toBeVisible();
}

test('the client registry: PAN first, the three gates on the screens, the admin\'s approval, PAN pending, who reads what', async ({ page }) => {
  test.setTimeout(300_000);
  const u = String(Date.now()).slice(-6); const pan = fakePan(); const name = `ABC Exim ${u} Ltd`;

  // 1 · Gate 1: PAN first
  await signIn(page, USERS.sm);
  await page.goto('/clients');
  await page.getByTestId('client-new').click();
  await page.getByLabel('Entity type').selectOption('individual');
  await page.getByLabel(/^PAN/).fill(pan);
  await expect(page.getByTestId('pan-problem')).toContainText('P as the PAN');           // a company's PAN for an individual
  await page.getByLabel('Entity type').selectOption('company');
  await expect(page.getByTestId('pan-problem')).toHaveCount(0);
  await page.getByLabel(/^Legal name/).fill(name);
  await page.getByTestId('pan-check').click();
  const g1 = page.getByTestId('gate1-form');
  await g1.getByLabel('State it starts in').selectOption({ label: 'Uttar Pradesh' });
  await g1.getByLabel('Name', { exact: true }).fill('A. Kumar');
  await g1.getByLabel('Designation').fill('Director');
  await g1.getByLabel('Phone').fill('9000000001');
  await g1.getByLabel('Email').fill('a.kumar@abcexim.test');
  await g1.getByTestId('crops-of-interest').getByLabel('Kalanamak rice').check();
  await g1.getByLabel('How they came to us').selectOption('outreach');
  await expectNoSideScroll(page);
  await g1.getByTestId('client-create').click();
  await expect(card(page)).toHaveAttribute('data-status', 'prospect');
  await expect(card(page).locator('[data-testid="gate"][data-gate="1"]')).toHaveAttribute('data-done', '7');
  await expect(card(page).locator('[data-testid="gate"][data-gate="2"]')).toHaveAttribute('data-done', '0');
  await expect(page.getByTestId('pan')).toHaveText(pan);                                     // his own client: the PAN in full
  const url = page.url();

  // 2 · Gate 2: the details (a GSTIN of another state refused), the documents, Diagnostic
  const d = page.getByTestId('details-form');
  await d.getByLabel('Address').fill('12 Civil Lines');
  await d.getByLabel('City').fill('Gorakhpur');
  await d.getByLabel('State', { exact: true }).fill('Uttar Pradesh');
  await d.getByLabel(/^CIN/).fill('U01100UP2025PTC123456');
  await d.getByLabel(/^GSTIN/).fill(`05${pan}1Z5`);                                          // Uttarakhand's code
  await d.getByLabel('Authorised signatory').fill('A. Kumar');
  await d.getByLabel('Designation').fill('Director');
  await d.getByTestId('details-save').click();
  await expect(d.getByRole('alert')).toContainText('starts with this state\'s code');
  await d.getByLabel(/^GSTIN/).fill(`09${pan}1Z5`);
  await d.getByTestId('details-save').click();
  await expect(item(page, 'gstin')).toHaveAttribute('data-done', 'yes');
  await expect(item(page, 'reg_office')).toHaveAttribute('data-done', 'yes');
  await expect(page.getByTestId('move-diagnostic')).toBeDisabled();
  await upload(page, 'Diagnostic order or agreement', { 'Signed on': '2026-10-20', 'Amount (₹)': '50000' });
  await upload(page, 'Certificate of incorporation');
  await expect(card(page).locator('[data-testid="gate"][data-gate="2"]')).toHaveAttribute('data-done', '6');
  await page.getByTestId('move-diagnostic').click();
  await expect(card(page)).toHaveAttribute('data-status', 'diagnostic');

  // 3 · Gate 3: billing, the national documents, the KYC tick, the first Active asked of the admin
  await d.getByLabel('Billing contact').fill('Accounts, ABC Exim');
  await d.getByLabel('Invoice email').fill('accounts@abcexim.test');
  await d.getByTestId('details-save').click();
  await expect(item(page, 'billing')).toHaveAttribute('data-done', 'yes');
  await expect(item(page, 'iec')).toHaveCount(0);                                            // no export scope yet: no IEC asked
  await upload(page, 'Master Services Agreement', { 'Signed on': '2026-10-20', 'Term ends on': '2029-10-19' });
  await upload(page, 'Farmer Data and Consent Addendum', { 'Signed on': '2026-10-20' });
  await upload(page, 'Signatory authority');
  await page.getByTestId('kyc-tick').click();
  await expect(card(page).getByTestId('kyc-done')).toBeVisible();
  await page.getByTestId('move-active').click();
  await expect(card(page).getByTestId('awaiting-approval')).toBeVisible();
  await expect(card(page)).toHaveAttribute('data-status', 'diagnostic');
  await expectNoSideScroll(page);

  // the same PAN again: "Already registered with GrainVeda", and no second client
  await page.goto('/clients/new');
  await page.getByLabel('Entity type').selectOption('company');
  await page.getByLabel(/^PAN/).fill(pan);
  await page.getByLabel(/^Legal name/).fill('ABC Exim Limited');
  await page.getByTestId('pan-check').click();
  await expect(page.getByTestId('already-registered')).toContainText('Already registered with GrainVeda');
  await expect(page.getByTestId('gate1-form')).toHaveCount(0);
  await signOut(page);

  // 4 · the admin approves the first Active from the Overview
  await signIn(page, USERS.admin);
  await page.goto('/');
  await page.getByTestId('ov-approval').filter({ hasText: name }).getByRole('link').click();
  await page.getByTestId('approve').click();
  await expect(card(page)).toHaveAttribute('data-status', 'active');
  await expect(page.getByTestId('pan')).toHaveText(pan);
  await expect(page.getByTestId('details-form')).toHaveCount(0);                             // the admin fills no gate
  await expectNoSideScroll(page);
  await signOut(page);

  // 5 · a client registered before the registry: "PAN pending", GrainVeda's own brand; its PAN typed once
  await signIn(page, USERS.sm);
  await page.goto('/clients/00000000-0000-4000-8000-000000000201');
  await expect(page.getByTestId('own-brand-note')).toContainText('Operated by GrainVeda (own brand)');
  await expect(card(page).getByTestId('legacy-note')).toBeVisible();
  if (await page.getByTestId('set-pan-open').count()) {                                     // not yet typed on this stack
    await expect(page.getByTestId('pan-pending').first()).toBeVisible();
    await page.getByTestId('set-pan-open').click();
    await page.getByTestId('set-pan').getByLabel('PAN').fill(fakePan(Date.now() + 77));
    await page.getByTestId('set-pan').getByRole('button').click();
    await expect(page.getByTestId('pan-pending')).toHaveCount(0);
  }
  await signOut(page);

  // 6 · the Client Manager reads his client's record (not its files); the client's own login reads its company only
  await signIn(page, USERS.cm);
  await page.goto('/clients');
  await expect(page.getByTestId('client-row')).toHaveCount(1);
  await page.getByTestId('client-row').getByRole('link').click();
  await expect(page.getByTestId('identity')).toBeVisible();
  await expect(page.getByTestId('gates')).toHaveCount(0);
  await expect(page.getByTestId('doc-list')).toHaveCount(0);
  await page.goto(url);
  await expect(page.getByTestId('client-page')).toHaveCount(0);                              // ABC Exim is not his
  await signOut(page);
  await signIn(page, USERS.view);
  await page.goto('/clients');
  await expect(page.getByTestId('client-new')).toHaveCount(0);
  await expect(page.getByTestId('client-row')).toHaveCount(1);
  await expectNoSideScroll(page);
});
