# CLAUDE.md — cuddly-train

Guidance for AI assistants working in this repository.

---

## Repository Overview

**cuddly-train** is a multi-purpose MSP (Managed Service Provider) automation toolkit with three distinct layers:

1. **PowerShell Automation Scripts** (~85 scripts) — IT Glue REST API integrations, Datto RMM deployment components, Windows system administration, Entra ID / Microsoft 365 management, and security remediation.
2. **Headless Browser Automation** (TypeScript + Playwright) — Web UI automation for IT Glue Network Glue, Datto EDR, and Duo Security where no API exists.
3. **Infrastructure & Utility Assets** — Azure VM provisioning, Active Directory migration helpers, DFHack Lua scripts, ImmyBot payloads.

The repository prioritizes **safe, batch-friendly operations**: every destructive script supports `-WhatIf` dry-runs, rate limiting, and pagination controls.

---

## Directory Structure

```
cuddly-train/
├── *.ps1                           # Root-level PowerShell scripts (IT Glue, Datto RMM, Entra, Duo, cleanup)
├── package.json                    # Node.js project (headless automation)
├── .gitignore                      # Excludes .env, node_modules, storage_state.json, CSV outputs
├── README.md                       # IT Glue automation overview
├── TESTING-QUICK-REFERENCE.md      # Testing workflow for Resolve-RmmAntivirusState.ps1
│
├── it-glue-headless/               # Playwright: Network Glue SNMPv3 credential injection
│   ├── ng-snmp-md5aes.ts
│   ├── it-glue-headless.env        # Local credentials (gitignored)
│   ├── it-glue-headless.env.example
│   └── tsconfig.json
│
├── datto-edr-headless/             # Playwright: Datto EDR policy assignment auditing
│   ├── datto-edr-policy-snapshot.ts
│   ├── datto-edr-headless.env.example
│   └── tsconfig.json
│
├── duo-headless/                   # Playwright: Duo external MFA details scraper
│   ├── duo-external-mfa-details-scrape.ts
│   ├── duo-headless.env.example
│   └── tsconfig.json
│
├── powertechnology-immybot/        # ImmyBot payload scripts for PTI client
│   ├── pti-*.ps1                   # Runtime scripts (workstation baseline, printers, VPN, etc.)
│   ├── immy-wrappers/              # Thin wrapper scripts for Immy test/set tasks
│   ├── pti-common.ps1              # Shared helpers (stage-and-install, blocked-package)
│   └── build-pti-immy-payload.ps1  # Builds PTI-Immy-Payload.zip
│
├── ADto365-HardMatch/              # AD → Entra ID hard-match utilities
├── HardMatch/                      # GUI-assisted hard-match helpers
├── dfremote-azure/                 # Dwarf Fortress Remote Azure VM provisioning + DFHack Lua
├── netthack/                       # NetHack environment setup for PuTTY
├── enterprise-app-onboard-wave-*/  # Enterprise app onboarding tracking data
└── .github/
    └── copilot-instructions.md     # Legacy instructions (superseded by this file)
```

---

## Technology Stack

| Layer | Language | Runtime | Key Libraries |
|---|---|---|---|
| PowerShell automation | PowerShell 5.1 | Windows only | Built-in REST (`Invoke-RestMethod`) |
| Headless automation | TypeScript | Node.js 18+ | Playwright 1.46.0, tsx 4.7.0, dotenv 16.4.5 |
| ImmyBot payloads | PowerShell 5.1 | Windows only | — |
| Azure provisioning | PowerShell 5.1 | Windows only | Az PowerShell module |

---

## Development Workflows

### Node.js / TypeScript (Headless Automation)

```bash
npm install                               # Install Playwright + dependencies
npm run setup                             # Install Playwright's Chromium browser (first time only)

npm start                                 # IT Glue SNMPv3 headless run
npm run start:headed                      # IT Glue SNMPv3 with visible browser (for SSO/MFA debugging)

npm run edr:policy-snapshot               # Datto EDR policy snapshot (headless)
npm run edr:policy-snapshot:headed        # Datto EDR with visible browser

npm run duo:external-mfa-scrape           # Duo external MFA details scraper (headless)
npm run duo:external-mfa-scrape:headed    # Duo scraper with visible browser
```

Scripts run via `tsx` — no build step required.

**First-time setup per headless tool:**
1. Copy `<tool>.env.example` → `<tool>.env` and fill in credentials.
2. Run headed to complete SSO/MFA interactively: `npm run start:headed`
3. Session is saved to `storage_state.json`; subsequent runs reuse it headlessly.

### PowerShell Scripts

No build system. Scripts execute directly in PowerShell 5.1+.

```powershell
# Dry-run (no changes, review output):
.\script-name.ps1 -Subdomain 'example' -ApiKey 'xxxxxxxx' -WhatIf

# Verbose dry-run (shows pagination, rate-limit, decision logic):
.\script-name.ps1 -Subdomain 'example' -ApiKey 'xxxxxxxx' -Verbose

# Production run (after validation):
.\script-name.ps1 -Subdomain 'example' -ApiKey 'xxxxxxxx' -WhatIf:$false
```

