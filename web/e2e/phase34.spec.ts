// Migration 62 (Phase 1, release 4 of Veda's combined brief of 19 Oct 2026: E2.1, only shipped packs are released), on a
// 527 px screen, scope Basti mill (it asks no shipment details). A lot packed as 100 × 1 kg and 58 × 500 g is sold by the
// kilogram, 40 kg to one buyer. The Shipment form asks the codes loaded although nothing else is asked; 39 packs for
// 40 kg are refused in plain words; the 40 packs are added by From/To. The QR step says how many packs go live and how
// many stay held. After the seal a shipped pack says "Genuine pack, sealed record"; a pack of the same batch that was
// not shipped says "Packed, not yet released". Every rule is the database's (tests/57_shipped_packs.sql).
import { test, expect } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, openSlot, procure, recordQc, reviewAndSave, verifyIncoming, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const S = SCOPES.bastiMill;

test('a packed lot sold by the kilogram ships by its codes; only the shipped packs go live', async ({ page }) => {
  test.setTimeout(420_000);

  await signIn(page, USERS.procurement); const p = await procure(page, S, 'Suresh Yadav', '199', '2', '2'); await signOut(page);   // 195 kg
  await signIn(page, USERS.qc); const q = await recordQc(page, S, p, '11.8'); await signOut(page);

  await signIn(page, USERS.mill);
  await openSlot(page, 'milling', S);
  await verifyIncoming(page, q);
  await page.getByRole('button', { name: /Record Milling/ }).click();
  await page.getByLabel(/^Head rice/).fill('130'); await page.getByLabel(/^Broken rice/).fill('0'); await page.getByLabel(/^Husk/).fill('54'); await page.getByLabel(/^Bran/).fill('0');
  const m = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?M-\d{4}/); await signOut(page);

  await signIn(page, USERS.sorting);
  await openSlot(page, 'packing', S);
  await verifyIncoming(page, m);
  await page.getByRole('button', { name: /Record Packing/ }).click();
  await page.getByLabel('Packets 1').fill('100'); await page.getByLabel('Size (kg) 1').fill('1');
  await page.getByRole('button', { name: '+ packet size' }).click();
  await page.getByLabel('Packets 2').fill('58'); await page.getByLabel('Size (kg) 2').fill('0.5');
  const pk = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?PK-\d{4}/);
  const batch = (await page.getByTestId('packed').textContent())!.match(/PRSDM-KNM-KH26-B\d{4}/)![0];
  await signOut(page);

  // sold by the kilogram: 40 kg to one buyer
  await signIn(page, USERS.commercial);
  await openSlot(page, 'commercial', S);
  await verifyIncoming(page, pk);
  await page.getByRole('button', { name: /Record Commercial Clearance/ }).click();
  await page.getByLabel(/^Buyer/).fill('Lucknow Retail'); await page.getByLabel(/^Market/).selectOption('domestic');
  await page.getByLabel(/Quantity to this buyer/).fill('40');
  const cm = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?CM-\d{4}/); await signOut(page);

  // the shipment: the codes are asked although the scope asks no details; 39 packs for 40 kg are refused
  await signIn(page, USERS.shipment);
  await openSlot(page, 'shipment', S);
  await verifyIncoming(page, cm);
  await page.getByRole('button', { name: /Record Shipment/ }).click();
  await expect(page.getByLabel(/^Shipped/)).toHaveValue('40');
  await expect(page.getByTestId('pack-codes')).toBeVisible();
  await page.getByLabel(/Vehicle/).fill('UP55T1234');
  await page.getByLabel(/Dispatch date/).fill(new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10));
  await page.getByLabel(/Destination/).fill('Lucknow');
  await page.getByTestId('pc-range').click();
  await page.getByTestId('pc-from').fill(`${batch}-0001`); await page.getByTestId('pc-to').fill(`${batch}-0039`);
  await page.getByTestId('pc-range-add').click();
  await expect(page.getByTestId('preview-error')).toContainText('The packs loaded weigh 39 kg; the shipment is 40 kg. Add or remove codes.');
  // the range box stays open
  await page.getByTestId('pc-from').fill(`${batch}-0040`); await page.getByTestId('pc-to').fill(`${batch}-0040`);
  await page.getByTestId('pc-range-add').click();
  await expect(page.getByTestId('serials-count')).toHaveText('40 pack codes');
  await expect(page.getByTestId('preview-ok')).toContainText('40 kg');
  await expectNoSideScroll(page);
  const sh = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?SH-\d{4}/); await signOut(page);

  // the QR step: 40 go live, 118 stay held
  await signIn(page, USERS.qr);
  await openSlot(page, 'qr_activation', S);
  await verifyIncoming(page, sh);
  await expect(page.getByTestId('release-summary')).toContainText(`Packs that go live with this seal: 40 (batch ${batch}). Not yet released: 118.`);
  await expectNoSideScroll(page);
  await page.getByTestId('release-read').check();
  await page.getByRole('button', { name: 'Activate and seal' }).click();
  await expect(page.getByTestId('sealed')).toContainText(/GV-[0-9A-F]{12}/);
  await signOut(page);

  // a shipped pack, and one of the same batch that stayed behind
  await page.goto(`/p/${batch}-0040`);
  await expect(page.getByTestId('pv-seal-title')).toHaveText('Genuine pack, sealed record');
  await expect(page.getByTestId('public-journey')).not.toContainText('Suresh Yadav');
  await expectNoSideScroll(page);
  await page.goto(`/p/${batch}-0041`);
  await expect(page.getByTestId('pv-not-released')).toBeVisible();
  await expect(page.getByTestId('pv-not-released')).toContainText('Packed, not yet released');
  await expect(page.getByTestId('public-journey')).toHaveCount(0);
  await expectNoSideScroll(page);
});
