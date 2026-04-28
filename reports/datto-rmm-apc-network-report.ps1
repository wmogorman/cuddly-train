<#
.SYNOPSIS
  Reports all Datto RMM devices matched by the "UPS Devices - APC" custom
  filter and exports them to CSV.

.DESCRIPTION
  Authenticates against the Datto RMM REST API using OAuth 2.0, looks up the
  named custom device filter, then retrieves all devices matched by that filter.
  Results are sorted by site and hostname and written to CSV.

  The filter name is configurable via -FilterName.  The "UPS Devices - APC"
  filter in the RMM portal already encodes the correct identification logic for
  APC by Schneider Electric devices across all enrollment methods (SNMP network
  devices, full agents, etc.).

.PARAMETER ApiKey
  Datto RMM API key.  Can also be supplied via DATTO_RMM_API_KEY or -EnvFile.

.PARAMETER ApiSecretKey
  Datto RMM API secret key.  Can also be supplied via DATTO_RMM_API_SECRET or
  -EnvFile.

.PARAMETER EnvFile
  Path to a .env file containing DATTO_RMM_API_KEY and DATTO_RMM_API_SECRET.
  Defaults to .\datto-rmm.env.

.PARAMETER ApiUrl
  Base URL for your Datto RMM platform.
  Defaults to https://zinfandel-api.centrastage.net

.PARAMETER FilterName
  Name of the custom device filter to use.
  Defaults to "UPS Devices - APC".

.PARAMETER OutputCsvPath
  Path for the output CSV file.  Defaults to datto-rmm-apc-devices.csv in the
  current directory.

.EXAMPLE
  .\datto-rmm-apc-network-report.ps1

.EXAMPLE
  .\datto-rmm-apc-network-report.ps1 -FilterName "UPS Devices - APC" -OutputCsvPath ..\artifacts\datto-rmm\apc-devices.csv
#>

[CmdletBinding()]
param(
  [string] $ApiKey,
  [string] $ApiSecretKey,
  [string] $EnvFile       = ".\datto-rmm.env",
  [string] $ApiUrl        = "https://zinfandel-api.centrastage.net",
  [string] $FilterName    = "UPS Devices - APC",
  [string] $OutputCsvPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
  param([string] $Message)
  Write-Host "[datto-rmm-apc-network-report] $Message"
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

function Get-Prop {
  param($Obj, [string] $Name, $Default = "")
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
  return $Default
}

function Find-FilterByName {
  param([string] $BaseUrl, [string] $Token, [string] $Name)

  foreach ($endpoint in @('/api/v2/filter/custom-filters', '/api/v2/filter/default-filters')) {
    $page = 0
    do {
      $uri      = "$BaseUrl${endpoint}?max=250&page=$page"
      $response = Invoke-RmmApi -Uri $uri -Token $Token

      $batch = if ($null -ne $response.filters) { $response.filters }
               elseif ($response -is [array])    { $response }
               else                              { @() }

      $match = $batch | Where-Object { $_.name -eq $Name } | Select-Object -First 1
      if ($match) { return $match }

      $nextUrl = if ($null -ne $response.pageDetails) { $response.pageDetails.nextPageUrl } else { $null }
      $page++

    } while (-not [string]::IsNullOrWhiteSpace($nextUrl))
  }

  return $null
}

function Get-FilteredDevices {
  param([string] $BaseUrl, [string] $Token, [int] $FilterId)

  $all  = [System.Collections.Generic.List[object]]::new()
  $page = 0

  do {
    $uri      = "$BaseUrl/api/v2/account/devices?filterId=$FilterId&max=250&page=$page"
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

$artifactsDir = Join-Path (Split-Path $PSCommandPath -Parent) "artifacts\datto-rmm"
if (-not (Test-Path $artifactsDir)) { New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null }
if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) { $OutputCsvPath = Join-Path $artifactsDir "datto-rmm-apc-devices.csv" }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Step "Authenticating with $ApiUrl ..."
$token = Get-OAuthToken -BaseUrl $ApiUrl -Key $ApiKey -Secret $ApiSecretKey
Write-Step "Token obtained."

Write-Step "Looking up filter: '$FilterName' ..."
$filter = Find-FilterByName -BaseUrl $ApiUrl -Token $token -Name $FilterName
if ($null -eq $filter) {
  throw "Custom filter '$FilterName' not found. Check the filter name in the RMM portal under Setup > Device Filters."
}
Write-Step "  Found filter ID $($filter.id)."

Write-Step "Fetching devices matched by filter ..."
$devices = Get-FilteredDevices -BaseUrl $ApiUrl -Token $token -FilterId $filter.id
Write-Step "  Found $($devices.Count) device(s)."

$rows = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($device in $devices) {
  $deviceType = $device.PSObject.Properties['deviceType']
  $category   = if ($null -ne $deviceType -and $null -ne $deviceType.Value) { Get-Prop $deviceType.Value 'category' } else { '' }
  $type       = if ($null -ne $deviceType -and $null -ne $deviceType.Value) { Get-Prop $deviceType.Value 'type' }     else { '' }

  $rows.Add([PSCustomObject]@{
    SiteName       = Get-Prop $device 'siteName'
    SiteUid        = Get-Prop $device 'siteUid'
    Hostname       = Get-Prop $device 'hostname'
    Description    = Get-Prop $device 'description'
    DeviceUid      = Get-Prop $device 'uid'
    DeviceCategory = $category
    DeviceType     = $type
    InternalIP     = Get-Prop $device 'intIpAddress'
    ExternalIP     = Get-Prop $device 'extIpAddress'
    Online         = Get-Prop $device 'online' $false
    LastSeen       = if ((Get-Prop $device 'lastSeen') -ne '') {
                       [DateTimeOffset]::FromUnixTimeMilliseconds([long](Get-Prop $device 'lastSeen')).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
                     } else { '' }
    PortalUrl      = Get-Prop $device 'portalUrl'
  })
}

if ($rows.Count -eq 0) {
  Write-Step "No devices found matching filter '$FilterName'."
}
else {
  $rows | Sort-Object SiteName, Hostname |
    Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Encoding UTF8
  Write-Step "Report written to: $OutputCsvPath"
}
