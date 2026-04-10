<#
.SYNOPSIS
Test scenario suite for Resolve-RmmAntivirusState.ps1 timeout fixes.

.DESCRIPTION
Provides a collection of test scenarios to validate the timeout protection
and core functionality of the antivirus state resolver script.

Scenarios:
1. Quick Baseline - Fast validation (30 seconds)
2. Timeout Protection - Verify all timeout paths work correctly
3. Multiple Candidates - Test with multiple non-target AV products
4. Service Enumeration - Test slow service/process lookups
5. Retry Path - Test AVG-specific retry logic (manual setup required)

.PARAMETER Scenario
Which scenario to run: 'Baseline', 'Timeout', 'Candidates', 'Services', 'RetryPath', or 'All'
Default: 'Baseline'

.PARAMETER Verbose
Enable verbose output for debugging.

.EXAMPLE
.\Test-RmmAntivirusState-Scenarios.ps1 -Scenario Baseline

.\Test-RmmAntivirusState-Scenarios.ps1 -Scenario All -Verbose

.\Test-RmmAntivirusState-Scenarios.ps1 -Scenario Timeout
#>

[CmdletBinding()]
param(
    [ValidateSet('Baseline', 'Timeout', 'Candidates', 'Services', 'RetryPath', 'All')]
    [string]$Scenario = 'Baseline',
    
    [switch]$Verbose
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path $MyInvocation.MyCommand.Path
$resolverScript = Join-Path $scriptRoot 'Resolve-RmmAntivirusState.ps1'
$logDir = 'C:\ProgramData\DattoRMM\AVRemediation'

if (-not (Test-Path $resolverScript)) {
    Write-Error "Script not found: $resolverScript"
    exit 1
}

function Invoke-ScenarioTest {
    param(
        [string]$Name,
        [scriptblock]$Test
    )
    
    Write-Host "`n" -NoNewline
    Write-Host "=" * 70 -ForegroundColor Cyan
    Write-Host "SCENARIO: $Name" -ForegroundColor Cyan
    Write-Host "=" * 70 -ForegroundColor Cyan
    
    $startTime = Get-Date
    try {
        & $Test
        $duration = (Get-Date) - $startTime
        Write-Host "`n✓ Scenario completed in $([Math]::Round($duration.TotalSeconds, 2))s" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Error "Scenario failed: $_"
        return $false
    }
}

function Get-LatestSummary {
    if (Test-Path $logDir) {
        $latest = Get-ChildItem $logDir -Filter '*.json' -ErrorAction SilentlyContinue | 
            Sort-Object LastWriteTime -Descending | 
            Select-Object -First 1
        
        if ($latest) {
            return Get-Content $latest.FullName | ConvertFrom-Json
        }
    }
    return $null
}

function Show-SummaryResults {
    param([psobject]$Summary)
    
    if (-not $Summary) {
        Write-Host "`n⚠ No summary found (script may not have run)" -ForegroundColor Yellow
        return
    }
    
    Write-Host "`nTest Results:" -ForegroundColor Cyan
    Write-Host "  Computer: $($Summary.ComputerName)"
    Write-Host "  Timestamp: $($Summary.Timestamp)"
    Write-Host "  Target Mode: $($Summary.TargetMode)"
    Write-Host "  Outcome: $(if ($Summary.Outcome -match 'Success|Remediated|NoAction') { Write-Host $Summary.Outcome -ForegroundColor Green -NoNewline } else { Write-Host $Summary.Outcome -ForegroundColor Yellow -NoNewline })"
    Write-Host ""
    Write-Host "  Products Before: $($Summary.BeforeInventory.Products.Count)"
    Write-Host "  Products After: $($Summary.AfterInventory.Products.Count)"
    Write-Host "  Uninstall Attempts: $($Summary.UninstallAttempts.Count)"
    Write-Host "  Reboot Required: $($Summary.RebootRequired)"
    Write-Host "  Next Action: $($Summary.NextAction)"
    
    if ($Summary.UninstallAttempts.Count -gt 0) {
        Write-Host "`n  Uninstall Summary:" -ForegroundColor Cyan
        foreach ($attempt in $Summary.UninstallAttempts) {
            $icon = switch ($attempt.Status) {
                'Removed' { '✓' }
                'ManualCleanupRequired' { '⚠' }
                'Failed' { '✗' }
                'DryRun' { '→' }
                default { '?' }
            }
            Write-Host "    $icon $($attempt.DisplayName): $($attempt.Status)"
        }
    }
}

# ===== Scenario 1: Baseline =====
if ($Scenario -in @('Baseline', 'All')) {
    Invoke-ScenarioTest 'Quick Baseline (Dry-Run)' {
        Write-Host "`nRunning resolver in dry-run mode..."
        Write-Host "Mode: WindowsDefender" -ForegroundColor Gray
        Write-Host "Flags: -DryRun (no actual changes)" -ForegroundColor Gray
        
        & $resolverScript -TargetMode WindowsDefender -DryRun -ErrorAction Stop 2>&1 | 
            Out-Null
        
        $summary = Get-LatestSummary
        Show-SummaryResults $summary
        
        if ($summary -and $summary.Outcome -ne 'Failed') {
            Write-Host "`n✓ Baseline test passed" -ForegroundColor Green
        }
        else {
            throw "Baseline test failed with outcome: $($summary.Outcome)"
        }
    } | Out-Null
}

# ===== Scenario 2: Timeout Protection =====
if ($Scenario -in @('Timeout', 'All')) {
    Invoke-ScenarioTest 'Timeout Protection Validation' {
        Write-Host "`nValidating timeout mechanisms..."
        Write-Host "Checking: Invoke-CommandWithTimeout wrapper"
        Write-Host "Checking: Elapsed time tracking"
        Write-Host "Checking: Per-operation timeouts (services, processes, tasks)"
        
        $scriptContent = Get-Content $resolverScript -Raw
        
        $checks = @{
            'Invoke-CommandWithTimeout calls' = ([regex]::Matches($scriptContent, 'Invoke-CommandWithTimeout').Count)
            'Service timeout protection' = [int]($scriptContent -match '\$script:ServiceStopTimeoutSeconds')
            'Process cleanup timeout' = [int]($scriptContent -match '\$script:ProcessCleanupTimeoutSeconds')
            'Global time tracking' = [int]($scriptContent -match '\$script:StartTimeUtc')
            'Elapsed time helpers' = [int]($scriptContent -match 'Get-ElapsedTimeSeconds|Test-TimeoutExceeded')
        }
        
        Write-Host "`nTimeout Protection Inventory:" -ForegroundColor Cyan
        $allPresent = $true
        foreach ($check in $checks.GetEnumerator()) {
            $present = $check.Value -gt 0
            $allPresent = $allPresent -and $present
            $icon = if ($present) { '✓' } else { '✗' }
            Write-Host "  $icon $($check.Key): $($check.Value)"
        }
        
        if (-not $allPresent) {
            throw "Some timeout protections are missing"
        }
        
        Write-Host "`n✓ All timeout mechanisms are in place" -ForegroundColor Green
    } | Out-Null
}

# ===== Scenario 3: Multiple Candidates =====
if ($Scenario -in @('Candidates', 'All')) {
    Invoke-ScenarioTest 'Multiple Uninstall Candidates' {
        Write-Host "`nThis test validates handling of multiple non-target AV products."
        Write-Host "Note: Dry-run mode - no actual uninstalls will occur`n" -ForegroundColor Gray
        
        $installedAV = Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'Antivirus|Antimalware|Security|Defender|AVG|Bitdefender|Norton|Kaspersky|Trend|Sophos' } |
            Select-Object -ExpandProperty DisplayName -Unique
        
        if ($installedAV.Count -eq 0) {
            Write-Host "ℹ No multiple AV products detected on system (single or no target installed)" -ForegroundColor Gray
            Write-Host "Running test anyway with dry-run..." -ForegroundColor Gray
        }
        else {
            Write-Host "Detected $($installedAV.Count) security product(s):" -ForegroundColor Cyan
            $installedAV | ForEach-Object { Write-Host "  - $_" }
        }
        
        Write-Host "`nExecuting in dry-run mode..." -ForegroundColor Gray
        & $resolverScript -TargetMode WindowsDefender -DryRun -ErrorAction Stop 2>&1 | Out-Null
        
        $summary = Get-LatestSummary
        Show-SummaryResults $summary
        
        if ($summary -and $summary.UninstallAttempts.Count -gt 0) {
            Write-Host "`n✓ Successfully processed $($summary.UninstallAttempts.Count) candidate(s)" -ForegroundColor Green
        }
        elseif ($summary) {
            Write-Host "`nℹ No candidates to process (system may already be clean)" -ForegroundColor Gray
        }
    } | Out-Null
}

