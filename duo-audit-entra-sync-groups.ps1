<#
.SYNOPSIS
  Audit Duo child accounts for required Microsoft Entra ID user sync groups.

.DESCRIPTION
  Enumerates managed Duo child accounts via the Accounts API, finds Azure/Entra
  user directory syncs in each child account, and reports whether each sync has
  the required sync-managed Duo groups materialized.

  This script is read-only. It does not modify Duo sync configuration.

.NOTES
  Usage note:
  - This audit uses current sync-managed Duo groups returned by the documented
    Admin API as evidence.
  - Duo's documented API does not expose the selected group list shown on the
    Microsoft Entra ID sync configuration page in the Duo Admin Panel.
  - A tenant flagged as missing may still have a group selected in the UI if
    that selection is not currently visible through /admin/v1/groups.
  - Treat flagged results as an audit shortlist and validate edge cases in the
    Duo UI when needed.

.REQUIREMENTS
  - Windows PowerShell 5.1+ (or PowerShell 7+)
  - Parent Accounts API application credentials (IKey/SKey/ParentApiHost)
  - Parent Accounts API app must be authorized for child Admin API access

.EXAMPLES
  .\duo-audit-entra-sync-groups.ps1 `
    -ParentApiHost "api-xxxx.duosecurity.com" `
    -IKey "DIXXXXXXXXXXXXXXXXXX" `
    -SKey "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" `
    -OutputCsvPath ".\artifacts\duo\duo-entra-sync-group-audit.csv"

  .\duo-audit-entra-sync-groups.ps1 -SelfTest
#>

