import { chromium, Page, BrowserContext, Locator } from 'playwright';
import * as fs from 'fs';
import * as path from 'path';
import dotenv from 'dotenv';
import 'dotenv/config';

dotenv.config();
dotenv.config({ path: path.resolve('./datto-rmm-headless/datto-rmm-snmp-credentials.env') });

const STORAGE = path.resolve('./datto-rmm-headless/storage_state.json');

const env = (k: string, req = true): string => {
  const v = process.env[k];
  if (!v && req) throw new Error(`Missing env: ${k}`);
  return v || '';
};

interface PlanRow {
  OrgName: string;
  DattoSiteName: string;
  DattoSiteUid: string;
  AuthPassphrase: string;
  PrivPassphrase: string;
  MatchStatus: string;
}

function parseCSVLine(line: string): string[] {
  const result: string[] = [];
  let current = '';
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === '"') {
      if (inQuotes && line[i + 1] === '"') { current += '"'; i++; }
      else inQuotes = !inQuotes;
    } else if (c === ',' && !inQuotes) {
      result.push(current);
      current = '';
    } else {
      current += c;
    }
  }
  result.push(current);
  return result;
}

function readPlanCSV(csvPath: string): PlanRow[] {
  const content = fs.readFileSync(csvPath, 'utf-8');
  const lines = content.split(/\r?\n/).filter(l => l.trim());
  if (lines.length < 2) return [];
  const headers = parseCSVLine(lines[0]);
  return lines.slice(1).map(line => {
    const vals = parseCSVLine(line);
    const get = (h: string) => vals[headers.indexOf(h)] ?? '';
    return {
      OrgName:        get('OrgName'),
      DattoSiteName:  get('DattoSiteName'),
      DattoSiteUid:   get('DattoSiteUid'),
      AuthPassphrase: get('AuthPassphrase'),
      PrivPassphrase: get('PrivPassphrase'),
      MatchStatus:    get('MatchStatus'),
    };
  });
}

async function firstVisibleOf(...candidates: Locator[]): Promise<Locator | null> {
  for (const loc of candidates) {
    try {
      if (await loc.first().isVisible({ timeout: 100 }).catch(() => false)) return loc.first();
    } catch { /* ignore */ }
  }
  return null;
}

async function ensureLoggedIn(page: Page, context: BrowserContext, rmmUrl: string): Promise<void> {
  const rmmHost = new URL(rmmUrl).hostname;
  await page.goto(rmmUrl, { waitUntil: 'domcontentloaded', timeout: 30_000 });

  // If still on the RMM domain after navigation, the stored session is valid
  if (new URL(page.url()).hostname === rmmHost) {
    console.log('Existing session is valid.');
    return;
  }

  // Redirected to SSO/identity provider — wait for the user to complete login
  console.log('Not logged in. Complete SSO/MFA in the browser window, then the script will continue automatically.');
  await page.waitForURL(`**${rmmHost}**`, { timeout: 180_000 });
  await page.waitForLoadState('domcontentloaded', { timeout: 15_000 });

  await context.storageState({ path: STORAGE });
  console.log(`Session saved to ${STORAGE}`);
}

async function navigateToCreateCredential(page: Page, rmmUrl: string): Promise<void> {
  // Datto RMM is a SPA — try known URL first, then fallback variants
  for (const url of [
    `${rmmUrl}/credential`,
    `${rmmUrl}/#/setup/credentials/create`,
    `${rmmUrl}/setup/credentials/create`,
    `${rmmUrl}/#/credentials/create`,
  ]) {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 15_000 }).catch(() => {});
    if (await page.getByPlaceholder('Enter a name').isVisible({ timeout: 4_000 }).catch(() => false)) {
      return;
    }
  }

  // Fallback: navigate via the Setup menu
  const setupLink = await firstVisibleOf(
    page.getByRole('link', { name: /^setup$/i }).first(),
    page.getByRole('button', { name: /^setup$/i }).first(),
    page.locator('[href*="setup"]').first(),
  );
  if (!setupLink) throw new Error(
    `Cannot reach Create Credential page from ${rmmUrl}.\n` +
    `Run with HEADED=1 and navigate to Setup → Credentials manually to discover the URL, then set DATTO_RMM_URL accordingly.`
  );
  await setupLink.click();
  await page.waitForLoadState('networkidle', { timeout: 10_000 });

  const credsLink = await firstVisibleOf(
    page.getByRole('link', { name: /credentials/i }).first(),
    page.getByRole('menuitem', { name: /credentials/i }).first(),
  );
  if (!credsLink) throw new Error('Cannot find Credentials link under Setup menu.');
  await credsLink.click();
  await page.waitForLoadState('networkidle', { timeout: 10_000 });

  const createBtn = await firstVisibleOf(
    page.getByRole('button', { name: /create credential|add credential|\+/i }).first(),
    page.getByRole('link', { name: /create credential|add credential/i }).first(),
  );
  if (!createBtn) throw new Error('Cannot find Create Credential button on credentials list page.');
  await createBtn.click();
  await page.waitForLoadState('networkidle', { timeout: 10_000 });

  if (!await page.getByPlaceholder('Enter a name').isVisible({ timeout: 4_000 }).catch(() => false)) {
    throw new Error('Create Credential form did not load after navigating via Setup menu.');
  }
}

