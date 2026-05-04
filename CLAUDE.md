# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

MSP operations toolkit: PowerShell scripts for IT Glue, Datto RMM, Datto BCDR, Datto EDR, and Duo REST APIs; Playwright/TypeScript headless automation for the same platforms; and miscellaneous Windows/Entra admin utilities.

## Running things

### PowerShell scripts (root level)

Scripts at the root are invoked directly. Always validate with `-WhatIf -Verbose` before a live run:

```powershell
.\script-name.ps1 -Subdomain 'datamax' -WhatIf -Verbose
.\script-name.ps1 -Subdomain 'datamax' -WhatIf:$false -Verbose
```

API keys default to environment variables (`$env:ITGlueKey`, `$env:DattoRmmApiKey`, etc.) — never pass them as literals.

### Daily reports

```powershell
cd reports
.\morning-report.ps1                    # run all suites
.\morning-report.ps1 -Skip EDR         # skip a suite (RMM, BCDR, EDR, Duo)
```

Each suite needs a `.env` file in `reports/` — copy the matching `.env.example` and fill in credentials. Output lands in `artifacts/` (gitignored).

### Playwright/TypeScript automation

```bash
npm install          # once
npm run setup        # installs Playwright Chromium once

npm start                           # IT Glue Network Glue SNMP
npm run start:headed                # same, with visible browser (for SSO/MFA)
npm run edr:policy-snapshot
npm run duo:external-mfa-scrape
```

Each headless subdirectory (`it-glue-headless/`, `datto-edr-headless/`, `duo-headless/`) has its own `.env` file. Load order: `dotenv.config()` (root), then `dotenv.config({ path: './subdir/subdir.env' })`. Login state is persisted in `storage_state.json` so repeated runs skip re-login.

## PowerShell script architecture

All IT Glue API scripts share the same internal structure — copy from an existing script rather than rebuilding from scratch:

- **`Invoke-ITGlue`** helper — handles auth headers (`x-api-key`, `x-account-subdomain`), URL building, retry with exponential backoff on 429/5xx, and JSON:API error body parsing. See `bulk-create-passwords.ps1` for the canonical version with response-body error extraction; `delete-ad-computer.ps1` for the variant that converts Body to JSON internally.
- **`New-RandomPassword`** / `New-RandomPassphrase` — cryptographic RNG with Fisher-Yates shuffle, guarantees one char from each character class. Copy from `bulk-create-passwords.ps1`.
- **Pagination** — `GET` with `page[size]` and `page[number]`, loop until response count < page size, sort by `id` for stability.
- **Rate limiting** — sliding window (`$windowStart`, `$windowCount`, `$RateLimitChanges`, `$RateLimitWindowSeconds`). Sleep the remainder of the window when the counter reaches the limit. See `delete-ad-computer.ps1`.
- **WhatIf** — `[CmdletBinding(SupportsShouldProcess)]` + `$PSCmdlet.ShouldProcess(target, operation)` wrapping every write. The `else` branch emits a `[WHATIF] Would ...` line.

Every script begins with:
```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
```

## Output conventions

- Generated artifacts → `artifacts/<tool>/` (gitignored, created at runtime)
- Reference/historical outputs worth keeping → `samples/`
- Example inputs and config templates → `examples/`
- Runbooks and operator notes → `docs/`
- Root script filenames are intentionally stable (Datto RMM components reference them by name)