[CmdletBinding(DefaultParameterSetName = "Audit")]
param(
  [Parameter(Mandatory, ParameterSetName = "Audit")]
  [string] $ParentApiHost,

  [Parameter(Mandatory, ParameterSetName = "Audit")]
  [string] $IKey,

  [Parameter(Mandatory, ParameterSetName = "Audit")]
  [string] $SKey,

  [Parameter(ParameterSetName = "Audit")]
  [string[]] $OnlyAccountIds,

  [Parameter(ParameterSetName = "Audit")]
  [string[]] $OnlyAccountNames,

  [Parameter(ParameterSetName = "Audit")]
  [string[]] $RequiredGroupNames = @(
    "ActaMSP Global Administrators Audit",
    "ActaMSP Integration Group"
  ),

  [Parameter(ParameterSetName = "Audit")]
  [string] $OutputCsvPath,

  [Parameter(Mandatory, ParameterSetName = "SelfTest")]
  [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
  $OutputCsvPath = Join-Path -Path $PSScriptRoot -ChildPath "artifacts\duo\duo-entra-sync-group-audit.csv"
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
    [Parameter(Mandatory)][ValidateSet("GET", "POST", "DELETE")] [string] $Method,
    [Parameter(Mandatory)][string] $ApiHost,
    [Parameter(Mandatory)][string] $Path,
    [hashtable] $Params = @{}
  )

  $headers = New-DuoAuthHeaders -Method $Method -ApiHost $ApiHost -Path $Path -Params $Params -IKey $IKey -SKey $SKey
  $uri = "https://$ApiHost$Path"

  try {
    if ($Method -in @("GET", "DELETE")) {
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

function Normalize-NameList {
  param([string[]] $Values)

  return @(
    $Values |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.Trim() } |
      Select-Object -Unique
  )
}

function Get-UserDirectorySyncs {
  param(
    [Parameter(Mandatory)][string] $ApiHost,
    [Parameter(Mandatory)][string] $AccountId
  )

  $resp = Invoke-DuoApi -Method GET -ApiHost $ApiHost -Path "/admin/v1/users/directorysync" -Params @{
    account_id = $AccountId
  }

  if ($resp.stat -ne "OK") {
    throw "List directory syncs failed: $($resp | ConvertTo-Json -Depth 10)"
  }

  $syncs = @($resp.response | Where-Object { $null -ne $_ })
  return @(
    $syncs | Where-Object {
      [string](Get-PropertyValue -InputObject $_ -PropertyNames @("directory_type")) -ieq "azure"
    }
  )
}

function Get-DuoGroups {
  param(
    [Parameter(Mandatory)][string] $ApiHost,
    [Parameter(Mandatory)][string] $AccountId
  )

  $all = @()
  $limit = 100
  $offset = 0

  while ($true) {
    $resp = Invoke-DuoApi -Method GET -ApiHost $ApiHost -Path "/admin/v1/groups" -Params @{
      account_id = $AccountId
      limit      = $limit
      offset     = $offset
    }

    if ($resp.stat -ne "OK") {
      throw "List groups failed: $($resp | ConvertTo-Json -Depth 10)"
    }

    $page = @($resp.response | Where-Object { $null -ne $_ })
    $all += $page

    $metadata = Get-PropertyValue -InputObject $resp -PropertyNames @("metadata")
    $nextOffset = $null
    if ($null -ne $metadata) {
      $nextOffset = Get-PropertyValue -InputObject $metadata -PropertyNames @("next_offset")
    }

    if ($null -eq $nextOffset -or [string]::IsNullOrWhiteSpace([string]$nextOffset)) {
      break
    }

    $offset = [int]$nextOffset
  }

  return $all
}

function Parse-EntraManagedGroupName {
  param([string] $GroupName)

  if ([string]::IsNullOrWhiteSpace($GroupName)) {
    return $null
  }

  if ($GroupName -match '^.+? \(formerly from ".+"\)$') {
    return $null
  }

  $match = [System.Text.RegularExpressions.Regex]::Match(
    $GroupName,
    '^(?<BaseName>.+?) \(from Microsoft Entra ID sync "(?<SyncName>.+)"\)$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )

  if (-not $match.Success) {
    return $null
  }

  return [PSCustomObject]@{
    BaseName = $match.Groups["BaseName"].Value
    SyncName = $match.Groups["SyncName"].Value
    FullName = $GroupName
  }
}

function New-AuditRow {
  param(
    [string] $AccountName,
    [string] $AccountId,
    [string] $ApiHost,
    [string] $DirectoryKey,
    [string] $DirectoryName,
    [string] $RequiredGroupName,
    [Nullable[bool]] $Present,
    [string] $EvidenceGroupName,
    [string] $Status,
    [string] $Notes
  )

  return [PSCustomObject][ordered]@{
    AccountName       = $AccountName
    AccountId         = $AccountId
    ApiHost           = $ApiHost
    DirectoryKey      = $DirectoryKey
    DirectoryName     = $DirectoryName
    RequiredGroupName = $RequiredGroupName
    Present           = $Present
    EvidenceGroupName = $EvidenceGroupName
    Status            = $Status
    Notes             = $Notes
  }
}

function Invoke-ParserSelfTest {
  $testCases = @(
    [PSCustomObject]@{
      Name        = "Current managed group parses"
      Input       = 'ActaMSP Integration Group (from Microsoft Entra ID sync "Acme Corp Entra ID")'
      ShouldMatch = $true
      BaseName    = "ActaMSP Integration Group"
      SyncName    = "Acme Corp Entra ID"
    },
    [PSCustomObject]@{
      Name        = "Base name with parentheses parses"
      Input       = 'Finance (West) (from Microsoft Entra ID sync "Acme Corp Entra ID")'
      ShouldMatch = $true
      BaseName    = "Finance (West)"
      SyncName    = "Acme Corp Entra ID"
    },
    [PSCustomObject]@{
      Name        = "Formerly managed group does not parse"
      Input       = 'ActaMSP Integration Group (formerly from "Acme Corp Entra ID")'
      ShouldMatch = $false
      BaseName    = $null
      SyncName    = $null
    },
    [PSCustomObject]@{
      Name        = "Unmanaged group does not parse"
      Input       = "ActaMSP Integration Group"
      ShouldMatch = $false
      BaseName    = $null
      SyncName    = $null
    },
    [PSCustomObject]@{
      Name        = "Multiple sync names remain distinguishable"
      Input       = 'DMX Duo MFA Enabled (from Microsoft Entra ID sync "Tenant B")'
      ShouldMatch = $true
      BaseName    = "DMX Duo MFA Enabled"
      SyncName    = "Tenant B"
    }
  )

  $results = foreach ($case in $testCases) {
    $parsed = Parse-EntraManagedGroupName -GroupName $case.Input
    $actualMatch = ($null -ne $parsed)
    $passed =
      ($actualMatch -eq $case.ShouldMatch) -and
      (($null -eq $parsed -and -not $case.ShouldMatch) -or (
        $parsed.BaseName -eq $case.BaseName -and
        $parsed.SyncName -eq $case.SyncName
      ))

    [PSCustomObject][ordered]@{
      Test        = $case.Name
      Passed      = $passed
      Input       = $case.Input
      ActualMatch = $actualMatch
      BaseName    = if ($null -ne $parsed) { $parsed.BaseName } else { $null }
      SyncName    = if ($null -ne $parsed) { $parsed.SyncName } else { $null }
    }
  }

  $results | Format-Table -AutoSize | Out-Host

  $failed = @($results | Where-Object { -not $_.Passed })
  if ($failed.Count -gt 0) {
    throw "Parser self-test failed for $($failed.Count) case(s)."
  }

  Write-Host "Parser self-test passed ($($results.Count) cases)."
}

if ($PSCmdlet.ParameterSetName -eq "SelfTest") {
  Invoke-ParserSelfTest
  return
}

if ([string]::IsNullOrWhiteSpace($IKey)) {
  throw "IKey cannot be empty."
}
if ([string]::IsNullOrWhiteSpace($SKey)) {
  throw "SKey cannot be empty."
}
if ([string]::IsNullOrWhiteSpace($ParentApiHost)) {
  throw "ParentApiHost cannot be empty."
}

$RequiredGroupNames = Normalize-NameList -Values $RequiredGroupNames
if (-not $RequiredGroupNames -or $RequiredGroupNames.Count -eq 0) {
  throw "At least one RequiredGroupName must be provided."
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
  TotalAccounts           = $accounts.Count
  TotalAzureUserSyncs     = 0
  CompliantSyncs          = 0
  MissingRequiredSyncs    = 0
  UnknownSyncs            = 0
  NoAzureUserSyncAccounts = 0
  FailedAccounts          = 0
  SkippedAccounts         = 0
}

$results = @()

Write-Host ("Targeting {0} child account(s). Required groups: {1}" -f $summary.TotalAccounts, ($RequiredGroupNames -join ", "))
Write-Host "Inference note: this audit uses current sync-managed Duo groups from the documented Admin API as evidence. Duo's documented API does not expose the selected group list shown on the Entra sync configuration page."
Write-Host ""

foreach ($acct in $accounts) {
  $childId = [string]$acct.account_id
  $childName = [string]$acct.name
  $childHostRaw = [string]$acct.api_hostname

  if ([string]::IsNullOrWhiteSpace($childId) -or [string]::IsNullOrWhiteSpace($childHostRaw)) {
    $summary.SkippedAccounts++
    Write-Warning "Skipping account with missing account_id/api_hostname. Name='$childName'"
    continue
  }

  try {
    $childHost = Resolve-DuoHost -HostOrUrl $childHostRaw
  } catch {
    $summary.SkippedAccounts++
    Write-Warning "Skipping [$childName] ($childId): invalid child host '$childHostRaw'."
    continue
  }

  Write-Host "==> [$childName] ($childId) host=$childHost"

  try {
    $azureSyncs = @(Get-UserDirectorySyncs -ApiHost $childHost -AccountId $childId)

    if ($azureSyncs.Count -eq 0) {
      $summary.NoAzureUserSyncAccounts++
      $results += New-AuditRow -AccountName $childName -AccountId $childId -ApiHost $childHost `
        -DirectoryKey "" -DirectoryName "" -RequiredGroupName "" -Present $null -EvidenceGroupName "" `
        -Status "NoAzureUserSync" -Notes "No Azure/Entra user directory syncs were found in this account."
      Write-Host "    No Azure/Entra user syncs found."
      continue
    }

    $groups = @(Get-DuoGroups -ApiHost $childHost -AccountId $childId)
    $entraManagedGroups = @(
      $groups |
        ForEach-Object {
          $groupName = [string](Get-PropertyValue -InputObject $_ -PropertyNames @("name"))
          $parsed = Parse-EntraManagedGroupName -GroupName $groupName
          if ($null -ne $parsed) {
            [PSCustomObject]@{
              BaseName = $parsed.BaseName
              SyncName = $parsed.SyncName
              FullName = $parsed.FullName
              GroupId  = [string](Get-PropertyValue -InputObject $_ -PropertyNames @("group_id"))
            }
          }
        } |
        Where-Object { $null -ne $_ }
    )

    foreach ($sync in $azureSyncs) {
      $summary.TotalAzureUserSyncs++

      $directoryKey = [string](Get-PropertyValue -InputObject $sync -PropertyNames @("directory_key"))
      $directoryName = [string](Get-PropertyValue -InputObject $sync -PropertyNames @("name"))
      $syncGroups = @($entraManagedGroups | Where-Object { $_.SyncName -ieq $directoryName })

      if ($syncGroups.Count -eq 0) {
        $summary.UnknownSyncs++
        Write-Host "    [$directoryName] UnknownNotMaterialized"

        foreach ($requiredGroupName in $RequiredGroupNames) {
          $results += New-AuditRow -AccountName $childName -AccountId $childId -ApiHost $childHost `
            -DirectoryKey $directoryKey -DirectoryName $directoryName -RequiredGroupName $requiredGroupName `
            -Present $false -EvidenceGroupName "" -Status "UnknownNotMaterialized" `
            -Notes "No current sync-managed Entra groups matched this sync name in Duo group output. The documented Admin API does not expose the selected group list from the sync configuration page."
        }

        continue
      }

      $rowBuffer = @()
      $missingGroups = [System.Collections.Generic.List[string]]::new()

      foreach ($requiredGroupName in $RequiredGroupNames) {
        $match = @($syncGroups | Where-Object { $_.BaseName -ieq $requiredGroupName } | Select-Object -First 1)
        $isPresent = ($match.Count -gt 0)

        if (-not $isPresent) {
          $missingGroups.Add($requiredGroupName) | Out-Null
        }

        $rowBuffer += [PSCustomObject]@{
          RequiredGroupName = $requiredGroupName
          Present           = $isPresent
          EvidenceGroupName = if ($isPresent) { [string]$match[0].FullName } else { "" }
        }
      }

      $syncStatus = $null
      $syncNotes = $null
      if ($missingGroups.Count -eq 0) {
        $summary.CompliantSyncs++
        $syncStatus = "Compliant"
        $syncNotes = "All required groups are present in current sync-managed Duo group output."
      } else {
        $summary.MissingRequiredSyncs++
        $syncStatus = "MissingRequiredGroup"
        $syncNotes = "Missing from current sync-managed Duo group output: $($missingGroups -join ", "). The documented Admin API does not expose the selected group list from the sync configuration page, so validate flagged tenants in the Duo UI if needed."
      }

      Write-Host ("    [{0}] {1}" -f $directoryName, $syncStatus)

      foreach ($row in $rowBuffer) {
        $results += New-AuditRow -AccountName $childName -AccountId $childId -ApiHost $childHost `
          -DirectoryKey $directoryKey -DirectoryName $directoryName -RequiredGroupName $row.RequiredGroupName `
          -Present $row.Present -EvidenceGroupName $row.EvidenceGroupName -Status $syncStatus -Notes $syncNotes
      }
    }
  } catch {
    $summary.FailedAccounts++
    $message = $_.Exception.Message
    Write-Warning "Failed auditing [$childName] ($childId): $message"
    $results += New-AuditRow -AccountName $childName -AccountId $childId -ApiHost $childHost `
      -DirectoryKey "" -DirectoryName "" -RequiredGroupName "" -Present $null -EvidenceGroupName "" `
      -Status "Error" -Notes $message
  }
}

$results = @(
  $results |
    Sort-Object AccountName, AccountId, DirectoryName, RequiredGroupName, Status
)

$outputDir = Split-Path -Parent $OutputCsvPath
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir)) {
  [void](New-Item -ItemType Directory -Path $outputDir -Force)
}

$results | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Summary:"
$summary.GetEnumerator() | ForEach-Object {
  Write-Host ("  {0}: {1}" -f $_.Key, $_.Value)
}
Write-Host "CSV written to: $OutputCsvPath"

$results
