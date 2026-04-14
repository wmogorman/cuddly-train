<#
.SYNOPSIS
  Audits screenshot verification status for all agents across all Datto BCDR devices.

.DESCRIPTION
  Uses the Datto Partner Portal REST API (api.datto.com/v1) to enumerate all BCDR
  devices and their agents, then reports screenshot verification status for each.

  NOTE: The Partner Portal API exposes only STATUS data (last attempt timestamp,
  pass/fail). The screenshot verification wait-time CONFIGURATION setting is stored
  on each physical device and is not accessible via this API. Use -OutputCsvPath to
  export a report with portal links for manual remediation of wait-time settings.

  Agents are flagged as needing attention if:
    - Screenshot verification has never run  (lastScreenshotAttempt = 0)
    - The last screenshot verification failed (lastScreenshotAttemptStatus = false)
    - The agent is active (not paused and not archived)

.PARAMETER PublicKey
  Datto API public key. Can also be set via DATTO_PUBLIC_KEY env var or -EnvFile.

.PARAMETER SecretKey
  Datto API secret key. Can also be set via DATTO_SECRET_KEY env var or -EnvFile.

.PARAMETER EnvFile
  Path to a .env file containing DATTO_PUBLIC_KEY and DATTO_SECRET_KEY.

.PARAMETER OutputCsvPath
  Optional path to write full results as CSV.

.PARAMETER IncludeArchived
  Include archived agents in the report (excluded by default).

.PARAMETER IncludePaused
  Include paused agents in the report (excluded by default).

.EXAMPLE
  .\datto-bcdr-screenshot-audit.ps1 -EnvFile .\datto-bcdr.env
  .\datto-bcdr-screenshot-audit.ps1 -EnvFile .\datto-bcdr.env -OutputCsvPath .\screenshot-audit.csv
  .\datto-bcdr-screenshot-audit.ps1 -EnvFile .\datto-bcdr.env -IncludeArchived -IncludePaused
#>

[CmdletBinding()]
param(
  [string] $PublicKey,
  [string] $SecretKey,
  [string] $EnvFile,
  [string] $OutputCsvPath,
  [switch] $IncludeArchived,
  [switch] $IncludePaused
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ApiBase = "https://api.datto.com/v1"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
  param([string] $Message)
  Write-Host "[datto-bcdr-screenshot-audit] $Message"
}

function Read-EnvFile {
  param([string] $Path)
  if (-not (Test-Path $Path)) { throw "Env file not found: $Path" }
  $vars = @{}
  foreach ($line in (Get-Content $Path)) {
    $line = $line.Trim()
    if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -match '^([^=]+)=(.*)$') { $vars[$Matches[1].Trim()] = $Matches[2].Trim() }
  }
  return $vars
}

function Get-AuthHeader {
  param([string] $Pub, [string] $Sec)
  $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${Pub}:${Sec}"))
  return @{ Authorization = "Basic $b64" }
}

function Invoke-DattoApi {
  param([string] $Path, [hashtable] $Headers)
  try {
    return Invoke-RestMethod -Uri "$script:ApiBase$Path" -Method GET -Headers $Headers -ContentType "application/json"
  }
  catch {
    $status = $_.Exception.Response.StatusCode.value__
    throw "API error [$Path] HTTP $status : $($_.Exception.Message)"
  }
}

function Get-AllPages {
  param([string] $Path, [hashtable] $Headers)
  $allItems = [System.Collections.Generic.List[object]]::new()
  $page = 1
  $pageSize = 100
  do {
    $sep   = if ($Path.Contains("?")) { "&" } else { "?" }
    $paged = Invoke-DattoApi -Path "${Path}${sep}page=${page}&perPage=${pageSize}" -Headers $Headers

    $batch = if ($paged -is [array]) { $paged }
             elseif ($null -ne $paged.PSObject.Properties["items"]) { $paged.items }
             else { $null }

    if ($null -eq $batch -or @($batch).Count -eq 0) { break }
    foreach ($item in $batch) { $allItems.Add($item) }

    $total = $null
    if ($null -ne $paged -and $paged -isnot [array]) {
      foreach ($candidate in @("pagination.totalCount","totalCount","count","total")) {
        $val = $paged
        foreach ($p in $candidate.Split(".")) {
          if ($null -eq $val) { $val = $null; break }
          try { $val = $val.$p } catch { $val = $null; break }
        }
        if ($null -ne $val) { $total = [int]$val; break }
      }
    }
    if ($null -ne $total -and $allItems.Count -ge $total) { break }
    if (@($batch).Count -lt $pageSize) { break }
    $page++
  } while ($true)
  return $allItems
}

function Resolve-Field {
  param($Obj, [string[]] $Candidates)
  foreach ($name in $Candidates) {
    try { $val = $Obj.$name; if ($null -ne $val) { return $val } } catch { }
  }
  return $null
}

function Format-UnixTime {
  param([long] $Ts)
  if ($Ts -eq 0 -or $null -eq $Ts) { return "never" }
  return ([DateTimeOffset]::FromUnixTimeSeconds($Ts)).LocalDateTime.ToString("yyyy-MM-dd HH:mm")
}

# ---------------------------------------------------------------------------
# Credential resolution
# ---------------------------------------------------------------------------

