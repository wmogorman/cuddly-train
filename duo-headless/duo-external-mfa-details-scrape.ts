import { chromium, Locator, Page } from "playwright";
import * as fs from "fs";
import * as path from "path";
import dotenv from "dotenv";

dotenv.config();
dotenv.config({ path: path.resolve("./duo-headless/duo-headless.env") });

type CliArgs = {
  inputPath: string;
  outputPath: string;
  accountFilter: string[];
  limit?: number;
  help: boolean;
};

type CsvRow = Record<string, string>;

type ScrapedFields = {
  UiProviderName: string;
  UiClientId: string;
  UiGuestClientId: string;
  UiDiscoveryEndpoint: string;
  UiAppId: string;
  UiEntraTenantId: string;
  UiDetailsUrl: string;
  UiScrapeStatus: string;
  UiScrapeError: string;
  UiArtifactPath: string;
};

const DEFAULT_INPUT = path.resolve("./duo-external-mfa-applications.csv");
const DEFAULT_OUTPUT = path.resolve("./duo-external-mfa-ui-details.csv");
const DEFAULT_ADMIN_URL = "https://admin.duosecurity.com";
const STORAGE = path.resolve("./duo-headless/storage_state.json");
const ARTIFACTS_DIR = path.resolve("./duo-headless/artifacts");

function printHelp(): void {
  console.log(`Usage: tsx duo-headless/duo-external-mfa-details-scrape.ts [options]

Options:
  --input <path>     Input CSV from duo-audit-external-mfa-apps.ps1
                     Default: ${DEFAULT_INPUT}
  --output <path>    Output CSV path
                     Default: ${DEFAULT_OUTPUT}
  --account <name>   Restrict to one or more AccountName values from the input CSV
  --limit <number>   Only process the first N filtered rows
  --help             Show this message

Environment:
  DUO_ADMIN_URL      Duo admin panel base URL
                     Default: ${DEFAULT_ADMIN_URL}
  DUO_ADMIN_EMAIL    Optional username for direct Duo admin login
  DUO_ADMIN_PASSWORD Optional password for direct Duo admin login
  HEADED=1           Show the browser for manual SSO/MFA and session capture

Session behavior:
  - The script saves Playwright storage state to ${STORAGE}
  - Run headed once if Duo uses SSO or MFA so the session can be reused headlessly
`);
}

function parseArgs(argv: string[]): CliArgs {
  let inputPath = DEFAULT_INPUT;
  let outputPath = DEFAULT_OUTPUT;
  const accountFilter: string[] = [];
  let limit: number | undefined;
  let help = false;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i] ?? "";

    if (arg === "--help" || arg === "-h") {
      help = true;
      continue;
    }
    if (arg === "--input") {
      inputPath = path.resolve(argv[i + 1] ?? "");
      i += 1;
      continue;
    }
    if (arg === "--output") {
      outputPath = path.resolve(argv[i + 1] ?? "");
      i += 1;
      continue;
    }
    if (arg === "--account") {
      const value = (argv[i + 1] ?? "").trim();
      if (value) {
        accountFilter.push(value);
      }
      i += 1;
      continue;
    }
    if (arg === "--limit") {
      const value = Number.parseInt(argv[i + 1] ?? "", 10);
      if (!Number.isFinite(value) || value < 1) {
        throw new Error(`Invalid --limit value: ${argv[i + 1] ?? ""}`);
      }
      limit = value;
      i += 1;
      continue;
    }

    throw new Error(`Unknown argument: ${arg}`);
  }

  return {
    inputPath,
    outputPath,
    accountFilter,
    limit,
    help,
  };
}

function ensureParentDirectory(filePath: string): void {
  const parent = path.dirname(filePath);
  fs.mkdirSync(parent, { recursive: true });
}

function env(key: string): string {
  return process.env[key]?.trim() ?? "";
}

