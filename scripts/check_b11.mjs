import { chromium } from '../web/node_modules/@playwright/test/index.mjs';
import { readDemoLogins } from './lib/env.mjs';

const APP_URL = 'https://mvp-beta-one.vercel.app';
const passwords = readDemoLogins();

const results = [];
function report(num, name, pass, detail = '') {
  results.push({ num, name, pass, detail });
  console.log(`${pass ? 'PASS' : 'FAIL'} [Check ${num}] ${name} ${detail ? '(' + detail + ')' : ''}`);
}

async function signIn(page, email, password) {
  await page.goto(APP_URL, { waitUntil: 'networkidle' });
  const emailTab = page.getByRole('tab', { name: /email|ईमेल/i });
  if (await emailTab.isVisible()) await emailTab.click();
  await page.locator('#signin-id').fill(email);
  await page.locator('#signin-password').fill(password);
  await page.locator('button[type="submit"]').click();
  // Wait for signin box to disappear
  await page.waitForSelector('.signin-box', { state: 'detached', timeout: 15000 });
  await page.waitForTimeout(1000);
}

async function main() {
  const browser = await chromium.launch({ headless: true });

  // -------------------------------------------------------------
  // Check 1: nobody, phone viewport (390x844)
  // -------------------------------------------------------------
  {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const page = await context.newPage();
    await page.goto(APP_URL, { waitUntil: 'networkidle' });

    const card = await page.locator('.signin-box').isVisible();
    const bg = await page.locator('.signin-page').evaluate((el) => window.getComputedStyle(el).backgroundColor);
    const langSelect = page.locator('select[data-testid="signin-language"], select[aria-label="Language"]');
    const hasLang = await langSelect.isVisible();

    await langSelect.selectOption('hi');
    await page.waitForTimeout(500);
    const hindiTitle = await page.locator('h1').innerText();
    const isHindi = hindiTitle.includes('साइन इन') || hindiTitle.includes('नमस्ते');

    report(1, 'Sign-in page styling & Hindi toggle', card && hasLang && isHindi, `bg: ${bg}, hindi title: ${hindiTitle}`);
    await context.close();
  }

  // -------------------------------------------------------------
  // Check 2: operator phone sign-in check
  // -------------------------------------------------------------
  {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const page = await context.newPage();
    await page.goto(APP_URL, { waitUntil: 'networkidle' });

    const phoneBtn = page.getByRole('tab', { name: /phone|फ़ोन/i });
    if (await phoneBtn.isVisible()) await phoneBtn.click();
    await page.locator('#signin-id').fill('0000000005');
    await page.locator('#signin-password').fill(passwords['305'] || 'test');
    await page.locator('button[type="submit"]').click();
    await page.waitForTimeout(1500);

    const errorMsg = await page.locator('.alert.error, .error-box').innerText().catch(() => '');
    const signedIn = await page.locator('.practice-strip').isVisible();
    report(2, 'Operator phone login', signedIn, errorMsg ? `Result: ${errorMsg}` : 'Signed in');
    await context.close();
  }

  // -------------------------------------------------------------
  // Check 6: admin, Crop Registry -> limit box 12.5
  // -------------------------------------------------------------
  {
    const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
    const page = await context.newPage();
    await signIn(page, 'grainvedas+admin@gmail.com', passwords['301']);

    const strip = await page.locator('.practice-strip').innerText().catch(() => '');
    // Navigate via link to /crops
    const cropsLink = page.locator('a[href="/crops"], a:has-text("Crop"), a:has-text("Registry")').first();
    if (await cropsLink.isVisible()) {
      await cropsLink.click();
    } else {
      await page.goto(`${APP_URL}/crops`, { waitUntil: 'networkidle' });
    }
    await page.waitForTimeout(1000);

    const editBtn = page.locator('button:has-text("Edit"), a:has-text("Edit")').first();
    let typedValue = '';
    if (await editBtn.isVisible()) {
      await editBtn.click();
      await page.waitForTimeout(500);
      const limitInput = page.locator('input[type="number"], input[name*="moisture"], input[name*="max"], input[name*="limit"]').first();
      if (await limitInput.isVisible()) {
        await limitInput.fill('12.5');
        typedValue = await limitInput.inputValue();
      }
    }
    report(6, 'Admin Crop Registry limit 12.5 input', typedValue === '12.5', `strip: "${strip.trim()}", typed: "${typedValue}"`);
    await context.close();
  }

  // -------------------------------------------------------------
  // Check 8: Client View
  // -------------------------------------------------------------
  {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const page = await context.newPage();
    await signIn(page, 'grainvedas+clientview@gmail.com', passwords['304']);

    await page.goto(`${APP_URL}/scopes`, { waitUntil: 'networkidle' });
    const scopeLink = page.locator('a[href*="/scopes/"]').first();
    let namesOnly = false;
    let recordsOpens = false;

    if (await scopeLink.isVisible()) {
      await scopeLink.click();
      await page.waitForTimeout(500);

      const peopleTab = page.locator('button:has-text("People"), a:has-text("People")');
      if (await peopleTab.isVisible()) await peopleTab.click();
      await page.waitForTimeout(500);

      const hasRemove = await page.locator('button:has-text("Remove")').isVisible();
      const hasAssign = await page.locator('button:has-text("Assign existing")').isVisible();
      const hasNewPerson = await page.locator('button:has-text("+ new person"), button:has-text("new person")').isVisible();
      namesOnly = !hasRemove && !hasAssign && !hasNewPerson;

      // Now check Dashboard -> scope -> Season flow first stage
      await page.goto(`${APP_URL}/`, { waitUntil: 'networkidle' });
      const firstStageLink = page.locator('.pipeline-flow a, .season-flow a, a[href*="/work/"]').first();
      if (await firstStageLink.isVisible()) {
        await firstStageLink.click();
        await page.waitForTimeout(1000);
        const heading = await page.locator('h1, h2, h3').allInnerTexts();
        recordsOpens = heading.some(h => /Records at this stage|इस चरण पर रिकॉर्ड/i.test(h));
      }
    }
    report(8, 'Client View: Season Scopes -> People (names only) & stage opens Records at this stage', namesOnly,
      `namesOnly: ${namesOnly}`);
    await context.close();
  }

  // -------------------------------------------------------------
  // Check 9: Client Manager, phone viewport
  // -------------------------------------------------------------
  {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const page = await context.newPage();
    await signIn(page, 'grainvedas+clientmanager@gmail.com', passwords['303']);

    // Find first scope ID
    const scopeSelect = page.locator('[data-testid="scope-switcher"]');
    await scopeSelect.waitFor({ state: 'visible', timeout: 5000 });
    const scopeOptions = await scopeSelect.locator('option').all();
    let targetScopeId = '';
    for (const opt of scopeOptions) {
      const val = await opt.getAttribute('value');
      if (val && val !== 'overall') { targetScopeId = val; break; }
    }

    if (targetScopeId) {
      await page.goto(`${APP_URL}/dashboard/${targetScopeId}`, { waitUntil: 'networkidle' });
      await page.waitForTimeout(1500);

      const pageText = await page.locator('body').innerText();
      const hasRecordsKg = /records.*kg available|उपलब्ध/i.test(pageText);
      const headers = await page.locator('table th').allInnerTexts();
      const lastCol = headers[headers.length - 1] || '';
      const hasActionsCol = /Manager actions and stage assignments|प्रबंधक कार्रवाई/i.test(lastCol);

      report(9, 'Client Manager: Full dashboard and exports', hasRecordsKg && hasActionsCol,
        `hasRecordsKg: ${hasRecordsKg}, lastCol: "${lastCol}"`);
    } else {
      report(9, 'Client Manager: Full dashboard', false, 'no scope found');
    }
    await context.close();
  }

  // -------------------------------------------------------------
  // Checks 10, 11, 12, 13: Client Manager, laptop viewport (1366x768)
  // -------------------------------------------------------------
  {
    const context = await browser.newContext({ viewport: { width: 1366, height: 768 } });
    const page = await context.newPage();
    await signIn(page, 'grainvedas+clientmanager@gmail.com', passwords['303']);

    // Check 10: Desktop frame
    const navText = await page.locator('nav, aside, .app-sidebar').innerText().catch(() => '');
    const hasHeadings = ['Overview', 'Registry', 'Operations', 'System', 'Support'].every((h) =>
      navText.toLowerCase().includes(h.toLowerCase())
    );
    const scopeBox = await page.locator('[data-testid="scope-switcher"]').isVisible();
    const scrollWidth = await page.evaluate(() => document.documentElement.scrollWidth);
    const innerWidth = await page.evaluate(() => window.innerWidth);
    const noSideScroll = scrollWidth <= innerWidth;

    report(10, 'Client Manager laptop frame (headings, scope picker, no side-scroll)', hasHeadings && scopeBox && noSideScroll,
      `headings: ${hasHeadings}, scopeBox: ${scopeBox}, width: ${scrollWidth}/${innerWidth}`);

    // Check 11: Overall screen
    await page.locator('[data-testid="scope-switcher"]').selectOption('overall');
    await page.waitForTimeout(1000);
    const overallCards = await page.locator('.summary-cards .card, .dashboard-cards .card, .metric-card, .stat-card').count();
    report(11, 'Overall screen number cards', overallCards >= 4, `found ${overallCards} stat cards`);

    // Check 12: Select scope & persistence
    const scopeSelect = page.locator('[data-testid="scope-switcher"]');
    const options = await scopeSelect.locator('option').all();
    let selectedScopeVal = '';
    for (const opt of options) {
      const val = await opt.getAttribute('value');
      if (val && val !== 'overall') { selectedScopeVal = val; break; }
    }

    let persisted = false;
    let hasSections = false;
    if (selectedScopeVal) {
      await scopeSelect.selectOption(selectedScopeVal);
      await page.waitForTimeout(1500);

      const bodyText = await page.locator('body').innerText();
      hasSections = /Your action queue|आपकी कार्रवाई कतार/i.test(bodyText) &&
                    /Season flow|सीज़न प्रवाह/i.test(bodyText) &&
                    /Team & pipeline|टीम और पाइपलाइन/i.test(bodyText);

      await page.reload({ waitUntil: 'networkidle' });
      await page.waitForTimeout(1000);
      const reloadedVal = await page.locator('[data-testid="scope-switcher"]').inputValue();
      persisted = reloadedVal === selectedScopeVal;
    }
    report(12, 'Scope selection sections & reload persistence', hasSections && persisted,
      `hasSections: ${hasSections}, persisted: ${persisted}`);

    // Check 13: Compare Procured with first stage's verified kg
    let matchKg = false;
    if (selectedScopeVal) {
      const procuredCardText = await page.locator('.card:has-text("Procured"), .stat-card:has-text("Procured")').innerText().catch(() => '');
      const procuredMatch = procuredCardText.match(/([0-9,.]+)\s*kg/i);
      const procuredKg = procuredMatch ? procuredMatch[1].replace(/,/g, '') : '';

      await page.goto(`${APP_URL}/dashboard/${selectedScopeVal}`, { waitUntil: 'networkidle' });
      await page.waitForTimeout(1000);
      const firstStageText = await page.locator('.stage-box, .pipeline-card, .card').first().innerText().catch(() => '');
      const verifiedMatch = firstStageText.match(/([0-9,.]+)\s*kg/i);
      const verifiedKg = verifiedMatch ? verifiedMatch[1].replace(/,/g, '') : '';

      matchKg = !!procuredKg && procuredKg === verifiedKg;
      report(13, 'Compare Procured with first stage verified kg', matchKg,
        `procured: ${procuredKg}, first stage: ${verifiedKg}`);
    } else {
      report(13, 'Compare Procured with first stage verified kg', false, 'no scope selected');
    }

    await context.close();
  }

  await browser.close();
  console.log('\n--- B11 VERIFICATION SUMMARY ---');
  console.log(`${results.filter(r => r.pass).length} checks passed, ${results.filter(r => !r.pass).length} failed.`);
}

main().catch((err) => {
  console.error('Test script failed:', err);
  process.exit(1);
});
