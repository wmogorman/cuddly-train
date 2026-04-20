<#
.SYNOPSIS
  Audits health of all active Datto BCDR devices and agents.

.DESCRIPTION
  Uses the Datto Partner Portal REST API (api.datto.com/v1) to enumerate all
  active BCDR devices and agents, then reports issues across four categories:

    device-offline       Device has not checked in within -DeviceOfflineHours
    device-alerts        Device has one or more active alerts
    backup-never         Agent has never completed a successful backup
    backup-stale         Agent's last backup is older than -BackupStaleHours
    screenshot-never     Screenshot verification has never run on this agent
    screenshot-failed    Last screenshot verification attempt failed

  Filters applied by default (matching the portal's default view):
    - Hidden devices and agents are skipped
    - Devices with an expired servicePeriod (cancelled subscriptions) are skipped
    - Archived agents are skipped
    - Paused agents are skipped

.PARAMETER PublicKey
  Datto API public key. Can also be set via DATTO_PUBLIC_KEY env var or -EnvFile.

.PARAMETER SecretKey
  Datto API secret key. Can also be set via DATTO_SECRET_KEY env var or -EnvFile.

.PARAMETER EnvFile
  Path to a .env file containing DATTO_PUBLIC_KEY and DATTO_SECRET_KEY.

.PARAMETER OutputCsvPath
  Optional path to write the full issue list as CSV.

.PARAMETER DeviceOfflineHours
  Hours since last check-in before a device is considered offline. Default: 4.

.PARAMETER BackupStaleHours
  Hours since last successful backup before an agent is flagged. Default: 25
  (allows a little slack over a standard daily backup schedule).

.PARAMETER IncludeCancelled
  Include devices with expired service periods (cancelled subscriptions).

.EXAMPLE
  .\datto-bcdr-health-audit.ps1 -EnvFile .\datto-bcdr.env
  .\datto-bcdr-health-audit.ps1 -EnvFile .\datto-bcdr.env -OutputCsvPath .\health-audit.csv
  .\datto-bcdr-health-audit.ps1 -EnvFile .\datto-bcdr.env -DeviceOfflineHours 2 -BackupStaleHours 48
#>

[CmdletBinding()]
param(
  [string] $PublicKey,
  [string] $SecretKey,
  [string] $EnvFile,
  [string] $OutputCsvPath,
  [int]    $DeviceOfflineHours = 4,
  [int]    $BackupStaleHours   = 25,
  [switch] $IncludeCancelled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ApiBase          = "https://api.datto.com/v1"
$script:Now              = Get-Date
$script:CancelledStatuses = @('cancelled','canceled','inactive','expired','terminated','suspended','decommissioned')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
  param([string] $Message)
  Write-Host "[datto-bcdr-health-audit] $Message"
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
  $pageSize   = 100
  $maxPages   = 50  # safety cap --- prevents infinite loops if the API repeats pages
  $strategies = @(
    @{ Name = "_page/_perPage"; PageParam = "_page"; PageSizeParam = "_perPage" },
    @{ Name = "page/perPage";   PageParam = "page";  PageSizeParam = "perPage"  }
  )
  $lastItems  = [System.Collections.Generic.List[object]]::new()

  foreach ($strategy in $strategies) {
    $allItems    = [System.Collections.Generic.List[object]]::new()
    $seenIds     = [System.Collections.Generic.HashSet[string]]::new()
    $page        = 1
    $shouldRetry = $false

    do {
      $sep   = if ($Path.Contains("?")) { "&" } else { "?" }
      $paged = Invoke-DattoApi -Path "${Path}${sep}$($strategy.PageParam)=${page}&$($strategy.PageSizeParam)=${pageSize}" -Headers $Headers

      $batch = if ($paged -is [array]) { $paged }
               elseif ($null -ne $paged.PSObject.Properties["items"]) { $paged.items }
               else { $null }

      if ($null -eq $batch -or @($batch).Count -eq 0) { break }

      # Detect when the API is returning the same page repeatedly.
      # Use the first item's identifier as a fingerprint.
      $firstItem = @($batch)[0]
      $firstId   = Resolve-Field -Obj $firstItem -Candidates @(
        'serialNumber','volume','agentKey','assetId','id','name'
      )
      if ($null -ne $firstId -and -not $seenIds.Add($firstId.ToString())) {
        $totalCount = Resolve-Field -Obj $paged -Candidates @(
          'pagination.totalCount','totalCount','pagination.total'
        )
        $totalPages = Resolve-Field -Obj $paged -Candidates @(
          'pagination.totalPages','totalPages','pagination.pages'
        )
        if (($null -ne $totalCount -and $allItems.Count -lt [int]$totalCount) -or
            ($null -ne $totalPages -and $page -le [int]$totalPages) -or
            ($page -gt 1 -and $allItems.Count -ge $pageSize -and @($batch).Count -eq $pageSize)) {
          $shouldRetry = $true
        }
        break
      }

      foreach ($item in $batch) { $allItems.Add($item) }

      $totalCount = Resolve-Field -Obj $paged -Candidates @(
        'pagination.totalCount','totalCount','pagination.total'
      )
      $totalPages = Resolve-Field -Obj $paged -Candidates @(
        'pagination.totalPages','totalPages','pagination.pages'
      )
      $nextPage = Resolve-Field -Obj $paged -Candidates @(
        'pagination.nextPage','nextPage','pagination.next'
      )

      if ($null -ne $totalCount -and $allItems.Count -ge [int]$totalCount) { break }
      if ($null -ne $totalPages -and $page -ge [int]$totalPages) { break }
      if (@($batch).Count -lt $pageSize) { break }
      if ($page -ge $maxPages) { break }

      if ($null -ne $nextPage -and [int]$nextPage -gt $page) { $page = [int]$nextPage }
      else { $page++ }
    } while ($true)

    if ($allItems.Count -gt 0) { $lastItems = $allItems }
    if (-not $shouldRetry) { return $allItems }

    Write-Warning "Datto pagination for [$Path] repeated a page when using $($strategy.Name); retrying with alternate parameter names."
  }

  return $lastItems
}

function Resolve-Field {
  param($Obj, [string[]] $Candidates)
  foreach ($name in $Candidates) {
    $val = $Obj
    foreach ($segment in $name.Split('.')) {
      if ($null -eq $val) { break }
      if ($val -is [System.Collections.IDictionary]) {
        if ($val.Contains($segment)) { $val = $val[$segment] }
        else { $val = $null; break }
        continue
      }
      $prop = $val.PSObject.Properties[$segment]
      if ($null -eq $prop) { $val = $null; break }
      $val = $prop.Value
    }
    if ($null -ne $val) { return $val }
  }
  return $null
}

function Format-UnixTime {
  param([long] $Ts)
  if ($Ts -eq 0 -or $null -eq $Ts) { return "never" }
  return ([DateTimeOffset]::FromUnixTimeSeconds($Ts)).LocalDateTime.ToString("yyyy-MM-dd HH:mm")
}

function Format-Age {
  param([long] $Ts)
  if ($Ts -eq 0 -or $null -eq $Ts) { return "n/a" }
  $age = $script:Now - ([DateTimeOffset]::FromUnixTimeSeconds($Ts)).LocalDateTime
  if ($age.TotalDays -ge 1) { return "$([int]$age.TotalDays)d ago" }
  return "$([int]$age.TotalHours)h ago"
}

function Test-DeviceCancelled {
  param($Device)
  $statusVal = Resolve-Field -Obj $Device -Candidates @(
    'status','subscriptionStatus','deviceStatus','state',
    'registrationStatus','contractStatus','serviceStatus'
  )
  if ($null -ne $statusVal -and $script:CancelledStatuses -contains $statusVal.ToString().ToLower()) {
    return $true
  }
  # Only treat a device as cancelled if its service period expired more than 60 days
  # ago. This avoids false-positives for devices that are simply offline or a few
  # weeks behind on billing --- those should still appear as health issues.
  $sp = Resolve-Field -Obj $Device -Candidates @('servicePeriod','serviceExpiry','contractEnd','expiryDate')
  if ($null -ne $sp -and -not [string]::IsNullOrWhiteSpace($sp.ToString())) {
    try {
      if ([datetime]::Parse($sp.ToString()) -lt $script:Now.AddDays(-60)) { return $true }
    }
    catch { }
  }
  return $false
}

function New-Issue {
  param(
    [string] $IssueType,
    [string] $DeviceName,
    [string] $DeviceSerial,
    [string] $Detail,
    [string] $AgentName  = "",
    [string] $AgentKey   = ""
  )
  [PSCustomObject]@{
    IssueType    = $IssueType
    DeviceName   = $DeviceName
    DeviceSerial = $DeviceSerial
    AgentName    = $AgentName
    AgentKey     = $AgentKey
    Detail       = $Detail
  }
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

$issues = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($device in $devices) {
  $serial = $device.serialNumber
  $dname  = $device.name

  if ((Resolve-Field -Obj $device -Candidates @('hidden')) -eq $true) { continue }
  if (-not $IncludeCancelled -and (Test-DeviceCancelled -Device $device)) { continue }

  # ---- Device-level checks ------------------------------------------------

  # Offline: lastSeenDate too old
  $lastSeen = Resolve-Field -Obj $device -Candidates @('lastSeenDate','lastSeen','lastContact')
  if ($null -ne $lastSeen -and -not [string]::IsNullOrWhiteSpace($lastSeen.ToString())) {
    try {
      $lastSeenDt = [datetime]::Parse($lastSeen.ToString())
      if (($script:Now - $lastSeenDt).TotalHours -gt $DeviceOfflineHours) {
        $issues.Add((New-Issue -IssueType "device-offline" `
          -DeviceName $dname -DeviceSerial $serial `
          -Detail "Last seen: $($lastSeenDt.ToString('yyyy-MM-dd HH:mm')) ($([int]($script:Now - $lastSeenDt).TotalHours)h ago)"))
      }
    }
    catch { }
  }

  # Active alerts
  $alertCount = Resolve-Field -Obj $device -Candidates @('alertCount','activeAlerts','alerts')
  if ($null -ne $alertCount -and [int]$alertCount -gt 0) {
    $issues.Add((New-Issue -IssueType "device-alerts" `
      -DeviceName $dname -DeviceSerial $serial `
      -Detail "$alertCount active alert(s)"))
  }

  # ---- Agent-level checks -------------------------------------------------

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
    if ((Resolve-Field -Obj $asset -Candidates @('hidden'))     -eq $true)  { continue }
    if ((Resolve-Field -Obj $asset -Candidates @('isArchived')) -eq $true)  { continue }
    if ((Resolve-Field -Obj $asset -Candidates @('isPaused'))   -eq $true)  { continue }

    $agentKey  = Resolve-Field -Obj $asset -Candidates @("volume","agentKey","keyName","key","assetId","id","name")
    $agentName = Resolve-Field -Obj $asset -Candidates @("name","hostname","displayName","agentName")

    $lastSnapshotTs = [long]($asset.lastSnapshot)
    $lastSsAttemptTs = [long]($asset.lastScreenshotAttempt)
    $lastSsOk        = [bool]($asset.lastScreenshotAttemptStatus)

    # Backup never ran
    if ($lastSnapshotTs -eq 0) {
      $issues.Add((New-Issue -IssueType "backup-never" `
        -DeviceName $dname -DeviceSerial $serial `
        -AgentName $agentName -AgentKey $agentKey `
        -Detail "No successful backup recorded" `
        ))
    }
    # Backup stale
    elseif (($script:Now - ([DateTimeOffset]::FromUnixTimeSeconds($lastSnapshotTs)).LocalDateTime).TotalHours -gt $BackupStaleHours) {
      $issues.Add((New-Issue -IssueType "backup-stale" `
        -DeviceName $dname -DeviceSerial $serial `
        -AgentName $agentName -AgentKey $agentKey `
        -Detail "Last backup: $(Format-UnixTime $lastSnapshotTs) ($(Format-Age $lastSnapshotTs))" `
        ))
    }

    # Screenshot verification never ran
    if ($lastSsAttemptTs -eq 0) {
      $issues.Add((New-Issue -IssueType "screenshot-never" `
        -DeviceName $dname -DeviceSerial $serial `
        -AgentName $agentName -AgentKey $agentKey `
        -Detail "Screenshot verification never attempted" `
        ))
    }
    # Screenshot verification last failed
    elseif (-not $lastSsOk) {
      $issues.Add((New-Issue -IssueType "screenshot-failed" `
        -DeviceName $dname -DeviceSerial $serial `
        -AgentName $agentName -AgentKey $agentKey `
        -Detail "Last attempt: $(Format-UnixTime $lastSsAttemptTs) --- failed" `
        ))
    }
  }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$byType = $issues | Group-Object IssueType | Sort-Object Name

$colours = @{
  'device-offline'   = 'Red'
  'device-alerts'    = 'Yellow'
  'backup-never'     = 'Red'
  'backup-stale'     = 'Red'
  'screenshot-never' = 'Yellow'
  'screenshot-failed'= 'Red'
}

Write-Host ""
Write-Host "=== Datto BCDR Health Audit ===" -ForegroundColor White
Write-Host "  Total issues : $($issues.Count)" -ForegroundColor $(if ($issues.Count) { "Red" } else { "Green" })
foreach ($grp in $byType) {
  $col = if ($colours.ContainsKey($grp.Name)) { $colours[$grp.Name] } else { "White" }
  Write-Host ("  {0,-22} : {1}" -f $grp.Name, $grp.Count) -ForegroundColor $col
}

foreach ($grp in $byType) {
  $col = if ($colours.ContainsKey($grp.Name)) { $colours[$grp.Name] } else { "White" }
  Write-Host ""
  Write-Host "--- $($grp.Name) ($($grp.Count)) ---" -ForegroundColor $col
  foreach ($issue in ($grp.Group | Sort-Object DeviceName, AgentName)) {
    $label = if ($issue.AgentName) { "$($issue.DeviceName) / $($issue.AgentName)" } else { $issue.DeviceName }
    Write-Host "  $label" -ForegroundColor $col
    Write-Host "    $($issue.Detail)" -ForegroundColor DarkGray
  }
}

if ($OutputCsvPath) {
  $issues | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8
  Write-Step "Results written to: $OutputCsvPath"
}

return $issues


