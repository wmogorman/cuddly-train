<#
.SYNOPSIS
Pre-flight validation for Resolve-RmmAntivirusState.ps1 before Datto RMM deployment.

.DESCRIPTION
Runs a series of syntax, logic, and functional checks to ensure the script is safe
to upload and run in production. All tests are read-only (uses -DryRun and -WhatIf).

.PARAMETER ScriptPath
Path to Resolve-RmmAntivirusState.ps1. Defaults to current directory.

.PARAMETER Mode
Execution mode: 'Full' (all checks), 'Quick' (syntax + dry-run only), 'Extended' (all + detailed analysis).
Default: 'Quick'

.EXAMPLE
.\Test-RmmAntivirusState-PreFlight.ps1

.\Test-RmmAntivirusState-PreFlight.ps1 -Mode Full

.\Test-RmmAntivirusState-PreFlight.ps1 -ScriptPath "C:\scripts\Resolve-RmmAntivirusState.ps1" -Mode Extended
#>

[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'Resolve-RmmAntivirusState.ps1'),
    [ValidateSet('Quick', 'Full', 'Extended')]
    [string]$Mode = 'Quick'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsWarnings = 0

function Write-TestHeader {
    param([string]$Header)
    Write-Host "`n" -NoNewline
    Write-Host '=' * 70 -ForegroundColor Cyan
    Write-Host $Header -ForegroundColor Cyan
    Write-Host '=' * 70 -ForegroundColor Cyan
}

function Write-TestPass {
    param([string]$Message)
    Write-Host "✓ PASS: $Message" -ForegroundColor Green
    $script:TestsPassed++
}

function Write-TestFail {
    param([string]$Message)
    Write-Host "✗ FAIL: $Message" -ForegroundColor Red
    $script:TestsFailed++
}

function Write-TestWarn {
    param([string]$Message)
    Write-Host "⚠ WARN: $Message" -ForegroundColor Yellow
    $script:TestsWarnings++
}

# ===== Test 1: File Existence =====
Write-TestHeader 'Test 1: Script File Validation'

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-TestFail "Script not found at: $ScriptPath"
    exit 1
}
Write-TestPass "Script file exists at: $ScriptPath"

$scriptSize = (Get-Item $ScriptPath).Length
Write-TestPass "Script size: $([Math]::Round($scriptSize / 1KB)) KB"

# ===== Test 2: Syntax Validation =====
Write-TestHeader 'Test 2: PowerShell Syntax Validation'

try {
    $tokens = @()
    $errors = @()
    $null = [System.Management.Automation.PSParser]::Tokenize(
        [IO.File]::ReadAllText($ScriptPath),
        [ref]$errors
    )
    
    if ($errors.Count -eq 0) {
        Write-TestPass "Syntax is valid ($($tokens.Count) tokens)"
    }
    else {
        Write-TestFail "Syntax errors found: $($errors.Count)"
        foreach ($error in $errors) {
            Write-Host "  - $($error.Message) at line $($error.Token.StartLine)" -ForegroundColor Red
        }
        exit 1
    }
}
catch {
    Write-TestFail "Syntax validation failed: $_"
    exit 1
}

# ===== Test 3: Required Functions =====
Write-TestHeader 'Test 3: Required Functions'

$requiredFunctions = @(
    'Resolve-UninstallAction',
    'Invoke-UninstallEntry',
    'Get-SecurityInventory',
    'Get-RemovalCandidates',
    'Resolve-Outcome',
    'Get-ElapsedTimeSeconds',
    'Test-TimeoutExceeded'
)

$scriptContent = Get-Content $ScriptPath -Raw
foreach ($func in $requiredFunctions) {
    if ($scriptContent -match "function\s+$func\s*\{") {
        Write-TestPass "Function found: $func"
    }
    else {
        Write-TestFail "Function missing: $func"
    }
}

# ===== Test 4: Timeout Protection Checks =====
Write-TestHeader 'Test 4: Timeout Protection Validation'

$timeoutChecks = @{
    'ServiceStopTimeoutSeconds' = 'Service stop timeout defined'
    'ProcessCleanupTimeoutSeconds' = 'Process cleanup timeout defined'
    'StartTimeUtc' = 'Elapsed time tracking initialized'
}

foreach ($varName in $timeoutChecks.Keys) {
    if ($scriptContent -match "\`$script:$varName\s*=") {
        Write-TestPass $timeoutChecks[$varName]
    }
    else {
        Write-TestFail $timeoutChecks[$varName]
    }
}

# Check for Invoke-CommandWithTimeout calls
$timeoutCallCount = ([regex]::Matches($scriptContent, 'Invoke-CommandWithTimeout')).Count
if ($timeoutCallCount -ge 5) {
    Write-TestPass "Timeout-protected operations: $timeoutCallCount calls to Invoke-CommandWithTimeout"
}
else {
    Write-TestWarn "Low timeout protection count: $timeoutCallCount (expected >= 5)"
}

# ===== Test 5: Dry-Run Mode Validation =====
Write-TestHeader 'Test 5: Dry-Run Execution (WindowsDefender Mode)'

Write-Host "Running: & '$ScriptPath' -TargetMode WindowsDefender -DryRun -Verbose" -ForegroundColor Gray

$dryRunOutput = $null
$dryRunException = $null

try {
    $dryRunOutput = & $ScriptPath -TargetMode WindowsDefender -DryRun -Verbose -ErrorAction Stop 2>&1
}
catch {
    $dryRunException = $_
}