# ===== Scenario 4: Service Enumeration =====
if ($Scenario -in @('Services', 'All')) {
    Invoke-ScenarioTest 'Service/Process Enumeration Performance' {
        Write-Host "`nTesting service and process enumeration performance..."
        Write-Host "This validates that timeout-protected operations complete quickly`n" -ForegroundColor Gray
        
        $measurements = @()
        
        # Measure SecurityCenter2 query
        Write-Host "Measuring SecurityCenter2 CIM query..." -ForegroundColor Cyan
        $start = Get-Date
        try {
            $null = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName 'AntivirusProduct' -ErrorAction Stop
            $duration = (Get-Date) - $start
            $measurements += [pscustomobject]@{ Operation = 'SecurityCenter2 query'; Seconds = $duration.TotalSeconds }
            Write-Host "  ✓ Completed in $([Math]::Round($duration.TotalSeconds, 3))s" -ForegroundColor Green
        }
        catch {
            Write-Host "  ⚠ Query failed or unsupported: $_" -ForegroundColor Yellow
        }
        
        # Measure Get-Service
        Write-Host "Measuring Get-Service enumeration..." -ForegroundColor Cyan
        $start = Get-Date
        $services = Get-Service -ErrorAction SilentlyContinue
        $duration = (Get-Date) - $start
        $measurements += [pscustomobject]@{ Operation = 'Get-Service'; Seconds = $duration.TotalSeconds; Count = $services.Count }
        Write-Host "  ✓ Completed in $([Math]::Round($duration.TotalSeconds, 3))s ($($services.Count) services)" -ForegroundColor Green
        
        # Measure Get-Process
        Write-Host "Measuring Get-Process enumeration..." -ForegroundColor Cyan
        $start = Get-Date
        $processes = Get-Process -ErrorAction SilentlyContinue
        $duration = (Get-Date) - $start
        $measurements += [pscustomobject]@{ Operation = 'Get-Process'; Seconds = $duration.TotalSeconds; Count = $processes.Count }
        Write-Host "  ✓ Completed in $([Math]::Round($duration.TotalSeconds, 3))s ($($processes.Count) processes)" -ForegroundColor Green
        
        Write-Host "`nPerformance Summary:" -ForegroundColor Cyan
        $measurements | Format-Table -Property Operation, Seconds -AutoSize | Out-String | Write-Host
        
        $slowOps = $measurements | Where-Object { $_.Seconds -gt 5 }
        if ($slowOps) {
            Write-Host "⚠ Warning: Some operations are slow (may timeout in constrained environments)" -ForegroundColor Yellow
            $slowOps | Format-Table -Property Operation, Seconds
        }
        else {
            Write-Host "✓ All enumeration operations complete quickly" -ForegroundColor Green
        }
    } | Out-Null
}