function normalizeAdminUrl(input: string): string {
  const value = input.trim();
  if (!value) {
    return DEFAULT_ADMIN_URL;
  }
  if (/^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\//.test(value)) {
    return value.replace(/\/+$/, "");
  }
  return `https://${value.replace(/\/+$/, "")}`;
}

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let inQuotes = false;

  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i] ?? "";

    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i += 1;
        } else {
          inQuotes = false;
        }
      } else {
        field += ch;
      }
      continue;
    }

    if (ch === '"') {
      inQuotes = true;
      continue;
    }
    if (ch === ",") {
      row.push(field);
      field = "";
      continue;
    }
    if (ch === "\r") {
      continue;
    }
    if (ch === "\n") {
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
      continue;
    }

    field += ch;
  }

  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }

  return rows;
}

function readCsvObjects(filePath: string): CsvRow[] {
  if (!fs.existsSync(filePath)) {
    throw new Error(`Input CSV not found: ${filePath}`);
  }

  const raw = fs.readFileSync(filePath, "utf8");
  const rows = parseCsv(raw);
  if (rows.length === 0) {
    return [];
  }

  const headers = rows[0] ?? [];
  return rows.slice(1).map((values) => {
    const record: CsvRow = {};
    headers.forEach((header, index) => {
      record[header] = values[index] ?? "";
    });
    return record;
  });
}