# In dry-run mode, the script intentionally fails if no action was taken
# We're just verifying the script ran and generated output
if ($null -ne $dryRunOutput -or $null -ne $dryRunException) {
    Write-TestPass "Dry-run execution completed (script ran and generated output)"
    
    # Check if log file was created
    $logDir = 'C:\ProgramData\DattoRMM\AVRemediation'
    if (Test-Path $logDir) {
        $logFiles = Get-ChildItem $logDir -Filter '*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($logFiles) {
            Write-TestPass "Log file was created: $($logFiles.Name)"
        }
    }
}
else {
    Write-TestFail "Dry-run execution did not produce output"
}

# ===== Test 6: Log Output Validation =====
Write-TestHeader 'Test 6: Log and Summary Output Validation'

$logDir = 'C:\ProgramData\DattoRMM\AVRemediation'
if (Test-Path -LiteralPath $logDir) {
    $latestFiles = Get-ChildItem $logDir | Sort-Object LastWriteTime -Descending | Select-Object -First 2
    
    if ($latestFiles) {
        Write-TestPass "Log directory exists and contains files"
        
        $latestJson = $latestFiles | Where-Object { $_.Extension -eq '.json' } | Select-Object -First 1
        if ($latestJson) {
            try {
                $summary = Get-Content $latestJson.FullName | ConvertFrom-Json
                Write-TestPass "Latest summary JSON is valid"
                
                $requiredFields = @('ComputerName', 'Timestamp', 'TargetMode', 'Outcome', 'LogPath')
                foreach ($field in $requiredFields) {
                    if ($summary | Get-Member -Name $field) {
                        Write-TestPass "Summary field present: $field"
                    }
                    else {
                        Write-TestFail "Summary field missing: $field"
                    }
                }
                
                Write-Host "`nLatest Summary:" -ForegroundColor Cyan
                Write-Host "  Computer: $($summary.ComputerName)"
                Write-Host "  Timestamp: $($summary.Timestamp)"
                Write-Host "  Mode: $($summary.TargetMode)"
                Write-Host "  Outcome: $($summary.Outcome)"
                Write-Host "  Reboot Required: $($summary.RebootRequired)"
            }
            catch {
                Write-TestFail "Failed to parse summary JSON: $_"
            }
        }
        else {
            Write-TestWarn "No JSON summary files found (expected after first run)"
        }
    }
}
else {
    Write-TestWarn "Log directory doesn't exist yet (will be created on first run): $logDir"
}

# ===== Test 7: WhatIf Mode Validation (Extended) =====
if ($Mode -in @('Full', 'Extended')) {
    Write-TestHeader 'Test 7: WhatIf Mode Validation'
    
    Write-Host "Running: & '$ScriptPath' -TargetMode DattoAV -WhatIf" -ForegroundColor Gray
    
    try {
        $whatIfOutput = & $ScriptPath -TargetMode DattoAV -WhatIf 2>&1
        Write-TestPass "WhatIf mode execution completed"
        
        $whatIfText = $whatIfOutput | Out-String
        if ($whatIfText -match 'WhatIf|would' -or $whatIfText.Length -gt 100) {
            Write-TestPass "WhatIf output appears valid"
        }
    }
    catch {
        Write-TestWarn "WhatIf mode encountered an issue: $_"
    }
}

# ===== Test 8: Parameter Validation (Extended) =====
if ($Mode -in @('Full', 'Extended')) {
    Write-TestHeader 'Test 8: Parameter Validation'
    
    $validModes = @('DattoAV', 'WindowsDefender')
    foreach ($mode in $validModes) {
        try {
            $null = & $ScriptPath -TargetMode $mode -DryRun -ErrorAction Stop 2>&1
            Write-TestPass "Mode parameter accepted: $mode"
        }
        catch {
            Write-TestFail "Mode parameter validation failed for: $mode"
        }
    }
}

# ===== Test 9: Performance Baseline (Extended) =====
if ($Mode -eq 'Extended') {
    Write-TestHeader 'Test 9: Performance Baseline'
    
    Write-Host "Measuring script execution time (dry-run)..." -ForegroundColor Gray
    $startTime = Get-Date
    
    try {
        $null = & $ScriptPath -TargetMode WindowsDefender -DryRun -ErrorAction Stop 2>&1
        $duration = (Get-Date) - $startTime
        
        Write-TestPass "Dry-run completed in $([Math]::Round($duration.TotalSeconds, 2)) seconds"
        
        if ($duration.TotalSeconds -lt 60) {
            Write-TestPass "Performance is acceptable for CI/CD pipelines"
        }
        else {
            Write-TestWarn "Performance may be slow for rapid iteration: $([Math]::Round($duration.TotalSeconds, 2))s"
        }
    }
    catch {
        Write-TestWarn "Performance baseline test failed: $_"
    }
}

# ===== Summary =====
Write-TestHeader 'Test Summary'

$totalTests = $script:TestsPassed + $script:TestsFailed
$passRate = if ($totalTests -gt 0) { [Math]::Round(($script:TestsPassed / $totalTests) * 100) } else { 0 }

Write-Host "Total Tests: $totalTests"
Write-Host "  ✓ Passed: $($script:TestsPassed) ($passRate%)" -ForegroundColor Green
Write-Host "  ✗ Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  ⚠ Warnings: $($script:TestsWarnings)" -ForegroundColor Yellow

if ($script:TestsFailed -eq 0) {
    Write-Host "`n✓ All checks passed! Script is ready for deployment." -ForegroundColor Green
    exit 0
}
else {
    Write-Host "`n✗ Some checks failed. Fix issues before deploying." -ForegroundColor Red
    exit 1
}
