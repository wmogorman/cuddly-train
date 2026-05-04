[CmdletBinding()]
param(
  [string] $PolicyAssignmentsCsvPath,
  [string] $OutputCsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
  param([string] $Message)
  Write-Host "[datto-edr-ta-analyze] $Message"
}

# ---------------------------------------------------------------------------
# Resolve input/output paths
# ---------------------------------------------------------------------------

$artifactsDir = Join-Path (Split-Path $PSCommandPath -Parent) "artifacts/datto-edr"

if ([string]::IsNullOrWhiteSpace($PolicyAssignmentsCsvPath)) {
  $latest = Get-ChildItem -Path $artifactsDir -Filter "ta-report-policy-assignments-*.csv" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $latest) {
    throw "No policy assignments CSV found in $artifactsDir. Run datto-edr-ta-report.ps1 first, or pass -PolicyAssignmentsCsvPath."
  }
  $PolicyAssignmentsCsvPath = $latest.FullName
}

if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
  $OutputCsvPath = Join-Path $artifactsDir "ta-report-gaps.csv"
}

Write-Step "Reading: $PolicyAssignmentsCsvPath"
$allRows = @(Import-Csv -Path $PolicyAssignmentsCsvPath)
Write-Step "  $($allRows.Count) assignment rows loaded."

# ---------------------------------------------------------------------------
# Helper: is an assignment row active (resolved and not explicitly disabled)?
# PolicyEnabled="" means unknown — treat as active to avoid false positives.
# ---------------------------------------------------------------------------

function Test-Active {
  param($Row)
  if ($Row.ResolutionStatus -ne "Resolved") { return $false }
  if ($Row.PolicyEnabled -eq "False") { return $false }
  return $true
}

# ---------------------------------------------------------------------------
# Analyze per scope (Organization + Location)
# ---------------------------------------------------------------------------

Write-Step "Analyzing gaps..."

$findings = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Finding {
  param(
    [string] $Organization,
    [string] $Location,
    [string] $FindingType,
    [ValidateSet("Critical", "Warning")] [string] $Severity,
    [string] $Detail
  )
  $findings.Add([pscustomobject][ordered]@{
    Organization = $Organization
    Location     = $Location
    Severity     = $Severity
    FindingType  = $FindingType
    Detail       = $Detail
  }) | Out-Null
}

$scopeGroups = @($allRows | Group-Object { "$($_.Organization)|$($_.Location)" })

foreach ($group in $scopeGroups) {
  $rows    = @($group.Group)
  $orgName = $rows[0].Organization
  $locName = $rows[0].Location

  # -------------------------------------------------------------------------
  # AV analysis
  # -------------------------------------------------------------------------

  $davRows = @($rows | Where-Object { $_.PolicyType -eq "Datto AV" })
  $wdRows  = @($rows | Where-Object { $_.PolicyType -eq "Windows Defender" })

  $davActive = @($davRows | Where-Object { Test-Active $_ }).Count -gt 0
  $wdActive  = @($wdRows  | Where-Object { Test-Active $_ }).Count -gt 0

  if (-not $davActive -and -not $wdActive) {
    $davStatus = if (@($davRows | Where-Object { $_.ResolutionStatus -eq "Resolved" }).Count -gt 0) { "disabled" } else { "unassigned" }
    $wdStatus  = if (@($wdRows  | Where-Object { $_.ResolutionStatus -eq "Resolved" }).Count -gt 0) { "disabled" } else { "unassigned" }
    Add-Finding -Organization $orgName -Location $locName `
      -FindingType "No AV Protection" `
      -Severity "Critical" `
      -Detail "Datto AV is $davStatus and Windows Defender is $wdStatus — no antivirus active."
  } elseif ($davActive -and -not $wdActive) {
    # Windows Defender disabled — check if active Datto AV policy is the no-real-time variant
    $noRtActive = @($davRows | Where-Object { (Test-Active $_) -and $_.EffectivePolicyName -imatch 'no.?real.?time' })
    if ($noRtActive.Count -gt 0) {
      $names = ($noRtActive | ForEach-Object { $_.EffectivePolicyName } | Select-Object -Unique) -join "; "
      Add-Finding -Organization $orgName -Location $locName `
        -FindingType "No Real-Time AV" `
        -Severity "Critical" `
        -Detail "Windows Defender is inactive and Datto AV is running without real-time protection ($names)."
    }
  }

  # -------------------------------------------------------------------------
  # Ransomware analysis
  # -------------------------------------------------------------------------

  $rwRows   = @($rows | Where-Object { $_.PolicyType -eq "Ransomware" })
  $rwActive = @($rwRows | Where-Object { Test-Active $_ }).Count -gt 0

  if (-not $rwActive) {
    $rwStatus = if (@($rwRows | Where-Object { $_.ResolutionStatus -eq "Resolved" }).Count -gt 0) { "disabled" } else { "unassigned" }
    Add-Finding -Organization $orgName -Location $locName `
      -FindingType "Ransomware Detection Disabled" `
      -Severity "Critical" `
      -Detail "No active ransomware detection policy ($rwStatus)."
  } else {
    # Ransomware is on — check that a device group has a rollback policy
    $rollbackRows = @($rwRows | Where-Object {
      (Test-Active $_) -and
      -not [string]::IsNullOrWhiteSpace($_.DeviceGroupName) -and
      $_.EffectivePolicyName -imatch 'rollback'
    })
    if ($rollbackRows.Count -eq 0) {
      Add-Finding -Organization $orgName -Location $locName `
        -FindingType "No Rollback Group" `
        -Severity "Warning" `
        -Detail "Ransomware detection is active but no device group has a rollback policy assigned."
    }
  }
}

# ---------------------------------------------------------------------------
# Sort: Critical before Warning, then alpha by org/location
# ---------------------------------------------------------------------------

$severityOrder = @{ Critical = 0; Warning = 1 }
$sorted = @(
  $findings | Sort-Object `
    @{ Expression = { $severityOrder[$_.Severity] } },
    { $_.Organization },
    { $_.Location },
    { $_.FindingType }
)

$sorted | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$critical = @($sorted | Where-Object { $_.Severity -eq "Critical" }).Count
$warning  = @($sorted | Where-Object { $_.Severity -eq "Warning" }).Count

Write-Step ""
Write-Step "=== Gap Analysis Summary ==="
Write-Step "  Total scopes analyzed: $($scopeGroups.Count)"
Write-Step "  Critical findings:     $critical"
Write-Step "  Warning findings:      $warning"
Write-Step ""
Write-Step "Gaps report: $OutputCsvPath"

if ($critical -gt 0) {
  Write-Step ""
  Write-Step "--- Critical ---"
  foreach ($f in @($sorted | Where-Object { $_.Severity -eq "Critical" })) {
    Write-Step "  [$($f.FindingType)] $($f.Organization) / $($f.Location)"
    Write-Step "    $($f.Detail)"
  }
}

if ($warning -gt 0) {
  Write-Step ""
  Write-Step "--- Warnings ---"
  foreach ($f in @($sorted | Where-Object { $_.Severity -eq "Warning" })) {
    Write-Step "  [$($f.FindingType)] $($f.Organization) / $($f.Location)"
    Write-Step "    $($f.Detail)"
  }
}
