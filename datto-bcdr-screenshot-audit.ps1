<#
.SYNOPSIS
  Audits screenshot verification wait times for all agents across all Datto BCDR devices.

.DESCRIPTION
  Uses the Datto Partner Portal REST API to enumerate all BCDR devices and their
  agents, then reports the screenshot verification wait time configured for each.
  Flags any agent whose wait time is below the specified minimum.

.PARAMETER PublicKey
  Datto API public key. Can also be provided via DATTO_PUBLIC_KEY env var or a .env file.

.PARAMETER SecretKey
  Datto API secret key. Can also be provided via DATTO_SECRET_KEY env var or a .env file.

.PARAMETER EnvFile
  Path to a .env file containing DATTO_PUBLIC_KEY and DATTO_SECRET_KEY.

.PARAMETER MinWaitMinutes
  Minimum acceptable screenshot verification wait time in minutes. Defaults to 5.

.PARAMETER OutputCsvPath
  Optional path to write audit results as CSV.

.PARAMETER ShowRawFields
  Dumps all screenshot/verification-related fields from the raw API response.
  Use this on first run to discover the exact field names the API returns.

.EXAMPLE
  .\datto-bcdr-screenshot-audit.ps1 -EnvFile .\datto-bcdr.env
  .\datto-bcdr-screenshot-audit.ps1 -PublicKey e24658 -SecretKey 77abd2... -ShowRawFields
  .\datto-bcdr-screenshot-audit.ps1 -EnvFile .\datto-bcdr.env -OutputCsvPath .\screenshot-audit.csv
#>

[CmdletBinding()]
param(
  [string] $PublicKey,
  [string] $SecretKey,
  [string] $EnvFile,
  [int]    $MinWaitMinutes = 5,
  [string] $OutputCsvPath,
  [switch] $ShowRawFields
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
    [string] $Path,
    [string] $Method = "GET",
    [hashtable] $Headers,
    [object] $Body
  )
  $uri    = "$script:ApiBase$Path"
  $params = @{
    Uri     = $uri
    Method  = $Method
    Headers = $Headers
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
    throw "API call failed [$Method $Path] → HTTP $status : $($_.Exception.Message)"
  }
}

function Get-AllPages {
  param(
    [string]    $Path,
    [hashtable] $Headers
  )
  $allItems = [System.Collections.Generic.List[object]]::new()
  $page     = 1
  $pageSize = 100
  do {
    $sep   = if ($Path.Contains("?")) { "&" } else { "?" }
    $paged = Invoke-DattoApi -Path "${Path}${sep}page=${page}&perPage=${pageSize}" -Headers $Headers
    if ($null -eq $paged -or $null -eq $paged.items) { break }
    foreach ($item in $paged.items) { $allItems.Add($item) }
    $page++
  } while ($allItems.Count -lt $paged.pagination.totalCount)
  return $allItems
}

# Recursively flattens a PSObject/hashtable into dot-notation key paths and values.
function Get-FlatProperties {
  param($Obj, [string] $Prefix = "")
  if ($null -eq $Obj) { return }
  if ($Obj -is [string] -or $Obj -is [ValueType]) {
    [PSCustomObject]@{ Key = $Prefix; Value = $Obj }
    return
  }
  foreach ($prop in $Obj.PSObject.Properties) {
    $childKey = if ($Prefix) { "$Prefix.$($prop.Name)" } else { $prop.Name }
    if ($null -eq $prop.Value -or $prop.Value -is [string] -or $prop.Value -is [ValueType]) {
      [PSCustomObject]@{ Key = $childKey; Value = $prop.Value }
    }
    else {
      Get-FlatProperties -Obj $prop.Value -Prefix $childKey
    }
  }
}

function Find-ScreenshotFields {
  param($AgentObj)
  $keywords = 'screenshot', 'verify', 'verification', 'waittime', 'wait_time', 'delay', 'localVerif'
  $flat = Get-FlatProperties -Obj $AgentObj
  return $flat | Where-Object {
    $k = $_.Key.ToLower()
    ($keywords | Where-Object { $k -like "*$_*" }) -ne $null
  }
}

# Attempts to read the screenshot wait time from common field locations.
# Returns $null if the field is not found.
function Get-WaitTime {
  param($AgentObj)

  # Try the most likely field paths in order of probability.
  $candidates = @(
    { $AgentObj.screenshotVerification.waitTime },
    { $AgentObj.screenshotVerification.delay },
    { $AgentObj.screenshotVerification.waitMinutes },
    { $AgentObj.localVerification.waitTime },
    { $AgentObj.localVerification.delay },
    { $AgentObj.localVerification.waitMinutes },
    { $AgentObj.screenshotWaitTime },
    { $AgentObj.screenshotDelay },
    { $AgentObj.verification.waitTime }
  )

  foreach ($candidate in $candidates) {
    try {
      $val = & $candidate
      if ($null -ne $val) { return [int]$val }
    }
    catch { }
  }
  return $null
}

