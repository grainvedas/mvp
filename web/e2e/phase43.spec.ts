// Migration 72 (Phase 3, release 5 of Veda's combined brief: Part E3, F, A4), on a 527 px screen. Prasaadam (GrainVeda's
// own brand, which has no owner of its own) has no public page until the admin approves it from its portfolio; then
// /verified/PRSDM shows its name, "Operated by GrainVeda (own brand)", the figures, "Verify any pack", no price and no
// farmer's name; the card gives the badge and its snippet. Suspended in every state, the page says "Verification paused";
// resumed, it does not. The client's viewer reads the card and approves nothing. Unpublished with a reason, nothing is
// public. The Audit log names the page. Who approves for a client with an owner, recalls, partners, the lifetime period
// and the outputs' verify pages after it are the database's (tests/67_showcase_lifetime.sql). Item 73: the line above
// the name says "verified" only while active; the client's status lines in the Audit log name it.
import { test, expect } from '@playwright/test';
import { signIn, signOut, expectNoSideScroll, apiAs, USERS } from './helpers';

test.use({ viewport: { width: 527, height: 900 } });
const PRSDM = '00000000-0000-4000-8000-000000000201';
const ok = (r: { ok: boolean; data: unknown }) => expect(r.ok, JSON.stringify(r.data)).toBe(true);