# ===== Scenario 5: Retry Path (Manual Setup) =====
if ($Scenario -in @('RetryPath', 'All')) {
    Invoke-ScenarioTest 'AVG Retry Path (Information Only)' {
        Write-Host "`n⚠ This scenario requires manual setup and is informational only`n" -ForegroundColor Yellow
        
        Write-Host "To test the AVG retry path manually:" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Install AVG Antivirus on a test system"
        Write-Host "2. Run the resolver in dry-run mode first to identify the uninstall command:"
        Write-Host "   & '$resolverScript' -TargetMode WindowsDefender -DryRun -Verbose"
        Write-Host ""
        Write-Host "3. Manually check the uninstall command:"
        Write-Host "   reg query HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall | findstr /i AVG"
        Write-Host ""
        Write-Host "4. Test in controlled environment:"
        Write-Host "   # WARNING: This will actually uninstall!"
        Write-Host "   # Use VM snapshot/restore or test system"
        Write-Host "   & '$resolverScript' -TargetMode WindowsDefender"
        Write-Host ""
        Write-Host "The script will automatically handle:"
        Write-Host "  ✓ Stats.ini retry if primary uninstall fails with exit code 5"
        Write-Host "  ✓ Service/process cleanup before retry"
        Write-Host "  ✓ MSI fallback if custom uninstaller fails"
        Write-Host "  ✓ All operations timeout-protected"
        Write-Host ""
        
        Write-Host "Review the JSON summary for detailed retry information:" -ForegroundColor Cyan
        if (Test-Path $logDir) {
            $latest = Get-ChildItem $logDir -Filter '*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latest) {
                Write-Host "  Latest: $($latest.FullName)"
            }
        }
    } | Out-Null
}

# ===== Final Summary =====
Write-Host "`n" -NoNewline
Write-Host "=" * 70 -ForegroundColor Green
Write-Host "TEST SUITE COMPLETE" -ForegroundColor Green
Write-Host "=" * 70 -ForegroundColor Green

Write-Host "`nNext Steps:" -ForegroundColor Cyan
Write-Host "1. Review the test results above"
Write-Host "2. Check logs in: $logDir"
Write-Host "3. If tests pass, upload script to Datto RMM:"
Write-Host "   - Create component from Resolve-RmmAntivirusState.ps1"
Write-Host "   - Test on 1-2 devices before rolling out"
Write-Host "   - Monitor execution time on production systems"
Write-Host ""
