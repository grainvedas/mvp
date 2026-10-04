import { chromium } from '../web/node_modules/@playwright/test/index.mjs';
import { readDemoLogins } from './lib/env.mjs';

async function test() {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  page.on('console', msg => console.log('PAGE LOG:', msg.text()));
  page.on('pageerror', err => console.log('PAGE ERROR:', err.message));
  await page.goto('https://mvp-beta-one.vercel.app', { waitUntil: 'networkidle' });

  const pw = readDemoLogins()['301'];
  await page.getByRole('tab', { name: /email/i }).click();
  await page.locator('#signin-id').fill('grainvedas+admin@gmail.com');
  await page.locator('#signin-password').fill(pw);
  await page.locator('button[type="submit"]').click();
  await page.waitForTimeout(3000);

  const err = await page.locator('.alert.error, .error-box').innerText().catch(() => '');
  console.log('Error displayed on page:', err);
  console.log('Page body HTML sample:', (await page.locator('body').innerHTML()).slice(0, 300));
  await browser.close();
}
test();
