# Quick Reference: Testing Resolve-RmmAntivirusState.ps1

## TL;DR - Fast Iteration Workflow

```powershell
# 1. Quick syntax check + dry-run (2 minutes total)
.\Test-RmmAntivirusState-PreFlight.ps1 -Mode Quick

# 2. Run specific scenarios (5-10 minutes)
.\Test-RmmAntivirusState-Scenarios.ps1 -Scenario Baseline
.\Test-RmmAntivirusState-Scenarios.ps1 -Scenario Timeout

# 3. Full validation before deploying to Datto (10-15 minutes)
.\Test-RmmAntivirusState-PreFlight.ps1 -Mode Full
.\Test-RmmAntivirusState-Scenarios.ps1 -Scenario All
```

---

## Test Scripts Overview

### `Test-RmmAntivirusState-PreFlight.ps1`
Pre-flight validation before Datto RMM deployment.

**Modes:**
- **Quick** (default, ~30 sec): Syntax + dry-run only
- **Full** (~2 min): Full validation suite
- **Extended** (~5 min): Full + detailed analysis + performance baseline

**Usage:**
```powershell
# Quick check
.\Test-RmmAntivirusState-PreFlight.ps1

# Full validation
.\Test-RmmAntivirusState-PreFlight.ps1 -Mode Full

# Detailed analysis
.\Test-RmmAntivirusState-PreFlight.ps1 -Mode Extended
```

**What it checks:**
- ✓ File exists and is readable
- ✓ PowerShell syntax is valid
- ✓ Required functions are present
- ✓ Timeout protections are in place
- ✓ Dry-run execution succeeds
- ✓ Log/JSON output is valid
- ✓ WhatIf mode works (Full mode)
- ✓ Parameters are validated (Full mode)

---

### `Test-RmmAntivirusState-Scenarios.ps1`
Functional test scenarios with different configurations.

**Scenarios:**
1. **Baseline** - Quick dry-run test (30 sec)
2. **Timeout** - Verify all timeout mechanisms (10 sec)
3. **Candidates** - Multiple uninstall candidates (1-2 min)
4. **Services** - Performance benchmarks (30 sec)
5. **RetryPath** - AVG retry logic (info only, manual setup)
6. **All** - Run all scenarios (5-10 min)

**Usage:**
```powershell
# Single scenario
.\Test-RmmAntivirusState-Scenarios.ps1 -Scenario Baseline

# All scenarios
.\Test-RmmAntivirusState-Scenarios.ps1 -Scenario All

# Verbose output
.\Test-RmmAntivirusState-Scenarios.ps1 -Scenario Timeout -Verbose
```

---

## Typical Development Cycle

### Iteration 1: Make a change
```powershell
# Edit Resolve-RmmAntivirusState.ps1
notepad .\Resolve-RmmAntivirusState.ps1

# Quick check (30 seconds)
.\Test-RmmAntivirusState-PreFlight.ps1 -Mode Quick
```

**Outcome:** If it fails, you get feedback immediately. If it passes, proceed.

### Iteration 2: Validate functionality
```powershell
# Test specific scenarios related to your change
.\Test-RmmAntivirusState-Scenarios.ps1 -Scenario Timeout

# OR test everything
.\Test-RmmAntivirusState-Scenarios.ps1 -Scenario All
```

**Outcome:** Functional validation in 5-10 minutes.

### Iteration 3: Final validation before Datto
```powershell
# Full pre-flight check
.\Test-RmmAntivirusState-PreFlight.ps1 -Mode Full

# Review logs
$json = Get-Content 'C:\ProgramData\DattoRMM\AVRemediation\<latest>.json' | ConvertFrom-Json
$json | Select-Object Outcome, RebootRequired, NextAction
```

**Outcome:** If all green, deploy to Datto RMM.

---

## Manual Testing (When Scripts Aren't Enough)

### Direct execution with verbose output
```powershell
# Dry-run (safest for initial testing)
.\Resolve-RmmAntivirusState.ps1 -TargetMode WindowsDefender -DryRun -Verbose

# WhatIf mode (PowerShell prompts before dangerous ops)
.\Resolve-RmmAntivirusState.ps1 -TargetMode WindowsDefender -WhatIf

# Actual execution (production-like, but on safe system)
.\Resolve-RmmAntivirusState.ps1 -TargetMode WindowsDefender
```