**Datto RMM Deployment:**
```powershell
# Component command in Datto RMM:
powershell.exe -NoProfile -Command "& { . .\script-name.ps1 -Subdomain 'example' -WhatIf:$false }"
```

### Testing Resolve-RmmAntivirusState.ps1

This script has a dedicated test suite (see `TESTING-QUICK-REFERENCE.md`):

```powershell
# Fast iteration (30 seconds):
.\Test-RmmAntivirusState-PreFlight.ps1 -Mode Quick

# Functional scenarios:
.\Test-RmmAntivirusState-Scenarios.ps1 -Scenario Baseline
.\Test-RmmAntivirusState-Scenarios.ps1 -Scenario Timeout

# Full pre-deployment validation:
.\Test-RmmAntivirusState-PreFlight.ps1 -Mode Full
.\Test-RmmAntivirusState-Scenarios.ps1 -Scenario All
```

---

## Key Conventions

### PowerShell Scripts

1. **Strict mode and error handling** — All scripts must start with:
   ```powershell
   Set-StrictMode -Version Latest
   $ErrorActionPreference = 'Stop'
   ```

2. **Comment-based help** — Every script requires `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, and `.EXAMPLE` blocks.

3. **Credential management** — Never hard-code secrets. Default to environment variables with parameter fallback:
   ```powershell
   [Parameter()] [string] $ApiKey = $env:ITGlueKey
   ```
   Common env vars: `$env:ITGlueKey`, `$env:DuoAdminKey`, `$env:DuoIntKey`, `$env:DuoSecretKey`.

4. **WhatIf support** — All scripts that write, delete, or modify data must use `[CmdletBinding(SupportsShouldProcess)]` and check `$PSCmdlet.ShouldProcess()` before every destructive call.

5. **Rate limiting** — Scripts that write to APIs implement `RateLimitChanges` / `RateLimitWindowSeconds` parameters. Default safe values: 3000 changes per 600 seconds. Emit rate-limit status to console for Datto log visibility.

6. **Pagination** — List operations must paginate. Use a `PageSize` parameter (default 50–500 depending on API) and loop until the page is smaller than `PageSize`.

7. **Batching** — Write operations use `MaxPerRun` and optionally `RunUntilEmpty` flags so operators can run incrementally and verify before committing to large changes.

8. **Output format** — Emit `[PSCustomObject]` for summary counts/status (Datto RMM aggregates stdout). Verbose stream for per-item decisions.

9. **Wrapper pattern** — `__wrapper.ps1` is the Datto entry point; it invokes `__inner.ps1` for core logic. The wrapper handles parameter inspection and logging headers.

### TypeScript / Headless Scripts

1. **dotenv loading order** — Load root `.env` first, then override with the subdirectory env:
   ```typescript
   dotenv.config();
   dotenv.config({ path: './subdir/subdir.env', override: true });
   ```

2. **Required env var helper** — Use the pattern below; never silently fall through:
   ```typescript
   const env = (key: string, required = true): string => {
     const val = process.env[key] ?? '';
     if (required && !val) throw new Error(`Missing env: ${key}`);
     return val;
   };
   ```

3. **Selector resilience** — Use `firstVisibleOf()` to try multiple Playwright locators before failing. Fall back to XPath only as a last resort.

4. **Session persistence** — Save browser context to `storage_state.json` after a successful login. Load it on subsequent runs to skip authentication.

5. **Headed debugging** — Respect the `HEADED` env var (`process.env.HEADED === '1'`) to launch a visible browser for interactive SSO/MFA flows.

6. **CLI argument parsing** — Parse `--flag value` pairs from `process.argv`. Include `--help` output that lists all supported flags.

7. **TypeScript strict mode** — All headless subdirectories use `tsconfig.json` with `"strict": true` and `"target": "ES2020"`.

### General

- **Secret hygiene** — `.gitignore` excludes `.env`, `storage_state.json`, `*.csv` outputs, `node_modules/`. Never commit credentials.
- **Example files** — Provide `.env.example` (and `.json.example` where applicable) with all required keys and placeholder values.
- **Batch safety** — Always test with `-WhatIf` / `-Verbose` / `HEADED=1` before production runs.
- **Console logging** — Prefer `Write-Host` / `Write-Verbose` / `console.log` over file writes. Datto RMM and terminal capture stdout naturally.
- **Subdirectory grouping** — Related scripts belong in a named subdirectory (`duo-headless/`, `powertechnology-immybot/`, etc.).

---

## Script Inventory (Root Level)

| Category | Scripts |
|---|---|
| IT Glue API | `delete-ad-computer.ps1`, `flexible-asset-types.ps1`, `remove-description-passwords.ps1`, `bulk-create-passwords.ps1`, `edit-password-notes.ps1` |
| Duo / External MFA | `duo-audit-external-mfa-apps.ps1`, `duo-audit-entra-sync-groups.ps1`, `duo-create-admin-api-integrations.ps1`, `duo-update-branding.ps1`, `external-mfa-rollout.ps1`, `external-mfa-rollout-core.ps1`, `external-mfa-rollout-all-tenants.ps1`, `external-mfa-rollout-gui.ps1` |
| Datto EDR / AV | `datto-edr-policy-audit.ps1`, `Resolve-RmmAntivirusState.ps1`, `Remove-LegacyAV.ps1` |
| Entra ID / M365 | `global-admin-audit.ps1`, `break-glass-group-compliance.ps1`, `credential-audit.ps1`, `dmx-integration-group-standardize.ps1`, `nosync-department-audit.ps1` |
| Enterprise App Onboard | `enterprise-app-onboard-all-partners.ps1`, `actamsp-bootstrap.ps1`, `actamsp-bootstrap-all-partners.ps1` |
| Windows Cleanup | `Cleanup-Deep.ps1`, `Remove-ShiftBrowser.ps1`, `dell-cleanup.ps1`, `remove-legacy-support-ticket-shortcut.ps1`, `remove-per-user-support-ticket-shortcut.ps1`, `Disable-CEIP.ps1` |
| System Admin | `apply-ntfs-auditing-to-share-roots.ps1`, `check-host-health.ps1`, `check-groups.ps1`, `check-moderation-everywhere.ps1`, `mdm-make-available.ps1`, `push-by-serial.ps1`, `redirect-endpoint.ps1`, `update-manufacturer-model.ps1`, `import-manufacturer-model.ps1` |
| Profile Migration | `local-to-public.ps1`, `staff-to-public.ps1`, `change-contact-location.ps1` |
| Password Management | `strong-password-techcare.ps1`, `resolve-bad-password-events.ps1` |
| Utilities | `get-largest-files.ps1`, `new-support-ticket.ps1`, `esu-script.ps1` |
| Datto RMM Wrapper | `__wrapper.ps1` → `__inner.ps1` |
| Test Harness | `Test-RmmAntivirusState-PreFlight.ps1`, `Test-RmmAntivirusState-Scenarios.ps1` |

---

## Adding New Scripts

### New PowerShell Script (checklist)

- [ ] Add `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE` comment block
- [ ] Use `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`
- [ ] Add `[CmdletBinding(SupportsShouldProcess)]` if any destructive operations exist
- [ ] Default credential parameters to `$env:` variables
- [ ] Implement `RateLimitChanges` / `RateLimitWindowSeconds` for API write loops
- [ ] Implement `PageSize` loop for list operations
- [ ] Emit a `[PSCustomObject]` summary at the end
- [ ] Test locally with `-WhatIf` and `-Verbose` before deploying to Datto

### New Headless Automation Script

- [ ] Create a new subdirectory: `<vendor>-headless/`
- [ ] Add `<vendor>-headless.env.example` listing all required keys
- [ ] Add a `tsconfig.json` with `"strict": true`
- [ ] Add an npm script in `package.json` for headless and `:headed` variants
- [ ] Implement `firstVisibleOf()` for selector resilience
- [ ] Save `storage_state.json` after first successful login
- [ ] Accept `HEADED=1` env var for debugging

---

## Troubleshooting

### PowerShell — API Errors

| Error | Cause | Fix |
|---|---|---|
| 401 Unauthorized | Missing/invalid API key or subdomain | Confirm `$env:ITGlueKey` value and `-Subdomain` match the IT Glue account |
| 429 Too Many Requests | Rate limit hit | Increase `RateLimitWindowSeconds` or decrease `RateLimitChanges` |
| Unexpected JSON | API schema changed | Add `-Verbose` to capture raw response and adjust parsing |

### PowerShell — AV Remediation

```powershell
# Check what security products are installed:
Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\* |
    Where-Object { $_.DisplayName -match 'Security|Antivirus|Defender' } |
    Select-Object DisplayName, Publisher, DisplayVersion

