<#
.SYNOPSIS
  Update IT Glue contact locations based on location name prefix.

.DESCRIPTION
  Finds contacts in one or more organizations whose current location name starts
  with a provided prefix and updates them to a target location name.

.PARAMETER ApiKey
  IT Glue API key. Defaults to $env:ITGlueKey for Datto RMM compatibility.

.PARAMETER OrgId
  One or more IT Glue organization IDs to process.

.PARAMETER SourceLocationPrefix
  Location name prefix to match (case-insensitive). Contacts whose location name
  starts with this value will be updated.

.PARAMETER TargetLocationName
  Target location name to set (case-insensitive exact match).

.PARAMETER BaseUri
  Base API URL. Default: https://api.itglue.com.

.PARAMETER PageSize
  Number of records to pull per request. Default: 100.

.EXAMPLE
  PowerShell (no profile), 64-bit:
    -Command "& { . .\change-contact-location.ps1 -OrgId 12345 -SourceLocationPrefix 'HQ' -TargetLocationName 'Headquarters' -WhatIf }"
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [Parameter(Mandatory=$false)]
  [string]$ApiKey = $env:ITGlueKey,

  [Parameter(Mandatory=$true)]
  [string[]]$OrgId,

  [Parameter(Mandatory=$true)]
  [string]$SourceLocationPrefix,

  [Parameter(Mandatory=$true)]
  [string]$TargetLocationName,

  [Parameter(Mandatory=$false)]
  [string]$BaseUri = 'https://api.itglue.com',

  [Parameter(Mandatory=$false)]
  [ValidateRange(1,1000)]
  [int]$PageSize = 100
)

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
  throw 'Missing API key. Pass -ApiKey or set env var ITGlueKey.'
}

$SourceLocationPrefix = $SourceLocationPrefix.Trim()
$TargetLocationName = $TargetLocationName.Trim()

if ([string]::IsNullOrWhiteSpace($SourceLocationPrefix)) {
  throw 'SourceLocationPrefix cannot be empty.'
}

