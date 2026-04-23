# Reports

Daily API audit and export scripts for Datto RMM, Datto BCDR, Datto EDR, and Duo. Each script queries its respective API and writes a CSV to `artifacts/<tool>/`. Run them all at once with `morning-report.ps1`.

## Quick start

```powershell
cd reports
.\morning-report.ps1
```

Output lands in `artifacts/` at the repo root. The full run takes roughly 5–15 minutes depending on tenant count.

## Credentials

Each tool needs a `.env` file in this directory. Copy the corresponding `.env.example`, fill in your credentials, and save without the `.example` extension. The `.env` files are gitignored.

| File | Variables | Where to get them |
|------|-----------|-------------------|
| `datto-rmm.env` | `DATTO_RMM_API_KEY`, `DATTO_RMM_API_SECRET` | Datto RMM → Setup → API |
| `datto-bcdr.env` | `DATTO_PUBLIC_KEY`, `DATTO_SECRET_KEY` | Datto Partner Portal → API credentials |
| `datto-edr.env` | `DATTO_EDR_HOST`, `DATTO_EDR_TOKEN` | Datto EDR → Settings → API |
| `duo-accounts-api.env` | `DUO_PARENT_API_HOST`, `DUO_IKEY`, `DUO_SKEY` | Duo Admin Panel → Applications → Accounts API |

## morning-report.ps1

Orchestrates all daily report scripts in sequence and prints a summary.

```
.\morning-report.ps1 [-Skip <suite,...>] [-ArtifactsRoot <path>]
                     [-DattoRmmEnvFile <path>] [-DattoBcdrEnvFile <path>]
                     [-DattoEdrEnvFile <path>] [-DuoEnvFile <path>]
```

**`-Skip`** accepts any combination of suite names to omit: `RMM`, `BCDR`, `EDR`, `Duo`.

```powershell
.\morning-report.ps1                       # run everything
.\morning-report.ps1 -Skip EDR            # skip both EDR scripts
.\morning-report.ps1 -Skip RMM,BCDR       # skip multiple suites
```

Example summary output:

```
=== Morning Report Summary ===
[OK]    datto-rmm-filter-report              12s
[OK]    datto-bcdr-health-audit              45s
[OK]    datto-edr-ta-report                 118s
[OK]    datto-edr-ta-analyze                  3s
[OK]    duo-audit-entra-sync-groups          22s
[OK]    duo-audit-external-mfa-apps          18s
[OK]    duo-audit-security-access            20s
========================================================
Completed in 3m 58s  |  7 OK, 0 failed, 0 skipped
```

Exit code is `0` on full success, `1` if any script failed — useful for scheduled task alerting.

---

## Datto RMM

### datto-rmm-filter-report.ps1

Exports all custom device filters and their device counts.

```powershell
.\datto-rmm-filter-report.ps1 -EnvFile .\datto-rmm.env
.\datto-rmm-filter-report.ps1 -EnvFile .\datto-rmm.env -IncludeDefault
.\datto-rmm-filter-report.ps1 -EnvFile .\datto-rmm.env -SkipDeviceCount
```

**Output:** `artifacts/datto-rmm/datto-rmm-filters.csv`

Columns: `FilterType`, `FilterId`, `FilterName`, `Description`, `DeviceCount`, `DateCreated`, `LastUpdated`

**Note:** The Datto RMM API does not expose filter criteria/rules, policy associations, or job schedules — only what is listed above.

---

## Datto BCDR

### datto-bcdr-health-audit.ps1

Reports issues across all active BCDR devices and agents: offline devices, active alerts, agents that have never backed up, stale backups, and screenshot verification failures.

```powershell
.\datto-bcdr-health-audit.ps1 -EnvFile .\datto-bcdr.env
.\datto-bcdr-health-audit.ps1 -EnvFile .\datto-bcdr.env -OutputCsvPath .\my-output.csv
.\datto-bcdr-health-audit.ps1 -EnvFile .\datto-bcdr.env -DeviceOfflineHours 2 -BackupStaleHours 48
```

**Output:** `artifacts/datto-bcdr/datto-bcdr-health-audit.csv` (when run via `morning-report.ps1`)

**Issue types reported:**

| IssueType | Meaning |
|-----------|---------|
| `device-offline` | Device has not checked in within `-DeviceOfflineHours` (default 4) |
| `device-alerts` | Device has one or more active alerts |
| `backup-never` | Agent has never completed a successful backup |
| `backup-stale` | Last backup is older than `-BackupStaleHours` (default 25) |
| `screenshot-never` | Screenshot verification has never run |
| `screenshot-failed` | Last screenshot verification attempt failed |

### datto-bcdr-screenshot-enforce.ps1

Reports screenshot verification status across agents and optionally opens portal links for remediation. Not included in `morning-report.ps1` — run standalone as needed.

```powershell
.\datto-bcdr-screenshot-enforce.ps1 -EnvFile .\datto-bcdr.env
.\datto-bcdr-screenshot-enforce.ps1 -EnvFile .\datto-bcdr.env -OnlyNeedsAttention
.\datto-bcdr-screenshot-enforce.ps1 -EnvFile .\datto-bcdr.env -OpenPortalLinks   # opens browser tabs
```

