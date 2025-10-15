import { chromium, expect, Page, Locator } from 'playwright';
import * as fs from 'fs';
import * as path from 'path';
import 'dotenv/config';
import dotenv from 'dotenv';

const STORAGE = path.resolve('./storage_state.json');
const ITG_URL = 'https://app.itglue.com';

const env = (k: string, req = true) => {
  const v = process.env[k];
  if (!v && req) throw new Error(`Missing env: ${k}`);
  return v || '';
};

// Load default .env and the repo-scoped env file if present
dotenv.config();
dotenv.config({ path: path.resolve('./it-glue-headless/it-glue-headless.env') });

async function firstVisibleOf(...candidates: Locator[]): Promise<Locator | null> {
  for (const loc of candidates) {
    try {
      if (await loc.first().isVisible({ timeout: 100 }).catch(() => false)) return loc.first();
    } catch {
      // ignore
    }
  }
  return null;
}

async function ensureLogin(page: Page) {
  await page.goto(ITG_URL, { waitUntil: 'domcontentloaded' });

  // If we're already authenticated, IT Glue will land us on dashboard.
  if (await page.getByRole('link', { name: /Dashboard/i }).first().isVisible().catch(() => false)) {
    return;
  }

  // Otherwise try email/password login (headed run recommended for SSO/MFA).
  const emailSel = await firstVisibleOf(
    page.getByLabel(/email/i),
    page.getByRole('textbox', { name: /email/i }),
    page.locator('input[type="email"]')
  );
  const pwdSel = await firstVisibleOf(
    page.getByLabel(/password/i),
    page.getByRole('textbox', { name: /password/i }),
    page.locator('input[type="password"]')
  );

  if (emailSel && (await emailSel.isVisible().catch(() => false))) {
    await emailSel.fill(env('ITG_EMAIL'));
    if (pwdSel && (await pwdSel.isVisible().catch(() => false))) {
      await pwdSel.fill(env('ITG_PASSWORD'));
    }
    const signInBtn = await firstVisibleOf(
      page.getByRole('button', { name: /sign in|log in|continue/i }).first(),
      page.getByRole('link', { name: /sign in|log in|continue/i }).first()
    );
    if (signInBtn) await signInBtn.click();
  }

  // Give time for SSO/MFA; user may need to interact if headed.
  await page.waitForLoadState('networkidle', { timeout: 120_000 });
  // Confirm by checking we can see top-nav or dashboard
  await expect(page.getByRole('link', { name: /Dashboard/i }).first()).toBeVisible({ timeout: 60_000 });
}

async function goToNetworkGlue(page: Page) {
  // Admin > Network Glue
  const admin = await firstVisibleOf(
    page.getByRole('link', { name: /^Admin$/i }).first(),
    page.getByRole('button', { name: /^Admin$/i }).first()
  );
  if (admin) await admin.click();
  const ng = await firstVisibleOf(
    page.getByRole('link', { name: /Network Glue/i }).first(),
    page.getByRole('button', { name: /Network Glue/i }).first()
  );
  if (!ng) throw new Error('Could not find Network Glue navigation');
  await ng.click();
  await page.waitForLoadState('networkidle');
}

async function openOrg(page: Page, orgName: string) {
  // There's usually a search/filter box on Network Glue
  const search = await firstVisibleOf(
    page.getByRole('textbox', { name: /search|filter organizations/i }).first(),
    page.locator('input[type="search"]').first(),
    page.getByRole('textbox').first()
  );
  if (search) await search.fill(orgName);
  // Click the org row/link
  const orgLink = await firstVisibleOf(
    page.getByRole('link', { name: new RegExp(`^${orgName}$`, 'i') }).first(),
    page.getByRole('link', { name: new RegExp(orgName, 'i') }).first(),
    page.getByText(new RegExp(`^${orgName}$`, 'i')).first()
  );
  if (!orgLink) throw new Error(`Organization not found: ${orgName}`);
  await orgLink.click();
  await page.waitForLoadState('networkidle');
}

async function openSnmpSettings(page: Page) {
  // Button or link typically labeled "View SNMP Settings" or "SNMP Settings"
  const btn = await firstVisibleOf(
    page.getByRole('link', { name: /snmp settings/i }).first(),
    page.getByRole('button', { name: /snmp settings/i }).first(),
    page.getByText(/snmp settings/i).first()
  );
  if (!btn) throw new Error('Could not locate SNMP Settings button/link');
  await btn.click();
  await page.waitForLoadState('networkidle');
}