if ([string]::IsNullOrWhiteSpace($TargetLocationName)) {
  throw 'TargetLocationName cannot be empty.'
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

function Get-ITGlueLocations {
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
  $uri = '{0}/locations?filter[organization_id]={1}&page[size]={2}' -f $BaseUri, $encodedOrgId, $PageSize
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

function Get-ITGlueContacts {
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
  $uri = '{0}/contacts?filter[organization_id]={1}&page[size]={2}' -f $BaseUri, $encodedOrgId, $PageSize
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

function Update-ITGlueContactLocation {
  param(
    [string]$ApiKey,
    [string]$BaseUri,
    [string]$ContactId,
    [string]$LocationId
  )

  $headers = @{
    'x-api-key'    = $ApiKey
    'Accept'       = 'application/vnd.api+json'
    'Content-Type' = 'application/vnd.api+json'
  }

  $body = @{
    data = @{
      type = 'contacts'
      id   = [string]$ContactId
      relationships = @{
        location = @{
          data = @{
            type = 'locations'
            id   = [string]$LocationId
          }
        }
      }
    }
  } | ConvertTo-Json -Depth 6

  $uri = '{0}/contacts/{1}' -f $BaseUri, [System.Uri]::EscapeDataString([string]$ContactId)
  Invoke-ITGlueRequest -Uri $uri -Method 'PATCH' -Headers $headers -Body $body -ContentType 'application/vnd.api+json'
}

function Get-ContactDisplayName {
  param($Contact)

  $firstName = $Contact.attributes.'first-name'
  $lastName = $Contact.attributes.'last-name'
  if (-not [string]::IsNullOrWhiteSpace($firstName) -or -not [string]::IsNullOrWhiteSpace($lastName)) {
    return ("{0} {1}" -f $firstName, $lastName).Trim()
  }

  if ($Contact.attributes.name) {
    return [string]$Contact.attributes.name
  }

  return [string]$Contact.id
}

$organizations = Get-ITGlueOrganizations -ApiKey $ApiKey -BaseUri $BaseUri -OrgIds $OrgId
if (-not $organizations) {
  Write-Warning 'No organizations found to process.'
  return
}

$updates = @()

foreach ($org in $organizations) {
  Write-Verbose "Processing organization $($org.Id) - $($org.Name)"
  $locations = Get-ITGlueLocations -ApiKey $ApiKey -BaseUri $BaseUri -OrgId $org.Id -PageSize $PageSize

  if (-not $locations -or $locations.Count -eq 0) {
    Write-Warning ("No locations found for organization {0}. Skipping." -f $org.Name)
    continue
  }

  $locationsById = @{}
  foreach ($loc in $locations) {
    $locationsById[[string]$loc.id] = [string]$loc.attributes.name
  }

  $sourceLocations = $locations | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_.attributes.name) -and
    $_.attributes.name.StartsWith($SourceLocationPrefix, [System.StringComparison]::OrdinalIgnoreCase)
  }

  if (-not $sourceLocations -or $sourceLocations.Count -eq 0) {
    Write-Warning ("No locations starting with '{0}' found for {1}." -f $SourceLocationPrefix, $org.Name)
    continue
  }

  $targetLocations = $locations | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_.attributes.name) -and
    $_.attributes.name.Equals($TargetLocationName, [System.StringComparison]::OrdinalIgnoreCase)
  }

  if (-not $targetLocations -or $targetLocations.Count -eq 0) {
    Write-Warning ("Target location '{0}' not found for {1}." -f $TargetLocationName, $org.Name)
    continue
  }

  if ($targetLocations.Count -gt 1) {
    Write-Warning ("Multiple locations named '{0}' found for {1}. Skipping to avoid ambiguity." -f $TargetLocationName, $org.Name)
    continue
  }

  $targetLocation = $targetLocations[0]
  $sourceLocationIds = $sourceLocations | ForEach-Object { [string]$_.id }

  $contacts = Get-ITGlueContacts -ApiKey $ApiKey -BaseUri $BaseUri -OrgId $org.Id -PageSize $PageSize
  if (-not $contacts -or $contacts.Count -eq 0) {
    Write-Verbose ("No contacts found for {0}." -f $org.Name)
    continue
  }

  foreach ($contact in $contacts) {
    $locationId = $null
    if ($contact.relationships -and $contact.relationships.location -and $contact.relationships.location.data) {
      $locationId = [string]$contact.relationships.location.data.id
    }
    elseif ($contact.attributes -and $contact.attributes.'location-id') {
      $locationId = [string]$contact.attributes.'location-id'
    }

    if ([string]::IsNullOrWhiteSpace($locationId)) {
      continue
    }

    if ($sourceLocationIds -notcontains $locationId) {
      continue
    }

    if ($locationId -eq [string]$targetLocation.id) {
      continue
    }

    $fromLocationName = $locationsById[$locationId]
    $contactName = Get-ContactDisplayName -Contact $contact
    $target = "{0} ({1})" -f $contactName, $org.Name

    if ($PSCmdlet.ShouldProcess($target, "Update contact location to '$($targetLocation.attributes.name)'")) {
      try {
        Update-ITGlueContactLocation -ApiKey $ApiKey -BaseUri $BaseUri -ContactId $contact.id -LocationId $targetLocation.id
        $updates += [PSCustomObject]@{
          OrgId        = $org.Id
          OrgName      = $org.Name
          ContactId    = $contact.id
          ContactName  = $contactName
          FromLocation = $fromLocationName
          ToLocation   = $targetLocation.attributes.name
        }
      }
      catch {
        Write-Warning ("Failed to update contact {0} ({1}): {2}" -f $contact.id, $contactName, $_.Exception.Message)
      }
    }
  }
}

if ($updates.Count -gt 0) {
  $exportPath = 'C:\itglue-contact-location-changes.csv'
  $updates | Export-Csv -Path $exportPath -NoTypeInformation
  Write-Host ("Updated {0} contact(s). Report: {1}" -f $updates.Count, $exportPath)
}
else {
  Write-Host 'No contacts required updates.'
}
