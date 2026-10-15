// The crop registry (migration 42, Veda 13 Oct 2026, State Manager brief part C), on a 527 px screen: the State
// Manager makes a crop ready (yield, typed limits, practices, harvest window, recommended chain); the Client Manager's
// wizard starts from that chain and does not offer a crop that is not ready; the Client Manager answers a farmer's
// practice; Procurement is refused while a required practice is open and warned for an optional one and outside the
// harvest window; the lab's verdict follows the types; the admin removes an unused crop and retires one in use. Every
// rule is also the database's (tests/36_crop_registry.sql).
import { test, expect } from '@playwright/test';
import { signIn, signOut, apiAs, expectNoSideScroll, openSlot, refusal, verifyIncoming, USERS } from './helpers';
import { hi } from '../src/lib/i18n.hi';

test.use({ viewport: { width: 527, height: 900 } });
const PRSDM = '00000000-0000-4000-8000-000000000201';
const UP = '00000000-0000-4000-8000-000000000001';
const letters = (n: number) => String(n).split('').map((d) => 'ABCDEFGHIJ'[Number(d)]).join('');
const u = Date.now();
const CODE = `Q${letters(u).slice(-3)}`;                 // a new code each run (unique within Uttar Pradesh)
const NOTREADY = `Z${letters(u).slice(-3)}`;
const NAME = `Test basmati ${CODE}`;
const month = Number(new Intl.DateTimeFormat('en-IN', { timeZone: 'Asia/Kolkata', month: 'numeric' }).format(new Date()));
const away = (k: number) => ((month - 1 + k) % 12) + 1;    // a harvest window that does not hold this month

