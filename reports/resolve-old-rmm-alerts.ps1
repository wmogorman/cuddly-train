<#
.SYNOPSIS
  Resolves all open Datto RMM alerts older than a configurable number of days.

.DESCRIPTION
  Authenticates against the Datto RMM REST API using OAuth 2.0, retrieves all
  open alerts, and resolves any that are older than -AgeDays days (default: 30).

  Use -WhatIf to preview which alerts would be resolved without making changes.

.PARAMETER ApiKey
  Datto RMM API key.  Can also be supplied via the DATTO_RMM_API_KEY
  environment variable or an -EnvFile.

.PARAMETER ApiSecretKey
  Datto RMM API secret key.  Can also be supplied via DATTO_RMM_API_SECRET
  or an -EnvFile.

.PARAMETER EnvFile
  Path to a .env file containing DATTO_RMM_API_KEY and DATTO_RMM_API_SECRET.
  Defaults to .\datto-rmm.env.

.PARAMETER ApiUrl
  Base URL for your Datto RMM platform.
  Defaults to https://zinfandel-api.centrastage.net

.PARAMETER AgeDays
  Resolve alerts older than this many days. Defaults to 30.

.PARAMETER WhatIf
  List alerts that would be resolved without actually resolving them.

.PARAMETER OutputCsvPath
  Optional path for a CSV report of resolved (or would-be-resolved) alerts.

.EXAMPLE
  .\resolve-old-rmm-alerts.ps1 -EnvFile .\datto-rmm.env -WhatIf

.EXAMPLE
  .\resolve-old-rmm-alerts.ps1 -EnvFile .\datto-rmm.env

.EXAMPLE
  .\resolve-old-rmm-alerts.ps1 -EnvFile .\datto-rmm.env -AgeDays 60 -OutputCsvPath resolved.csv
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $ApiKey,
  [string] $ApiSecretKey,
  [string] $EnvFile       = ".\datto-rmm.env",
  [string] $ApiUrl        = "https://zinfandel-api.centrastage.net",
  [int]    $AgeDays       = 30,
  [string] $OutputCsvPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
  param([string] $Message)
  Write-Host "[resolve-old-rmm-alerts] $Message"
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