if ($EnvFile) {
  Write-Step "Loading credentials from: $EnvFile"
  $envVars = Read-EnvFile -Path $EnvFile
  if (-not $PublicKey -and $envVars.ContainsKey("DATTO_PUBLIC_KEY")) { $PublicKey = $envVars["DATTO_PUBLIC_KEY"] }
  if (-not $SecretKey -and $envVars.ContainsKey("DATTO_SECRET_KEY")) { $SecretKey = $envVars["DATTO_SECRET_KEY"] }
}
if (-not $PublicKey) { $PublicKey = $env:DATTO_PUBLIC_KEY }
if (-not $SecretKey) { $SecretKey = $env:DATTO_SECRET_KEY }
if (-not $PublicKey -or -not $SecretKey) {
  throw "API credentials required. Use -PublicKey/-SecretKey, -EnvFile, or DATTO_PUBLIC_KEY/DATTO_SECRET_KEY env vars."
}

$headers = Get-AuthHeader -Pub $PublicKey -Sec $SecretKey

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Step "Fetching device list ..."
$devices = Get-AllPages -Path "/bcdr/device" -Headers $headers
Write-Step "Found $($devices.Count) device(s)."

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($device in $devices) {
  $serial = $device.serialNumber
  $dname  = $device.name
  Write-Step "  $dname ($serial)"

  try {
    $assets = @(Get-AllPages -Path "/bcdr/device/$serial/asset" -Headers $headers)
  }
  catch {
    Write-Warning "    Could not list assets: $_"
    continue
  }

  foreach ($asset in $assets) {
    $assetType = Resolve-Field -Obj $asset -Candidates @("type","assetType","kind")
    if ($assetType -eq "share" -or $assetType -eq "nas" -or $assetType -eq "nasShare") { continue }

    $agentKey  = Resolve-Field -Obj $asset -Candidates @("volume","agentKey","keyName","key","assetId","id","name")
    $agentName = Resolve-Field -Obj $asset -Candidates @("name","hostname","displayName","agentName")
    $isPaused  = [bool]($asset.isPaused)
    $isArchived = [bool]($asset.isArchived)

    if (-not $IncludeArchived -and $isArchived) { continue }
    if (-not $IncludePaused  -and $isPaused)    { continue }

    $lastAttemptTs = [long]($asset.lastScreenshotAttempt)
    $lastAttemptOk = [bool]($asset.lastScreenshotAttemptStatus)

    # An agent needs attention if screenshot verification has never run or last run failed.
    $neverRan  = ($lastAttemptTs -eq 0)
    $lastFailed = (-not $neverRan -and -not $lastAttemptOk)
    $needsAttention = $neverRan -or $lastFailed

    # Best-effort portal URL for the agent settings page.
    $portalUrl = "https://portal.dattobackup.com/continuity/devices/$serial/agents/$agentKey/settings"

    $results.Add([PSCustomObject]@{
      DeviceName        = $dname
      DeviceSerial      = $serial
      AgentName         = $agentName
      AgentKey          = $agentKey
      IsPaused          = $isPaused
      IsArchived        = $isArchived
      LastAttempt       = Format-UnixTime -Ts $lastAttemptTs
      LastAttemptPassed = if ($neverRan) { "n/a" } else { $lastAttemptOk.ToString() }
      NeedsAttention    = $needsAttention
      Reason            = if ($neverRan) { "never-ran" } elseif ($lastFailed) { "last-failed" } else { "ok" }
      PortalUrl         = $portalUrl
    })
  }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$ok         = @($results | Where-Object { -not $_.NeedsAttention })
$attention  = @($results | Where-Object { $_.NeedsAttention })
$neverRan   = @($results | Where-Object { $_.Reason -eq "never-ran" })
$lastFailed = @($results | Where-Object { $_.Reason -eq "last-failed" })

Write-Host ""
Write-Host "=== Screenshot Verification Audit ===" -ForegroundColor White
Write-Host "  Total active agents    : $($results.Count)"
Write-Host "  Passing                : $($ok.Count)"         -ForegroundColor Green
Write-Host "  Needs attention        : $($attention.Count)"  -ForegroundColor $(if ($attention.Count) { "Red" } else { "Green" })
Write-Host "    Never ran            : $($neverRan.Count)"   -ForegroundColor $(if ($neverRan.Count)   { "Yellow" } else { "Green" })
Write-Host "    Last attempt failed  : $($lastFailed.Count)" -ForegroundColor $(if ($lastFailed.Count) { "Red" }    else { "Green" })

if ($attention.Count -gt 0) {
  Write-Host ""
  Write-Host "--- Agents needing attention ---" -ForegroundColor Yellow
  $attention | ForEach-Object {
    $flag = if ($_.Reason -eq "never-ran") { "[NEVER RAN]" } else { "[FAILED]   " }
    Write-Host "  $flag  $($_.DeviceName) / $($_.AgentName)" -ForegroundColor $(if ($_.Reason -eq "last-failed") { "Red" } else { "Yellow" })
  }
}

Write-Host ""
Write-Host "NOTE: The Partner Portal API does not expose the screenshot verification" -ForegroundColor Cyan
Write-Host "wait-time configuration. To set wait time >= 5 minutes for each agent:" -ForegroundColor Cyan
Write-Host "  1. Run this script with -OutputCsvPath to get a list with portal links" -ForegroundColor Cyan
Write-Host "  2. Use datto-bcdr-screenshot-enforce.ps1 to open/report portal URLs"   -ForegroundColor Cyan
Write-Host "  3. On each device: Protect tab > Configure Agent > Screenshot Verification > Additional wait time" -ForegroundColor Cyan

if ($OutputCsvPath) {
  $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8
  Write-Step "Results written to: $OutputCsvPath"
}

return $results
