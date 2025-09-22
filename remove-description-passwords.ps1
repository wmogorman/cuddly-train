<#
.SYNOPSIS
  Scan IT Glue passwords for descriptions that might contain plaintext credentials.

.DESCRIPTION
  Fetches all passwords for a given organization and flags descriptions that look like
  they contain embedded passwords. Intended for Datto RMM or ad-hoc execution.

.PARAMETER ApiKey
  IT Glue API key. Defaults to $env:ITGlueKey for Datto RMM compatibility.

.PARAMETER OrgId
  IT Glue organization ID to inspect.

.PARAMETER BaseUri
  Base API URL. Default: https://api.itglue.com.

.EXAMPLE
  # Datto RMM recommended invocation
  # Store the API key in a Global/Site credential exposed as $env:ITGlueKey
  PowerShell (no profile), 64-bit:
    -Command "& { . .\remove-description-passwords.ps1 -OrgId 12345 }"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$false)]
  [string]$ApiKey = $env:ITGlueKey,

  [Parameter(Mandatory=$true)]
  [string]$OrgId,

  [Parameter(Mandatory=$false)]
  [string]$BaseUri = 'https://api.itglue.com'
)

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
  throw 'Missing API key. Pass -ApiKey or set env var ITGlueKey.'
}

if ([string]::IsNullOrWhiteSpace($OrgId)) {
  throw 'Missing OrgId. Specify -OrgId to target an IT Glue organization.'
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

  $uri = '{0}/organizations/{1}/passwords?page[size]=1000' -f $BaseUri.TrimEnd('/'), $OrgId
  $results = @()

  do {
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    $results  += $response.data
    $uri       = $response.links.next
  } while ($uri)

  return $results
}

function Test-DescriptionForPassword {
  param([string]$Description)

  if ([string]::IsNullOrWhiteSpace($Description)) {
    return $false
  }

  $patterns = @(
    'password\s*is\s*[:=]?\s*\S+',
    'pwd\s*[:=]?\s*\S+',
    'pass\s*[:=]?\s*\S+',
    'pw\s*[:=]?\s*\S+'
  )

  foreach ($pattern in $patterns) {
    if ($Description -match $pattern) {
      return $true
    }
  }

  return $false
}

$passwords = Get-ITGluePasswords -ApiKey $ApiKey -BaseUri $BaseUri -OrgId $OrgId
$report = @()

foreach ($pw in $passwords) {
  $desc = $pw.attributes.description
  if (Test-DescriptionForPassword -Description $desc) {
    $report += [PSCustomObject]@{
      PasswordName = $pw.attributes.name
      Description  = $desc
      PasswordID   = $pw.id
    }
  }
}

$report | Export-Csv -Path './itglue-passwords-to-investigate.csv' -NoTypeInformation
Write-Host 'Report generated: itglue-passwords-to-investigate.csv'