async function tryAddCredentialOnCurrentNetwork(page: Page): Promise<boolean> {
  // Click "Add" / "Add Credential" within the current network panel, if present
  const addBtn = await firstVisibleOf(
    page.getByRole('button', { name: /^(add|add credential|add snmp)$/i }).first(),
    page.getByRole('button', { name: /add (credential|snmp)/i }).first(),
    page.getByText(/^add credential$/i).first()
  );
  if (!addBtn) return false; // likely already has a credential
  await addBtn.click();

  // Choose SNMP v3 tab/radio
  const v3Tab = await firstVisibleOf(
    page.getByRole('tab', { name: /snmp v?3/i }).first(),
    page.getByLabel(/snmp v?3/i).first(),
    page.getByText(/snmp v?3/i).first()
  );
  if (v3Tab) await v3Tab.click();

  // Fill fields; label text may vary slightly across tenants — use flexible matches
  const userField = await firstVisibleOf(
    page.getByLabel(/security name|user(name)?/i).first(),
    page.locator('input[name*="user"]').first()
  );
  if (!userField) throw new Error('Could not find SNMPv3 user/security name field');
  await userField.fill(env('SNMPV3_USER'));

  const authProto = await firstVisibleOf(page.getByLabel(/authentication protocol/i).first());
  if (authProto) await authProto.selectOption({ label: env('SNMPV3_AUTH_PROTO') }); // e.g. MD5
  const authPass = await firstVisibleOf(page.getByLabel(/authentication (passphrase|password)/i).first());
  if (authPass) await authPass.fill(env('SNMPV3_AUTH_PASS'));

  const privProto = await firstVisibleOf(page.getByLabel(/privacy protocol|encryption protocol/i).first());
  if (privProto) await privProto.selectOption({ label: env('SNMPV3_PRIV_PROTO') }); // e.g. AES
  const privPass = await firstVisibleOf(page.getByLabel(/privacy (passphrase|password)|encryption key/i).first());
  if (privPass) await privPass.fill(env('SNMPV3_PRIV_PASS'));

  // Save
  const save = await firstVisibleOf(
    page.getByRole('button', { name: /save/i }).first(),
    page.getByText(/^save$/i).first()
  );
  if (!save) throw new Error('Could not find Save button');
  await save.click();

  // Wait for toast/snackbar or for the form to disappear
  await page.waitForTimeout(1500);
  return true;
}

async function addSnmpv3Md5Aes(page: Page, netName?: string) {
  // If NETWORK_NAME is provided, select only that network
  if (netName) {
    const netTab = await firstVisibleOf(
      page.getByRole('tab', { name: new RegExp(netName, 'i') }).first(),
      page.getByRole('button', { name: new RegExp(netName, 'i') }).first(),
      page.getByText(new RegExp(`^${netName}$`, 'i')).first()
    );
    if (netTab) {
      await netTab.click();
      await page.waitForTimeout(500);
    }
    const added = await tryAddCredentialOnCurrentNetwork(page);
    console.log(added ? `Added SNMPv3 to network: ${netName}` : `Skipped (existing?) network: ${netName}`);
    return;
  }

  // Otherwise iterate through all visible network tabs if present
  const tabs = page.getByRole('tab');
  const tabCount = await tabs.count().catch(() => 0);
  if (tabCount > 0) {
    for (let i = 0; i < tabCount; i++) {
      const tab = tabs.nth(i);
      const name = (await tab.innerText().catch(() => '')).trim();
      await tab.click();
      await page.waitForTimeout(300);
      const added = await tryAddCredentialOnCurrentNetwork(page);
      console.log(added ? `Added SNMPv3 to network tab: ${name || i}` : `Skipped network tab: ${name || i}`);
    }
    return;
  }

  // Fallback: try each visible "Add" button on the page one-by-one
  const addButtons = page.getByRole('button', { name: /^(add|add credential|add snmp)$/i });
  const addCount = await addButtons.count().catch(() => 0);
  for (let i = 0; i < addCount; i++) {
    const btn = addButtons.nth(i);
    if (await btn.isVisible().catch(() => false)) {
      await btn.click();
      await tryAddCredentialOnCurrentNetwork(page);
      // After saving, the DOM may re-render; reopen SNMP settings to refresh buttons
      await openSnmpSettings(page);
    }
  }
}

async function runManualSync(page: Page) {
  // Back to the org's Network page where the "Run Discovery/Sync Now" lives
  // Often there's a "Back" breadcrumb; if present, use it.
  const back = page.getByRole('link', { name: /back|network(s)?/i }).first();
  if (await back.isVisible().catch(() => false)) {
    await back.click();
  } else {
    await page.goBack().catch(() => {});
  }
  await page.waitForLoadState('networkidle');

  // Press "Run Discovery" / "Sync Now"
  const syncBtnCandidate = page.getByRole('button', { name: /run discovery|sync now|rescan/i }).first();
  const syncBtn = (await syncBtnCandidate.isVisible().catch(() => false))
    ? syncBtnCandidate
    : await firstVisibleOf(page.getByRole('link', { name: /run discovery|sync now|rescan/i }).first());
  if (syncBtn && (await syncBtn.isVisible().catch(() => false))) {
    await syncBtn.click();
    await page.waitForTimeout(1000);
  }
}

(async () => {
  const browser = await chromium.launch({
    headless: !process.env.HEADED, // set HEADED=1 to see the browser
  });

  const context = fs.existsSync(STORAGE)
    ? await browser.newContext({ storageState: STORAGE })
    : await browser.newContext();

  const page = await context.newPage();

  try {
    await ensureLogin(page);

    // Save session after first successful login
    if (!fs.existsSync(STORAGE)) {
      await context.storageState({ path: STORAGE });
    }

    // Navigate to Network Glue for target org
    await goToNetworkGlue(page);
    await openOrg(page, env('ORG_NAME'));

    // Open SNMP Settings
    await openSnmpSettings(page);

    // Add the v3 MD5+AES credential (optionally scoped to one network)
    const networkName = process.env.NETWORK_NAME?.trim() || undefined;
    await addSnmpv3Md5Aes(page, networkName);

    // Kick a manual sync
    await runManualSync(page);

    console.log('Done. SNMPv3 (MD5+AES) credential added and sync triggered.');
  } catch (err) {
    console.error('Failed:', err);
    process.exitCode = 1;
  } finally {
    // Persist session for next runs
    await context.storageState({ path: STORAGE });
    await browser.close();
  }
})();
