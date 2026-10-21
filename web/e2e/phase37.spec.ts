// Migration 65 (Phase 2, release 2 of Veda's combined brief: Parts C and D), on a 527 px screen. Ram (State Manager of
// Uttar Pradesh) is given Assam too by the HR Admin for this test (taken back at the end). A client Active in Uttar
// Pradesh: Ram types its PAN again and "Add Assam to this client"; Assam goes through its own gates on the screens (a UP
// GSTIN refused for Assam) and is Active on his KYC tick, with no second approval; the admin is told ("… added in Assam
// by UP State Manager"). Client 201 suspended in Uttar Pradesh: its public page says "Verification paused"; resumed. An
// FSSAI licence 30 days from expiry warns on the Clients page. The client's own login uploads a renewed MSA; Ram is told
// and accepts it. Every rule is the database's (tests/60_client_states_status.sql).
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, onboardClient, approveClient, procure, recordQc, sealLot, refusal, TINY_PDF, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const RAM = '00000000-0000-4000-8000-000000000302';
const ASSAM = '00000000-0000-4000-8000-000000000002';
const CLIENT = '00000000-0000-4000-8000-000000000201';
const card = (page: Page, state: string) => page.locator(`[data-testid="client-state-card"][data-state="${state}"]`);
const isoIn = (days: number) => new Date(Date.now() + days * 86_400_000 + 5.5 * 3_600_000).toISOString().slice(0, 10);

/** A lot of client 201 sealed already (an earlier test's), or one sealed here through Siddharthnagar. */
async function aSealedLot(page: Page): Promise<string> {
  await signIn(page, USERS.admin);
  const api = await apiAs(page);
  const fps = await api.rows('footprints', `select=id&stage_type=eq.qr_activation&scope_id=in.(${Object.values(SCOPES).join(',')})&limit=40`);
  for (const f of fps) {
    const s = await api.rows('qr_seals', `select=qr_code&footprint_id=eq.${f.id}`);
    if (s.length) { await signOut(page); return String(s[0].qr_code); }
  }
  await signOut(page);
  const S = SCOPES.siddharthnagar;
  await signIn(page, USERS.procurement); const p = await procure(page, S, 'Ram Achal', '102', '2', '1'); await signOut(page);
  await signIn(page, USERS.qc); const q = await recordQc(page, S, p, '11.8'); await signOut(page);
  await signIn(page, USERS.qr); const code = await sealLot(page, S, q); await signOut(page);
  return code;
}