function Get-OAuthToken {
  param([string] $BaseUrl, [string] $Key, [string] $Secret)

  # Datto RMM uses a public OAuth client; these are the hardcoded public
  # credentials documented in the official API whitepaper.
  $b64  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("public-client:public"))
  $body = "grant_type=password&username=$([Uri]::EscapeDataString($Key))&password=$([Uri]::EscapeDataString($Secret))"

  try {
    $response = Invoke-RestMethod `
      -Uri         "$BaseUrl/auth/oauth/token" `
      -Method      POST `
      -Headers     @{ Authorization = "Basic $b64" } `
      -Body        $body `
      -ContentType "application/x-www-form-urlencoded"
    return $response.access_token
  }
  catch {
    $status = $_.Exception.Response.StatusCode.value__
    throw "Authentication failed (HTTP $status). Check your API key and secret."
  }
}

function Invoke-RmmApi {
  param([string] $Uri, [string] $Token)
  try {
    return Invoke-RestMethod `
      -Uri         $Uri `
      -Method      GET `
      -Headers     @{ Authorization = "Bearer $Token" } `
      -ContentType "application/json"
  }
  catch {
    $status = $_.Exception.Response.StatusCode.value__
    throw "API error [$Uri] HTTP $status : $($_.Exception.Message)"
  }
}

function Invoke-RmmPost {
  param([string] $Uri, [string] $Token)
  try {
    return Invoke-RestMethod `
      -Uri         $Uri `
      -Method      POST `
      -Headers     @{ Authorization = "Bearer $Token" } `
      -ContentType "application/json"
  }
  catch {
    $status = $_.Exception.Response.StatusCode.value__
    throw "API error [$Uri] HTTP $status : $($_.Exception.Message)"
  }
}

function Get-AllDevices {
  param([string] $BaseUrl, [string] $Token)

  $all  = [System.Collections.Generic.List[object]]::new()
  $page = 0

  do {
    $uri      = "$BaseUrl/api/v2/account/devices?max=250&page=$page"
    $response = Invoke-RmmApi -Uri $uri -Token $Token

    $batch = if ($null -ne $response.devices) { $response.devices }
             elseif ($response -is [array])    { $response }
             else                              { @() }

    foreach ($item in $batch) { $all.Add($item) }

    $nextUrl = if ($null -ne $response.pageDetails) { $response.pageDetails.nextPageUrl } else { $null }
    $page++

  } while (-not [string]::IsNullOrWhiteSpace($nextUrl))

  return $all
}

function Get-DeviceOpenAlerts {
  param([string] $BaseUrl, [string] $Token, [string] $DeviceUid)

  $all  = [System.Collections.Generic.List[object]]::new()
  $page = 0

  do {
    $uri      = "$BaseUrl/api/v2/device/$DeviceUid/alerts/open?max=250&page=$page"
    $response = Invoke-RmmApi -Uri $uri -Token $Token

    $batch = if ($null -ne $response.alerts) { $response.alerts }
             elseif ($response -is [array])   { $response }
             else                             { @() }

    foreach ($item in $batch) { $all.Add($item) }

    $nextUrl = if ($null -ne $response.pageDetails) { $response.pageDetails.nextPageUrl } else { $null }
    $page++

  } while (-not [string]::IsNullOrWhiteSpace($nextUrl))

  return $all
}

function Get-Prop {
  param($Obj, [string] $Name, $Default = "")
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

function ConvertFrom-UnixMs {
  param([object] $Ms)
  if ($null -eq $Ms -or $Ms -eq 0) { return "" }
  return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Ms).LocalDateTime.ToString("yyyy-MM-dd HH:mm")
}

# ---------------------------------------------------------------------------
# Credential resolution (params > .env file > environment variables)
# ---------------------------------------------------------------------------

if (-not [string]::IsNullOrWhiteSpace($EnvFile)) {
  Write-Step "Reading credentials from env file: $EnvFile"
  $envVars = Read-EnvFile -Path $EnvFile
  if ([string]::IsNullOrWhiteSpace($ApiKey)       -and $envVars.ContainsKey('DATTO_RMM_API_KEY'))    { $ApiKey       = $envVars['DATTO_RMM_API_KEY'] }
  if ([string]::IsNullOrWhiteSpace($ApiSecretKey) -and $envVars.ContainsKey('DATTO_RMM_API_SECRET')) { $ApiSecretKey = $envVars['DATTO_RMM_API_SECRET'] }
}

if ([string]::IsNullOrWhiteSpace($ApiKey))       { $ApiKey       = [Environment]::GetEnvironmentVariable('DATTO_RMM_API_KEY') }
if ([string]::IsNullOrWhiteSpace($ApiSecretKey)) { $ApiSecretKey = [Environment]::GetEnvironmentVariable('DATTO_RMM_API_SECRET') }

if ([string]::IsNullOrWhiteSpace($ApiKey))       { throw "API key is required. Use -ApiKey, -EnvFile, or set DATTO_RMM_API_KEY." }
if ([string]::IsNullOrWhiteSpace($ApiSecretKey)) { throw "API secret key is required. Use -ApiSecretKey, -EnvFile, or set DATTO_RMM_API_SECRET." }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Step "Authenticating with $ApiUrl ..."
$token = Get-OAuthToken -BaseUrl $ApiUrl -Key $ApiKey -Secret $ApiSecretKey
Write-Step "Token obtained."

Write-Step "Fetching all devices ..."
$devices = Get-AllDevices -BaseUrl $ApiUrl -Token $token
Write-Step "  Found $($devices.Count) device(s)."

$cutoffMs  = [DateTimeOffset]::UtcNow.AddDays(-$AgeDays).ToUnixTimeMilliseconds()
$oldAlerts = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Step "Scanning open alerts per device ..."
$i = 0
foreach ($device in $devices) {
  $i++
  $deviceUid  = $device.uid
  $deviceName = if ($null -ne $device.hostname) { $device.hostname } else { $deviceUid }

  Write-Progress -Activity "Scanning devices" -Status "$deviceName ($i/$($devices.Count))" -PercentComplete ([int]($i / $devices.Count * 100))

  try {
    $alerts = Get-DeviceOpenAlerts -BaseUrl $ApiUrl -Token $token -DeviceUid $deviceUid
    foreach ($alert in $alerts) {
      $ts = Get-Prop $alert 'timestamp' 0
      if ($ts -ne 0 -and [long]$ts -lt $cutoffMs) {
        $oldAlerts.Add([PSCustomObject]@{
          AlertObj   = $alert
          DeviceName = $deviceName
        })
      }
    }
  }
  catch {
    Write-Warning "Could not fetch alerts for device $deviceName ($deviceUid): $_"
  }
}

Write-Progress -Activity "Scanning devices" -Completed
Write-Step "  Found $($oldAlerts.Count) open alert(s) older than $AgeDays days."

if ($oldAlerts.Count -gt 0 -and $VerbosePreference -ne 'SilentlyContinue') {
  Write-Verbose "First alert object properties:"
  $oldAlerts[0].AlertObj | Format-List | Out-String | Write-Verbose
}

if ($oldAlerts.Count -eq 0) {
  Write-Step "Nothing to resolve. Exiting."
  exit 0
}

$rows     = [System.Collections.Generic.List[PSCustomObject]]::new()
$resolved = 0
$failed   = 0

foreach ($entry in $oldAlerts) {
  $alert   = $entry.AlertObj
  $uid     = Get-Prop $alert 'alertUid'
  $device  = $entry.DeviceName
  $ts      = [long](Get-Prop $alert 'timestamp' 0)
  $msg     = Get-Prop $alert 'alertMessage' (Get-Prop $alert 'description' (Get-Prop $alert 'message'))
  $ageMs   = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $ts
  $ageDays = [math]::Round($ageMs / 86400000, 1)
  $created = ConvertFrom-UnixMs -Ms $ts
  $prio    = Get-Prop $alert 'priority'

  $status = ""

  if ($PSCmdlet.ShouldProcess("Alert $uid on $device (age: $ageDays days)", "Resolve")) {
    try {
      Invoke-RmmPost -Uri "$ApiUrl/api/v2/alert/$uid/resolve" -Token $token | Out-Null
      $status = "Resolved"
      $resolved++
      Write-Step "  RESOLVED  [$ageDays d]  $device — $msg"
    }
    catch {
      $status = "Failed: $_"
      $failed++
      Write-Warning "  FAILED    [$ageDays d]  $device — $msg`n             $_"
    }
  }
  else {
    $status = "WhatIf"
    Write-Step "  WOULD RESOLVE  [$ageDays d]  $device — $msg"
  }

  $rows.Add([PSCustomObject]@{
    AlertUid     = $uid
    DeviceName   = $device
    Priority     = $prio
    AlertMessage = $msg
    Created      = $created
    AgeDays      = $ageDays
    Status       = $status
  })
}

Write-Step ""
if ($WhatIfPreference) {
  Write-Step "WhatIf complete. $($oldAlerts.Count) alert(s) would be resolved."
}
else {
  Write-Step "Done. Resolved: $resolved  |  Failed: $failed  |  Total candidates: $($oldAlerts.Count)"
}

if (-not [string]::IsNullOrWhiteSpace($OutputCsvPath)) {
  $rows | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Encoding UTF8
  Write-Step "Report written to: $OutputCsvPath"
}