# ---------------------------------------------------------------------------
# Credential resolution
# ---------------------------------------------------------------------------

if ($EnvFile) {
  Write-Step "Loading credentials from env file: $EnvFile"
  $env = Read-EnvFile -Path $EnvFile
  if (-not $PublicKey -and $env.ContainsKey("DATTO_PUBLIC_KEY"))  { $PublicKey = $env["DATTO_PUBLIC_KEY"] }
  if (-not $SecretKey -and $env.ContainsKey("DATTO_SECRET_KEY"))  { $SecretKey = $env["DATTO_SECRET_KEY"] }
}

if (-not $PublicKey) { $PublicKey = $env:DATTO_PUBLIC_KEY }
if (-not $SecretKey) { $SecretKey = $env:DATTO_SECRET_KEY }

if (-not $PublicKey -or -not $SecretKey) {
  throw "API credentials are required. Provide -PublicKey/-SecretKey, -EnvFile, or set DATTO_PUBLIC_KEY/DATTO_SECRET_KEY environment variables."
}

$headers = Get-AuthHeader -Pub $PublicKey -Sec $SecretKey

# ---------------------------------------------------------------------------
# Main audit
# ---------------------------------------------------------------------------

Write-Step "Fetching BCDR device list from $script:ApiBase ..."
$devices = Get-AllPages -Path "/bcdr/device" -Headers $headers
Write-Step "Found $($devices.Count) device(s)."

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($device in $devices) {
  $serial = $device.serialNumber
  $dname  = $device.name

  Write-Step "  Device: $dname ($serial) — fetching agents ..."
  try {
    $agents = Get-AllPages -Path "/bcdr/device/$serial/asset" -Headers $headers
  }
  catch {
    Write-Warning "    Could not retrieve agents for $serial : $_"
    continue
  }

  foreach ($agent in $agents) {
    # Skip share-type assets (NAS shares); only process backup agents.
    if ($agent.type -eq "share") { continue }

    $agentKey  = $agent.agentKey
    $agentName = $agent.name

    # Fetch the full agent detail to get configuration fields.
    try {
      $detail = Invoke-DattoApi -Path "/bcdr/device/$serial/asset/$agentKey" -Headers $headers
    }
    catch {
      Write-Warning "    Could not fetch detail for agent '$agentName' ($agentKey): $_"
      $detail = $agent
    }

    if ($ShowRawFields) {
      $ssFields = Find-ScreenshotFields -AgentObj $detail
      if ($ssFields) {
        Write-Host "    [RAW] Agent: $agentName ($agentKey)" -ForegroundColor Cyan
        foreach ($f in $ssFields) {
          Write-Host "      $($f.Key) = $($f.Value)" -ForegroundColor DarkCyan
        }
      }
    }

    $waitTime = Get-WaitTime -AgentObj $detail
    $compliant = if ($null -eq $waitTime) { $null } else { $waitTime -ge $MinWaitMinutes }

    $results.Add([PSCustomObject]@{
      DeviceName   = $dname
      DeviceSerial = $serial
      AgentName    = $agentName
      AgentKey     = $agentKey
      WaitMinutes  = $waitTime
      MinRequired  = $MinWaitMinutes
      Compliant    = $compliant
    })
  }
}

# ---------------------------------------------------------------------------
# Output summary
# ---------------------------------------------------------------------------

$unknown    = @($results | Where-Object { $null -eq $_.Compliant })
$compliant  = @($results | Where-Object { $_.Compliant -eq $true  })
$violations = @($results | Where-Object { $_.Compliant -eq $false })

Write-Host ""
Write-Host "=== Screenshot Verification Audit ===" -ForegroundColor White
Write-Host "  Total agents checked : $($results.Count)"
Write-Host "  Compliant (>= ${MinWaitMinutes}m)   : $($compliant.Count)" -ForegroundColor Green
Write-Host "  Non-compliant        : $($violations.Count)" -ForegroundColor $(if ($violations.Count) { "Red" } else { "Green" })
Write-Host "  Field not found      : $($unknown.Count)"    -ForegroundColor $(if ($unknown.Count)    { "Yellow" } else { "Green" })

if ($unknown.Count -gt 0) {
  Write-Host ""
  Write-Host "--- Agents with unknown wait-time field (run -ShowRawFields to diagnose) ---" -ForegroundColor Yellow
  $unknown | ForEach-Object { Write-Host "  $($_.DeviceName) / $($_.AgentName)" -ForegroundColor Yellow }
}

if ($violations.Count -gt 0) {
  Write-Host ""
  Write-Host "--- Non-compliant agents (wait < ${MinWaitMinutes} minutes) ---" -ForegroundColor Red
  $violations | ForEach-Object {
    Write-Host "  $($_.DeviceName) / $($_.AgentName)  [current: $($_.WaitMinutes)m]" -ForegroundColor Red
  }
}

if ($OutputCsvPath) {
  $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8
  Write-Step "Results written to: $OutputCsvPath"
}

return $results