test('a state added to a client, its gates, the notice; suspended and resumed; the warning; a renewal accepted', async ({ page, browser }) => {
  test.setTimeout(480_000);
  const u = String(Date.now()).slice(-6); const name = `XYZ Agro ${u} Ltd`;
  const code = await aSealedLot(page);

  // the client, Active in Uttar Pradesh (its gates on the screens are phase36's)
  await signIn(page, USERS.sm);
  const c = await onboardClient(page, { name, exports: false });
  await signOut(page);
  await signIn(page, USERS.admin); await approveClient(page, c.id); await signOut(page);

  // Ram is given Assam as well, for this test
  await signIn(page, USERS.hrAdmin);
  const hr = await apiAs(page);
  const seat = await hr.rpc('assign', { p_employee: RAM, p_lens: 'state', p_target: ASSAM, p_op_role: 'state_supervisor', p_stages: [], p_posting: '', p_ends_on: null });
  expect(seat.ok, refusal(seat)).toBe(true);
  const seatId = String((seat.data as { assignment: { id: string } }).assignment.id);
  await signOut(page);
  let suspended = false;
  try {
    // 1 · C: "Already registered with GrainVeda" → "Add Assam to this client"
    await signIn(page, USERS.sm);
    await page.goto('/clients/new');
    await page.getByLabel('Entity type').selectOption('company');
    await page.getByLabel(/^PAN/).fill(c.pan);
    await page.getByLabel(/^Legal name/).fill(name);
    await page.getByTestId('pan-check').click();
    await expect(page.getByTestId('already-registered')).toContainText('Already registered with GrainVeda');
    await expect(page.getByTestId('gate1-form')).toHaveCount(0);
    await expectNoSideScroll(page);
    await page.getByTestId('add-state').filter({ hasText: 'Add Assam to this client' }).click();
    await expect(card(page, 'Assam')).toHaveAttribute('data-status', 'prospect');
    await expect(card(page, 'Uttar Pradesh')).toHaveAttribute('data-status', 'active');
    await expect(page.getByTestId('add-state')).toHaveCount(0);

    // Assam's own gates: its GSTIN (Assam's code 18, the same PAN), signatory, billing, its diagnostic order
    const d = card(page, 'Assam').getByTestId('details-form');
    await d.getByLabel(/^GSTIN/).fill(`09${c.pan}1Z5`);
    await d.getByLabel('Authorised signatory').fill('A. Bora');
    await d.getByLabel('Designation').fill('Director');
    await d.getByLabel('Billing contact').fill('Accounts, Guwahati');
    await d.getByLabel('Invoice email').fill('ghy@xyzagro.test');
    await d.getByTestId('details-save').click();
    await expect(d.getByRole('alert')).toContainText('starts with this state\'s code');
    await d.getByLabel(/^GSTIN/).fill(`18${c.pan}1Z5`);
    await d.getByTestId('details-save').click();
    await expect(card(page, 'Assam').locator('[data-testid="gate-item"][data-key="gstin"]')).toHaveAttribute('data-done', 'yes');
    await expect(card(page, 'Assam').locator('[data-testid="gate-item"][data-key="msa"]')).toHaveAttribute('data-done', 'yes');   // national: reused
    const up = card(page, 'Assam').getByTestId('doc-upload');
    await up.getByLabel('Document').selectOption({ label: 'Diagnostic order or agreement' });
    await up.getByLabel('Signed on').fill('2026-10-21');
    await up.getByLabel('Amount (₹)').fill('20000');
    await up.getByLabel(/^File/).setInputFiles({ name: 'order.pdf', mimeType: 'application/pdf', buffer: TINY_PDF });
    await up.getByTestId('doc-save').click();
    await expect(card(page, 'Assam').locator('[data-testid="gate"][data-gate="2"]')).toHaveAttribute('data-done', '6');
    await card(page, 'Assam').getByTestId('move-diagnostic').click();
    await expect(card(page, 'Assam')).toHaveAttribute('data-status', 'diagnostic');
    await card(page, 'Assam').getByTestId('kyc-tick').click();
    await card(page, 'Assam').getByTestId('move-active').click();
    await expect(card(page, 'Assam')).toHaveAttribute('data-status', 'active');          // no second approval
    await expect(card(page, 'Assam').getByTestId('awaiting-approval')).toHaveCount(0);
    await expectNoSideScroll(page);

    // 4 · D: an FSSAI licence 30 days from expiry warns (60 days ahead), never suspends
    const api = await apiAs(page);
    const fs = await api.rpc('save_client_details', { p_client: c.id, p_state: (await api.rows('states', 'select=id&name=eq.Uttar%20Pradesh'))[0].id,
      p: { fssai: { number: '10026999000001', expires_on: isoIn(30) } } });
    expect(fs.ok, refusal(fs)).toBe(true);
    await page.goto('/clients');
    await expect(page.getByTestId('expiries').locator(`[data-testid="expiry"][data-client="${c.code}"][data-kind="fssai"]`)).toHaveAttribute('data-level', 'd60');
    await expectNoSideScroll(page);

    // 2 · D: client 201 suspended in Uttar Pradesh: "Verification paused" on its released page; resumed
    await page.goto(`/clients/${CLIENT}`);
    const c201 = card(page, 'Uttar Pradesh');
    await c201.getByTestId('status-suspended').click();
    await c201.getByTestId('status-why').fill('Practice (test): payment overdue');
    await c201.getByTestId('status-go').click();
    suspended = true;
    await expect(c201).toHaveAttribute('data-status', 'suspended');
    await expect(c201.getByTestId('status-note')).toContainText('Verification paused');
    await expectNoSideScroll(page);
    const anon = await browser.newPage({ viewport: { width: 527, height: 900 } });
    await anon.goto(`/verify/${code}`);
    await expect(anon.getByTestId('pv-verification')).toHaveAttribute('data-status', 'paused');
    await expect(anon.getByTestId('pv-verification')).toContainText('Verification paused');
    await expect(anon.getByTestId('pv-journey')).toBeVisible();                            // already released: still live
    await c201.getByTestId('status-active').click();
    await c201.getByTestId('status-why').fill('Practice (test): payment received');
    await c201.getByTestId('status-go').click();
    await expect(c201).toHaveAttribute('data-status', 'active');
    suspended = false;
    await anon.reload();
    await expect(anon.getByTestId('pv-journey')).toBeVisible();
    await expect(anon.getByTestId('pv-verification')).toHaveCount(0);
    await anon.close();
    await signOut(page);

    // C: the admin is told
    await signIn(page, USERS.admin);
    const n = page.getByTestId('notice').filter({ hasText: `${name} added in Assam by UP State Manager` });
    await expect(n).toBeVisible();
    await page.getByTestId('notices-read').click();
    await expect(n).toHaveCount(0);
    await signOut(page);

    // 5 · B5: the client's own login uploads a renewed MSA; Ram is told and accepts it
    await signIn(page, USERS.view);
    await page.goto(`/clients/${CLIENT}`);
    const f = page.getByTestId('renewal-form');
    await f.getByLabel('Document').selectOption({ label: 'Master Services Agreement' });
    await f.getByLabel('Signed on').fill('2026-10-21');
    await f.getByLabel('Term ends on').fill('2029-10-20');
    await f.getByLabel(/^File/).setInputFiles({ name: 'msa-renewed.pdf', mimeType: 'application/pdf', buffer: TINY_PDF });
    await f.getByTestId('renewal-save').click();
    await expect(page.getByTestId('renewal').first()).toHaveAttribute('data-decided', 'waiting');
    await expect(page.getByTestId('status-actions')).toHaveCount(0);                       // the login moves no status
    await expectNoSideScroll(page);
    await signOut(page);
    await signIn(page, USERS.sm);
    await expect(page.getByTestId('notice').filter({ hasText: 'a renewed Master Services Agreement uploaded by' }).first()).toBeVisible();
    await page.goto(`/clients/${CLIENT}`);
    const r = page.getByTestId('renewal').filter({ has: page.getByTestId('renewal-accept') }).first();
    await r.getByTestId('renewal-accept').click();
    await expect(page.getByTestId('renewal').first()).toHaveAttribute('data-decided', 'accepted');
    await signOut(page);
  } finally {
    if (suspended) {
      await signIn(page, USERS.sm);
      await (await apiAs(page)).rpc('client_set_status', { p_client: CLIENT, p_state: '00000000-0000-4000-8000-000000000001', p_to: 'active', p_reason: 'Practice (test): put back after a failed run' });
      await signOut(page);
    }
    await signIn(page, USERS.hrAdmin);
    await (await apiAs(page)).rpc('end_assignment', { p_assignment: seatId, p_reason: 'e2e phase37: the test is done' });
    await signOut(page);
  }
});
