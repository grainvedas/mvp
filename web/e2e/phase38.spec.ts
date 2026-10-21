// Migration 66 (Phase 2, release 3 of Veda's combined brief: Parts E, F and G), on a 527 px screen. The Client Manager
// of GrainVeda's own brand (client 201) registers an FPO by its PAN as a sourcing partner of Siddharthnagar's scope, with
// "Partner agrees to be named publicly", and marks Ram Achal a member of it. At the farm gate "Procured through" is
// pre-filled with that FPO and the farmers can be filtered to its members. The lot is tested and sealed; its public
// page says "Operated by GrainVeda (own brand)" and "Sourced through" the FPO, and still no farmer's name. Every rule is
// the database's (tests/61_sourcing_partners_hooks.sql).
import { test, expect } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, openSlot, pickFarmer, fillWhere, reviewAndSave, recordQc, sealLot, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const S = SCOPES.siddharthnagar;
const RAM_ACHAL = '00000000-0000-4000-8000-000000000501';
/** A fake, format-valid PAN of an association or cooperative (4th letter A), different each run. */
function fakeFpoPan(seed = Date.now()): string {
  const L = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  return `ZZZA${L[Math.floor(seed / 10000) % L.length]}${String(seed).slice(-4)}${L[Math.floor(seed / 7) % L.length]}`;
}

test('a sourcing partner on a scope, named publicly; a member farmer; "Procured through" at the farm gate; the public page', async ({ page }) => {
  test.setTimeout(360_000);
  const u = String(Date.now()).slice(-5); const fpo = `Bansi Kisan FPO ${u} (test)`;

  // 1 · the Client Manager: the partner, by its PAN, on the scope; named publicly
  await signIn(page, USERS.cm);
  const cm = await apiAs(page);                    // a run before left its partner here: one partner, so the form pre-fills it
  for (const x of ((await cm.rpc('scope_partners', { p_scope: S })).data as { entity_id: string }[]) ?? [])
    await cm.rpc('remove_scope_partner', { p_scope: S, p_entity: x.entity_id, p_reason: 'e2e phase38: a fresh partner for this run' });
  await page.goto(`/scopes/${S}`);
  const card = page.getByTestId('scope-partners');
  await expect(card).toBeVisible();
  await card.getByTestId('sp-register-open').click();
  const reg = card.getByTestId('sp-register');
  await reg.getByLabel('Entity type').selectOption('cooperative');
  await reg.getByLabel('PAN').fill(fakeFpoPan());
  await reg.getByLabel(/^Legal name/).fill(fpo);
  await reg.getByTestId('sp-register-go').click();
  await expect(card.getByTestId('sp-pick')).toHaveValue(/[0-9a-f-]{36}/);                // the new partner chosen
  await card.getByTestId('sp-named').check();
  await card.getByTestId('sp-add').click();
  const row = card.getByTestId('sp-row').filter({ hasText: fpo });
  await expect(row).toHaveAttribute('data-named', 'yes');
  await expectNoSideScroll(page);

  // Ram Achal is a member of it
  await page.goto(`/farmers/${RAM_ACHAL}`);
  const m = page.getByTestId('farmer-membership');
  await expect(m.getByTestId('farmer-member').locator('option', { hasText: fpo })).toBeAttached();
  const opt = (await m.getByTestId('farmer-member').locator('option').allTextContents()).find((x) => x.startsWith(fpo))!;
  await m.getByTestId('farmer-member').selectOption({ label: opt });
  await m.getByTestId('farmer-member-save').click();
  await expect(m.getByTestId('farmer-member-save')).toBeDisabled();
  await expectNoSideScroll(page);
  await signOut(page);

  // 2 · the farm gate: "Procured through" pre-filled, the farmers filtered to the FPO's members
  await signIn(page, USERS.procurement);
  await openSlot(page, 'procurement', S);
  await expect(page.getByTestId('pick-procured_through').locator('option:checked')).toHaveText(fpo);
  await page.getByTestId('pick-member').selectOption({ label: `${fpo} members` });
  await expect(page.getByTestId('pick-village').locator('option')).toHaveCount(2);      // the members' one village
  await pickFarmer(page, 'Ram Achal');
  await page.getByLabel(/Gross weight/).fill('102');
  await page.getByLabel(/^Bags/).fill('2');
  await page.getByLabel(/Tare per bag/).fill('1');
  for (const i of [1, 2, 3]) await page.getByLabel(`Moisture (3 readings) ${i}`).fill('11.8');
  await fillWhere(page);
  await expectNoSideScroll(page);
  const p = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?P-\d{4}/);
  await signOut(page);
  await signIn(page, USERS.qc); const q = await recordQc(page, S, p, '11.8'); await signOut(page);
  await signIn(page, USERS.qr); const code = await sealLot(page, S, q); await signOut(page);

  // 3 · the public page: GrainVeda's own brand; sourced through the FPO, which agreed; no farmer's name
  await page.goto(`/verify/${code}`);
  await expect(page.getByTestId('pv-own-brand')).toHaveText('Operated by GrainVeda (own brand)');
  await expect(page.getByTestId('pv-sourced')).toContainText(fpo);
  await expect(page.getByTestId('pv-not-farm-verified')).toHaveCount(0);
  await expect(page.getByTestId('public-journey')).not.toContainText('Ram Achal');
  await expectNoSideScroll(page);
});