test('the showcase page: approved by the admin for the own brand, public, paused when suspended, unpublished', async ({ page, browser }) => {
  test.setTimeout(240_000);
  const visitor = await (await browser.newContext({ viewport: { width: 527, height: 900 } })).newPage();
  // a stack this test ran on before: its page taken down first
  await signIn(page, USERS.admin);
  const before = await (await apiAs(page)).rpc('showcase_of', { p_client: PRSDM });
  if ((before.data as { status: string }).status === 'published') ok(await (await apiAs(page)).rpc('showcase_unpublish', { p_client: PRSDM, p_reason: 'e2e72: a run before' }));
  // nothing public before it is approved
  await visitor.goto('/verified/PRSDM');
  await expect(visitor.getByTestId('sc-none')).toBeVisible();

  // the admin: Prasaadam's portfolio → Showcase page: preview, then approve and publish
  await page.goto(`/portfolio/${PRSDM}`);
  const card = page.getByTestId('showcase-card');
  await expect(card).toBeVisible();
  await expect(card.getByTestId('sh-status')).toContainText(/Not published|Unpublished on/);              // a stack run before leaves it unpublished
  await card.getByTestId('sh-preview').click();
  await expect(page.getByTestId('sc-preview')).toBeVisible();
  await expect(page.getByTestId('sc-own-brand')).toHaveText('Operated by GrainVeda (own brand)');
  await expectNoSideScroll(page);
  await page.goto(`/portfolio/${PRSDM}`);
  await card.getByTestId('sh-publish').click();
  await expect(card.getByTestId('sh-publish-confirm')).toBeVisible();
  await card.getByTestId('sh-publish-go').click();
  await expect(card).toHaveAttribute('data-status', 'published');
  await expect(card.getByTestId('sh-snippet')).toHaveValue(/\/verified\/PRSDM" target="_blank" rel="noopener"><img src="[^"]+\/api\/badge\?c=PRSDM"/);
  await expect(card.getByTestId('sh-badge-img')).toBeVisible();
  await expectNoSideScroll(page);

  // the public page, on a phone
  await visitor.goto('/verified/prsdm');
  await expect(visitor.getByTestId('sc-name')).toHaveText('GrainVeda (Prasaadam trade scope)');
  await expect(visitor.getByTestId('sc-own-brand')).toHaveText('Operated by GrainVeda (own brand)');
  await expect(visitor.getByTestId('sc-banner')).toHaveAttribute('data-status', 'active');
  await expect(visitor.getByTestId('sc-totals')).toBeVisible();
  await expect(visitor.getByTestId('sc-state').first()).toBeVisible();
  const text = await visitor.getByTestId('showcase').innerText();
  expect(text).not.toMatch(/₹|INR|price/i);                                                   // never a price
  expect(text).not.toContain('Suresh Yadav');                                                  // never a farmer's name
  await expectNoSideScroll(visitor);
  await visitor.getByTestId('sc-code').fill('GV-000000000000');
  await visitor.getByTestId('sc-go').click();
  await expect(visitor).toHaveURL(/\/verify\/GV-000000000000$/);

  // suspended in every state: "Verification paused" on the page; resumed: active again
  const admin = await apiAs(page);
  ok(await admin.rpc('client_set_status', { p_client: PRSDM, p_state: null, p_to: 'suspended', p_reason: 'e2e72: every state paused' }));
  await visitor.goto('/verified/PRSDM');
  await expect(visitor.getByTestId('sc-banner')).toHaveAttribute('data-status', 'paused');
  await expect(visitor.getByTestId('sc-banner')).toContainText('Verification paused');
  await expect(visitor.getByText('Verified by GrainVeda', { exact: true })).toHaveCount(0);
  await expect(visitor.getByTestId('sc-eyebrow')).toHaveText('Showcase · GrainVeda');                     // item 73 (1)
  ok(await admin.rpc('client_set_status', { p_client: PRSDM, p_state: null, p_to: 'active', p_reason: 'e2e72: every state resumed' }));
  await visitor.goto('/verified/PRSDM');
  await expect(visitor.getByTestId('sc-banner')).toHaveAttribute('data-status', 'active');
  await expect(visitor.getByTestId('sc-eyebrow')).toHaveText('Showcase · verified by GrainVeda');
  await signOut(page);

  // the client's own login: a viewer reads the card and approves nothing (phase39 makes it the client's owner when the
  // whole suite runs: an owner may unpublish it, so it is offered)
  await signIn(page, USERS.view);
  const me = await apiAs(page);
  const kind = ((await me.rpc('my_context')).data as { user?: { client_account?: { kind?: string } } }).user?.client_account?.kind;
  await page.goto('/portfolio');
  const vc = page.getByTestId('showcase-card');
  await expect(vc).toHaveAttribute('data-status', 'published');
  await expect(vc.getByTestId('sh-publish')).toHaveCount(0);                                   // published already
  if (kind === 'viewer') {
    await expect(vc.getByTestId('sh-unpublish')).toHaveCount(0);
    const refused = await me.rpc('showcase_unpublish', { p_client: PRSDM, p_reason: 'a viewer tries' });
    expect(refused.ok).toBe(false);
  } else {
    expect(kind).toBe('owner');
    await expect(vc.getByTestId('sh-unpublish')).toBeVisible();
  }
  await expectNoSideScroll(page);
  await signOut(page);

  // the admin unpublishes it, with a reason; nothing is public; the Audit log names the page
  await signIn(page, USERS.admin);
  await page.goto(`/portfolio/${PRSDM}`);
  await card.getByTestId('sh-unpublish').click();
  await card.getByTestId('sh-why').fill('e2e72: taken down after the check');
  await card.getByTestId('sh-unpublish-go').click();
  await expect(card).toHaveAttribute('data-status', 'unpublished');
  await expect(card.getByTestId('sh-status')).toContainText('e2e72: taken down after the check');
  await visitor.goto('/verified/PRSDM');
  await expect(visitor.getByTestId('sc-none')).toBeVisible();
  await page.goto('/system/audit');
  await expect(page.locator('[data-action="showcase_published"]').first()).toContainText('published the showcase page of');
  await expect(page.locator('[data-action="showcase_unpublished"]').first()).toContainText('PRSDM');
  await expect(page.locator('[data-action="client_status"]').first().getByTestId('audit-client')).toHaveText('PRSDM');   // item 73 (3)
  await expect(page.locator('[data-action="client_status"]').first().getByTestId('audit-client')).toHaveAttribute('href', `/clients/${PRSDM}`);
  await expectNoSideScroll(page);
  await signOut(page);
  await visitor.context().close();
});