---

## Datto EDR

### datto-edr-ta-report.ps1

Exports Threat Analysis enrollment status, policy definitions, and policy assignments across all accounts and locations.

```powershell
.\datto-edr-ta-report.ps1 -EnvFile .\datto-edr.env
```

**Output:** Three CSVs in `artifacts/datto-edr/`:

| File | Contents |
|------|----------|
| `ta-report-enrollment.csv` | Endpoint enrollment status per account/location |
| `ta-report-policies.csv` | All defined Threat Analysis policies |
| `ta-report-policy-assignments.csv` | Which policies are assigned to which scopes |

### datto-edr-ta-analyze.ps1

Analyzes the policy assignment CSV produced by `datto-edr-ta-report.ps1` and flags scopes with missing or incomplete coverage. Run after `datto-edr-ta-report.ps1` — `morning-report.ps1` handles this automatically.

```powershell
.\datto-edr-ta-analyze.ps1   # auto-discovers latest ta-report-policy-assignments.csv
.\datto-edr-ta-analyze.ps1 -PolicyAssignmentsCsvPath .\my-assignments.csv
```

**Output:** `artifacts/datto-edr/ta-report-gaps.csv`

Columns: `Organization`, `Location`, `Severity`, `FindingType`, `Detail`

### datto-edr-policy-audit.ps1

Audits EDR policy configurations against a reference JSON. Requires a config file — see `examples/datto-edr-policy-audit.example.json` for the format. Not included in `morning-report.ps1`.

```powershell
.\datto-edr-policy-audit.ps1 -ConfigPath ..\examples\datto-edr-policy-audit.example.json
```

**Output:** `artifacts/datto-edr/datto-edr-policy-audit.csv` + `.json`

---

## Duo

All Duo scripts use the **Accounts API** (`duo-accounts-api.env`) to enumerate child accounts, then query each child's Admin API.

### duo-audit-entra-sync-groups.ps1

Verifies that each child account's Microsoft Entra ID directory sync has the required sync-managed Duo groups materialized.

```powershell
.\duo-audit-entra-sync-groups.ps1 -ParentApiHost api-xxxx.duosecurity.com -IKey DI... -SKey ...
# or set DUO_PARENT_API_HOST / DUO_IKEY / DUO_SKEY in duo-accounts-api.env and use morning-report.ps1
```

**Output:** `artifacts/duo/duo-entra-sync-group-audit.csv`

**Note:** The Duo API does not expose the sync group list from the admin panel — this script infers group presence from sync-managed group names in the Admin API response. Treat flagged accounts as a shortlist to validate in the Duo UI.

### duo-audit-external-mfa-apps.ps1

Finds child accounts that have a Microsoft Entra ID External MFA (`microsoft-eam`) integration.

```powershell
.\duo-audit-external-mfa-apps.ps1 -EnvFilePath .\duo-accounts-api.env
.\duo-audit-external-mfa-apps.ps1 -EnvFilePath .\duo-accounts-api.env -OnlyAccountNames "Acme Corp"
```

**Output:** `artifacts/duo/duo-external-mfa-applications.csv`

### duo-audit-security-access.ps1

Audits external (non-MSP) admin accounts and active bypass codes across all child accounts.

```powershell
.\duo-audit-security-access.ps1 -EnvFilePath .\duo-accounts-api.env
.\duo-audit-security-access.ps1 -EnvFilePath .\duo-accounts-api.env -MspEmailDomain actamsp.com
```

**Output:** Two CSVs in `artifacts/duo/`:

| File | Contents |
|------|----------|
| `duo-admin-access-audit.csv` | All admins classified as `MspAdmin` or `ExternalAdmin` |
| `duo-bypass-codes-audit.csv` | Bypass codes, expiration status (`Indefinite` if no expiry set) |

### duo-create-admin-api-integrations.ps1

Creates or verifies Admin API integrations across child accounts. **Has write side effects** — use `-WhatIf` first. Not included in `morning-report.ps1`.

```powershell
.\duo-create-admin-api-integrations.ps1 -ParentApiHost api-xxxx.duosecurity.com -IKey DI... -SKey ... -WhatIf
.\duo-create-admin-api-integrations.ps1 -ParentApiHost api-xxxx.duosecurity.com -IKey DI... -SKey ...
```

**Output:** `artifacts/duo/duo-admin-api-integrations.csv`

---

## Outputs reference

All artifacts are written to `artifacts/` at the repo root and are gitignored.

```
artifacts/
  datto-rmm/
    datto-rmm-filters.csv
  datto-bcdr/
    datto-bcdr-health-audit.csv
  datto-edr/
    ta-report-enrollment.csv
    ta-report-policies.csv
    ta-report-policy-assignments.csv
    ta-report-gaps.csv
  duo/
    duo-entra-sync-group-audit.csv
    duo-external-mfa-applications.csv
    duo-admin-access-audit.csv
    duo-bypass-codes-audit.csv
```
