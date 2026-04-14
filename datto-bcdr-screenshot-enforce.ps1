<#
.SYNOPSIS
  Ensures screenshot verification wait time is at least N minutes for every agent
  on every Datto BCDR device in the partner portal.

.DESCRIPTION
  Uses the Datto Partner Portal REST API to enumerate all BCDR devices and agents,
  then attempts to raise the screenshot verification wait time to the specified
  minimum for any agent that is below the threshold.

  IMPORTANT: The Datto Partner Portal API is primarily read-oriented for BCDR
  configuration. If write attempts return HTTP 404/405/501, the API does not
  expose that endpoint and changes must be made through the device's local web
  interface (https://<device-ip>/configure/agent/<agentKey>) or the Partner Portal
  UI. The script will export a remediation report in that case.

.PARAMETER PublicKey
  Datto API public key. Can also be provided via DATTO_PUBLIC_KEY env var or .env file.

.PARAMETER SecretKey
  Datto API secret key. Can also be provided via DATTO_SECRET_KEY env var or .env file.

.PARAMETER EnvFile
  Path to a .env file containing DATTO_PUBLIC_KEY and DATTO_SECRET_KEY.

.PARAMETER MinWaitMinutes
  Minimum wait time to enforce, in minutes. Defaults to 5.

.PARAMETER WaitFieldPath
  Dot-notation path to the screenshot wait-time field in the agent JSON object.
  Defaults to "screenshotVerification.waitTime". Override once you know the
  actual field name (run datto-bcdr-screenshot-audit.ps1 -ShowRawFields first).

.PARAMETER OutputCsvPath
  Path to write a CSV of all agents and their before/after status.

.PARAMETER WhatIf
  Reports what would be changed without actually making API write calls.

.EXAMPLE
  # Dry run — see what would change
  .\datto-bcdr-screenshot-enforce.ps1 -EnvFile .\datto-bcdr.env -WhatIf

  # Enforce minimum 5-minute wait for all agents
  .\datto-bcdr-screenshot-enforce.ps1 -EnvFile .\datto-bcdr.env

  # Enforce 10-minute minimum and save a report
  .\datto-bcdr-screenshot-enforce.ps1 -EnvFile .\datto-bcdr.env -MinWaitMinutes 10 -OutputCsvPath .\remediation.csv
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $PublicKey,
  [string] $SecretKey,
  [string] $EnvFile,
  [int]    $MinWaitMinutes = 5,
  [string] $WaitFieldPath  = "screenshotVerification.waitTime",
  [string] $OutputCsvPath,
  [switch] $WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ApiBase = "https://api.datto.com/v1"

# ---------------------------------------------------------------------------
# Helpers
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
    if ($line -match '^([^=]+)=(.*)$') {
      $vars[$Matches[1].Trim()] = $Matches[2].Trim()
    }
  }
  return $vars
}

function Get-AuthHeader {
  param([string] $Pub, [string] $Sec)
  $raw   = "${Pub}:${Sec}"
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
  $b64   = [Convert]::ToBase64String($bytes)
  return @{ Authorization = "Basic $b64" }
}

function Invoke-DattoApi {
  param(
    [string]    $Path,
    [string]    $Method = "GET",
    [hashtable] $Headers,
    [object]    $Body
  )
  $uri    = "$script:ApiBase$Path"
  $params = @{
    Uri         = $uri
    Method      = $Method
    Headers     = $Headers
    ContentType = "application/json"
  }
  if ($null -ne $Body) {
    $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
  }
  try {
    return Invoke-RestMethod @params
  }
  catch {
    $status = $_.Exception.Response.StatusCode.value__
    $err    = [PSCustomObject]@{ StatusCode = $status; Message = $_.Exception.Message }
    throw $err
  }
}

