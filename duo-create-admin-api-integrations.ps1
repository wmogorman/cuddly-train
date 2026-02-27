<#
.SYNOPSIS
  Create a Duo Admin API integration across child accounts (MSP parent/child).

.DESCRIPTION
  Retrieves child accounts from the parent Accounts API application, then creates
  an Admin API integration in each targeted child account using:
    - adminapi_read_resource = 1
    - adminapi_allow_to_set_permissions = 1

  By default, the script skips creation when an Admin API integration with the
  same name already exists in a child account. Use -AllowDuplicates to force
  creation.

.REQUIREMENTS
  - Windows PowerShell 5.1+ (or PowerShell 7+)
  - Parent Accounts API application credentials (IKey/SKey/ParentApiHost)
  - Parent Accounts API app must have permission to call Admin API for children
#>

param(
  [Parameter(Mandatory)] [string] $ParentApiHost,
  [Parameter(Mandatory)] [string] $IKey,
  [Parameter(Mandatory)] [string] $SKey,

  [Parameter()] [string] $IntegrationName = "MSP Admin API",

  [string[]] $OnlyAccountIds,
  [string[]] $OnlyAccountNames,

  [switch] $AllowDuplicates,
  [switch] $WhatIf,

  # Output includes integration keys and (for newly created integrations) secret keys.
  [string] $OutputCsvPath = ".\duo-admin-api-integrations.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($IKey)) {
  throw "IKey cannot be empty."
}
if ([string]::IsNullOrWhiteSpace($SKey)) {
  throw "SKey cannot be empty."
}
if ([string]::IsNullOrWhiteSpace($IntegrationName)) {
  throw "IntegrationName cannot be empty."
}

function Resolve-DuoHost {
  param([Parameter(Mandatory)][string] $HostOrUrl)

  $value = $HostOrUrl.Trim()
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Host value is empty."
  }

  if ($value -match '^[a-zA-Z][a-zA-Z0-9+\-.]*://') {
    try {
      return ([System.Uri]$value).Host
    } catch {
      throw "Invalid host/URL value: $HostOrUrl"
    }
  }

  if ($value.Contains('/')) {
    $value = $value.Split('/')[0]
  }

  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Invalid host value: $HostOrUrl"
  }

  return $value
}

function ConvertTo-DuoUrlEncode {
  param([Parameter(Mandatory)][string] $Value)

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
  $sb = New-Object System.Text.StringBuilder

  foreach ($b in $bytes) {
    $ch = [char]$b
    $isUnreserved =
      ($b -ge 0x41 -and $b -le 0x5A) -or
      ($b -ge 0x61 -and $b -le 0x7A) -or
      ($b -ge 0x30 -and $b -le 0x39) -or
      ($ch -eq '_') -or ($ch -eq '.') -or ($ch -eq '~') -or ($ch -eq '-')

    if ($isUnreserved) {
      [void]$sb.Append($ch)
    } else {
      [void]$sb.AppendFormat("%{0:X2}", $b)
    }
  }

  return $sb.ToString()
}

function Get-DuoParamsString {
  param([hashtable] $Params)

  $pairs = foreach ($k in ($Params.Keys | Sort-Object)) {
    $ek = ConvertTo-DuoUrlEncode -Value ([string]$k)
    $ev = ConvertTo-DuoUrlEncode -Value ([string]$Params[$k])
    "$ek=$ev"
  }

  return ($pairs -join "&")
}

