import { chromium, expect, Page } from 'playwright';
import * as fs from 'fs';
import * as path from 'path';
import 'dotenv/config';

const STORAGE = path.resolve('./storage_state.json');
const ITG_URL = 'https://app.itglue.com';

const env = (k: string, req = true) => {
  const v = process.env[k];
  if (!v && req) throw new Error(`Missing env: ${k}`);
  return v || '';
};

async function ensureLogin(page: Page) {
  await page.goto(ITG_URL, { waitUntil: 'domcontentloaded' });

  // If we’re already authenticated, IT Glue will land us on dashboard.
  if (await page.getByRole('link', { name: /Dashboard/i }).first().isVisible().catch(() => false)) {
    return;
  }

  // Otherwise try email/password login (headed run recommended for SSO/MFA).
  const emailSel = page.getByLabel(/email/i).or(page.getByRole('textbox', { name: /email/i }));
  const pwdSel   = page.getByLabel(/password/i).or(page.getByRole('textbox', { name: /password/i }));

  if (await emailSel.isVisible().catch(() => false)) {
    await emailSel.fill(env('ITG_EMAIL'));
    if (await pwdSel.isVisible().catch(() => false)) {
      await pwdSel.fill(env('ITG_PASSWORD'));
    }
    // Click a button that likely says "Sign in" / "Log in" / similar
    await page.getByRole('button', { name: /sign in|log in|continue/i }).first().click();
  }

  // Give time for SSO/MFA; user may need to interact if headed.
  await page.waitForLoadState('networkidle', { timeout: 120_000 });
  // Confirm by checking we can see top-nav or dashboard
  await expect(page.getByRole('link', { name: /Dashboard/i }).first()).toBeVisible({ timeout: 60_000 });
}

async function goToNetworkGlue(page: Page) {
  // Admin → Network Glue
  await page.getByRole('link', { name: /^Admin$/i }).click();
  await page.getByRole('link', { name: /Network Glue/i }).click();
  await page.waitForLoadState('networkidle');
}

async function openOrg(page: Page, orgName: string) {
  // There’s usually a search/filter box on Network Glue
  const search = page.getByRole('textbox', { name: /search|filter organizations/i }).first();
  if (await search.isVisible().catch(() => false)) {
    await search.fill(orgName);
  } else {
    // Fallback: there may be a generic search box
    const anySearch = page.getByRole('textbox').first();
    if (await anySearch.isVisible().catch(() => false)) await anySearch.fill(orgName);
  }
  // Click the org row/link
  await page.getByRole('link', { name: new RegExp(`^${orgName}$`, 'i') }).first().click();
  await page.waitForLoadState('networkidle');
}

async function openSnmpSettings(page: Page) {
  // Button or link typically labeled “View SNMP Settings” or “SNMP Settings”
  const btn = page.getByRole('link', { name: /snmp settings/i })
               .or(page.getByRole('button', { name: /snmp settings/i }));
  await btn.first().click();
  await page.waitForLoadState('networkidle');
}

async function addSnmpv3Md5Aes(page: Page, netName?: string) {
  // If NETWORK_NAME is provided, select that network’s SNMP settings tab/panel
  if (netName) {
    // Networks often appear as tabs or expandable rows
    const netTab = page.getByRole('tab', { name: new RegExp(netName, 'i') })
                  .or(page.getByRole('button', { name: new RegExp(netName, 'i') }))
                  .or(page.getByText(new RegExp(`^${netName}$`, 'i')).first());
    if (await netTab.isVisible().catch(() => false)) {
      await netTab.click();
      await page.waitForTimeout(500);
    }
  }

  // Click “Add” / “Add Credential”
  const addBtn = page.getByRole('button', { name: /add (credential|snmp)|add/i }).first();
  await addBtn.click();

  // Choose SNMP v3 tab/radio
  const v3Tab = page.getByRole('tab', { name: /snmp v?3/i })
               .or(page.getByLabel(/snmp v?3/i))
               .or(page.getByText(/snmp v?3/i));
  if (await v3Tab.isVisible().catch(() => false)) await v3Tab.first().click();

  // Fill fields; label text may vary slightly across tenants—use flexible matches
  await page.getByLabel(/security name|user(name)?/i).fill(env('SNMPV3_USER'));
  await page.getByLabel(/authentication protocol/i).selectOption({ label: env('SNMPV3_AUTH_PROTO') }); // MD5
  await page.getByLabel(/authentication (passphrase|password)/i).fill(env('SNMPV3_AUTH_PASS'));
  await page.getByLabel(/privacy protocol|encryption protocol/i).selectOption({ label: env('SNMPV3_PRIV_PROTO') }); // AES
  await page.getByLabel(/privacy (passphrase|password)|encryption key/i).fill(env('SNMPV3_PRIV_PASS'));

  // Save
  const save = page.getByRole('button', { name: /save/i }).first();
  await save.click();

  // Wait for toast/snackbar or for the form to disappear
  await page.waitForTimeout(1500);
}

async function runManualSync(page: Page) {
  // Back to the org’s Network page where the “Run Discovery/Sync Now” lives
  // Often there’s a “Back” breadcrumb; if present, use it.
  const back = page.getByRole('link', { name: /back|network(s)?/i }).first();
  if (await back.isVisible().catch(() => false)) {
    await back.click();
  } else {
    await page.goBack().catch(() => {});
  }
  await page.waitForLoadState('networkidle');

  // Press “Run Discovery” / “Sync Now”
  const syncBtn = page
    .getByRole('button', { name: /run discovery|sync now|rescan/i })
    .or(page.getByRole('link', { name: /run discovery|sync now|rescan/i }));
  if (await syncBtn.first().isVisible().catch(() => false)) {
    await syncBtn.first().click();
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

    console.log('✅ SNMPv3 (MD5+AES) credential added and sync triggered.');
  } catch (err) {
    console.error('❌ Failed:', err);
    process.exitCode = 1;
  } finally {
    // Persist session for next runs
    await context.storageState({ path: STORAGE });
    await browser.close();
  }
})();
