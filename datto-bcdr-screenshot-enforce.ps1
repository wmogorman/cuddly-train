<#
.SYNOPSIS
  Reports all active Datto BCDR agents with direct portal links for setting
  screenshot verification wait time to at least 5 minutes.

.DESCRIPTION
  The Datto Partner Portal REST API (api.datto.com/v1) exposes only STATUS data
  for BCDR agents — it does not expose or allow setting the screenshot verification
  wait-time configuration. That setting is stored on each physical device.

  This script:
    1. Enumerates all active agents across all BCDR devices via the API
    2. Reports each agent's current screenshot verification status
    3. Outputs a CSV and/or opens portal URLs so you can set wait time >= 5 min
       on each agent: Protect > Configure Agent > Screenshot Verification >
       "Additional wait time for the protected machine"

  Agents are prioritised in the output: never-ran first, then failed, then passing.

.PARAMETER PublicKey
  Datto API public key. Can also be set via DATTO_PUBLIC_KEY env var or -EnvFile.

.PARAMETER SecretKey
  Datto API secret key. Can also be set via DATTO_SECRET_KEY env var or -EnvFile.

.PARAMETER EnvFile
  Path to a .env file containing DATTO_PUBLIC_KEY and DATTO_SECRET_KEY.

.PARAMETER OutputCsvPath
  Path to write the remediation report as CSV. Defaults to .\screenshot-remediation.csv.

.PARAMETER OnlyNeedsAttention
  Only include agents where screenshot verification never ran or last failed.

.PARAMETER OpenPortalLinks
  Open each agent's portal settings page in the default browser.
  WARNING: This will open one browser tab per agent. Use with -OnlyNeedsAttention.

.EXAMPLE
  # Generate full report
  .\datto-bcdr-screenshot-enforce.ps1 -EnvFile .\datto-bcdr.env -OutputCsvPath .\remediation.csv

  # Report only agents that need fixing
  .\datto-bcdr-screenshot-enforce.ps1 -EnvFile .\datto-bcdr.env -OnlyNeedsAttention

  # Open portal pages for agents that need fixing (one tab per agent)
  .\datto-bcdr-screenshot-enforce.ps1 -EnvFile .\datto-bcdr.env -OnlyNeedsAttention -OpenPortalLinks
#>

