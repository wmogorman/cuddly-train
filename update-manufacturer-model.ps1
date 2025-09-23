<#
.SYNOPSIS
  Populate manufacturer and model on IT Glue configuration items that are missing those fields.

.DESCRIPTION
  Looks through configurations for one or more organizations, trying to infer manufacturer
  and model values from the description or notes fields. Designed for Datto RMM or ad-hoc execution.

.PARAMETER ApiKey
  IT Glue API key. Defaults to $env:ITGlueKey for Datto RMM compatibility.

.PARAMETER OrgId
  Optional one or more IT Glue organization IDs. When omitted, every accessible organization is scanned.

.PARAMETER BaseUri
  Base API URL. Default: https://api.itglue.com.

.PARAMETER PageSize
  Number of configuration records to pull per request. Default: 100.

.EXAMPLE
  PowerShell (no profile), 64-bit:
    -Command "& { . .\update-manufacturer-model.ps1 }"

.EXAMPLE
  PowerShell (no profile), 64-bit:
    -Command "& { . .\update-manufacturer-model.ps1 -OrgId 12345 -Verbose }"
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [Parameter(Mandatory=$false)]
  [string]$ApiKey = $env:ITGlueKey,

  [Parameter(Mandatory=$false)]
  [string[]]$OrgId,

  [Parameter(Mandatory=$false)]
  [string]$BaseUri = 'https://api.itglue.com',

  [Parameter(Mandatory=$false)]
  [ValidateRange(1,1000)]
  [int]$PageSize = 100
)

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
  throw 'Missing API key. Pass -ApiKey or set env var ITGlueKey.'
}

$BaseUri = $BaseUri.TrimEnd('/')

function Invoke-ITGlueRequest {
  param(
    [Parameter(Mandatory=$true)] [string]$Uri,
    [Parameter(Mandatory=$true)] [string]$Method,
    [hashtable]$Headers,
    $Body,
    [string]$ContentType
  )

  $invokeParams = @{
    Uri         = $Uri
    Method      = $Method
    Headers     = $Headers
    ErrorAction = 'Stop'
  }

  if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
    $invokeParams['Body'] = $Body
  }

  if ($PSBoundParameters.ContainsKey('ContentType') -and -not [string]::IsNullOrWhiteSpace($ContentType)) {
    $invokeParams['ContentType'] = $ContentType
  }

  try {
    Invoke-RestMethod @invokeParams
  }
  catch {
    $message = $_.Exception.Message
    if ($_.Exception.Response -and $_.Exception.Response.ResponseUri) {
      $message = "{0} (URI: {1})" -f $message, $_.Exception.Response.ResponseUri
    }
    throw (New-Object System.Exception("IT Glue request failed: $message", $_.Exception))
  }
}

function Get-ITGlueOrganizations {
  param(
    [string]$ApiKey,
    [string]$BaseUri,
    [string[]]$OrgIds
  )

  $headers = @{
    'x-api-key' = $ApiKey
    'Accept'    = 'application/vnd.api+json'
  }

  $results = @()

  if ($OrgIds -and $OrgIds.Count -gt 0) {
    foreach ($id in $OrgIds) {
      $uri = '{0}/organizations/{1}' -f $BaseUri, $id
      try {
        $response = Invoke-ITGlueRequest -Uri $uri -Method 'GET' -Headers $headers
        if ($response.data) {
          $results += [PSCustomObject]@{
            Id   = [string]$response.data.id
            Name = [string]$response.data.attributes.name
          }
        }
      }
      catch {
        Write-Warning ("Failed to retrieve organization {0}: {1}" -f $id, $_.Exception.Message)
      }
    }

    return $results | Sort-Object -Property Id -Unique
  }

  $uri = '{0}/organizations?page[size]=1000' -f $BaseUri
  do {
    $response = Invoke-ITGlueRequest -Uri $uri -Method 'GET' -Headers $headers
    if ($response.data) {
      foreach ($org in $response.data) {
        $results += [PSCustomObject]@{
          Id   = [string]$org.id
          Name = [string]$org.attributes.name
        }
      }
    }

    $uri = $response.links.next
  } while ($uri)

  return $results | Sort-Object -Property Id -Unique
}

function Get-ITGlueConfigurations {
  param(
    [string]$ApiKey,
    [string]$BaseUri,
    [string]$OrgId,
    [int]$PageSize
  )

  $headers = @{
    'x-api-key' = $ApiKey
    'Accept'    = 'application/vnd.api+json'
  }

  $encodedOrgId = [System.Uri]::EscapeDataString([string]$OrgId)
  $uri = '{0}/configurations?filter[organization_id]={1}&page[size]={2}' -f $BaseUri, $encodedOrgId, $PageSize
  $results = @()

  while ($true) {
    $response = Invoke-ITGlueRequest -Uri $uri -Method 'GET' -Headers $headers
    if ($response.data) {
      $results += $response.data
    }

    if (-not $response.links -or [string]::IsNullOrWhiteSpace([string]$response.links.next)) {
      break
    }

    $uri = [string]$response.links.next
  }

  return $results
}

