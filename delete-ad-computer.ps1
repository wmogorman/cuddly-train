<# 
.SYNOPSIS
  Deletes IT Glue Flexible Assets of a given type (default: "AD Computer") in controlled batches.

.DESCRIPTION
  Designed for hourly runs in Datto RMM. Each run deletes up to -MaxPerRun assets, so you can
  safely chip away without blasting the API or nuking everything at once.

.PARAMETER ApiKey
  IT Glue API key. If omitted, the script will use $env:ITG_API_KEY.

.PARAMETER Subdomain
  Your IT Glue account subdomain (the “x-account-subdomain” header).

.PARAMETER AssetTypeName
  Flexible Asset Type name. Default: "AD Computer".

.PARAMETER OrgId
  Optional: limit deletions to a single IT Glue organization ID.

.PARAMETER MaxPerRun
  Max records to delete in this run. Default: 200.

.PARAMETER PageSize
  How many assets to fetch per list call. Default: 200.

.PARAMETER BaseUri
  Base API URL. Default: https://api.itglue.com

.EXAMPLE
  .\Delete-AdComputers.ps1 -Subdomain "datamax" -MaxPerRun 200

.EXAMPLE (Datto RMM recommended)
  PowerShell (no profile), 64-bit:
    -Command "& { . .\Delete-AdComputers.ps1 -Subdomain 'datamax' -MaxPerRun 200 -WhatIf:$false }"
  Store API key as a Site or Global variable and expose to the script via $env:ITG_API_KEY.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory=$false)]
  [string]$ApiKey = $env:ITG_API_KEY,

  [Parameter(Mandatory=$true)]
  [string]$Subdomain,

  [Parameter(Mandatory=$false)]
  [string]$AssetTypeName = 'AD Computer',

  [Parameter(Mandatory=$false)]
  [Nullable[int]]$OrgId,

  [Parameter(Mandatory=$false)]
  [int]$MaxPerRun = 200,

  [Parameter(Mandatory=$false)]
  [int]$PageSize = 200,

  [Parameter(Mandatory=$false)]
  [string]$BaseUri = 'https://api.itglue.com'
)

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
  throw "Missing API key. Pass -ApiKey or set env var ITG_API_KEY."
}

# --- Helpers -----------------------------------------------------------------

function Invoke-ITGlue {
  param(
    [Parameter(Mandatory=$true)] [string]$Method,
    [Parameter(Mandatory=$true)] [string]$Path,
    [Parameter(Mandatory=$false)] [hashtable]$Query,
    [Parameter(Mandatory=$false)] $Body,
    [int]$MaxRetries = 5
  )

  $headers = @{
    'x-api-key'            = $ApiKey
    'x-account-subdomain'  = $Subdomain
    'Content-Type'         = 'application/vnd.api+json'
    'Accept'               = 'application/vnd.api+json'
  }

  # Build URL
  $uriBuilder = [System.UriBuilder]::new(($BaseUri.TrimEnd('/') + '/' + $Path.TrimStart('/')))
  if ($Query) {
    $pairs = @()
    foreach ($k in $Query.Keys) {
      # Support nested query keys like "filter[flexible_asset_type_id]"
      $pairs += ('{0}={1}' -f [System.Uri]::EscapeDataString($k), [System.Uri]::EscapeDataString([string]$Query[$k]))
    }
    $uriBuilder.Query = [string]::Join('&',$pairs)
  }
  $uri = $uriBuilder.Uri.AbsoluteUri

  $attempt = 0
  $delay   = 1
  do {
    try {
      if ($Method -eq 'GET')   { return Invoke-RestMethod -Method Get    -Uri $uri -Headers $headers -ErrorAction Stop }
      if ($Method -eq 'DELETE'){ return Invoke-RestMethod -Method Delete -Uri $uri -Headers $headers -ErrorAction Stop }
      if ($Method -eq 'POST' -or $Method -eq 'PATCH') {
        $json = ($Body | ConvertTo-Json -Depth 20)
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $json -ErrorAction Stop
      }
      throw "Unsupported method: $Method"
    }
    catch {
      $attempt++
      $resp = $_.Exception.Response
      $statusCode = $null
      if ($resp -and $resp.StatusCode) { $statusCode = [int]$resp.StatusCode }
      # Retry on 429 or 5xx
      if (($statusCode -eq 429) -or ($statusCode -ge 500 -and $statusCode -lt 600)) {
        Start-Sleep -Seconds $delay
        $delay = [Math]::Min(30, [int]([Math]::Ceiling($delay * 1.8)))
        continue
      }
      throw
    }
  } while ($attempt -le $MaxRetries)
}

function Get-FlexTypeIdByName {
  param([string]$name)
  $result = Invoke-ITGlue -Method GET -Path "flexible_asset_types" -Query @{ 'filter[name]' = $name; 'page[size]' = 1 }
  $id = $result.data.attributes.id
  if (-not $id) {
    # Some tenants return id in data[0].id
    if ($result.data -and $result.data[0]) {
      return [int]$result.data[0].id
    }
    throw "Flexible Asset Type '$name' not found."
  }
  return [int]$id
}

function Get-FlexAssetsBatch {
  param(
    [int]$typeId,
    [int]$pageSize,
    [int]$pageNumber,
    [Nullable[int]]$orgId
  )
  $q = @{
    'filter[flexible_asset_type_id]' = $typeId
    'page[size]' = $pageSize
    'page[number]' = $pageNumber
    # Optional: stable sort so consecutive runs progress consistently
    'sort' = 'created_at'
  }
  if ($orgId.HasValue) { $q['filter[organization_id]'] = $orgId.Value }
  $res = Invoke-ITGlue -Method GET -Path "flexible_assets" -Query $q
  return $res.data
}

# --- Main --------------------------------------------------------------------

try {
  Write-Verbose "Resolving Flexible Asset Type ID for '$AssetTypeName'..."
  $typeId = Get-FlexTypeIdByName -name $AssetTypeName
  Write-Verbose "Type '$AssetTypeName' => ID $typeId"

  $deleted = 0
  $page    = 1

  while ($deleted -lt $MaxPerRun) {
    $batch = Get-FlexAssetsBatch -typeId $typeId -pageSize $PageSize -pageNumber $page -orgId $OrgId
    if (-not $batch -or $batch.Count -eq 0) {
      Write-Output "No more '$AssetTypeName' assets to process."
      break
    }

    foreach ($asset in $batch) {
      if ($deleted -ge $MaxPerRun) { break }

      $id   = $asset.id
      $name = $asset.attributes.'name'
      $org  = $asset.relationships.'organization'.data.id

      $target = "flexible_assets/$id"
      $caption = "Delete $AssetTypeName (ID=$id, OrgId=$org, Name='$name')"

      if ($PSCmdlet.ShouldProcess($caption, 'DELETE')) {
        try {
          Invoke-ITGlue -Method DELETE -Path $target | Out-Null
          $deleted++
          Write-Output "[DELETED] $caption"
        }
        catch {
          Write-Warning "[SKIPPED] $caption -> $($_.Exception.Message)"
        }
      } else {
        Write-Output "[WHATIF] Would delete: $caption"
      }
    }

    if ($deleted -ge $MaxPerRun) { break }
    # Advance to next page only if we fully consumed this one
    $page++
  }

  Write-Output "Run complete. Deleted this run: $deleted  | MaxPerRun: $MaxPerRun  | Type: '$AssetTypeName'  | Org filter: $(if ($PSBoundParameters.ContainsKey('OrgId') -and $null -ne $OrgId) { $OrgId } else { 'None' })"
}
catch {
  Write-Error $_
  exit 1
}