function csvEscape(value: string): string {
  const normalized = value ?? "";
  if (/[",\r\n]/.test(normalized)) {
    return `"${normalized.replace(/"/g, '""')}"`;
  }
  return normalized;
}

function writeCsvObjects(filePath: string, rows: CsvRow[]): void {
  ensureParentDirectory(filePath);

  if (rows.length === 0) {
    fs.writeFileSync(filePath, "", "utf8");
    return;
  }

  const headers = Array.from(
    rows.reduce((set, row) => {
      Object.keys(row).forEach((key) => set.add(key));
      return set;
    }, new Set<string>()),
  );

  const lines = [
    headers.map(csvEscape).join(","),
    ...rows.map((row) => headers.map((header) => csvEscape(row[header] ?? "")).join(",")),
  ];

  fs.writeFileSync(filePath, lines.join("\r\n"), "utf8");
}

function buildArtifactPath(accountName: string): string {
  const safe = accountName.replace(/[^A-Za-z0-9._-]+/g, "_");
  ensureParentDirectory(path.join(ARTIFACTS_DIR, "placeholder.txt"));
  return path.join(ARTIFACTS_DIR, `${safe}.png`);
}

async function firstVisibleOf(...candidates: Locator[]): Promise<Locator | null> {
  for (const locator of candidates) {
    if (await locator.first().isVisible({ timeout: 250 }).catch(() => false)) {
      return locator.first();
    }
  }
  return null;
}

async function isAuthenticated(page: Page): Promise<boolean> {
  const match = await firstVisibleOf(
    page.getByRole("link", { name: /^Applications$/i }),
    page.getByRole("button", { name: /^Applications$/i }),
    page.getByRole("link", { name: /^Home$/i }),
    page.getByRole("button", { name: /Account/i }),
    page.locator("header button").filter({ hasText: /Account|Viewing|Subaccounts|Parent/i }),
  );
  return match !== null;
}

async function waitForAuthenticated(page: Page): Promise<void> {
  const timeoutMs = 180_000;
  const started = Date.now();

  while (Date.now() - started < timeoutMs) {
    if (await isAuthenticated(page)) {
      return;
    }
    await page.waitForTimeout(1_000);
  }

  throw new Error("Timed out waiting for Duo admin authentication.");
}

async function ensureLogin(page: Page, adminUrl: string): Promise<void> {
  const headed = Boolean(process.env.HEADED);
  const hasCredentials = Boolean(env("DUO_ADMIN_EMAIL")) && Boolean(env("DUO_ADMIN_PASSWORD"));
  const hasStoredSession = fs.existsSync(STORAGE);

  await page.goto(adminUrl, { waitUntil: "domcontentloaded" });

  if (await isAuthenticated(page)) {
    return;
  }

  const emailField = await firstVisibleOf(
    page.getByLabel(/email|username/i),
    page.getByRole("textbox", { name: /email|username/i }),
    page.locator('input[type="email"]'),
    page.locator('input[name*="email" i]'),
  );
  const passwordField = await firstVisibleOf(
    page.getByLabel(/password/i),
    page.getByRole("textbox", { name: /password/i }),
    page.locator('input[type="password"]'),
  );

  if (hasCredentials && emailField && passwordField) {
    await emailField.fill(env("DUO_ADMIN_EMAIL"));
    await passwordField.fill(env("DUO_ADMIN_PASSWORD"));

    const submit = await firstVisibleOf(
      page.getByRole("button", { name: /sign in|log in|continue|next/i }),
      page.getByRole("link", { name: /sign in|log in|continue|next/i }),
      page.locator('button[type="submit"]'),
    );
    if (submit) {
      await submit.click();
    }
  } else if (!hasStoredSession && !headed && !hasCredentials) {
    throw new Error(
      "No saved Duo admin session is available. Run with HEADED=1 once and complete login manually, or set DUO_ADMIN_EMAIL and DUO_ADMIN_PASSWORD if direct login is supported.",
    );
  }

  await waitForAuthenticated(page);
}

async function openApplicationsPage(page: Page, adminUrl: string): Promise<void> {
  const targetUrl = `${adminUrl.replace(/\/+$/, "")}/applications`;
  await page.goto(targetUrl, { waitUntil: "domcontentloaded" });

  const heading = await firstVisibleOf(
    page.getByRole("heading", { name: /^Applications$/i }),
    page.getByText(/^Applications$/i),
  );
  if (heading) {
    return;
  }

  const appsNav = await firstVisibleOf(
    page.getByRole("link", { name: /^Applications$/i }),
    page.getByRole("button", { name: /^Applications$/i }),
    page.getByText(/^Applications$/i),
  );
  if (!appsNav) {
    throw new Error("Could not find Applications navigation.");
  }

  await appsNav.click();
  await page.waitForLoadState("domcontentloaded");
  await page.getByRole("heading", { name: /^Applications$/i }).first().waitFor({ state: "visible", timeout: 30_000 });
}

async function openAccountSwitcher(page: Page): Promise<void> {
  const opener = await firstVisibleOf(
    page.getByRole("button", { name: /Account/i }),
    page.getByRole("button", { name: /Viewing/i }),
    page.locator("header button").filter({ hasText: /Account|Viewing|Subaccounts|Parent/i }),
    page.locator('[role="banner"] button').filter({ hasText: /Account|Viewing|Subaccounts|Parent/i }),
    page.locator("button").filter({ hasText: /Viewing|Subaccounts|Parent/i }),
  );

  if (!opener) {
    throw new Error("Could not find the Duo account switcher.");
  }

  await opener.click();
  const searchBox = await firstVisibleOf(
    page.getByPlaceholder(/Search accounts/i),
    page.getByRole("textbox", { name: /Search accounts/i }),
    page.locator('input[placeholder*="Search accounts"]'),
  );
  if (!searchBox) {
    throw new Error("Account switcher opened, but the search input was not found.");
  }
}

async function switchToAccount(page: Page, accountName: string): Promise<void> {
  await openAccountSwitcher(page);

  const searchBox = await firstVisibleOf(
    page.getByPlaceholder(/Search accounts/i),
    page.getByRole("textbox", { name: /Search accounts/i }),
    page.locator('input[placeholder*="Search accounts"]'),
  );
  if (!searchBox) {
    throw new Error("Could not find account switcher search input.");
  }

  await searchBox.fill(accountName);
  await page.waitForTimeout(750);

  const exactPattern = new RegExp(`^${escapeRegex(accountName)}$`, "i");
  const containsPattern = new RegExp(escapeRegex(accountName), "i");
  const result = await firstVisibleOf(
    page.getByRole("button", { name: exactPattern }),
    page.getByRole("link", { name: exactPattern }),
    page.getByText(exactPattern),
    page.getByRole("button", { name: containsPattern }),
    page.getByRole("link", { name: containsPattern }),
    page.getByText(containsPattern),
  );

  if (!result) {
    throw new Error(`Could not find account switcher result for '${accountName}'.`);
  }

  await result.click();
  await page.waitForTimeout(1_250);
  await page.waitForLoadState("domcontentloaded", { timeout: 30_000 }).catch(() => {});
}

async function searchForIntegration(page: Page, searchText: string): Promise<void> {
  const searchBox = await firstVisibleOf(
    page.getByPlaceholder(/Search by name or key/i),
    page.getByRole("textbox", { name: /Search by name or key/i }),
    page.locator('input[placeholder*="Search by name or key"]'),
    page.locator('input[type="search"]'),
  );
  if (!searchBox) {
    throw new Error("Could not find the Applications search box.");
  }

  await searchBox.fill("");
  await searchBox.fill(searchText);
  await page.waitForTimeout(750);
}

async function openIntegrationDetails(page: Page, integrationName: string, integrationKey: string): Promise<void> {
  if (integrationKey) {
    await searchForIntegration(page, integrationKey);
  } else {
    await searchForIntegration(page, integrationName);
  }

  const namePattern = new RegExp(`^${escapeRegex(integrationName)}$`, "i");
  const appTarget = await firstVisibleOf(
    page.getByRole("link", { name: namePattern }),
    page.getByRole("button", { name: namePattern }),
    page.getByText(namePattern),
  );

  if (!appTarget) {
    if (integrationKey) {
      await searchForIntegration(page, integrationName);
    }

    const retryTarget = await firstVisibleOf(
      page.getByRole("link", { name: namePattern }),
      page.getByRole("button", { name: namePattern }),
      page.getByText(namePattern),
    );
    if (!retryTarget) {
      throw new Error(`Could not find application '${integrationName}' after filtering.`);
    }
    await retryTarget.click();
  } else {
    await appTarget.click();
  }

  await page.waitForLoadState("domcontentloaded");
  await page.getByText(/^Details$/i).first().waitFor({ state: "visible", timeout: 30_000 });
}

async function readFieldValue(page: Page, label: string): Promise<string> {
  const labelPattern = new RegExp(`^${escapeRegex(label)}$`, "i");
  const labelLocator = await firstVisibleOf(
    page.getByText(labelPattern),
    page.getByLabel(labelPattern),
  );
  if (!labelLocator) {
    return "";
  }

  const rowContainer = labelLocator.locator("xpath=ancestor::*[self::div or self::section or self::li][1]");
  const inlineInput = await firstVisibleOf(
    rowContainer.locator("input"),
    labelLocator.locator("xpath=following::*[self::input or self::textarea][1]"),
  );
  if (inlineInput) {
    const inputValue = (await inlineInput.inputValue().catch(() => "")).trim();
    if (inputValue) {
      return inputValue;
    }
    const attributeValue = (await inlineInput.getAttribute("value").catch(() => ""))?.trim() ?? "";
    if (attributeValue) {
      return attributeValue;
    }
  }

  const textSnippets = await rowContainer
    .locator("xpath=.//*[self::div or self::span or self::p or self::button]")
    .allInnerTexts()
    .catch(() => []);

  const cleaned = textSnippets
    .map((value) => value.replace(/\s+/g, " ").trim())
    .filter((value) => value && !new RegExp(`^${escapeRegex(label)}$`, "i").test(value) && !/^Copy$/i.test(value))
    .join(" ")
    .trim();

  return cleaned;
}

async function scrapeIntegrationDetails(page: Page): Promise<ScrapedFields> {
  const bodyText = await page.locator("body").innerText();
  const tenantIdMatch = bodyText.match(/Tenant ID:\s*([0-9a-fA-F-]{36})/i);

  return {
    UiProviderName: await readFieldValue(page, "Name"),
    UiClientId: await readFieldValue(page, "Client ID"),
    UiGuestClientId: await readFieldValue(page, "Client ID (Guest/Cross-Tenant)"),
    UiDiscoveryEndpoint: await readFieldValue(page, "Discovery Endpoint"),
    UiAppId: await readFieldValue(page, "App ID"),
    UiEntraTenantId: tenantIdMatch?.[1] ?? "",
    UiDetailsUrl: page.url(),
    UiScrapeStatus: "Scraped",
    UiScrapeError: "",
    UiArtifactPath: "",
  };
}

async function captureArtifact(page: Page, accountName: string): Promise<string> {
  const artifactPath = buildArtifactPath(accountName);
  await page.screenshot({ path: artifactPath, fullPage: true }).catch(() => {});
  return artifactPath;
}

function withDefaultScrapeFields(row: CsvRow): CsvRow {
  return {
    ...row,
    UiProviderName: "",
    UiClientId: "",
    UiGuestClientId: "",
    UiDiscoveryEndpoint: "",
    UiAppId: "",
    UiEntraTenantId: "",
    UiDetailsUrl: "",
    UiScrapeStatus: "",
    UiScrapeError: "",
    UiArtifactPath: "",
  };
}

function filterInputRows(rows: CsvRow[], args: CliArgs): CsvRow[] {
  let filtered = rows;

  if (args.accountFilter.length > 0) {
    const wanted = new Set(args.accountFilter.map((value) => value.toLowerCase()));
    filtered = filtered.filter((row) => wanted.has((row.AccountName ?? "").toLowerCase()));
  }

  if (typeof args.limit === "number") {
    filtered = filtered.slice(0, args.limit);
  }

  return filtered;
}

function validateInputRows(rows: CsvRow[]): void {
  if (rows.length === 0) {
    throw new Error("Input CSV has no rows to scrape.");
  }

  const missingColumns = ["AccountName", "IntegrationName", "IntegrationKey"].filter(
    (key) => !(key in rows[0]),
  );
  if (missingColumns.length > 0) {
    throw new Error(`Input CSV is missing required columns: ${missingColumns.join(", ")}`);
  }
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    return;
  }

  const inputRows = readCsvObjects(args.inputPath);
  validateInputRows(inputRows);

  const targetRows = filterInputRows(inputRows, args);
  if (targetRows.length === 0) {
    throw new Error("No input rows matched the requested filters.");
  }

  const adminUrl = normalizeAdminUrl(env("DUO_ADMIN_URL"));
  const browser = await chromium.launch({ headless: !process.env.HEADED });
  const context = fs.existsSync(STORAGE)
    ? await browser.newContext({ storageState: STORAGE })
    : await browser.newContext();
  const page = await context.newPage();

  const outputRows: CsvRow[] = [];

  try {
    await ensureLogin(page, adminUrl);
    await context.storageState({ path: STORAGE });

    let currentAccount = "";
    for (const row of targetRows) {
      const accountName = row.AccountName ?? "";
      const integrationName = row.IntegrationName ?? "Microsoft Entra ID: External MFA";
      const integrationKey = row.IntegrationKey ?? "";
      const outputRow = withDefaultScrapeFields(row);

      try {
        await page.goto(adminUrl, { waitUntil: "domcontentloaded" });

        if (accountName !== currentAccount) {
          console.log(`Switching to account: ${accountName}`);
          await switchToAccount(page, accountName);
          currentAccount = accountName;
        }

        await openApplicationsPage(page, adminUrl);
        console.log(`Opening app in ${accountName}: ${integrationName} (${integrationKey})`);
        await openIntegrationDetails(page, integrationName, integrationKey);

        Object.assign(outputRow, await scrapeIntegrationDetails(page));
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        outputRow.UiScrapeStatus = "Error";
        outputRow.UiScrapeError = message;
        outputRow.UiDetailsUrl = page.url();
        outputRow.UiArtifactPath = await captureArtifact(page, accountName);
      }

      outputRows.push(outputRow);
    }
  } finally {
    await context.storageState({ path: STORAGE }).catch(() => {});
    await browser.close();
  }

  writeCsvObjects(args.outputPath, outputRows);

  const okCount = outputRows.filter((row) => row.UiScrapeStatus === "Scraped").length;
  const errorCount = outputRows.length - okCount;
  console.log(`Wrote ${outputRows.length} row(s) to ${args.outputPath}. Scraped=${okCount} Error=${errorCount}`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