function New-DuoAuthHeaders {
  param(
    [Parameter(Mandatory)][string] $Method,
    [Parameter(Mandatory)][string] $ApiHost,
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][hashtable] $Params,
    [Parameter(Mandatory)][string] $IKey,
    [Parameter(Mandatory)][string] $SKey
  )

  $date = [System.DateTimeOffset]::UtcNow.ToString("r")
  $paramsLine = Get-DuoParamsString -Params $Params
  $canon = @(
    $date
    $Method.ToUpperInvariant()
    $ApiHost.ToLowerInvariant()
    $Path
    $paramsLine
  ) -join "`n"

  $hmac = New-Object System.Security.Cryptography.HMACSHA1 -ArgumentList (,([System.Text.Encoding]::UTF8.GetBytes($SKey)))
  $sigBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canon))
  $sigHex = -join ($sigBytes | ForEach-Object { $_.ToString("x2") })
  $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$IKey`:$sigHex"))

  return @{
    "Date"          = $date
    "Authorization" = "Basic $basic"
    "Host"          = $ApiHost
  }
}

function Invoke-DuoApi {
  param(
    [Parameter(Mandatory)][ValidateSet("GET","POST","DELETE")] [string] $Method,
    [Parameter(Mandatory)][string] $ApiHost,
    [Parameter(Mandatory)][string] $Path,
    [hashtable] $Params = @{}
  )

  $headers = New-DuoAuthHeaders -Method $Method -ApiHost $ApiHost -Path $Path -Params $Params -IKey $IKey -SKey $SKey
  $uri = "https://$ApiHost$Path"
  $isAccountDiscoveryCall = ($Path -eq "/accounts/v1/account/list")

  if ($WhatIf -and -not $isAccountDiscoveryCall) {
    $paramsPreview = Get-DuoParamsString -Params $Params
    Write-Host "[WHATIF] $Method $uri params: $paramsPreview"
    return $null
  }

  try {
    if ($Method -in @("GET","DELETE")) {
      $qs = Get-DuoParamsString -Params $Params
      if ($qs) {
        $uri = "$uri`?$qs"
      }
      return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
    }

    $body = Get-DuoParamsString -Params $Params
    return Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -ContentType "application/x-www-form-urlencoded" -Body $body
  } catch {
    $message = $_.Exception.Message
    if ($_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
      $message = "{0} Response: {1}" -f $message, $_.ErrorDetails.Message
    }
    throw "Duo API call failed ($Method $uri): $message"
  }
}

function Get-PropertyValue {
  param(
    [Parameter(Mandatory)] $InputObject,
    [Parameter(Mandatory)] [string[]] $PropertyNames
  )

  foreach ($name in $PropertyNames) {
    if ($InputObject -is [hashtable] -and $InputObject.ContainsKey($name)) {
      return $InputObject[$name]
    }

    $prop = $InputObject.PSObject.Properties[$name]
    if ($prop) {
      return $prop.Value
    }
  }

  return $null
}

function Get-AdminApiIntegrations {
  param(
    [Parameter(Mandatory)][string] $ApiHost,
    [Parameter(Mandatory)][string] $AccountId
  )

  $all = @()
  $limit = 300
  $offset = 0

  while ($true) {
    $resp = Invoke-DuoApi -Method GET -ApiHost $ApiHost -Path "/admin/v1/integrations" -Params @{
      account_id = $AccountId
      limit      = $limit
      offset     = $offset
    }

    if (-not $resp) {
      # WhatIf mode
      return @()
    }

    if ($resp.stat -ne "OK") {
      throw "List integrations failed: $($resp | ConvertTo-Json -Depth 10)"
    }

    $page = @($resp.response | Where-Object { $null -ne $_ })
    $all += $page

    if ($page.Count -lt $limit) {
      break
    }

    $offset += $limit
  }

  return $all
}

function Find-ExistingAdminApiIntegration {
  param(
    [Parameter(Mandatory)] $Integrations,
    [Parameter(Mandatory)][string] $Name
  )

  foreach ($integration in $Integrations) {
    $type = [string](Get-PropertyValue -InputObject $integration -PropertyNames @("type"))
    $intName = [string](Get-PropertyValue -InputObject $integration -PropertyNames @("name"))

    if ($type -eq "adminapi" -and $intName.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $integration
    }
  }

  return $null
}

$ParentApiHost = Resolve-DuoHost -HostOrUrl $ParentApiHost
$accountsResp = Invoke-DuoApi -Method POST -ApiHost $ParentApiHost -Path "/accounts/v1/account/list" -Params @{}

if (-not $accountsResp) {
  throw "Unable to retrieve accounts."
}
if ($accountsResp.stat -ne "OK") {
  throw "Accounts API returned FAIL: $($accountsResp | ConvertTo-Json -Depth 10)"
}

$accounts = @($accountsResp.response | Where-Object { $null -ne $_ })

if ($OnlyAccountIds) {
  $accounts = $accounts | Where-Object { $OnlyAccountIds -contains $_.account_id }
}
if ($OnlyAccountNames) {
  $accounts = $accounts | Where-Object { $OnlyAccountNames -contains $_.name }
}
if (-not $accounts -or $accounts.Count -eq 0) {
  Write-Warning "No child accounts matched the requested filters."
  return
}

$summary = [ordered]@{
  Total    = $accounts.Count
  Created  = 0
  Existing = 0
  Failed   = 0
  Skipped  = 0
}
$results = @()

