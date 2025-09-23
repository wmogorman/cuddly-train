<#
.SYNOPSIS
  Lists IT Glue flexible asset types and reports how many flexible assets exist for each.

.DESCRIPTION
  Intentionally designed for Datto RMM (or ad-hoc runs). Provide your IT Glue subdomain and API key
  (or store the key in the ITGlueKey environment variable). The script pages through all flexible asset
  types, queries each type for its total asset count, and writes the results as objects so Datto can
  capture them. Summary lines at the end show aggregate counts.

.PARAMETER ApiKey
  IT Glue API key. Defaults to $env:ITGlueKey for Datto RMM compatibility.

.PARAMETER Subdomain
  Your IT Glue account subdomain (value for the x-account-subdomain header).

.PARAMETER OrgId
  Optional comma-separated list (or array) of organization IDs to filter the asset counts.

.PARAMETER BaseUri
  Base IT Glue API URI. Default: https://api.itglue.com.

.PARAMETER PageSize
  Number of flexible asset types to request per page. Default: 100.

.EXAMPLE
  # Datto RMM recommended invocation
  PowerShell (no profile), 64-bit:
    -Command "& { . .\flexible-asset-types.ps1 -Subdomain 'datamax' }"

.EXAMPLE
  # Limit counts to a specific organization
  PowerShell (no profile), 64-bit:
    -Command "& { . .\flexible-asset-types.ps1 -Subdomain 'datamax' -OrgId 12345 }"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$false)]
  [string]$ApiKey = $env:ITGlueKey,

  [Parameter(Mandatory=$true)]
  [string]$Subdomain,

  [Parameter(Mandatory=$false)]
  [string[]]$OrgId,

  [Parameter(Mandatory=$false)]
  [string]$BaseUri = 'https://api.itglue.com',

  [Parameter(Mandatory=$false)]
  [int]$PageSize = 100
)

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
  throw 'Missing API key. Pass -ApiKey or set env var ITGlueKey.'
}

if ($PageSize -le 0) {
  throw '-PageSize must be greater than zero.'
}

$BaseUri = $BaseUri.TrimEnd('/')

$script:ApiHeaders = @{
  'x-api-key'           = $ApiKey
  'x-account-subdomain' = $Subdomain
  'Accept'              = 'application/vnd.api+json'
}

function Invoke-ITGlue {
  param(
    [Parameter(Mandatory=$true)] [string]$Method,
    [Parameter(Mandatory=$true)] [string]$Path,
    [hashtable]$Query,
    [int]$MaxRetries = 5
  )

  $uriBuilder = [System.UriBuilder]::new(($BaseUri + '/' + $Path.TrimStart('/')))
  if ($Query) {
    $pairs = foreach ($key in $Query.Keys) {
      '{0}={1}' -f [System.Uri]::EscapeDataString($key), [System.Uri]::EscapeDataString([string]$Query[$key])
    }
    $uriBuilder.Query = [string]::Join('&', $pairs)
  }
  $uri = $uriBuilder.Uri.AbsoluteUri

  $attempt = 0
  $delay   = 1
  do {
    try {
      return Invoke-RestMethod -Method $Method -Uri $uri -Headers $script:ApiHeaders -ErrorAction Stop
    }
    catch {
      $attempt++
      $resp = $_.Exception.Response
      $statusCode = $null
      if ($resp -and $resp.StatusCode) { $statusCode = [int]$resp.StatusCode }
      if ($attempt -lt $MaxRetries -and (($statusCode -eq 429) -or ($statusCode -ge 500 -and $statusCode -lt 600))) {
        Start-Sleep -Seconds $delay
        $delay = [Math]::Min(30, [int][Math]::Ceiling($delay * 1.5))
        continue
      }
      throw
    }
  } while ($attempt -lt $MaxRetries)
}

function Get-FlexibleAssetTypes {
  param([int]$PageSize)

  $results    = @()
  $pageNumber = 1

  while ($true) {
    $query = @{
      'page[size]'   = [string]$PageSize
      'page[number]' = [string]$pageNumber
      'sort'         = 'name'
    }

    $response = Invoke-ITGlue -Method 'GET' -Path 'flexible_asset_types' -Query $query
    $data     = $response.data

    if (-not $data -or $data.Count -eq 0) { break }

    $results += $data

    $hasNext = $false
    if ($response.links -and $response.links.next) {
      $nextLink = [string]$response.links.next
      if (-not [string]::IsNullOrWhiteSpace($nextLink)) { $hasNext = $true }
    }

    if (-not $hasNext) { break }

    $pageNumber++
  }

  return $results
}

function Get-FlexibleAssetCount {
  param(
    [Parameter(Mandatory=$true)] [int]$TypeId,
    [string]$OrgFilterValue
  )

  $query = @{
    'filter[flexible_asset_type_id]' = [string]$TypeId
    'page[size]'                     = '1'
    'page[number]'                   = '1'
  }

  if (-not [string]::IsNullOrWhiteSpace($OrgFilterValue)) {
    $query['filter[organization_id]'] = $OrgFilterValue
  }

  $response = Invoke-ITGlue -Method 'GET' -Path 'flexible_assets' -Query $query

  if ($response.meta) {
    if ($response.meta.total) { return [int]$response.meta.total }
    if ($response.meta.'total-count') { return [int]$response.meta.'total-count' }
    if ($response.meta.'record-count') { return [int]$response.meta.'record-count' }
  }

  if ($response.data) {
    return ($response.data | Measure-Object).Count
  }

  return 0
}

$types = Get-FlexibleAssetTypes -PageSize $PageSize
if (-not $types -or $types.Count -eq 0) {
  Write-Warning 'No flexible asset types returned.'
  return
}

$orgFilterValue = $null
if ($OrgId) {
  $orgFilterValue = ($OrgId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ','
}

$results = foreach ($type in $types) {
  $typeId = 0
  if ($type.id) { $typeId = [int]$type.id }

  if ($typeId -le 0) {
    Write-Warning 'Skipping flexible asset type missing a numeric ID.'
    continue
  }

  $name  = [string]$type.attributes.name
  Write-Verbose ("Counting assets for type {0} ({1})" -f $typeId, $name)

  $count = Get-FlexibleAssetCount -TypeId $typeId -OrgFilterValue $orgFilterValue

  [PSCustomObject]@{
    Id         = $typeId
    Name       = $name
    AssetCount = $count
  }
}

$results = $results | Where-Object { $_ -ne $null }
$sorted  = $results | Sort-Object -Property Name
$sorted

$totalAssets = ($results | Measure-Object -Property AssetCount -Sum).Sum
Write-Output ('Total flexible asset types: {0}' -f $results.Count)
Write-Output ('Aggregate flexible asset count: {0}' -f $totalAssets)