function Get-FirstMatchValue {
  param(
    [string]$Text,
    [string[]]$Keywords
  )

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return $null
  }

  foreach ($keyword in $Keywords) {
    $pattern = '(?im)^\s*{0}\s*[:=-]\s*(.+)$' -f [regex]::Escape($keyword)
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) {
      return $match.Groups[1].Value.Trim()
    }
  }

  return $null
}

function Extract-ManufacturerModel {
  param(
    [string]$Description,
    [string]$Notes
  )

  $manufacturer = $null
  $model = $null
  $sources = @()
  if (-not [string]::IsNullOrWhiteSpace($Description)) {
    $sources += $Description
  }
  if (-not [string]::IsNullOrWhiteSpace($Notes)) {
    $sources += $Notes
  }

  foreach ($source in $sources) {
    if (-not $manufacturer) {
      $manufacturer = Get-FirstMatchValue -Text $source -Keywords @('Manufacturer','Vendor','Make')
    }
    if (-not $model) {
      $model = Get-FirstMatchValue -Text $source -Keywords @('Model','Product Model')
    }

    if ($manufacturer -and $model) {
      break
    }
  }

  [PSCustomObject]@{
    Manufacturer = $manufacturer
    Model        = $model
  }
}

function Update-ITGlueConfiguration {
  param(
    [string]$ApiKey,
    [string]$BaseUri,
    [string]$ItemId,
    [hashtable]$Attributes
  )

  if (-not $Attributes -or $Attributes.Count -eq 0) {
    return
  }

  $headers = @{
    'x-api-key'    = $ApiKey
    'Accept'       = 'application/vnd.api+json'
    'Content-Type' = 'application/vnd.api+json'
  }

  $body = @{
    data = @{
      type       = 'configurations'
      id         = [string]$ItemId
      attributes = $Attributes
    }
  } | ConvertTo-Json -Depth 5

  $uri = '{0}/configurations/{1}' -f $BaseUri, [System.Uri]::EscapeDataString([string]$ItemId)
  Invoke-ITGlueRequest -Uri $uri -Method 'PATCH' -Headers $headers -Body $body -ContentType 'application/vnd.api+json'
}

$organizations = Get-ITGlueOrganizations -ApiKey $ApiKey -BaseUri $BaseUri -OrgIds $OrgId
if (-not $organizations) {
  Write-Warning 'No organizations found to scan.'
  return
}

$updates = @()

foreach ($org in $organizations) {
  Write-Verbose "Scanning organization $($org.Id) - $($org.Name)"
  $items = Get-ITGlueConfigurations -ApiKey $ApiKey -BaseUri $BaseUri -OrgId $org.Id -PageSize $PageSize

  foreach ($item in $items) {
    $currentManufacturer = $item.attributes.manufacturer
    $currentModel = $item.attributes.model
    $needsManufacturer = [string]::IsNullOrWhiteSpace($currentManufacturer)
    $needsModel = [string]::IsNullOrWhiteSpace($currentModel)

    if (-not ($needsManufacturer -or $needsModel)) {
      continue
    }

    $extracted = Extract-ManufacturerModel -Description $item.attributes.description -Notes $item.attributes.notes
    $attributesToUpdate = @{}

    if ($needsManufacturer -and -not [string]::IsNullOrWhiteSpace($extracted.Manufacturer)) {
      $attributesToUpdate['manufacturer'] = $extracted.Manufacturer
    }
    if ($needsModel -and -not [string]::IsNullOrWhiteSpace($extracted.Model)) {
      $attributesToUpdate['model'] = $extracted.Model
    }

    if ($attributesToUpdate.Count -eq 0) {
      continue
    }

    $target = '{0} ({1})' -f $item.attributes.name, $org.Name
    if ($PSCmdlet.ShouldProcess($target, 'Update manufacturer/model')) {
      try {
        Update-ITGlueConfiguration -ApiKey $ApiKey -BaseUri $BaseUri -ItemId $item.id -Attributes $attributesToUpdate
        $updates += [PSCustomObject]@{
          OrgId         = $org.Id
          OrgName       = $org.Name
          Configuration = $item.attributes.name
          Manufacturer  = $attributesToUpdate.manufacturer
          Model         = $attributesToUpdate.model
          ItemId        = $item.id
        }
      }
      catch {
        Write-Warning ("Failed to update configuration item {0} ({1}): {2}" -f $item.id, $target, $_.Exception.Message)
      }
    }
  }
}

if ($updates.Count -gt 0) {
  $exportPath = 'C:\itglue-configuration-updates.csv'
  $updates | Export-Csv -Path $exportPath -NoTypeInformation
  Write-Host ("Updated {0} configuration item(s). Report: {1}" -f $updates.Count, $exportPath)
}
else {
  Write-Host 'No configuration items required updates.'
}
