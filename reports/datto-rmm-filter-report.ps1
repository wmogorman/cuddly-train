<#
.SYNOPSIS
  Lists all custom (and optionally default) device filters in Datto RMM and
  exports them to CSV, including a device count per filter.

.DESCRIPTION
  Authenticates against the Datto RMM REST API using OAuth 2.0 and retrieves
  all custom device filters available to the authenticated account.

  Each row in the CSV includes:
    FilterType    - "Custom" or "Default"
    FilterId      - Numeric ID, usable as the filterId query param in other calls
    FilterName    - Display name of the filter
    Description   - Filter description (if set)
    DeviceCount   - Number of devices currently matched by this filter
    DateCreated   - When the filter was created
    LastUpdated   - When the filter was last modified

  NOTE ON API LIMITATIONS
  The Datto RMM REST API (v2) does NOT expose:
    - Filter criteria/rules (what conditions the filter evaluates)
    - Policy definitions or which policies target a given filter
    - Job/component schedules and their filter associations
  These are only accessible through the RMM web UI. This script reports
  everything the API makes available about filters.

.PARAMETER ApiKey
  Datto RMM API key.  Can also be supplied via the DATTO_RMM_API_KEY
  environment variable or an -EnvFile.

.PARAMETER ApiSecretKey
  Datto RMM API secret key.  Can also be supplied via DATTO_RMM_API_SECRET
  or an -EnvFile.

.PARAMETER EnvFile
  Path to a .env file containing DATTO_RMM_API_KEY and DATTO_RMM_API_SECRET.

.PARAMETER ApiUrl
  Base URL for your Datto RMM platform.
  Defaults to https://zinfandel-api.centrastage.net

.PARAMETER OutputCsvPath
  Path for the output CSV file.  Defaults to datto-rmm-filters.csv in the
  current directory.

.PARAMETER IncludeDefault
  When set, the built-in (default) Datto RMM filters are also included in
  the report alongside custom filters.

.PARAMETER SkipDeviceCount
  Skip the per-filter device count lookup.  Use this for a faster run when
  you have many filters and only need names and IDs.

.EXAMPLE
  .\datto-rmm-filter-report.ps1 -ApiKey XXXX -ApiSecretKey YYYY

.EXAMPLE
  .\datto-rmm-filter-report.ps1 -EnvFile .\datto-rmm.env -IncludeDefault

.EXAMPLE
  .\datto-rmm-filter-report.ps1 -EnvFile .\datto-rmm.env -SkipDeviceCount -OutputCsvPath C:\reports\filters.csv
#>

[CmdletBinding()]
param(
  [string] $ApiKey,
  [string] $ApiSecretKey,
  [string] $EnvFile,
  [string] $ApiUrl        = "https://zinfandel-api.centrastage.net",
  [string] $OutputCsvPath = "",
  [switch] $IncludeDefault,
  [switch] $SkipDeviceCount
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$artifactsDir = Join-Path (Split-Path $PSCommandPath -Parent) "artifacts\datto-rmm"
if (-not (Test-Path $artifactsDir)) { New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null }
if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) { $OutputCsvPath = Join-Path $artifactsDir "datto-rmm-filters.csv" }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
  param([string] $Message)
  Write-Host "[datto-rmm-filter-report] $Message"
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

function Get-AllFilters {
  param([string] $BaseUrl, [string] $Token, [string] $Endpoint)

  $all  = [System.Collections.Generic.List[object]]::new()
  $page = 0

  do {
    $uri      = "$BaseUrl/api$Endpoint`?max=250&page=$page"
    $response = Invoke-RmmApi -Uri $uri -Token $Token

    $batch = if ($null -ne $response.filters) { $response.filters }
             elseif ($response -is [array])    { $response }
             else                              { @() }

    foreach ($item in $batch) { $all.Add($item) }

    $nextUrl = if ($null -ne $response.pageDetails) { $response.pageDetails.nextPageUrl } else { $null }
    $page++

  } while (-not [string]::IsNullOrWhiteSpace($nextUrl))

  return $all
}

function Get-FilterDeviceCount {
  param([string] $BaseUrl, [string] $Token, [int] $FilterId)
  try {
    $response = Invoke-RmmApi -Uri "$BaseUrl/api/v2/account/devices?filterId=$FilterId&max=1&page=0" -Token $Token
    if ($null -ne $response.pageDetails -and $null -ne $response.pageDetails.totalCount) {
      return [int]$response.pageDetails.totalCount
    }
    return 0
  }
  catch {
    Write-Warning "Could not get device count for filter $FilterId : $_"
    return -1
  }
}

function ConvertFrom-UnixMs {
  param([object] $Ms)
  if ($null -eq $Ms -or $Ms -eq 0) { return "" }
  return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Ms).LocalDateTime.ToString("yyyy-MM-dd HH:mm")
}

# ---------------------------------------------------------------------------
# Credential resolution (params > env vars > .env file)
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

$rows = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-FilterRows {
  param([object[]] $Filters, [string] $FilterType)

  $i = 0
  foreach ($f in $Filters) {
    $i++
    $deviceCount = if ($SkipDeviceCount) { "" }
                   else {
                     Write-Step "  [$i/$($Filters.Count)] Getting device count for: $($f.name)"
                     Get-FilterDeviceCount -BaseUrl $ApiUrl -Token $token -FilterId $f.id
                   }

    $rows.Add([PSCustomObject]@{
      FilterType   = $FilterType
      FilterId     = $f.id
      FilterName   = $f.name
      Description  = if ($null -ne $f.description) { $f.description } else { "" }
      DeviceCount  = $deviceCount
      DateCreated  = ConvertFrom-UnixMs -Ms $f.dateCreate
      LastUpdated  = ConvertFrom-UnixMs -Ms $f.lastUpdated
    })
  }
}

Write-Step "Fetching custom filters ..."
$customFilters = Get-AllFilters -BaseUrl $ApiUrl -Token $token -Endpoint "/v2/filter/custom-filters"
Write-Step "  Found $($customFilters.Count) custom filter(s)."
Add-FilterRows -Filters $customFilters -FilterType "Custom"

if ($IncludeDefault) {
  Write-Step "Fetching default filters ..."
  $defaultFilters = Get-AllFilters -BaseUrl $ApiUrl -Token $token -Endpoint "/v2/filter/default-filters"
  Write-Step "  Found $($defaultFilters.Count) default filter(s)."
  Add-FilterRows -Filters $defaultFilters -FilterType "Default"
}

if ($rows.Count -eq 0) {
  Write-Warning "No filters found. The account may have no custom device filters defined."
}
else {
  $rows | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Encoding UTF8
  Write-Step "Exported $($rows.Count) filter(s) to: $OutputCsvPath"
  Write-Step ""
  Write-Step "NOTE: Filter criteria (rules) and policy/job associations are not"
  Write-Step "      exposed by the Datto RMM REST API. To view those, open the"
  Write-Step "      RMM web UI: Setup > Device Filters (criteria) or Policies."
}