[CmdletBinding()]
param(
  [string] $PublicKey,
  [string] $SecretKey,
  [string] $EnvFile,
  [string] $OutputCsvPath = ".\screenshot-remediation.csv",
  [switch] $OnlyNeedsAttention,
  [switch] $OpenPortalLinks,
  [switch] $IncludeCancelled,
  [switch] $ShowDeviceFields
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ApiBase = "https://api.datto.com/v1"

# ---------------------------------------------------------------------------
# Helpers (duplicated from audit script for standalone use)
# ---------------------------------------------------------------------------

function Write-Step {
  param([string] $Message)
  Write-Host "[datto-bcdr-screenshot-enforce] $Message"
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
  $page = 1; $pageSize = 100
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
# Enumerate
# ---------------------------------------------------------------------------

$script:CancelledStatuses = @('cancelled','canceled','inactive','expired','terminated','suspended','decommissioned')

function Test-DeviceCancelled {
  param($Device)

  $statusVal = Resolve-Field -Obj $Device -Candidates @(
    'status','subscriptionStatus','deviceStatus','state',
    'registrationStatus','contractStatus','serviceStatus'
  )
  if ($null -ne $statusVal -and $script:CancelledStatuses -contains $statusVal.ToString().ToLower()) {
    return $true
  }

  $sp = Resolve-Field -Obj $Device -Candidates @('servicePeriod','serviceExpiry','contractEnd','expiryDate')
  if ($null -ne $sp -and -not [string]::IsNullOrWhiteSpace($sp.ToString())) {
    try {
      $spDate = [datetime]::Parse($sp.ToString())
      if ($spDate -lt (Get-Date)) { return $true }
    }
    catch { }
  }

  return $false
}

Write-Step "Fetching device list ..."
$devices = Get-AllPages -Path "/bcdr/device" -Headers $headers
Write-Step "Found $($devices.Count) device(s). Enumerating agents ..."

if ($ShowDeviceFields -and $devices.Count -gt 0) {
  Write-Host "[RAW DEVICE FIELDS - first device]:" -ForegroundColor Magenta
  $devices[0].PSObject.Properties | ForEach-Object {
    Write-Host "  $($_.Name) = $($_.Value)" -ForegroundColor DarkMagenta
  }
}

$report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($device in $devices) {
  $serial = $device.serialNumber
  $dname  = $device.name

  if ((Resolve-Field -Obj $device -Candidates @('hidden')) -eq $true)      { continue }
  if (-not $IncludeCancelled -and (Test-DeviceCancelled -Device $device)) { continue }

  try {
    $assets = @(Get-AllPages -Path "/bcdr/device/$serial/asset" -Headers $headers)
  }
  catch {
    Write-Warning "Could not list assets for $dname ($serial): $_"
    continue
  }

  foreach ($asset in $assets) {
    $assetType = Resolve-Field -Obj $asset -Candidates @("type","assetType","kind")
    if ($assetType -eq "share" -or $assetType -eq "nas" -or $assetType -eq "nasShare") { continue }
    if ((Resolve-Field -Obj $asset -Candidates @('hidden')) -eq $true) { continue }

    # Skip archived and paused — they are not actively being backed up.
    if ([bool]($asset.isArchived)) { continue }
    if ([bool]($asset.isPaused))   { continue }

    $agentKey  = Resolve-Field -Obj $asset -Candidates @("volume","agentKey","keyName","key","assetId","id","name")
    $agentName = Resolve-Field -Obj $asset -Candidates @("name","hostname","displayName","agentName")

    $lastAttemptTs = [long]($asset.lastScreenshotAttempt)
    $lastAttemptOk = [bool]($asset.lastScreenshotAttemptStatus)
    $neverRan      = ($lastAttemptTs -eq 0)
    $lastFailed    = (-not $neverRan -and -not $lastAttemptOk)
    $needsAttention = $neverRan -or $lastFailed

    $priority = if ($neverRan) { 1 } elseif ($lastFailed) { 2 } else { 3 }
    $reason   = if ($neverRan) { "never-ran" } elseif ($lastFailed) { "last-failed" } else { "ok" }

    # Portal URL for this agent's screenshot verification settings.
    # Navigate to: Protect tab > agent row > Configure > Screenshot Verification
    # Set "Additional wait time for the protected machine" to >= 5 minutes.
    $portalUrl = "https://portal.dattobackup.com/continuity/devices/$serial/agents/$agentKey/settings"

    $report.Add([PSCustomObject]@{
      Priority          = $priority
      DeviceName        = $dname
      DeviceSerial      = $serial
      AgentName         = $agentName
      AgentKey          = $agentKey
      OS                = $asset.os
      LastAttempt       = Format-UnixTime -Ts $lastAttemptTs
      LastAttemptPassed = if ($neverRan) { "n/a" } else { $lastAttemptOk.ToString() }
      NeedsAttention    = $needsAttention
      Reason            = $reason
      # Direct setting to change: Protect > Configure Agent > Screenshot Verification >
      # "Additional wait time for the protected machine" = 5 (minutes)
      SettingToChange   = "Additional wait time >= 5 min"
      PortalUrl         = $portalUrl
    })
  }
}

# Sort: never-ran first, then failed, then passing. Within each group, by device then agent name.
$report = $report | Sort-Object Priority, DeviceName, AgentName

if ($OnlyNeedsAttention) {
  $report = @($report | Where-Object { $_.NeedsAttention })
}

# ---------------------------------------------------------------------------
# Console output
# ---------------------------------------------------------------------------

$neverRanCount  = @($report | Where-Object { $_.Reason -eq "never-ran"   }).Count
$failedCount    = @($report | Where-Object { $_.Reason -eq "last-failed" }).Count
$okCount        = @($report | Where-Object { $_.Reason -eq "ok"          }).Count

Write-Host ""
Write-Host "=== Screenshot Verification Remediation Report ===" -ForegroundColor White
Write-Host "  Active agents in report : $($report.Count)"
Write-Host "  Never ran               : $neverRanCount"  -ForegroundColor $(if ($neverRanCount)  { "Yellow" } else { "Green" })
Write-Host "  Last attempt failed     : $failedCount"    -ForegroundColor $(if ($failedCount)    { "Red" }    else { "Green" })
Write-Host "  Passing                 : $okCount"        -ForegroundColor Green
Write-Host ""
Write-Host "ACTION REQUIRED for never-ran and failed agents:" -ForegroundColor Cyan
Write-Host "  In the Datto Partner Portal, for each agent:" -ForegroundColor Cyan
Write-Host "    Protect tab > agent row > gear icon > Screenshot Verification" -ForegroundColor Cyan
Write-Host "    Set 'Additional wait time for the protected machine' to >= 5 minutes" -ForegroundColor Cyan
Write-Host ""

$needsAction = @($report | Where-Object { $_.NeedsAttention })
if ($needsAction.Count -gt 0) {
  Write-Host "--- Agents requiring action ($($needsAction.Count)) ---" -ForegroundColor Yellow
  foreach ($row in $needsAction) {
    $color = if ($row.Reason -eq "never-ran") { "Yellow" } else { "Red" }
    $tag   = if ($row.Reason -eq "never-ran") { "[NEVER RAN]" } else { "[FAILED]   " }
    Write-Host "  $tag  $($row.DeviceName) / $($row.AgentName)  (last: $($row.LastAttempt))" -ForegroundColor $color
    Write-Host "         $($row.PortalUrl)" -ForegroundColor DarkGray
  }
}

# ---------------------------------------------------------------------------
# CSV export
# ---------------------------------------------------------------------------

$report | Select-Object DeviceName, DeviceSerial, AgentName, AgentKey, OS,
                         LastAttempt, LastAttemptPassed, NeedsAttention, Reason,
                         SettingToChange, PortalUrl `
        | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8
Write-Step "Full report written to: $OutputCsvPath"

# ---------------------------------------------------------------------------
# Optional: open portal pages in browser
# ---------------------------------------------------------------------------

if ($OpenPortalLinks) {
  $toOpen = @($report | Where-Object { $_.NeedsAttention })
  Write-Step "Opening $($toOpen.Count) portal page(s) in browser ..."
  foreach ($row in $toOpen) {
    Start-Process $row.PortalUrl
    Start-Sleep -Milliseconds 400  # brief delay to avoid tab flood
  }
}

return $report