async function clickToggle(page: Page, label: string): Promise<void> {
  const btn = await firstVisibleOf(
    page.locator(`:text-is("${label}")`).first(),
    page.getByRole('button', { name: new RegExp(`^${label}$`, 'i') }).first(),
    page.getByRole('tab', { name: new RegExp(`^${label}$`, 'i') }).first(),
  );
  if (!btn) throw new Error(`Cannot find toggle button: ${label}`);
  await btn.click();
}

async function createCredential(
  page: Page,
  rmmUrl: string,
  credentialName: string,
  siteName: string,
  authPassphrase: string,
  privPassphrase: string,
): Promise<void> {
  await navigateToCreateCredential(page, rmmUrl);

  // Name
  const nameField = page.getByPlaceholder('Enter a name');
  await nameField.waitFor({ state: 'visible', timeout: 10_000 });
  await nameField.fill(credentialName);

  // Scope → Site
  await clickToggle(page, 'Site');

  // Site search — type name, pick first matching option
  const siteSearch = await firstVisibleOf(
    page.locator('input[placeholder*="site" i]').first(),
    page.locator('input[placeholder*="search" i]').first(),
    page.getByRole('textbox', { name: /site/i }).first(),
    page.locator('input[type="search"]').first(),
  );
  if (!siteSearch) throw new Error('Site search input did not appear after clicking Site scope.');
  await siteSearch.fill(siteName);

  // Wait for dropdown and click matching option
  await page.waitForTimeout(500);
  const option = await firstVisibleOf(
    page.getByRole('option', { name: siteName }).first(),
    page.getByRole('option').filter({ hasText: siteName }).first(),
    page.locator('[role="listbox"] [role="option"]').filter({ hasText: siteName }).first(),
    page.locator('li').filter({ hasText: siteName }).first(),
    page.locator('[class*="dropdown"] [class*="item"]').filter({ hasText: siteName }).first(),
  );
  if (!option) throw new Error(`No dropdown option matched site name: ${siteName}`);
  await option.click();

  // Type → SNMP
  await clickToggle(page, 'SNMP');

  // Version → v3
  await clickToggle(page, 'v3');

  // Authentication → SHA1
  await clickToggle(page, 'SHA1');

  // v3 user (security name)
  const v3UserVal = env('V3_USER', false) || 'ActaMSPv3';
  await page.getByPlaceholder('Enter a v3 user').fill(v3UserVal);

  // v3 password = auth passphrase
  await page.getByPlaceholder('Enter a v3 password').fill(authPassphrase);

  // Encryption → AES128
  await clickToggle(page, 'AES128');

  // v3 encryption key = privacy passphrase
  await page.getByPlaceholder('Enter a v3 encryption key').fill(privPassphrase);

  // Submit — the form resets in place on success (URL stays /credential)
  const submitBtn = await firstVisibleOf(
    page.getByRole('button', { name: /create credential/i }).first(),
    page.locator(':text("Create Credential")').first(),
    page.locator('[type="submit"]').first(),
  );
  if (!submitBtn) throw new Error('Cannot find Create Credential submit button.');
  await submitBtn.click();

  // Success: Name field clears. Failure: Name field retains our value.
  await page.waitForTimeout(2_000);
  const nameAfter = await page.getByPlaceholder('Enter a name').inputValue().catch(() => '');
  if (nameAfter === credentialName) {
    const errEl = await firstVisibleOf(
      page.locator('[role="alert"]').first(),
      page.locator('[class*="error"]').first(),
      page.locator('[class*="alert-danger"]').first(),
    );
    const errText = errEl ? await errEl.innerText().catch(() => '') : '';
    throw new Error(`Credential creation failed (form was not reset after submit). ${errText}`.trim());
  }
}