test('The crop registry: a ready crop, the wizard, the farmer\'s practice, Procurement and the lab, the admin\'s acts', async ({ page }) => {
  test.setTimeout(300_000);
  // 1 · Ram makes the crop ready, on the phone
  await signIn(page, USERS.sm);
  await page.goto('/crops');
  await page.getByRole('button', { name: 'Add a crop' }).click();
  const form = page.getByTestId('crop-form');
  await form.getByLabel('Name', { exact: true }).fill(NAME);
  await form.getByLabel(/^Code/).fill(CODE);
  await form.getByLabel(/^Yield per acre/).fill('1100');
  await form.getByLabel('Harvest from').selectOption(String(away(2)));
  await form.getByLabel('Harvest to').selectOption(String(away(3)));
  // a number, a grade and a yes/no limit
  await form.getByRole('button', { name: '+ limit' }).click();
  let row = form.getByTestId('limit-row').nth(0);
  await row.getByLabel('label', { exact: true }).fill('Moisture'); await row.getByLabel('key', { exact: true }).fill('moisture_pct');
  await row.getByLabel('domestic limit').fill('14'); await row.getByLabel('export limit').fill('13');
  await form.getByRole('button', { name: '+ limit' }).click();
  row = form.getByTestId('limit-row').nth(1);
  await row.getByLabel('label', { exact: true }).fill('Aroma'); await row.getByLabel('key', { exact: true }).fill('aroma');
  await row.getByLabel('type').selectOption('grade');
  await row.getByLabel('grades').fill('A, B, C');
  await form.getByRole('button', { name: '+ limit' }).click();
  row = form.getByTestId('limit-row').nth(2);
  await row.getByLabel('label', { exact: true }).fill('Live insects'); await row.getByLabel('key', { exact: true }).fill('live_insects');
  await row.getByLabel('type').selectOption('yesno');
  // two practices: the seed source (required, a choice) and the sowing date (optional)
  await form.getByTestId('gap-add').click();
  await form.getByTestId('gap-row').nth(0).getByLabel('Practice').fill('Seed source');
  await form.getByTestId('gap-row').nth(0).getByLabel('Type').selectOption('choice');
  await form.getByTestId('gap-row').nth(0).getByLabel('Options').fill('certified, farm_saved');
  await form.getByTestId('gap-required-0').check();
  await form.getByTestId('gap-add').click();
  await form.getByTestId('gap-row').nth(1).getByLabel('Practice').fill('Sowing date');
  await form.getByTestId('gap-row').nth(1).getByLabel('Type').selectOption('date');
  await form.getByTestId('doc-add').click();
  await form.getByLabel('Export documents').fill('Phytosanitary certificate');
  await expect(form.getByTestId('crop-form-ready')).toContainText('recommended chain');
  await form.getByTestId('crop-chain-start').click();
  await expect(form.getByTestId('crop-chain-preview')).toContainText('Procurement (farm-gate) → Quality Control → QR Activation (seal)');
  await expect(form.getByTestId('crop-form-ready')).toContainText('ready for a scope');
  await expectNoSideScroll(page);
  await form.getByRole('button', { name: 'Save' }).click();
  const card = page.getByTestId('crop-row').filter({ hasText: NAME });
  await expect(card.getByTestId('crop-ready')).toBeVisible();
  await expect(card.getByTestId('crop-state')).toHaveText('Uttar Pradesh');
  await expect(card).toContainText('Aroma A, B / A');
  await expect(card).toContainText('Seed source *');
  await expect(card.getByTestId('crop-use')).toContainText('not used yet');
  await expectNoSideScroll(page);
  // a crop that is not ready, made over the API as he could
  const ram = await apiAs(page);
  const nr = await ram.insert('crops', { name: `Not ready ${NOTREADY}`, code: NOTREADY, primary_unit: 'kg', state_id: UP });
  expect(nr.ok, refusal(nr)).toBe(true);
  const crop = (await ram.rows('crops', `code=eq.${CODE}&state_id=eq.${UP}`))[0] as { id: string; quality_params: unknown[] };
  expect(crop.quality_params).toHaveLength(3);
  await page.reload();
  await expect(page.getByTestId('crop-row').filter({ hasText: NOTREADY }).getByTestId('crop-missing')).toContainText('yield per acre, a quality limit, recommended chain');
  // his overview counts ready crops
  await page.goto('/');
  await expect(page.getByTestId('sh-crops-ready')).toBeVisible();
  await signOut(page);

  // 2 · the Client Manager's wizard: a crop that is not ready is not offered; the chain starts from the recommended one
  await signIn(page, USERS.cm);
  await page.goto('/scopes/new');
  await page.getByLabel(/Geography/).fill(`Registry ${CODE}`);
  await page.getByRole('button', { name: 'Next' }).click();
  await expect(page.locator('#wz-crop option', { hasText: NOTREADY })).toBeDisabled();
  await expect(page.getByTestId('wz-not-ready')).toBeVisible();
  await page.getByLabel('Crop').selectOption({ label: NAME });
  await page.getByRole('button', { name: 'Next' }).click();
  await expect(page.getByTestId('chain-preview')).toContainText('Procurement (farm-gate) → Quality Control → QR Activation (seal)');
  await expectNoSideScroll(page);
  // the scope itself, and its people, as the wizard would make them
  const cm = await apiAs(page);
  const sc = await cm.insert('scopes', { client_id: PRSDM, crop_id: crop.id, season_code: 'KH27', geography: `Registry ${CODE}`, chain: ['procurement', 'qc', 'qr_activation'], state_id: UP,
    stage_details_required: false });   // migration 53: this test is the crop registry; e2e/phase25 draws the sample first
  expect(sc.ok, refusal(sc)).toBe(true);
  const scope = (sc.data as { id: string }[])[0].id;
  const nrCrop = (await cm.rows('crops', `code=eq.${NOTREADY}`))[0] as { id: string };
  const bad = await cm.insert('scopes', { client_id: PRSDM, crop_id: nrCrop.id, season_code: 'KH27', geography: `Not ready ${CODE}`, chain: ['procurement', 'qc', 'qr_activation'], state_id: UP, status: 'active' });
  expect(refusal(bad)).toContain('this crop is not ready');
  // a person at every stage first (migration 44, A3), then it is activated
  for (const [who, stage] of [['00000000-0000-4000-8000-000000000305', 'procurement'], ['00000000-0000-4000-8000-000000000306', 'qc'], ['00000000-0000-4000-8000-000000000307', 'qr_activation']] as const)
    expect((await cm.rpc('assign', { p_employee: who, p_lens: 'scope', p_target: scope, p_op_role: 'operator', p_stages: [stage], p_posting: '', p_ends_on: null })).ok).toBe(true);
  expect((await cm.update('scopes', `id=eq.${scope}`, { status: 'active' })).ok).toBe(true);
  // 3 · the farmer's practice, on the farmer's page
  const farmers = await cm.rows('farmers', `client_id=eq.${PRSDM}&status=eq.active&order=name&limit=2`) as { id: string; name: string }[];
  const [answered, open] = farmers;
  await page.goto(`/farmers/${answered.id}`);
  const gap = page.getByTestId('farmer-gap');
  await expect(gap.getByRole('button', { name: 'Record practices' })).toBeVisible();                 // loaded
  if (await gap.getByLabel('Crop').count()) await gap.getByLabel('Crop').selectOption({ label: NAME });
  await expect(gap.getByTestId('gap-open-required')).toContainText('Seed source');
  await gap.getByLabel('Seed source *').selectOption('certified');
  await gap.getByTestId('gap-save').click();
  await expect(gap.getByTestId('gap-open-optional')).toContainText('Sowing date');
  await expectNoSideScroll(page);
  await signOut(page);

  // 4 · Procurement: refused while a required practice is open; warned for an optional one and outside the harvest window
  await signIn(page, USERS.procurement);
  const op = await apiAs(page);
  const lot = (farmer: string) => op.insert('footprints', { scope_id: scope, client_id: PRSDM, stage_type: 'procurement', farmer_id: farmer,
    created_by: '00000000-0000-4000-8000-000000000305', payload: { gross_kg: 100, bags: 2, tare_kg_per_bag: 1, moisture_pct: [12, 12, 12],
      collection_point_id: 'farm', gps_lat: 26.76, gps_lng: 83.37, delivered_by: 'farmer' } });   // migration 52: a new scope asks where, GPS, who
  const refused = await lot(open.id);
  expect(refusal(refused)).toContain('good farming practice not complete for this farmer');
  const ok = await lot(answered.id);
  expect(ok.ok, refusal(ok)).toBe(true);
  const p1 = (ok.data as { id: string; warnings: string[] }[])[0];
  expect(p1.warnings).toContain('good farming practice not filled: Sowing date');
  expect(p1.warnings.some((w) => w.startsWith('outside the harvest window'))).toBe(true);
  await signOut(page);

  // 5 · the lab, on the screen: a grade and a yes/no are picked, the preview and the saved verdict follow the types
  await signIn(page, USERS.qc);
  await openSlot(page, 'qc', scope);
  await verifyIncoming(page, (p1 as unknown as { footprint_code: string }).footprint_code);
  await page.getByRole('button', { name: /Record Quality Control for this lot/ }).click();
  await page.getByLabel(/Sample drawn/).fill('0.5');
  await page.getByLabel(/^Moisture \(%\)/).fill('12.5');
  await page.getByLabel(/^Aroma/).selectOption('B');
  await page.getByLabel(/^Live insects/).selectOption('no');
  // migration 50 (C5): a new scope asks for the lab report: the lab, its number and date, and the file
  await page.getByLabel('Lab *', { exact: true }).fill('Basti Grain Lab');
  await page.getByLabel('Report number *', { exact: true }).fill(`BGL-${Date.now() % 100000}`);
  await page.getByLabel('Report date *', { exact: true }).fill(new Date(Date.now() + 5.5 * 3600e3).toISOString().slice(0, 10));
  await page.getByLabel('Lab report (PDF or photo) *', { exact: true }).setInputFiles({ name: 'report.pdf', mimeType: 'application/pdf', buffer: Buffer.from(`%PDF-1.4\n% report ${Date.now()}\n%%EOF\n`) });
  await expect(page.getByTestId('verdict-preview')).toContainText('domestic passed · export not met');
  await expect(page.getByTestId('verdict-preview')).toContainText('Aroma (export)');
  await expectNoSideScroll(page);
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByLabel('I have checked these numbers against the lot').check();
  await page.getByRole('button', { name: 'Save record' }).click();
  await expect(page.getByTestId('saved')).toBeVisible();
  const lab = await apiAs(page);
  const qrow = (await lab.rows('footprints', `scope_id=eq.${scope}&stage_type=eq.qc`))[0] as { id: string; payload: { readings: Record<string, unknown> } };
  expect(qrow.payload.readings).toEqual({ moisture_pct: 12.5, aroma: 'B', live_insects: false });
  const v = (await lab.rows('qc_verdicts', `footprint_id=eq.${qrow.id}`))[0] as { domestic_verdict: string; export_verdict: string };
  expect([v.domestic_verdict, v.export_verdict]).toEqual(['pass', 'fail']);
  await page.goto(`/records/${qrow.id}`);
  const judged = page.locator('table').filter({ hasText: 'Aroma' });
  await expect(judged.getByRole('row').filter({ hasText: 'Aroma' })).toContainText('B');
  await expect(judged.getByRole('row').filter({ hasText: 'Live insects' })).toContainText('No');
  await expectNoSideScroll(page);
  await signOut(page);

  // 6 · Ram's ledger offers the lab operator who signed in his state under "Signed by"
  await signIn(page, USERS.sm);
  await page.goto('/system/ledger');
  await expect(page.getByTestId('ledger-person').locator('option', { hasText: 'QC Technician' })).toHaveCount(1);
  // Hindi, on the phone
  await page.goto('/crops');
  await page.getByLabel('Language').selectOption('hi');
  await expect(page.getByRole('button', { name: hi['crops.create'] })).toBeVisible();
  await expectNoSideScroll(page);
  await page.getByLabel('Language').selectOption('en');
  await signOut(page);

  // 7 · the admin: removes the unused crop, retires the crop in use; both in the Audit log
  await signIn(page, USERS.admin);
  await page.goto('/crops');
  const unused = page.getByTestId('crop-row').filter({ hasText: NOTREADY });
  await expect(unused.getByRole('button', { name: 'Edit' })).toHaveCount(0);
  await unused.getByTestId('crop-remove').click();
  await unused.getByLabel('Reason').fill('added by mistake');
  await unused.getByTestId('crop-admin-confirm').click();
  await expect(page.getByTestId('crop-row').filter({ hasText: NOTREADY })).toHaveCount(0);
  const used = page.getByTestId('crop-row').filter({ hasText: NAME });
  await expect(used.getByTestId('crop-remove')).toHaveCount(0);                 // in use: retire, not remove
  await used.getByTestId('crop-retire').click();
  await used.getByLabel('Reason').fill('replaced by a new variety');
  await used.getByTestId('crop-admin-confirm').click();
  await expect(used.getByTestId('crop-retired-note')).toContainText('replaced by a new variety');
  await expectNoSideScroll(page);
  await page.goto('/system/audit');
  await expect(page.locator('li', { hasText: 'removed the crop' }).filter({ hasText: NOTREADY })).toBeVisible();
  await expect(page.locator('li', { hasText: 'retired the crop' }).filter({ hasText: NAME })).toBeVisible();
  await signOut(page);
  // the Client Manager closes the test scope: its seats end with it (the demo operators hold their five scopes again)
  await signIn(page, USERS.cm);
  expect((await (await apiAs(page)).update('scopes', `id=eq.${scope}`, { status: 'closed' })).ok).toBe(true);
  await signOut(page);
});
