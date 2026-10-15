// Migration 50 (Veda, 15 Oct 2026: the operator-stages brief, release 3, "packs, proof and blocks"), on a 527 px screen,
// scope Basti mill (Procurement → QC → Milling → Packing → Commercial → Shipment → QR). The batch code is the system's;
// one label per pack, a reprint with a reason, a pack voided; a pack scanned before release says so; the delivery records
// what arrived (export: the proof of delivery first); the QR person reads a summary before release; the Client Manager
// recalls and every pack says so; the public page names no farmer. An export released on the client's acceptance needs
// the acceptance attached. Every rule is the database's (tests/44_packs_and_release.sql).
import { test, expect, type Page } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, openSlot, procure, recordQc, reviewAndSave, verifyIncoming, apiAs, USERS, SCOPES } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const S = SCOPES.bastiMill;
const PDF = (what: string) => ({ name: `${what}.pdf`, mimeType: 'application/pdf', buffer: Buffer.from(`%PDF-1.4\n% ${what} ${Date.now()}\n%%EOF\n`) });
/** The record a "saved" screen links to. */
const savedId = async (page: Page) => (await page.getByTestId('saved').locator('..').getByRole('link', { name: /^Open / }).getAttribute('href'))!.split('/').pop()!;

test('batch code, one label per pack, reprint and void, delivery, the summary before release, a recall on every pack', async ({ page }) => {
  test.setTimeout(420_000);

  await signIn(page, USERS.procurement); const p = await procure(page, S, 'Suresh Yadav', '199', '2', '2'); await signOut(page);   // 195 kg
  // the demo scopes are set not to ask for the lab report: its fields are there and the record is saved without them
  await signIn(page, USERS.qc); const q = await recordQc(page, S, p, '11.8'); await signOut(page);

  await signIn(page, USERS.mill);
  await openSlot(page, 'milling', S);
  await verifyIncoming(page, q);
  await page.getByRole('button', { name: /Record Milling/ }).click();
  await page.getByLabel(/Rice out/).fill('130'); await page.getByLabel(/^Bran/).fill('54'); await page.getByLabel(/^Loss/).fill('10');
  const m = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?M-\d{4}/); await signOut(page);

  // 1 · G1: the system gives the batch code; G8: one serial, one label per pack
  await signIn(page, USERS.sorting);
  await openSlot(page, 'packing', S);
  await verifyIncoming(page, m);
  await page.getByRole('button', { name: /Record Packing/ }).click();
  await expect(page.getByLabel(/Batch code/)).toHaveCount(0);
  await page.getByLabel('Packets 1').fill('100'); await page.getByLabel('Size (kg) 1').fill('1');
  await page.getByRole('button', { name: '+ packet size' }).click();
  await page.getByLabel('Packets 2').fill('58'); await page.getByLabel('Size (kg) 2').fill('0.5');
  await page.getByLabel(/^Wastage/).fill('1');
  const pk = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?PK-\d{4}/);
  const batch = (await page.getByTestId('packed').textContent())!.match(/PRSDM-KNM-KH26-B\d{4}/)![0];
  const pkId = await savedId(page);
  await page.getByTestId('packed').getByTestId('print-labels').click();
  await expect(page.getByTestId('reprint-note')).toHaveCount(0);
  await page.getByTestId('labels-go').click();
  await expect(page.getByTestId('labels-range')).toHaveText('Labels 1 to 120 of 158');
  await expect(page.getByTestId('pack-label')).toHaveCount(120);
  await expect(page.getByTestId('pack-label').first()).toContainText(`${batch}-0001`);
  await expect(page.getByTestId('pack-label').first()).toContainText('Packed');
  await expectNoSideScroll(page);
  await page.getByRole('button', { name: 'Next' }).click();
  await expect(page.getByTestId('pack-label')).toHaveCount(38);
  await expect(page.getByTestId('pack-label').last()).toContainText(`${batch}-0158`);
  // a second print is a reprint: it needs a reason
  await page.goto(`/records/${pkId}/labels`);
  await expect(page.getByTestId('reprint-note')).toContainText('printed 1 times before');
  await expect(page.getByTestId('labels-go')).toBeDisabled();
  await page.getByTestId('reprint-why').fill('roll jammed');
  await page.getByTestId('labels-go').click();
  await expect(page.getByTestId('pack-label')).toHaveCount(120);
  // a pack voided with a reason
  await page.goto(`/records/${pkId}`);
  const packs = page.getByTestId('packs-panel');
  await expect(packs.getByTestId('batch-code')).toHaveText(batch);
  await expect(packs.getByTestId('packs-count')).toHaveText('158 packed · 0 void');
  await packs.getByText(/Void a pack/).click();
  await packs.getByTestId('void-serial').fill(`${batch}-0158`);
  await packs.getByTestId('void-why').fill('short');
  await expect(packs.getByTestId('void-go')).toBeDisabled();
  await packs.getByTestId('void-why').fill('bag torn while stacking');
  await packs.getByTestId('void-go').click();
  await expect(packs.getByTestId('voided')).toBeVisible();
  await expect(packs.getByTestId('packs-count')).toHaveText('157 packed · 1 void');
  await expectNoSideScroll(page);
  await signOut(page);

  // 2 · Part D: a pack scanned before release; a void pack says so
  await page.goto(`/p/${batch}-0001`);
  await expect(page.getByTestId('pv-not-released')).toBeVisible();
  await expect(page.getByTestId('pv-pack')).toContainText(batch);
  await expect(page.getByTestId('public-journey')).toHaveCount(0);
  await expectNoSideScroll(page);
  await page.goto(`/p/${batch}-0158`);
  await expect(page.getByTestId('pv-void')).toBeVisible();

  await signIn(page, USERS.commercial);
  await openSlot(page, 'commercial', S);
  await verifyIncoming(page, pk);
  await page.getByRole('button', { name: /Record Commercial Clearance/ }).click();
  await page.getByLabel(/^Buyer/).fill('Amira Foods BV'); await page.getByLabel(/^Market/).selectOption('export');
  await page.getByLabel(/Quantity to this buyer/).fill('129');
  const cm = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?CM-\d{4}/); await signOut(page);

  // 3 · G12: the shipment asks no transit loss; the delivery records what arrived (export: the proof first)
  await signIn(page, USERS.shipment);
  await openSlot(page, 'shipment', S);
  await verifyIncoming(page, cm);
  await page.getByRole('button', { name: /Record Shipment/ }).click();
  await expect(page.getByLabel(/Transit loss/)).toHaveCount(0);
  await page.getByLabel(/Vehicle/).fill('MSKU7654321');
  await page.getByLabel(/Dispatch date/).fill(new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10));
  await page.getByLabel(/Destination/).fill('Rotterdam');
  const sh = await reviewAndSave(page, /PRSDM-KNM-KH26-(?:[A-Z]{2,4}-)?SH-\d{4}/);
  await page.getByRole('link', { name: `Open ${sh}` }).click();
  const dl = page.getByTestId('delivery-panel');
  await dl.getByTestId('delivery-kg').fill('128.5');
  await expect(dl.getByTestId('delivery-loss-preview')).toHaveText('Lost in transit: 0.5 kg');
  await dl.getByTestId('delivery-confirm').click();
  await expect(dl.locator('.alert.error')).toContainText('For export, attach the proof of delivery first.');
  await dl.getByTestId('delivery-pod').setInputFiles(PDF('pod'));
  await dl.getByTestId('delivery-confirm').click();
  await expect(page.getByTestId('delivery-panel').getByTestId('transit-loss')).toHaveText('0.5 kg');
  await expectNoSideScroll(page);
  await signOut(page);

  // 4 · G9: the summary before release, read and confirmed
  await signIn(page, USERS.qr);
  await openSlot(page, 'qr_activation', S);
  await verifyIncoming(page, sh);
  const sum = page.getByTestId('release-summary');
  await expect(sum).toContainText('Every step verified');
  await expect(sum).toContainText(`Packs: 157 (batch ${batch})`);
  await expect(sum).toContainText('Farmers in the lot: 1');
  await expect(page.getByTestId('seal-button')).toBeDisabled();
  await page.getByTestId('release-read').check();
  await page.getByTestId('seal-button').click();
  const code = (await page.getByTestId('sealed').textContent())!.match(/GV-[0-9A-F]{12}/)![0];
  await signOut(page);

  // after release the pack opens the lot's journey, with no farmer's name (Part D)
  await page.goto(`/p/${batch}-0001`);
  const pub = page.getByTestId('public-journey');
  await expect(pub).toBeVisible();
  await expect(page.getByTestId('pv-pack')).toContainText(`${batch}-0001`);
  await expect(pub).toContainText('Grown in Shohratgarh, Siddharthnagar');
  await expect(pub).not.toContainText('Suresh Yadav');
  await expect(page.getByTestId('pv-release')).toHaveCount(0);
  await expect(page.getByTestId('pv-packs')).toContainText('157 packs');

  // 5 · G10/C9: the Client Manager recalls; every pack says so, in both languages
  await signIn(page, USERS.cm);
  const api = await apiAs(page);
  const qrId = String((await api.rows('qr_seals', `qr_code=eq.${code}`))[0].footprint_id);
  await page.goto(`/records/${qrId}`);
  const rel = page.getByTestId('release-panel');
  await expect(rel).toHaveAttribute('data-status', 'active');
  await rel.getByTestId('release-to').selectOption('recalled');
  await expect(rel).toContainText('A recall is final');
  await rel.getByTestId('release-why').fill('moisture complaint from the buyer');
  await rel.getByTestId('release-go').click();
  await expect(page.getByTestId('release-panel')).toHaveAttribute('data-status', 'recalled');
  await expect(page.getByTestId('release-panel').getByTestId('release-to')).toHaveCount(0);   // a recall is not undone
  await signOut(page);
  for (const where of [`/p/${batch}-0077`, `/verify/${code}`]) {
    await page.goto(where);
    await expect(page.getByTestId('pv-release')).toHaveAttribute('data-status', 'recalled');
    await expect(page.getByTestId('pv-release')).toContainText('Recalled: do not use this lot');
    await expect(page.getByTestId('pv-release')).toContainText('moisture complaint from the buyer');
  }
  await page.getByLabel('Language').selectOption('hi');
  await expect(page.getByTestId('pv-release')).toContainText('वापस मँगाया गया');
});

test('an export released on the client\'s written acceptance needs it attached first', async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page, USERS.procurement); const p = await procure(page, SCOPES.basti, 'Ram Achal', '126', '3', '2', '12.4'); await signOut(page);
  await signIn(page, USERS.qc); await recordQc(page, SCOPES.basti, p, '12.4');
  const qId = await savedId(page);
  await signOut(page);
  await signIn(page, USERS.cm);
  await page.goto(`/records/${qId}`);
  const go = page.getByRole('button', { name: 'Override the export verdict' });
  await page.locator('#ov-reason').fill('buyer accepts 12.4 percent in writing');
  await expect(go).toBeDisabled();                                                     // no acceptance attached yet
  await page.getByTestId('acceptance-file').setInputFiles(PDF('acceptance'));
  await go.click();
  await expect(page.locator('.alert.warn', { hasText: 'buyer accepts 12.4 percent in writing' })).toBeVisible();
  await expect(page.locator('[data-label="acceptance"]')).toBeVisible();
  await expectNoSideScroll(page);
});