Write-Host ("Targeting {0} child account(s). IntegrationName='{1}' AllowDuplicates={2} WhatIf={3}" -f $summary.Total, $IntegrationName, [bool]$AllowDuplicates, [bool]$WhatIf)

foreach ($acct in $accounts) {
  $childId = [string]$acct.account_id
  $childName = [string]$acct.name
  $childHostRaw = [string]$acct.api_hostname

  if ([string]::IsNullOrWhiteSpace($childId) -or [string]::IsNullOrWhiteSpace($childHostRaw)) {
    $summary.Skipped++
    Write-Warning "Skipping account with missing account_id/api_hostname. Name='$childName'"
    continue
  }

  try {
    $childHost = Resolve-DuoHost -HostOrUrl $childHostRaw
  } catch {
    $summary.Skipped++
    Write-Warning "Skipping [$childName] ($childId): invalid child host '$childHostRaw'."
    continue
  }

  Write-Host "==> [$childName] ($childId) host=$childHost"

  try {
    if (-not $AllowDuplicates) {
      $existing = Find-ExistingAdminApiIntegration -Integrations (Get-AdminApiIntegrations -ApiHost $childHost -AccountId $childId) -Name $IntegrationName
      if ($existing) {
        $summary.Existing++
        $existingIKey = [string](Get-PropertyValue -InputObject $existing -PropertyNames @("ikey", "integration_key"))
        Write-Host "    Existing Admin API integration found with same name. Skipping creation."

        $results += [PSCustomObject]@{
          AccountName     = $childName
          AccountId       = $childId
          ApiHost         = $childHost
          Status          = "Existing"
          IntegrationName = $IntegrationName
          IntegrationType = "adminapi"
          IntegrationKey  = $existingIKey
          SecretKey       = $null
          Message         = "Skipped because integration name already exists."
        }
        continue
      }
    }

    $createParams = @{
      account_id                          = $childId
      name                                = $IntegrationName
      type                                = "adminapi"
      adminapi_read_resource              = "1"
      adminapi_allow_to_set_permissions   = "1"
    }

    $createResp = Invoke-DuoApi -Method POST -ApiHost $childHost -Path "/admin/v1/integrations" -Params $createParams

    if (-not $createResp) {
      # WhatIf mode
      $summary.Skipped++
      $results += [PSCustomObject]@{
        AccountName     = $childName
        AccountId       = $childId
        ApiHost         = $childHost
        Status          = "WhatIf"
        IntegrationName = $IntegrationName
        IntegrationType = "adminapi"
        IntegrationKey  = $null
        SecretKey       = $null
        Message         = "Preview only."
      }
      continue
    }

    if ($createResp.stat -ne "OK") {
      throw "Create integration failed: $($createResp | ConvertTo-Json -Depth 10)"
    }

    $createdObj = $createResp.response
    $createdIKey = [string](Get-PropertyValue -InputObject $createdObj -PropertyNames @("ikey", "integration_key"))
    $createdSKey = [string](Get-PropertyValue -InputObject $createdObj -PropertyNames @("skey", "secret_key"))

    $summary.Created++
    Write-Host "    Created Admin API integration. ikey=$createdIKey"

    $results += [PSCustomObject]@{
      AccountName     = $childName
      AccountId       = $childId
      ApiHost         = $childHost
      Status          = "Created"
      IntegrationName = $IntegrationName
      IntegrationType = "adminapi"
      IntegrationKey  = $createdIKey
      SecretKey       = $createdSKey
      Message         = "Created successfully."
    }
  } catch {
    $summary.Failed++
    $message = $_.Exception.Message
    Write-Warning "Failed for [$childName] ($childId): $message"

    $results += [PSCustomObject]@{
      AccountName     = $childName
      AccountId       = $childId
      ApiHost         = $childHost
      Status          = "Failed"
      IntegrationName = $IntegrationName
      IntegrationType = "adminapi"
      IntegrationKey  = $null
      SecretKey       = $null
      Message         = $message
    }
  }
}

if (-not $WhatIf -and $results.Count -gt 0) {
  try {
    $results | Export-Csv -Path $OutputCsvPath -NoTypeInformation
    Write-Host "Results exported to: $OutputCsvPath"
  } catch {
    Write-Warning "Could not export CSV to '$OutputCsvPath': $($_.Exception.Message)"
  }
}

Write-Host ("Done. Total={0} Created={1} Existing={2} Failed={3} Skipped={4}" -f $summary.Total, $summary.Created, $summary.Existing, $summary.Failed, $summary.Skipped)
