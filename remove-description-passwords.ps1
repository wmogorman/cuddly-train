<#
.SYNOPSIS
  Scan IT Glue passwords for descriptions that might contain plaintext credentials.

.DESCRIPTION
  Fetches passwords for one or more IT Glue organizations and flags descriptions that look
  like they contain embedded passwords. Intended for Datto RMM or ad-hoc execution.

.PARAMETER ApiKey
  IT Glue API key. Defaults to $env:ITGlueKey for Datto RMM compatibility.

.PARAMETER OrgId
  Optional one or more IT Glue organization IDs. When omitted, the script scans every organization
  accessible to the API key.

.PARAMETER BaseUri
  Base API URL. Default: https://api.itglue.com.

.EXAMPLE
  # Datto RMM recommended invocation across all orgs
  PowerShell (no profile), 64-bit:
    -Command "& { . .\remove-description-passwords.ps1 }"

.EXAMPLE
  # Scan a specific organization
  PowerShell (no profile), 64-bit:
    -Command "& { . .\remove-description-passwords.ps1 -OrgId 12345 }"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$false)]
  [string]$ApiKey = $env:ITGlueKey,

  [Parameter(Mandatory=$false)]
  [string[]]$OrgId,

  [Parameter(Mandatory=$false)]
  [string]$BaseUri = 'https://api.itglue.com'
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
    $Body
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

  Invoke-RestMethod @invokeParams
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

function Get-ITGluePasswords {
  param(
    [string]$ApiKey,
    [string]$BaseUri,
    [string]$OrgId
  )

  $headers = @{
    'x-api-key' = $ApiKey
    'Accept'    = 'application/vnd.api+json'
  }

  $encodedOrgId = [System.Uri]::EscapeDataString([string]$OrgId)
  $uri = '{0}/passwords?filter[organization_id]={1}&page[size]=1000' -f $BaseUri, $encodedOrgId
  $results = @()

  while ($true) {
    try {
      $response = Invoke-ITGlueRequest -Uri $uri -Method 'GET' -Headers $headers
    }
    catch {
      $statusCode = $null
      if ($_.Exception -and $_.Exception.Response -and $_.Exception.Response.StatusCode) {
        $statusCode = [int]$_.Exception.Response.StatusCode
      }

      if ($statusCode -eq 404) {
        Write-Warning ("Passwords endpoint returned 404 for organization {0}. Skipping." -f $OrgId)
        break
      }

      throw
    }

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

function Test-DescriptionForPassword {
  param([string]$Description)

  if ([string]::IsNullOrWhiteSpace($Description)) {
    return $false
  }

  if ($Description -match '(?i)password') {
    return $true
  }

  return $false
}

$organizations = Get-ITGlueOrganizations -ApiKey $ApiKey -BaseUri $BaseUri -OrgIds $OrgId
if (-not $organizations) {
  Write-Warning 'No organizations found to scan.'
  return
}

$report = @()

foreach ($org in $organizations) {
  Write-Verbose "Scanning organization $($org.Id) - $($org.Name)"
  $passwords = Get-ITGluePasswords -ApiKey $ApiKey -BaseUri $BaseUri -OrgId $org.Id

  foreach ($pw in $passwords) {
    $desc = $pw.attributes.description
    if (Test-DescriptionForPassword -Description $desc) {
      $report += [PSCustomObject]@{
        OrgId        = $org.Id
        OrgName      = $org.Name
        PasswordName = $pw.attributes.name
        Description  = $desc
        PasswordID   = $pw.id
      }
    }
  }
}

$report | Export-Csv -Path 'C:\itglue-passwords-to-investigate.csv' -NoTypeInformation
Write-Host 'Report generated: C:\itglue-passwords-to-investigate.csv'