# View latest AV remediation log:
Get-ChildItem 'C:\ProgramData\DattoRMM\AVRemediation\' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content
```

### Headless — Selector Failures

1. Run with a visible browser: `npm run start:headed`
2. Observe which element is missing or has changed
3. Update selectors using ARIA roles/labels first; fall back to XPath only if needed
4. Ensure `ORG_NAME` / `NETWORK_NAME` match exactly what IT Glue displays

### Headless — Stale Session

Delete `storage_state.json` and re-run headed to authenticate fresh.

---

## Environment & Dependencies

| Requirement | Version | Notes |
|---|---|---|
| Windows PowerShell | 5.1+ | PowerShell scripts are Windows-only |
| Node.js | 18+ | Headless automation |
| npm | bundled with Node.js | Dependency management |
| Playwright | 1.46.0 | Installed via `npm install` + `npm run setup` |
| tsx | 4.7.0 | Zero-config TypeScript runner; no compile step needed |
| dotenv | 16.4.5 | `.env` file loading for headless scripts |

---

## Git Workflow

- Default branch: `main`
- No CI/CD pipelines — validation is done locally before pushing
- Deploy to Datto RMM only after passing local tests (WhatIf + full pre-flight)
- Keep `.env` files, `storage_state.json`, and CSV outputs out of commits (enforced by `.gitignore`)
