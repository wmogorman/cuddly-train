import { chromium, Locator, Page } from "playwright";
import * as fs from "fs";
import * as path from "path";
import dotenv from "dotenv";

dotenv.config();
dotenv.config({ path: path.resolve("./datto-edr-headless/datto-edr-headless.env") });

type CliArgs = {
  configPath: string;
  outputPath: string;
};

type AssignmentRow = {
  organizationName: string;
  locationName?: string;
  policyName: string;
  policyType?: string;
  status?: string;
  enabled?: boolean;
  evidenceSource: string;
};

const STORAGE = path.resolve("./datto-edr-headless/storage_state.json");

function parseArgs(argv: string[]): CliArgs {
  let configPath = "";
  let outputPath = "";

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--config") {
      configPath = argv[i + 1] ?? "";
      i += 1;
      continue;
    }
    if (arg === "--output") {
      outputPath = argv[i + 1] ?? "";
      i += 1;
    }
  }

  if (!configPath || !outputPath) {
    throw new Error("Usage: tsx datto-edr-headless/datto-edr-policy-snapshot.ts --config <path> --output <path>");
  }

  return {
    configPath: path.resolve(configPath),
    outputPath: path.resolve(outputPath),
  };
}

function env(key: string): string {
  const value = process.env[key];
  if (!value) {
    throw new Error(`Missing env: ${key}`);
  }
  return value;
}

function normalizeBaseUrl(instanceUrl: string): string {
  const trimmed = instanceUrl.trim();
  if (/^[a-zA-Z][a-zA-Z0-9+\-.]*:\/\//.test(trimmed)) {
    return trimmed.replace(/\/+$/, "");
  }
  if (trimmed.includes(".")) {
    return `https://${trimmed.replace(/\/+$/, "")}`;
  }
  return `https://${trimmed.replace(/\/+$/, "")}.infocyte.com`;
}

function getOrganizationTargets(config: any): string[] {
  const explicit: string[] = Array.isArray(config?.UiFallback?.OrganizationNames)
    ? config.UiFallback.OrganizationNames.filter((value: unknown) => typeof value === "string" && value.trim())
    : [];
  if (explicit.length > 0) {
    return explicit;
  }

  const fromRules: string[] = Array.isArray(config?.AssignmentRules)
    ? config.AssignmentRules
        .map((rule: any) => String(rule?.OrganizationName ?? "").trim())
        .filter((name: string): name is string => Boolean(name && name !== "*"))
    : [];

  return [...new Set(fromRules)];
}

async function firstVisibleOf(...candidates: Locator[]): Promise<Locator | null> {
  for (const locator of candidates) {
    if (await locator.first().isVisible({ timeout: 250 }).catch(() => false)) {
      return locator.first();
    }
  }
  return null;
}

async function ensureLogin(page: Page, baseUrl: string): Promise<void> {
  await page.goto(baseUrl, { waitUntil: "domcontentloaded" });

  const alreadySignedIn = await firstVisibleOf(
    page.getByRole("link", { name: /organizations|policies/i }),
    page.getByRole("button", { name: /organizations|policies/i }),
  );
  if (alreadySignedIn) {
    return;
  }

  const email = await firstVisibleOf(
    page.getByLabel(/email/i),
    page.locator('input[type="email"]'),
  );
  const password = await firstVisibleOf(
    page.getByLabel(/password/i),
    page.locator('input[type="password"]'),
  );

  if (email && password) {
    await email.fill(env("DATTO_EDR_EMAIL"));
    await password.fill(env("DATTO_EDR_PASSWORD"));
    const submit = await firstVisibleOf(
      page.getByRole("button", { name: /sign in|log in|continue/i }),
      page.getByRole("link", { name: /sign in|log in|continue/i }),
    );
    if (submit) {
      await submit.click();
    }
  }

  await page.waitForLoadState("networkidle", { timeout: 120_000 });
  await page.getByRole("link", { name: /organizations|policies/i }).first().waitFor({ state: "visible", timeout: 60_000 });
}

async function openOrganizations(page: Page): Promise<void> {
  const organizationsNav = await firstVisibleOf(
    page.getByRole("link", { name: /^organizations$/i }),
    page.getByRole("button", { name: /^organizations$/i }),
    page.getByText(/^organizations$/i),
  );
  if (!organizationsNav) {
    throw new Error("Could not find Organizations navigation.");
  }
  await organizationsNav.click();
  await page.waitForLoadState("networkidle");
}

async function searchOrganization(page: Page, organizationName: string): Promise<void> {
  const searchBox = await firstVisibleOf(
    page.getByRole("textbox", { name: /search/i }),
    page.locator('input[type="search"]'),
    page.locator("input").first(),
  );

  if (searchBox) {
    await searchBox.fill(organizationName);
    await page.waitForTimeout(500);
  }
}

async function openOrganization(page: Page, organizationName: string): Promise<void> {
  await searchOrganization(page, organizationName);

  const orgLink = await firstVisibleOf(
    page.getByRole("link", { name: new RegExp(`^${organizationName}$`, "i") }),
    page.getByRole("link", { name: new RegExp(organizationName, "i") }),
    page.getByText(new RegExp(`^${organizationName}$`, "i")),
  );
  if (!orgLink) {
    throw new Error(`Could not find organization: ${organizationName}`);
  }

  await orgLink.click();
  await page.waitForLoadState("networkidle");
}