async function deleteAllSNMPv3Credentials(page: Page, rmmUrl: string): Promise<void> {
  let deleted = 0;

  // Navigate to credentials list and wait for page heading to confirm it loaded
  await page.goto(`${rmmUrl}/credentials`, { waitUntil: 'domcontentloaded', timeout: 30_000 });
  await page.locator(':text("Create Credential")').first().waitFor({ state: 'visible', timeout: 20_000 });
  await page.waitForTimeout(2_000);

  // Click the SNMP type tab — SNMPv3 credentials are beyond page 1 of the full list
  // (alphabetically "N" for "Name is not configured" precedes "S" for "SNMPv3")
  const snmpTab = page.locator(':text("SNMP")').first();
  if (await snmpTab.isVisible({ timeout: 3_000 }).catch(() => false)) {
    await snmpTab.click();
    await page.waitForTimeout(2_000);
  }

  while (true) {
    const credEl = page.locator(':text-is("SNMPv3")').first();
    if (!await credEl.isVisible({ timeout: 5_000 }).catch(() => false)) {
      console.log(`No more SNMPv3 credentials found. Total deleted: ${deleted}`);
      break;
    }

    await credEl.click();
    await page.waitForTimeout(1_500);

    const deleteBtn = await firstVisibleOf(
      page.getByRole('button', { name: /^delete$/i }).first(),
      page.locator(':text-is("Delete")').first(),
    );
    if (!deleteBtn) throw new Error('Delete button not found in credential detail panel.');
    await deleteBtn.click();

    // Confirm inside the validationModal dialog
    await page.waitForTimeout(800);

    // Check the "I understand this is irreversible" checkbox to enable Delete
    const checkbox = page.getByTestId('validationModalCheckbox');
    if (await checkbox.isVisible({ timeout: 2_000 }).catch(() => false)) {
      await checkbox.click();
      await page.waitForTimeout(500);
    }

    await page.getByTestId('dialogConfirm').click();

    await page.waitForTimeout(1_500);
    deleted++;
    console.log(`Deleted ${deleted}: SNMPv3`);
  }
}

(async () => {
  const rmmUrl  = env('DATTO_RMM_URL').replace(/\/$/, '');
  const cleanup = !!process.env.CLEANUP;

  const headed  = !!process.env.HEADED;
  const browser = await chromium.launch({ headless: !headed });
  const context = fs.existsSync(STORAGE)
    ? await browser.newContext({ storageState: STORAGE })
    : await browser.newContext();
  const page = await context.newPage();

  try {
    await ensureLoggedIn(page, context, rmmUrl);

    if (cleanup) {
      console.log('CLEANUP mode: deleting all SNMPv3 credentials...');
      await deleteAllSNMPv3Credentials(page, rmmUrl);
      return;
    }

    const csvPath = path.resolve(
      env('PLAN_CSV_PATH', false) || './artifacts/datto-rmm/snmp-credential-plan.csv'
    );

    if (!fs.existsSync(csvPath)) {
      throw new Error(
        `Plan CSV not found: ${csvPath}\nRun datto-rmm-snmp-credential-plan.ps1 first to generate it.`
      );
    }

    const allRows     = readPlanCSV(csvPath);
    const matchedRows = allRows.filter(r => r.MatchStatus === 'Matched');
    const skipped     = allRows.length - matchedRows.length;

    console.log(`Plan: ${allRows.length} total rows, ${matchedRows.length} Matched, ${skipped} skipped (Unmatched/MissingPassphrase).`);

    if (matchedRows.length === 0) {
      console.log('Nothing to do — no Matched rows in plan CSV.');
      return;
    }

    let created = 0;
    let failed  = 0;

    for (const row of matchedRows) {
      console.log(`\nSite: ${row.DattoSiteName}  (IT Glue org: ${row.OrgName})`);

      try {
        await createCredential(page, rmmUrl, 'SNMPv3', row.DattoSiteName, row.AuthPassphrase, row.PrivPassphrase);
        console.log('  [OK] SNMPv3');
        created++;
      } catch (err) {
        console.error(`  [FAIL] SNMPv3: ${err}`);
        failed++;
      }
    }

    console.log(`\nDone. Created: ${created} | Failed: ${failed} | Non-matched rows skipped: ${skipped}`);
  } catch (err) {
    console.error('Fatal:', err);
    process.exitCode = 1;
  } finally {
    await context.storageState({ path: STORAGE });
    await browser.close();
  }
})();