function Get-AllPages {
  param([string] $Path, [hashtable] $Headers)
  $allItems = [System.Collections.Generic.List[object]]::new()
  $page     = 1
  $pageSize = 100

  do {
    $sep   = if ($Path.Contains("?")) { "&" } else { "?" }
    $paged = Invoke-DattoApi -Path "${Path}${sep}page=${page}&perPage=${pageSize}" -Headers $Headers

    $batch = if ($paged -is [array]) {
      $paged
    }
    elseif ($null -ne $paged -and $null -ne $paged.PSObject.Properties["items"]) {
      $paged.items
    }
    else {
      $null
    }

    if ($null -eq $batch -or @($batch).Count -eq 0) { break }

    foreach ($item in $batch) { $allItems.Add($item) }

    $total = $null
    if ($null -ne $paged -and $paged -isnot [array]) {
      foreach ($candidate in @("pagination.totalCount","totalCount","count","total")) {
        $parts = $candidate.Split(".")
        $val   = $paged
        foreach ($p in $parts) {
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

# Reads a value at a dot-notation path (e.g. "screenshotVerification.waitTime") from a PSObject.
function Get-NestedValue {
  param($Obj, [string] $DotPath)
  $parts = $DotPath.Split(".")
  $cur   = $Obj
  foreach ($part in $parts) {
    if ($null -eq $cur) { return $null }
    try { $cur = $cur.$part } catch { return $null }
  }
  return $cur
}

# Sets a value at a dot-notation path, creating intermediate objects if needed.
# Returns the modified $Obj (which is a deep clone as a nested hashtable).
function Set-NestedValue {
  param($Obj, [string] $DotPath, $Value)
  # Deep-clone to a nested hashtable so we can modify safely.
  $clone = $Obj | ConvertTo-Json -Depth 20 | ConvertFrom-Json
  $parts = $DotPath.Split(".")
  $cur   = $clone
  for ($i = 0; $i -lt $parts.Count - 1; $i++) {
    $part = $parts[$i]
    if ($null -eq $cur.$part) {
      # Property doesn't exist — create it.
      $cur | Add-Member -NotePropertyName $part -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $cur = $cur.$part
  }
  $leaf = $parts[-1]
  try {
    $cur.$leaf = $Value
  }
  catch {
    $cur | Add-Member -NotePropertyName $leaf -NotePropertyValue $Value -Force
  }
  return $clone
}

# Tries PUT then PATCH for the agent endpoint; returns a status string.
function Set-AgentField {
  param(
    [string]    $Serial,
    [string]    $AgentKey,
    [hashtable] $Headers,
    $AgentDetail,
    [string]    $FieldPath,
    $NewValue
  )

  $updated = Set-NestedValue -Obj $AgentDetail -DotPath $FieldPath -Value $NewValue
  $apiPath = "/bcdr/device/$Serial/asset/$AgentKey"

  foreach ($method in @("PUT", "PATCH")) {
    try {
      Invoke-DattoApi -Path $apiPath -Method $method -Headers $Headers -Body $updated | Out-Null
      return "updated-$method"
    }
    catch {
      $sc = if ($_.StatusCode) { $_.StatusCode } else { "?" }
      if ($sc -in @(404, 405, 501)) {
        # Endpoint not supported — try next method.
        continue
      }
      # Other error (auth, validation, etc.) — surface it.
      return "error-$method-$sc"
    }
  }

  return "api-readonly"
}

# ---------------------------------------------------------------------------
# Credential resolution
# ---------------------------------------------------------------------------

if ($EnvFile) {
  Write-Step "Loading credentials from: $EnvFile"
  $env = Read-EnvFile -Path $EnvFile
  if (-not $PublicKey -and $env.ContainsKey("DATTO_PUBLIC_KEY")) { $PublicKey = $env["DATTO_PUBLIC_KEY"] }
  if (-not $SecretKey -and $env.ContainsKey("DATTO_SECRET_KEY")) { $SecretKey = $env["DATTO_SECRET_KEY"] }
}

if (-not $PublicKey) { $PublicKey = $env:DATTO_PUBLIC_KEY }
if (-not $SecretKey) { $SecretKey = $env:DATTO_SECRET_KEY }

if (-not $PublicKey -or -not $SecretKey) {
  throw "API credentials required. Provide -PublicKey/-SecretKey, -EnvFile, or set DATTO_PUBLIC_KEY/DATTO_SECRET_KEY."
}

$headers = Get-AuthHeader -Pub $PublicKey -Sec $SecretKey

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($WhatIf) { Write-Step "WhatIf mode — no changes will be made." }

Write-Step "Fetching BCDR device list ..."
$devices = Get-AllPages -Path "/bcdr/device" -Headers $headers
Write-Step "Found $($devices.Count) device(s)."

$report = [System.Collections.Generic.List[PSCustomObject]]::new()
$apiReadOnly = $false   # set to $true on first "api-readonly" response

foreach ($device in $devices) {
  $serial = $device.serialNumber
  $dname  = $device.name

  Write-Step "  Device: $dname ($serial)"

  try {
    $agents = Get-AllPages -Path "/bcdr/device/$serial/asset" -Headers $headers
  }
  catch {
    Write-Warning "    Failed to list agents: $_"
    continue
  }

  foreach ($agent in $agents) {
    if ($agent.type -eq "share") { continue }

    $agentKey  = $agent.agentKey
    $agentName = $agent.name

    # Fetch the full agent detail.
    try {
      $detail = Invoke-DattoApi -Path "/bcdr/device/$serial/asset/$agentKey" -Headers $headers
    }
    catch {
      Write-Warning "    Cannot fetch detail for '$agentName': $_"
      $detail = $agent
    }

    $currentWait = Get-NestedValue -Obj $detail -DotPath $WaitFieldPath
    $currentWaitInt = if ($null -ne $currentWait) { [int]$currentWait } else { $null }
    $needsChange = ($null -eq $currentWaitInt) -or ($currentWaitInt -lt $MinWaitMinutes)
    $outcome = "ok"

    if ($needsChange) {
      $newValue = $MinWaitMinutes

      if ($null -eq $currentWaitInt) {
        Write-Host "    [?] '$agentName' — field '$WaitFieldPath' not found; will attempt to set to ${newValue}m" -ForegroundColor Yellow
      }
      else {
        Write-Host "    [!] '$agentName' — wait is ${currentWaitInt}m (< ${MinWaitMinutes}m); raising to ${newValue}m" -ForegroundColor Red
      }

      if ($WhatIf) {
        $outcome = "would-update"
      }
      else {
        $outcome = Set-AgentField `
          -Serial      $serial `
          -AgentKey    $agentKey `
          -Headers     $headers `
          -AgentDetail $detail `
          -FieldPath   $WaitFieldPath `
          -NewValue    $newValue

        switch -Wildcard ($outcome) {
          "updated-*" {
            Write-Host "      -> Updated via $($outcome.Split('-')[1].ToUpper())" -ForegroundColor Green
          }
          "api-readonly" {
            $apiReadOnly = $true
            Write-Host "      -> API returned 404/405 — write not supported via Partner Portal API" -ForegroundColor Yellow
          }
          "error-*" {
            Write-Warning "      -> $outcome"
          }
        }
      }
    }
    else {
      Write-Host "    [OK] '$agentName' — wait is ${currentWaitInt}m (>= ${MinWaitMinutes}m)" -ForegroundColor Green
    }

    $report.Add([PSCustomObject]@{
      DeviceName     = $dname
      DeviceSerial   = $serial
      AgentName      = $agentName
      AgentKey       = $agentKey
      WaitFieldPath  = $WaitFieldPath
      WaitBefore     = $currentWaitInt
      WaitAfter      = if ($needsChange -and $outcome -like "updated-*") { $MinWaitMinutes } else { $currentWaitInt }
      MinRequired    = $MinWaitMinutes
      NeedsChange    = $needsChange
      Outcome        = $outcome
      PortalUrl      = "https://portal.dattobackup.com/continuity/devices/$serial/agents/$agentKey/settings"
    })
  }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$changed  = @($report | Where-Object { $_.Outcome -like "updated-*" })
$failed   = @($report | Where-Object { $_.Outcome -like "error-*"   })
$readonly = @($report | Where-Object { $_.Outcome -eq "api-readonly" })
$ok       = @($report | Where-Object { $_.Outcome -eq "ok"           })
$wouldFix = @($report | Where-Object { $_.Outcome -eq "would-update" })

Write-Host ""
Write-Host "=== Enforcement Summary ===" -ForegroundColor White
Write-Host "  Already compliant : $($ok.Count)"      -ForegroundColor Green
if ($WhatIf) {
  Write-Host "  Would update      : $($wouldFix.Count)" -ForegroundColor Cyan
}
else {
  Write-Host "  Updated via API   : $($changed.Count)"  -ForegroundColor Green
  Write-Host "  API write blocked : $($readonly.Count)" -ForegroundColor $(if ($readonly.Count) { "Yellow" } else { "Green" })
  Write-Host "  Errors            : $($failed.Count)"   -ForegroundColor $(if ($failed.Count)    { "Red" }    else { "Green" })
}

if ($apiReadOnly) {
  Write-Host ""
  Write-Host "NOTE: The Datto Partner Portal API does not expose a write endpoint for agent" -ForegroundColor Yellow
  Write-Host "screenshot verification settings. The following agents require manual changes." -ForegroundColor Yellow
  Write-Host "Navigate to each agent's settings page and set 'Additional wait time' to" -ForegroundColor Yellow
  Write-Host ">= ${MinWaitMinutes} minutes, or use the device's local web interface." -ForegroundColor Yellow
  Write-Host ""

  $readonly | ForEach-Object {
    Write-Host "  $($_.DeviceName) / $($_.AgentName)"
    Write-Host "    Current : $($_.WaitBefore)m   Target : ${MinWaitMinutes}m"
    Write-Host "    Portal  : $($_.PortalUrl)"
    Write-Host ""
  }

  Write-Host "Alternatively, run datto-bcdr-screenshot-audit.ps1 -ShowRawFields to inspect" -ForegroundColor Yellow
  Write-Host "the exact field names the API returns, then re-run this script with:" -ForegroundColor Yellow
  Write-Host "  -WaitFieldPath <correct.field.path>" -ForegroundColor Yellow
}

if ($OutputCsvPath) {
  $report | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8
  Write-Step "Report written to: $OutputCsvPath"
}

return $report