async function readTableNearHeading(page: Page, heading: RegExp): Promise<Array<Record<string, string>>> {
  const headingLocator = await firstVisibleOf(
    page.getByRole("heading", { name: heading }),
    page.getByText(heading),
  );
  if (!headingLocator) {
    return [];
  }

  const section = headingLocator.locator("xpath=ancestor::*[self::section or self::div][1]");
  let table = section.locator("table").first();
  if (!(await table.isVisible().catch(() => false))) {
    table = headingLocator.locator("xpath=following::*[self::table][1]");
  }
  if (!(await table.isVisible().catch(() => false))) {
    return [];
  }

  const headers = await table.locator("thead th").allInnerTexts();
  const rows = table.locator("tbody tr");
  const count = await rows.count();
  const results: Array<Record<string, string>> = [];

  for (let i = 0; i < count; i += 1) {
    const cells = await rows.nth(i).locator("td").allInnerTexts();
    if (cells.length === 0) {
      continue;
    }
    const record: Record<string, string> = {};
    headers.forEach((header, index) => {
      record[header.trim()] = (cells[index] ?? "").trim();
    });
    results.push(record);
  }

  return results;
}

function inferEnabled(statusValue: string): boolean | undefined {
  const normalized = statusValue.trim().toLowerCase();
  if (!normalized) {
    return undefined;
  }
  if (["enabled", "active", "on"].includes(normalized)) {
    return true;
  }
  if (["disabled", "inactive", "off"].includes(normalized)) {
    return false;
  }
  return undefined;
}

function tableRowsToAssignments(organizationName: string, locationName: string | undefined, rows: Array<Record<string, string>>, evidenceSource: string): AssignmentRow[] {
  return rows
    .map((row) => {
      const policyName = row["Name"] || row["Policy"] || row["Policy Name"] || "";
      if (!policyName) {
        return null;
      }
      const status = row["Status"] || "";
      return {
        organizationName,
        locationName,
        policyName,
        policyType: row["Type"] || row["Policy Type"] || undefined,
        status: status || undefined,
        enabled: inferEnabled(status),
        evidenceSource,
      } as AssignmentRow;
    })
    .filter((row): row is AssignmentRow => row !== null);
}

async function scrapeOrganizationAssignments(page: Page, organizationName: string): Promise<AssignmentRow[]> {
  const rows = await readTableNearHeading(page, /assigned policies/i);
  return tableRowsToAssignments(organizationName, undefined, rows, "UI:organization-details");
}

async function scrapeLocationAssignments(page: Page, organizationName: string): Promise<AssignmentRow[]> {
  const locationTableRows = await readTableNearHeading(page, /^locations$/i);
  const locationNames = locationTableRows
    .map((row) => row["Location"] || row["Name"] || "")
    .filter(Boolean);

  const results: AssignmentRow[] = [];
  for (const locationName of locationNames) {
    const locationLink = await firstVisibleOf(
      page.getByRole("link", { name: new RegExp(`^${locationName}$`, "i") }),
      page.getByText(new RegExp(`^${locationName}$`, "i")),
    );
    if (!locationLink) {
      continue;
    }

    await locationLink.click();
    await page.waitForLoadState("networkidle");
    const rows = await readTableNearHeading(page, /assigned policies/i);
    results.push(...tableRowsToAssignments(organizationName, locationName, rows, "UI:location-details"));

    const back = await firstVisibleOf(
      page.getByRole("link", { name: /back|organization|organizations/i }),
      page.getByRole("button", { name: /back|organization|organizations/i }),
    );
    if (back) {
      await back.click();
    } else {
      await page.goBack();
    }
    await page.waitForLoadState("networkidle");
  }

  return results;
}

async function collectVisibleOrganizations(page: Page): Promise<string[]> {
  const links = await page.getByRole("link").allInnerTexts();
  return [...new Set(links.map((value) => value.trim()).filter((value) => value && !/^(dashboard|organizations|policies)$/i.test(value)))];
}

async function run(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const config = JSON.parse(fs.readFileSync(args.configPath, "utf8"));
  const baseUrl = normalizeBaseUrl(String(config.InstanceUrl ?? ""));
  const browser = await chromium.launch({ headless: !process.env.HEADED });
  const context = fs.existsSync(STORAGE)
    ? await browser.newContext({ storageState: STORAGE })
    : await browser.newContext();
  const page = await context.newPage();

  try {
    await ensureLogin(page, baseUrl);
    if (!fs.existsSync(STORAGE)) {
      await context.storageState({ path: STORAGE });
    }

    await openOrganizations(page);

    let organizations = getOrganizationTargets(config);
    if (organizations.length === 0) {
      organizations = await collectVisibleOrganizations(page);
    }
    if (organizations.length === 0) {
      throw new Error("No organizations were supplied or discovered for the UI fallback.");
    }

    const assignments: AssignmentRow[] = [];
    for (const organizationName of organizations) {
      await openOrganizations(page);
      await openOrganization(page, organizationName);
      assignments.push(...(await scrapeOrganizationAssignments(page, organizationName)));
      assignments.push(...(await scrapeLocationAssignments(page, organizationName)));
    }

    fs.mkdirSync(path.dirname(args.outputPath), { recursive: true });
    fs.writeFileSync(
      args.outputPath,
      JSON.stringify(
        {
          generatedAt: new Date().toISOString(),
          assignments,
        },
        null,
        2,
      ),
      "utf8",
    );
  } finally {
    await context.close();
    await browser.close();
  }
}

run().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