### Inspect output immediately
```powershell
# View latest log
$latest = Get-ChildItem 'C:\ProgramData\DattoRMM\AVRemediation\' | 
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-Content $latest.FullName

# Parse latest JSON
$summary = Get-Content 'C:\ProgramData\DattoRMM\AVRemediation\<latest>.json' | ConvertFrom-Json
$summary | Format-List
```

---

## Troubleshooting

### Script times out when running tests
```powershell
# Run in Quick mode only (skips expensive tests)
.\Test-RmmAntivirusState-PreFlight.ps1 -Mode Quick

# Check if system is under load
Get-Process | Sort-Object WS -Descending | Select-Object -First 5
```

### JSON output is invalid
```powershell
# Check if log directory exists
Test-Path 'C:\ProgramData\DattoRMM\AVRemediation\'

# Manually check JSON format
Get-Content 'C:\ProgramData\DattoRMM\AVRemediation\<latest>.json' | ConvertFrom-Json
```

### Dry-run doesn't match expected products
```powershell
# Manually inventory installed security products
Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\* |
    Where-Object { $_.DisplayName -match 'Security|Antivirus|Defender' } |
    Select-Object DisplayName, Publisher, DisplayVersion
```

---

## Performance Expectations

| Operation | Target | Actual |
|-----------|--------|--------|
| Pre-flight Quick | < 1 min | ~30 sec |
| Pre-flight Full | < 5 min | ~2 min |
| Scenario Baseline | < 1 min | ~30 sec |
| Scenario All | < 15 min | ~5-10 min |
| Single product uninstall | < 15 min | 1-3 min (dry-run) |
| Multi-product uninstall | < 45 min | 5-15 min (depends on count) |

---

## Key Files

```
Resolve-RmmAntivirusState.ps1          Main script (fixed)
├── Test-RmmAntivirusState-PreFlight.ps1       Pre-flight validation
├── Test-RmmAntivirusState-Scenarios.ps1       Functional tests
└── Quick-Reference.md                         This file

C:\ProgramData\DattoRMM\AVRemediation\         Output directory
├── <hostname>-<timestamp>.log                 Verbose execution log
└── <hostname>-<timestamp>.json                Summary results (parse with ConvertFrom-Json)
```

---

## Datto RMM Integration

**After passing all local tests:**

1. Open Datto RMM → Components
2. Create new component from Resolve-RmmAntivirusState.ps1
3. Component settings:
   - **Type:** PowerShell (64-bit, no profile)
   - **Command:** `-Command "& { . .\Resolve-RmmAntivirusState.ps1 -TargetMode 'WindowsDefender' -WhatIf:$false }"`
   - **Timeout:** 60 minutes (allows 45-minute script budget + 15-minute safety margin)
4. Test on 1-2 pilot systems first
5. Monitor logs in RMM for success/failure patterns

---

## Common Parameter Combinations

**Test run (safe):**
```powershell
.\Resolve-RmmAntivirusState.ps1 -TargetMode WindowsDefender -DryRun -Verbose
```

**Production run (actually removes):**
```powershell
.\Resolve-RmmAntivirusState.ps1 -TargetMode DattoAV
```

**Datto RMM component (no profile):**
```powershell
powershell.exe -NoProfile -Command "& { . .\Resolve-RmmAntivirusState.ps1 -TargetMode 'WindowsDefender' -WhatIf:$false }"
```

**Custom uninstall timeout (for slow systems):**
```powershell
.\Resolve-RmmAntivirusState.ps1 -TargetMode WindowsDefender -UninstallTimeoutMinutes 20
```

---

## Questions?

- **Script syntax error?** → Run `Test-RmmAntivirusState-PreFlight.ps1 -Mode Quick`
- **Unsure if safe to deploy?** → Run `Test-RmmAntivirusState-PreFlight.ps1 -Mode Full`
- **Want to validate specific scenarios?** → Run `Test-RmmAntivirusState-Scenarios.ps1 -Scenario <name>`
- **Need detailed logs?** → Check `C:\ProgramData\DattoRMM\AVRemediation\<latest>.json`
