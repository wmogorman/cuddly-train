# Copilot Instructions for cuddly-train

## Repository Overview

**cuddly-train** is a multi-purpose toolkit containing:

1. **PowerShell Automation Scripts** - IT Glue REST API integrations, Datto RMM workflows, and MSP admin tasks
2. **Headless Browser Automation** - Playwright-based TypeScript tools for IT Glue, Datto EDR, and Duo integration workflows
3. **Windows System Administration** - Migration helpers, cleanup utilities, and device management scripts

The repository prioritizes operational automation for managed service providers (MSPs) with a focus on safe, batch-friendly operations and API rate limiting.

## Key Architecture Patterns

### PowerShell Scripts (Root Level & Subdirectories)

Most PowerShell scripts follow this pattern:

- **CLI parameter-first design**: Parameters are strongly typed with `-Parameter` values
- **Datto RMM deployment**: Scripts use `[CmdletBinding(SupportsShouldProcess)]` to support `-WhatIf` for dry-run safety
- **Environment variables**: Sensitive credentials (API keys, subdomains) default to `$env:` variables before falling back to parameters
- **Rate limiting**: Scripts that perform writes implement throttling (e.g., `RateLimitChanges`/`RateLimitWindowSeconds`) to avoid API limits
- **Pagination & batching**: List operations paginate with `PageSize` control; write operations batch with `MaxPerRun`/`RunUntilEmpty` flags
- **Verbose & error handling**: Scripts emit structured output and respect `$ErrorActionPreference = 'Stop'`

### Wrapper Pattern

- `__wrapper.ps1`: Entry point that invokes `__inner.ps1`, used for parameter inspection and Datto RMM logging
- `__inner.ps1`: Core logic that can handle `-WhatIf` and `-Confirm` flags via `ShouldProcess()`

### Headless Browser Automation (TypeScript)

Located in subdirectories: `it-glue-headless/`, `duo-headless/`, `datto-edr-headless/`

**Pattern:**
- Uses **Playwright** with Chromium for web automation
- Environment config via `.env` file in each subdirectory (e.g., `it-glue-headless.env`)
- Session persistence via `storage_state.json` (reuses login across runs)
- Headed vs. headless execution: `HEADED=1` env var for debugging/SSO flows
- Fallback selector logic: Multiple selector attempts with graceful failure handling

**Common patterns:**
```typescript
const env = (k: string, req = true) => process.env[k] || (req ? throw : '');
dotenv.config({ path: './subdir/subdir.env' });
async function firstVisibleOf(...candidates: Locator[]): Promise<Locator | null>
```

## Build, Test, and Lint

### Node.js / TypeScript (Headless Automation)

```bash
npm install                    # Install dependencies (including Playwright)
npm run setup                  # Install Playwright's Chromium browser

# Available scripts (from package.json):
npm start                      # Run IT Glue SNMP headless automation
npm run start:headed           # Run headed (for SSO/MFA debugging)
npm run edr:policy-snapshot    # Datto EDR policy snapshot (headless)
npm run edr:policy-snapshot:headed  # EDR snapshot with UI debugging
npm run duo:external-mfa-scrape      # Duo external MFA details scraper (headless)
npm run duo:external-mfa-scrape:headed  # Duo scraper with UI debugging
```

Scripts are run via `tsx` (TypeScript runner), eliminating need for build steps.

### PowerShell Scripts

No build/test/lint tools are present for PowerShell. Scripts are executed directly:

```powershell
# Local testing (dry-run):
.\script-name.ps1 -Subdomain 'example' -ApiKey 'xxxxxxxx' -Verbose

# Dry-run (WhatIf):
.\script-name.ps1 -Subdomain 'example' -ApiKey 'xxxxxxxx' -WhatIf

# Production (after validation):
.\script-name.ps1 -Subdomain 'example' -ApiKey 'xxxxxxxx' -WhatIf:$false
```

## Key Conventions

### PowerShell-Specific

1. **Strict Mode**: Always set `Set-StrictMode -Version Latest` at script top
2. **Error Handling**: Use `$ErrorActionPreference = 'Stop'` to fail fast
3. **API Key Management**: Default to `$env:ITGlueKey`, `$env:DuoAdminKey`, etc.; never hard-code secrets
4. **Comment Headers**: Use `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE` blocks for script documentation
5. **Rate Limit Headers**: Emit rate-limit status via console for visibility in Datto logs
6. **WhatIf Support**: All destructive operations check `$PSCmdlet.ShouldProcess()` before executing
7. **Output Format**: Emit objects for aggregation (e.g., `[PSCustomObject] @{ Count = $deleted }`)

### TypeScript / Headless Automation

1. **dotenv Loading Order**: Load default `.env` first, then override with subdirectory-specific `.env`:
   ```typescript
   dotenv.config();
   dotenv.config({ path: './subdir/subdir.env' });
   ```

2. **Required vs. Optional Env Vars**: Use helper `const env = (key, required = true) => ...`
3. **Selector Fallbacks**: Multiple selector strategies to handle UI changes:
   ```typescript
   async function firstVisibleOf(...candidates: Locator[]): Promise<Locator | null>
   ```

4. **Storage State Persistence**: Save and reuse login state in `storage_state.json` to avoid repeated logins
5. **Error Messages**: Include context when throwing (e.g., `throw new Error('Missing env: KEY')`)

### General

1. **Subdirectory Organization**: Related scripts grouped by integration (e.g., `duo-headless/`, `powertechnology-immybot/`)
2. **Example Files**: `.env.example` and `.json.example` patterns used for configuration templates
3. **Batch Safety**: Always validate logic with `-Verbose` or `-WhatIf` before enabling destructive actions
4. **Logging**: Favor console output over file writes (Datto RMM captures stdout naturally)

## Common Tasks

### Adding a New PowerShell Script

1. Use comment block with `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`
2. Add `[CmdletBinding(SupportsShouldProcess)]` if destructive
3. Implement rate limiting if writing to APIs
4. Default to environment variables for credentials
5. Test with `-Verbose` and `-WhatIf` flags

### Adding a Headless Automation Script

1. Create a new subdirectory (e.g., `vendor-name-headless/`)
2. Create `vendor-name-headless.env.example` with all required config keys
3. Use Playwright's built-in selector strategies (role, label, text, xpath as fallback)
4. Persist login via `storage_state.json` to speed up reruns
5. Test with `HEADED=1` npm run script for debugging

### Troubleshooting API Rate Limits

For PowerShell scripts:
- Increase `RateLimitWindowSeconds` (e.g., 600 for 10 minutes)
- Decrease `RateLimitChanges` (e.g., 2000 instead of 3000)
- Check 429 response codes in `-Verbose` output

For headless scripts:
- Check IT Glue/Datto/Duo documentation for rate limit headers
- Implement exponential backoff in retry logic if needed

## Environment & Dependencies

- **Windows PowerShell 5.1+** for PowerShell scripts (scripts are Windows-only)
- **Node.js 18+** for headless automation
- **npm** for dependency management
- **Playwright 1.46.0** for browser automation (installed via npm)
- **.env files**: Store at subdirectory level (e.g., `it-glue-headless/.env`)
