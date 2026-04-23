[CmdletBinding()]
param(
    [string]   $ArtifactsRoot    = (Join-Path $PSScriptRoot ".." "artifacts"),
    [string]   $DattoRmmEnvFile  = (Join-Path $PSScriptRoot "datto-rmm.env"),
    [string]   $DattoBcdrEnvFile = (Join-Path $PSScriptRoot "datto-bcdr.env"),
    [string]   $DattoEdrEnvFile  = (Join-Path $PSScriptRoot "datto-edr.env"),
    [string]   $DuoEnvFile       = (Join-Path $PSScriptRoot "duo-accounts-api.env"),
    [string[]] $Skip             = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-EnvFile {
    param([string] $Path)
    $vars = @{}
    if (-not (Test-Path $Path)) { return $vars }
    foreach ($line in Get-Content $Path) {
        $line = $line.Trim()
        if ($line -match '^#' -or $line -eq '') { continue }
        $line = $line -replace '^export\s+', ''
        if ($line -match '^([^=]+)=(.*)$') {
            $key   = $Matches[1].Trim()
            $value = $Matches[2].Trim().Trim("'").Trim('"')
            $vars[$key] = $value
        }
    }
    return $vars
}

function Invoke-Report {
    param(
        [string]         $Name,
        [string]         $Suite,
        [scriptblock]    $Action,
        [pscustomobject] $DependsOn = $null
    )

    $r = [pscustomobject]@{
        Name    = $Name
        Suite   = $Suite
        Status  = 'Skipped'
        Elapsed = $null
        Error   = $null
    }

    if ($Skip -icontains $Suite) { return $r }

    if ($DependsOn -and $DependsOn.Status -ne 'OK') {
        $r.Error = "prerequisite '$($DependsOn.Name)' did not succeed"
        return $r
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action | Out-Null
        $r.Status  = 'OK'
    } catch {
        $r.Status = 'FAIL'
        $r.Error  = $_.Exception.Message
    } finally {
        $sw.Stop()
        $r.Elapsed = $sw.Elapsed
    }
    return $r
}

# Ensure artifact subdirectories exist
$rmmDir  = Join-Path $ArtifactsRoot "datto-rmm"
$bcdrDir = Join-Path $ArtifactsRoot "datto-bcdr"
$edrDir  = Join-Path $ArtifactsRoot "datto-edr"
$duoDir  = Join-Path $ArtifactsRoot "duo"

foreach ($d in @($rmmDir, $bcdrDir, $edrDir, $duoDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# Load Duo credentials now — duo-audit-entra-sync-groups requires explicit params, no -EnvFilePath
$duoCreds = Read-EnvFile -Path $DuoEnvFile

$results = [System.Collections.Generic.List[pscustomobject]]::new()

# 1. Datto RMM
$results.Add((Invoke-Report -Name "datto-rmm-filter-report" -Suite "RMM" -Action {
    & "$PSScriptRoot\datto-rmm-filter-report.ps1" `
        -EnvFile       $DattoRmmEnvFile `
        -OutputCsvPath (Join-Path $rmmDir "datto-rmm-filters.csv")
}))

# 2. Datto BCDR
$results.Add((Invoke-Report -Name "datto-bcdr-health-audit" -Suite "BCDR" -Action {
    & "$PSScriptRoot\datto-bcdr-health-audit.ps1" `
        -EnvFile       $DattoBcdrEnvFile `
        -OutputCsvPath (Join-Path $bcdrDir "datto-bcdr-health-audit.csv")
}))

# 3. Datto EDR TA Report — must succeed before analyze can run
$edrPolicyAssignmentsPath = Join-Path $edrDir "ta-report-policy-assignments.csv"
$edrReportResult = Invoke-Report -Name "datto-edr-ta-report" -Suite "EDR" -Action {
    & "$PSScriptRoot\datto-edr-ta-report.ps1" `
        -EnvFile                        $DattoEdrEnvFile `
        -OutputCsvPath                  (Join-Path $edrDir "ta-report-enrollment.csv") `
        -OutputPoliciesCsvPath          (Join-Path $edrDir "ta-report-policies.csv") `
        -OutputPolicyAssignmentsCsvPath $edrPolicyAssignmentsPath
}
$results.Add($edrReportResult)

# 4. Datto EDR TA Analyze (depends on #3)
$results.Add((Invoke-Report -Name "datto-edr-ta-analyze" -Suite "EDR" -DependsOn $edrReportResult -Action {
    & "$PSScriptRoot\datto-edr-ta-analyze.ps1" `
        -PolicyAssignmentsCsvPath $edrPolicyAssignmentsPath `
        -OutputCsvPath            (Join-Path $edrDir "ta-report-gaps.csv")
}))

# 5. Duo Entra sync groups
$results.Add((Invoke-Report -Name "duo-audit-entra-sync-groups" -Suite "Duo" -Action {
    & "$PSScriptRoot\duo-audit-entra-sync-groups.ps1" `
        -ParentApiHost $duoCreds['DUO_PARENT_API_HOST'] `
        -IKey          $duoCreds['DUO_IKEY'] `
        -SKey          $duoCreds['DUO_SKEY'] `
        -OutputCsvPath (Join-Path $duoDir "duo-entra-sync-group-audit.csv")
}))

# 6. Duo External MFA apps
$results.Add((Invoke-Report -Name "duo-audit-external-mfa-apps" -Suite "Duo" -Action {
    & "$PSScriptRoot\duo-audit-external-mfa-apps.ps1" `
        -EnvFilePath    $DuoEnvFile `
        -MatchesCsvPath (Join-Path $duoDir "duo-external-mfa-applications.csv")
}))

# 7. Duo Security access
$results.Add((Invoke-Report -Name "duo-audit-security-access" -Suite "Duo" -Action {
    & "$PSScriptRoot\duo-audit-security-access.ps1" `
        -EnvFilePath   $DuoEnvFile `
        -AdminCsvPath  (Join-Path $duoDir "duo-admin-access-audit.csv") `
        -BypassCsvPath (Join-Path $duoDir "duo-bypass-codes-audit.csv")
}))

# Summary
$succeeded = 0; $failed = 0; $skipped = 0
$totalElapsed = [timespan]::Zero

Write-Host ""
Write-Host "=== Morning Report Summary ===" -ForegroundColor Cyan

foreach ($r in $results) {
    switch ($r.Status) {
        'OK' {
            $succeeded++
            $totalElapsed = $totalElapsed.Add($r.Elapsed)
            $label = "[OK]  "; $color = 'Green'
            $time = "{0,5}s" -f [int]$r.Elapsed.TotalSeconds
        }
        'FAIL' {
            $failed++
            $totalElapsed = $totalElapsed.Add($r.Elapsed)
            $label = "[FAIL]"; $color = 'Red'
            $time = "{0,5}s" -f [int]$r.Elapsed.TotalSeconds
        }
        default {
            $skipped++
            $label = "[SKIP]"; $color = 'DarkGray'
            $time = "     -"
        }
    }
    $line = "{0}  {1,-42} {2}" -f $label, $r.Name, $time
    if ($r.Error) { $line += "  [$($r.Error)]" }
    Write-Host $line -ForegroundColor $color
}

$min = [int]$totalElapsed.TotalMinutes
$sec = $totalElapsed.Seconds
Write-Host ("=" * 56) -ForegroundColor Cyan
Write-Host ("Completed in {0}m {1}s  |  {2} OK, {3} failed, {4} skipped" -f $min, $sec, $succeeded, $failed, $skipped)
Write-Host ""

exit ($failed -gt 0 ? 1 : 0)
