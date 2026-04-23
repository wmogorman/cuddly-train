<#
.SYNOPSIS
  Audit Duo child accounts for Microsoft Entra ID: External MFA applications.

.DESCRIPTION
  Enumerates managed Duo child accounts via the Accounts API, retrieves each
  child account's integrations via the Admin API, and reports which accounts
  have integrations of type `microsoft-eam`.

  This script is read-only. It does not modify Duo configuration.

.NOTES
  - Uses the documented Duo Accounts API to enumerate child accounts.
  - Uses the documented Duo Admin API v1 integrations endpoint to retrieve
    integrations. Some legacy integration responses may expose secret-like
    values; this script redacts those values before CSV export.
  - The details CSV only contains fields returned by the Duo API. UI-only
    fields from the Duo Admin Panel are not synthesized.

.REQUIREMENTS
  - Windows PowerShell 5.1+ (or PowerShell 7+)
  - Parent Accounts API application credentials (IKey/SKey/ParentApiHost)
  - Parent Accounts API app must be authorized for child Admin API access

.EXAMPLES
  .\duo-audit-external-mfa-apps.ps1

  Uses `duo-accounts-api.env` next to this script for ParentApiHost, IKey,
  and SKey when present.

  .\duo-audit-external-mfa-apps.ps1 `
    -EnvFilePath ".\duo-accounts-api.env"

  .\duo-audit-external-mfa-apps.ps1 `
    -ParentApiHost "api-xxxx.duosecurity.com" `
    -IKey "DIXXXXXXXXXXXXXXXXXX" `
    -SKey "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  .\duo-audit-external-mfa-apps.ps1 -SelfTest
#>

[CmdletBinding(DefaultParameterSetName = "Audit")]
param(
  [Parameter(ParameterSetName = "Audit")]
  [string] $ParentApiHost,

  [Parameter(ParameterSetName = "Audit")]
  [string] $IKey,

  [Parameter(ParameterSetName = "Audit")]
  [string] $SKey,

  [Parameter(ParameterSetName = "Audit")]
  [string] $EnvFilePath = "duo-accounts-api.env",

  [Parameter(ParameterSetName = "Audit")]
  [string[]] $OnlyAccountIds,

  [Parameter(ParameterSetName = "Audit")]
  [string[]] $OnlyAccountNames,

  [Parameter(ParameterSetName = "Audit")]
  [string] $MatchesCsvPath,

  [Parameter(ParameterSetName = "Audit")]
  [string] $MissingCsvPath,

  [Parameter(Mandatory, ParameterSetName = "SelfTest")]
  [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ScriptRoot = Split-Path -Parent $PSCommandPath
$script:MicrosoftEamType = "microsoft-eam"
$script:SensitiveValueMarker = "[REDACTED]"

if ([string]::IsNullOrWhiteSpace($MatchesCsvPath)) {
  $MatchesCsvPath = Join-Path -Path $script:ScriptRoot -ChildPath "artifacts\duo\duo-external-mfa-applications.csv"
}
if ([string]::IsNullOrWhiteSpace($MissingCsvPath)) {
  $MissingCsvPath = Join-Path -Path $script:ScriptRoot -ChildPath "artifacts\duo\duo-external-mfa-missing-accounts.csv"
}

$script:MatchFixedColumns = @(
  "AccountName",
  "AccountId",
  "ApiHost",
  "TotalIntegrations",
  "MicrosoftEamCount",
  "MicrosoftEamMatchIndex",
  "AuditStatus",
  "AuditNotes",
  "IntegrationName",
  "IntegrationKey",
  "IntegrationType",
  "IntegrationNotes",
  "IntegrationPolicyKey",
  "IntegrationUserAccess"
)
$script:MissingFixedColumns = @(
  "AccountName",
  "AccountId",
  "ApiHost",
  "TotalIntegrations",
  "MicrosoftEamCount",
  "AuditStatus",
  "AuditNotes"
)
$script:TopLevelFlattenExclusions = @(
  "name",
  "integration_key",
  "type",
  "notes",
  "policy_key",
  "user_access"
)

function Resolve-DuoHost {
  param([Parameter(Mandatory)][string] $HostOrUrl)

  $value = $HostOrUrl.Trim()
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Host value is empty."
  }

  if ($value -match '^[a-zA-Z][a-zA-Z0-9+\-.]*://') {
    try {
      return ([System.Uri]$value).Host
    }
    catch {
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
    $ch = [char] $b
    $isUnreserved =
      ($b -ge 0x41 -and $b -le 0x5A) -or
      ($b -ge 0x61 -and $b -le 0x7A) -or
      ($b -ge 0x30 -and $b -le 0x39) -or
      ($ch -eq '_') -or ($ch -eq '.') -or ($ch -eq '~') -or ($ch -eq '-')

    if ($isUnreserved) {
      [void] $sb.Append($ch)
    }
    else {
      [void] $sb.AppendFormat("%{0:X2}", $b)
    }
  }

  return $sb.ToString()
}

function Get-DuoParamsString {
  param([hashtable] $Params)

  $pairs = foreach ($k in ($Params.Keys | Sort-Object)) {
    $ek = ConvertTo-DuoUrlEncode -Value ([string] $k)
    $ev = ConvertTo-DuoUrlEncode -Value ([string] $Params[$k])
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
  }
  catch {
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
    if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($name)) {
      return $InputObject[$name]
    }

    $prop = $InputObject.PSObject.Properties[$name]
    if ($prop) {
      return $prop.Value
    }
  }

  return $null
}

function Normalize-StringList {
  param([string[]] $Values)

  return @(
    $Values |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.Trim() } |
      Select-Object -Unique
  )
}

function Resolve-ConfigFilePath {
  param([string] $Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }

  if (Test-Path -LiteralPath $Path) {
    return (Resolve-Path -LiteralPath $Path).ProviderPath
  }

  if (-not [string]::IsNullOrWhiteSpace($script:ScriptRoot)) {
    $scriptPath = Join-Path -Path $script:ScriptRoot -ChildPath $Path
    if (Test-Path -LiteralPath $scriptPath) {
      return (Resolve-Path -LiteralPath $scriptPath).ProviderPath
    }

    return $scriptPath
  }

  return $Path
}

function Get-EnvFileSettings {
  param([string] $Path)

  $resolvedPath = Resolve-ConfigFilePath -Path $Path
  $values = [ordered]@{}

  if ([string]::IsNullOrWhiteSpace($resolvedPath) -or -not (Test-Path -LiteralPath $resolvedPath)) {
    return [PSCustomObject]@{
      Path   = $resolvedPath
      Exists = $false
      Values = $values
    }
  }

  $lineNumber = 0
  foreach ($line in (Get-Content -LiteralPath $resolvedPath -ErrorAction Stop)) {
    $lineNumber++
    $trimmed = $line.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
      continue
    }

    if ($trimmed.StartsWith("export ")) {
      $trimmed = $trimmed.Substring(7).Trim()
    }

    $separatorIndex = $trimmed.IndexOf("=")
    if ($separatorIndex -lt 1) {
      throw "Invalid env file line $lineNumber in '$resolvedPath'. Expected KEY=VALUE."
    }

    $key = $trimmed.Substring(0, $separatorIndex).Trim()
    $value = $trimmed.Substring($separatorIndex + 1)

    if ([string]::IsNullOrWhiteSpace($key)) {
      throw "Invalid env file line $lineNumber in '$resolvedPath'. Key cannot be empty."
    }

    if (
      (($value.Length -ge 2) -and $value.StartsWith('"') -and $value.EndsWith('"')) -or
      (($value.Length -ge 2) -and $value.StartsWith("'") -and $value.EndsWith("'"))
    ) {
      $value = $value.Substring(1, $value.Length - 2)
    }

    $values[$key] = $value
  }

  return [PSCustomObject]@{
    Path   = $resolvedPath
    Exists = $true
    Values = $values
  }
}

function Resolve-AuditCredentialValue {
  param(
    [Parameter(Mandatory)][string] $ParameterName,
    [Parameter(Mandatory)][string] $EnvVariableName,
    [string] $CurrentValue,
    [System.Collections.IDictionary] $EnvValues,
    [hashtable] $BoundParameters
  )

  if ($BoundParameters.ContainsKey($ParameterName)) {
    return $CurrentValue
  }

  if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
    return $CurrentValue
  }

  if ($null -ne $EnvValues -and $EnvValues.Contains($EnvVariableName)) {
    return [string] $EnvValues[$EnvVariableName]
  }

  return $CurrentValue
}

function Ensure-ParentDirectory {
  param([Parameter(Mandatory)][string] $Path)

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
    [void] (New-Item -ItemType Directory -Path $parent -Force)
  }
}

function Test-IsScalarValue {
  param($Value)

  if ($null -eq $Value) {
    return $true
  }

  if ($Value -is [string] -or $Value -is [char] -or $Value -is [System.Uri] -or $Value -is [System.Version]) {
    return $true
  }

  if ($Value.GetType().IsEnum -or $Value -is [System.ValueType]) {
    return $true
  }

  return $false
}

function ConvertTo-ExportScalar {
  param($Value)

  if ($null -eq $Value) {
    return $null
  }

  if ($Value -is [datetime]) {
    return $Value.ToString("o")
  }

  if ($Value -is [System.DateTimeOffset]) {
    return $Value.ToString("o")
  }

  if ($Value -is [System.Uri]) {
    return $Value.ToString()
  }

  if ($Value -is [char]) {
    return [string] $Value
  }

  if ($Value.GetType().IsEnum) {
    return $Value.ToString()
  }

  return $Value
}

function ConvertTo-ScalarText {
  param($Value)

  $exportValue = ConvertTo-ExportScalar -Value $Value
  if ($null -eq $exportValue) {
    return ""
  }

  return [string] $exportValue
}

function Get-ItemCount {
  param($Value)

  if ($null -eq $Value) {
    return 0
  }

  return @($Value).Count
}

function Get-ObjectMembers {
  param($InputObject)

  if ($null -eq $InputObject) {
    return @()
  }

  if ($InputObject -is [System.Collections.IDictionary]) {
    return @(
      foreach ($key in ($InputObject.Keys | Sort-Object)) {
        [PSCustomObject]@{
          Name  = [string] $key
          Value = $InputObject[$key]
        }
      }
    )
  }

  return @(
    $InputObject.PSObject.Properties |
      Where-Object { $_.MemberType -match 'Property$' } |
      ForEach-Object {
        [PSCustomObject]@{
          Name  = [string] $_.Name
          Value = $_.Value
        }
      }
  )
}

function Get-SanitizedColumnSegment {
  param([Parameter(Mandatory)][string] $Value)

  $sanitized = [System.Text.RegularExpressions.Regex]::Replace($Value, '[^A-Za-z0-9]', '_')
  if ([string]::IsNullOrWhiteSpace($sanitized)) {
    return "_"
  }

  return $sanitized
}

function Get-IntegrationColumnName {
  param([Parameter(Mandatory)][string[]] $PathSegments)

  $sanitized = $PathSegments | ForEach-Object { Get-SanitizedColumnSegment -Value ([string] $_) }
  return "Integration_{0}" -f ($sanitized -join "_")
}

function Test-IsSensitiveLeafName {
  param([string] $LeafName)

  if ([string]::IsNullOrWhiteSpace($LeafName)) {
    return $false
  }

  $trimmed = $LeafName.Trim()
  if ($trimmed -ieq "skey") {
    return $true
  }

  return ($trimmed -match '(?i)secret')
}

function Add-FlattenedIntegrationField {
  param(
    [Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary] $Result,
    [Parameter(Mandatory)][string[]] $PathSegments,
    [Parameter(Mandatory)][string] $LeafName,
    $Value
  )

  $columnName = Get-IntegrationColumnName -PathSegments $PathSegments

  if (Test-IsSensitiveLeafName -LeafName $LeafName) {
    $Result[$columnName] = $script:SensitiveValueMarker
    return
  }

  if (Test-IsScalarValue -Value $Value) {
    $Result[$columnName] = ConvertTo-ExportScalar -Value $Value
    return
  }

  if ($Value -is [System.Collections.IDictionary]) {
    $members = @(Get-ObjectMembers -InputObject $Value)
    if ($members.Count -eq 0) {
      $Result[$columnName] = ($Value | ConvertTo-Json -Compress -Depth 20)
      return
    }

    foreach ($member in $members) {
      Add-FlattenedIntegrationField -Result $Result -PathSegments ($PathSegments + @([string] $member.Name)) -LeafName ([string] $member.Name) -Value $member.Value
    }

    return
  }

  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $items = @($Value)
    if ($items.Count -eq 0) {
      $Result[$columnName] = ""
      return
    }

    $hasComplexItem = $false
    foreach ($item in $items) {
      if (-not (Test-IsScalarValue -Value $item)) {
        $hasComplexItem = $true
        break
      }
    }

    if ($hasComplexItem) {
      $Result[$columnName] = ($items | ConvertTo-Json -Compress -Depth 20)
    }
    else {
      $Result[$columnName] = (($items | ForEach-Object { ConvertTo-ScalarText -Value $_ }) -join "; ")
    }

    return
  }

  $members = @(Get-ObjectMembers -InputObject $Value)
  if ($members.Count -eq 0) {
    $Result[$columnName] = ($Value | ConvertTo-Json -Compress -Depth 20)
    return
  }

  foreach ($member in $members) {
    Add-FlattenedIntegrationField -Result $Result -PathSegments ($PathSegments + @([string] $member.Name)) -LeafName ([string] $member.Name) -Value $member.Value
  }
}

function Get-FlattenedIntegrationFields {
  param([Parameter(Mandatory)] $Integration)

  $result = New-Object System.Collections.Specialized.OrderedDictionary
  $excluded = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($name in $script:TopLevelFlattenExclusions) {
    [void] $excluded.Add($name)
  }

  foreach ($member in (Get-ObjectMembers -InputObject $Integration)) {
    if ($excluded.Contains([string] $member.Name)) {
      continue
    }

    Add-FlattenedIntegrationField -Result $result -PathSegments @([string] $member.Name) -LeafName ([string] $member.Name) -Value $member.Value
  }

  return $result
}

function Test-IsMicrosoftEamIntegration {
  param($Integration)

  if ($null -eq $Integration) {
    return $false
  }

  $typeValue = [string] (Get-PropertyValue -InputObject $Integration -PropertyNames @("type"))
  if ([string]::IsNullOrWhiteSpace($typeValue)) {
    return $false
  }

  return ($typeValue -ieq $script:MicrosoftEamType)
}

function Get-DuoAccounts {
  param([Parameter(Mandatory)][string] $ApiHost)

  $resp = Invoke-DuoApi -Method POST -ApiHost $ApiHost -Path "/accounts/v1/account/list" -Params @{}
  if (-not $resp) {
    throw "Unable to retrieve accounts."
  }

  if ($resp.stat -ne "OK") {
    throw "Accounts API returned FAIL: $($resp | ConvertTo-Json -Depth 10)"
  }

  return @($resp.response | Where-Object { $null -ne $_ })
}

function Get-DuoIntegrations {
  param(
    [Parameter(Mandatory)][string] $ApiHost,
    [Parameter(Mandatory)][string] $AccountId,
    [int] $Limit = 300,
    [scriptblock] $Invoker
  )

  if ($null -eq $Invoker) {
    $Invoker = {
      param($Method, $ResolvedApiHost, $Path, $Params)
      Invoke-DuoApi -Method $Method -ApiHost $ResolvedApiHost -Path $Path -Params $Params
    }.GetNewClosure()
  }

  $all = @()
  $offset = 0

  while ($true) {
    $resp = & $Invoker "GET" $ApiHost "/admin/v1/integrations" @{
      account_id = $AccountId
      limit      = $Limit
      offset     = $offset
    }

    if ($resp.stat -ne "OK") {
      throw "List integrations failed: $($resp | ConvertTo-Json -Depth 10)"
    }

    $page = @($resp.response | Where-Object { $null -ne $_ })
    $all += $page

    $metadata = Get-PropertyValue -InputObject $resp -PropertyNames @("metadata")
    $nextOffset = $null
    if ($null -ne $metadata) {
      $nextOffset = Get-PropertyValue -InputObject $metadata -PropertyNames @("next_offset")
    }

    if ($null -ne $nextOffset -and -not [string]::IsNullOrWhiteSpace([string] $nextOffset)) {
      $offset = [int] $nextOffset
      continue
    }

    if ((Get-ItemCount -Value $page) -lt $Limit) {
      break
    }

    $offset += $Limit
  }

  return $all
}

function New-MatchRecord {
  param(
    [string] $AccountName,
    [string] $AccountId,
    [string] $ApiHost,
    [int] $TotalIntegrations,
    [int] $MicrosoftEamCount,
    [int] $MicrosoftEamMatchIndex,
    [string] $AuditStatus,
    [string] $AuditNotes,
    $Integration
  )

  $fixed = [ordered]@{
    AccountName            = $AccountName
    AccountId              = $AccountId
    ApiHost                = $ApiHost
    TotalIntegrations      = $TotalIntegrations
    MicrosoftEamCount      = $MicrosoftEamCount
    MicrosoftEamMatchIndex = $MicrosoftEamMatchIndex
    AuditStatus            = $AuditStatus
    AuditNotes             = $AuditNotes
    IntegrationName        = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $Integration -PropertyNames @("name"))
    IntegrationKey         = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $Integration -PropertyNames @("integration_key"))
    IntegrationType        = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $Integration -PropertyNames @("type"))
    IntegrationNotes       = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $Integration -PropertyNames @("notes"))
    IntegrationPolicyKey   = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $Integration -PropertyNames @("policy_key"))
    IntegrationUserAccess  = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $Integration -PropertyNames @("user_access"))
  }

  return [PSCustomObject]@{
    Fixed = $fixed
    Flat  = Get-FlattenedIntegrationFields -Integration $Integration
  }
}

function New-MissingRecord {
  param(
    [string] $AccountName,
    [string] $AccountId,
    [string] $ApiHost,
    [int] $TotalIntegrations,
    [string] $AuditStatus,
    [string] $AuditNotes
  )

  return [PSCustomObject][ordered]@{
    AccountName       = $AccountName
    AccountId         = $AccountId
    ApiHost           = $ApiHost
    TotalIntegrations = $TotalIntegrations
    MicrosoftEamCount = 0
    AuditStatus       = $AuditStatus
    AuditNotes        = $AuditNotes
  }
}

function Convert-MatchRecordsToExportRows {
  param([object[]] $Records)

  $columnSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($record in $Records) {
    foreach ($key in $record.Flat.Keys) {
      [void] $columnSet.Add([string] $key)
    }
  }

  $extraColumns = @($columnSet | Sort-Object)
  $rows = @(
    foreach ($record in $Records) {
      $ordered = [ordered]@{}
      foreach ($column in $script:MatchFixedColumns) {
        $ordered[$column] = $record.Fixed[$column]
      }

      foreach ($column in $extraColumns) {
        $ordered[$column] = if ($record.Flat.Contains($column)) { $record.Flat[$column] } else { $null }
      }

      [PSCustomObject] $ordered
    }
  )

  return [PSCustomObject]@{
    Rows        = $rows
    ExtraColumnNames = $extraColumns
  }
}

function Write-CsvWithHeaders {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Rows,
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][string[]] $Columns
  )

  Ensure-ParentDirectory -Path $Path

  if ((Get-ItemCount -Value $Rows) -gt 0) {
    $Rows | Select-Object -Property $Columns | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    return
  }

  $placeholder = [ordered]@{}
  foreach ($column in $Columns) {
    $placeholder[$column] = ""
  }

  $headerLine = ([PSCustomObject] $placeholder | ConvertTo-Csv -NoTypeInformation)[0]
  Set-Content -LiteralPath $Path -Value $headerLine -Encoding UTF8
}

function Add-SelfTestResult {
  param(
    [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Results,
    [Parameter(Mandatory)][string] $Test,
    [Parameter(Mandatory)][bool] $Passed,
    [string] $Details = ""
  )

  $Results.Add([PSCustomObject][ordered]@{
    Test    = $Test
    Passed  = $Passed
    Details = $Details
  }) | Out-Null
}

function Invoke-SelfTest {
  $results = New-Object System.Collections.Generic.List[object]

  try {
    Add-SelfTestResult -Results $results -Test "Resolve raw Duo host" -Passed ((Resolve-DuoHost -HostOrUrl "api-123.duosecurity.com") -eq "api-123.duosecurity.com")
    Add-SelfTestResult -Results $results -Test "Resolve Duo host from URL" -Passed ((Resolve-DuoHost -HostOrUrl "https://api-123.duosecurity.com/admin") -eq "api-123.duosecurity.com")
    Add-SelfTestResult -Results $results -Test "Resolve Duo host from bare path suffix" -Passed ((Resolve-DuoHost -HostOrUrl "api-123.duosecurity.com/admin/v1") -eq "api-123.duosecurity.com")

    $tempEnvPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("duo-env-selftest-{0}.env" -f ([guid]::NewGuid().ToString("N")))
    try {
      Set-Content -LiteralPath $tempEnvPath -Encoding UTF8 -Value @(
        "# comment"
        "DUO_PARENT_API_HOST=api-selftest.duosecurity.com"
        "export DUO_IKEY=DISELFTEST123"
        "DUO_SKEY='secret-value'"
      )

      $envSettings = Get-EnvFileSettings -Path $tempEnvPath
    Add-SelfTestResult -Results $results -Test "Parse env file values" -Passed (
        $envSettings.Exists -and
        ($envSettings.Values["DUO_PARENT_API_HOST"] -eq "api-selftest.duosecurity.com") -and
        ($envSettings.Values["DUO_IKEY"] -eq "DISELFTEST123") -and
        ($envSettings.Values["DUO_SKEY"] -eq "secret-value")
      )
      Add-SelfTestResult -Results $results -Test "Get-ItemCount returns zero for null" -Passed ((Get-ItemCount -Value $null) -eq 0)
      Add-SelfTestResult -Results $results -Test "Explicit parameter value overrides env file" -Passed (
        (Resolve-AuditCredentialValue -ParameterName "IKey" -EnvVariableName "DUO_IKEY" -CurrentValue "manual-ikey" -EnvValues $envSettings.Values -BoundParameters @{ IKey = "manual-ikey" }) -eq "manual-ikey"
      )
    }
    finally {
      if (Test-Path -LiteralPath $tempEnvPath) {
        Remove-Item -LiteralPath $tempEnvPath -Force -ErrorAction SilentlyContinue
      }
    }

    $flattened = Get-FlattenedIntegrationFields -Integration ([PSCustomObject]@{
      name            = "Cisco Duo"
      integration_key = "DI123"
      type            = "microsoft-eam"
      notes           = "Primary"
      policy_key      = "PO123"
      user_access     = "ALL_USERS"
      groups_allowed  = @("GRP1", "GRP2")
      "odd name"      = "odd-value"
      nested          = [ordered]@{
        "client-id"    = "client-123"
        "child object" = [ordered]@{
          "discovery url" = "https://example.test/.well-known/openid-configuration"
          secret_key      = "super-secret"
        }
      }
      object_array    = @(
        [PSCustomObject]@{ id = 1 },
        [PSCustomObject]@{ id = 2 }
      )
      secret_key      = "plain-secret"
    })

    Add-SelfTestResult -Results $results -Test "Flatten excludes fixed top-level fields" -Passed (-not $flattened.Contains("Integration_name") -and -not $flattened.Contains("Integration_type"))
    Add-SelfTestResult -Results $results -Test "Flatten scalar arrays with preserved order" -Passed ($flattened["Integration_groups_allowed"] -eq "GRP1; GRP2")
    Add-SelfTestResult -Results $results -Test "Flatten nested object with sanitized names" -Passed ($flattened["Integration_nested_client_id"] -eq "client-123")
    Add-SelfTestResult -Results $results -Test "Flatten nested child object path" -Passed ($flattened["Integration_nested_child_object_discovery_url"] -eq "https://example.test/.well-known/openid-configuration")
    Add-SelfTestResult -Results $results -Test "Flatten object arrays as JSON" -Passed ($flattened["Integration_object_array"] -eq '[{"id":1},{"id":2}]')
    Add-SelfTestResult -Results $results -Test "Flatten odd property names" -Passed ($flattened["Integration_odd_name"] -eq "odd-value")
    Add-SelfTestResult -Results $results -Test "Redact top-level secret fields" -Passed ($flattened["Integration_secret_key"] -eq $script:SensitiveValueMarker)
    Add-SelfTestResult -Results $results -Test "Redact nested secret fields" -Passed ($flattened["Integration_nested_child_object_secret_key"] -eq $script:SensitiveValueMarker)

    Add-SelfTestResult -Results $results -Test "Exact microsoft-eam type match" -Passed (Test-IsMicrosoftEamIntegration -Integration ([PSCustomObject]@{ type = "microsoft-eam" }))
    Add-SelfTestResult -Results $results -Test "Case-insensitive microsoft-eam type match" -Passed (Test-IsMicrosoftEamIntegration -Integration ([PSCustomObject]@{ type = "MICROSOFT-EAM" }))
    Add-SelfTestResult -Results $results -Test "Reject nearby non-target type" -Passed (-not (Test-IsMicrosoftEamIntegration -Integration ([PSCustomObject]@{ type = "microsoft-eam-preview" })))
    Add-SelfTestResult -Results $results -Test "Reject missing type" -Passed (-not (Test-IsMicrosoftEamIntegration -Integration ([PSCustomObject]@{ name = "Cisco Duo" })))

    $metadataCalls = New-Object System.Collections.Generic.List[object]
    $metadataResponses = New-Object 'System.Collections.Generic.Queue[object]'
    $metadataResponses.Enqueue([PSCustomObject]@{
      stat     = "OK"
      response = @(
        [PSCustomObject]@{ integration_key = "INT1"; type = "microsoft-eam" },
        [PSCustomObject]@{ integration_key = "INT2"; type = "adminapi" }
      )
      metadata = [PSCustomObject]@{ next_offset = 2 }
    })
    $metadataResponses.Enqueue([PSCustomObject]@{
      stat     = "OK"
      response = @(
        [PSCustomObject]@{ integration_key = "INT3"; type = "microsoft-eam" }
      )
      metadata = [PSCustomObject]@{}
    })
    $metadataInvoker = {
      param($Method, $ApiHost, $Path, $Params)
      $metadataCalls.Add([PSCustomObject]@{
        Offset = [int] $Params["offset"]
        Limit  = [int] $Params["limit"]
      }) | Out-Null
      return $metadataResponses.Dequeue()
    }.GetNewClosure()
    $metadataPaged = @(Get-DuoIntegrations -ApiHost "api-123.duosecurity.com" -AccountId "DA123" -Limit 2 -Invoker $metadataInvoker)
    $metadataOffsets = @($metadataCalls | ForEach-Object { $_.Offset })
    Add-SelfTestResult -Results $results -Test "Pagination honors metadata next_offset" -Passed (($metadataPaged.Count -eq 3) -and ($metadataOffsets.Count -eq 2) -and ($metadataOffsets[0] -eq 0) -and ($metadataOffsets[1] -eq 2))

    $fallbackCalls = New-Object System.Collections.Generic.List[object]
    $fallbackResponses = New-Object 'System.Collections.Generic.Queue[object]'
    $fallbackResponses.Enqueue([PSCustomObject]@{
      stat     = "OK"
      response = @(
        [PSCustomObject]@{ integration_key = "INT1"; type = "microsoft-eam" },
        [PSCustomObject]@{ integration_key = "INT2"; type = "adminapi" }
      )
    })
    $fallbackResponses.Enqueue([PSCustomObject]@{
      stat     = "OK"
      response = @(
        [PSCustomObject]@{ integration_key = "INT3"; type = "microsoft-eam" }
      )
    })
    $fallbackInvoker = {
      param($Method, $ApiHost, $Path, $Params)
      $fallbackCalls.Add([PSCustomObject]@{
        Offset = [int] $Params["offset"]
        Limit  = [int] $Params["limit"]
      }) | Out-Null
      return $fallbackResponses.Dequeue()
    }.GetNewClosure()
    $fallbackPaged = @(Get-DuoIntegrations -ApiHost "api-123.duosecurity.com" -AccountId "DA123" -Limit 2 -Invoker $fallbackInvoker)
    $fallbackOffsets = @($fallbackCalls | ForEach-Object { $_.Offset })
    Add-SelfTestResult -Results $results -Test "Pagination falls back to offset plus limit" -Passed (($fallbackPaged.Count -eq 3) -and ($fallbackOffsets.Count -eq 2) -and ($fallbackOffsets[0] -eq 0) -and ($fallbackOffsets[1] -eq 2))
  }
  catch {
    Add-SelfTestResult -Results $results -Test "Unexpected self-test exception" -Passed $false -Details $_.Exception.Message
  }

  $results | Format-Table -AutoSize | Out-Host

  $failed = @($results | Where-Object { -not $_.Passed })
  if ($failed.Count -gt 0) {
    throw "Self-test failed for $($failed.Count) case(s)."
  }

  Write-Host "Self-test passed ($($results.Count) cases)."
}

if ($PSCmdlet.ParameterSetName -eq "SelfTest") {
  Invoke-SelfTest
  return
}

if ([string]::IsNullOrWhiteSpace($MatchesCsvPath)) {
  throw "MatchesCsvPath cannot be empty."
}
if ([string]::IsNullOrWhiteSpace($MissingCsvPath)) {
  throw "MissingCsvPath cannot be empty."
}

$envSettings = Get-EnvFileSettings -Path $EnvFilePath
$ParentApiHost = Resolve-AuditCredentialValue -ParameterName "ParentApiHost" -EnvVariableName "DUO_PARENT_API_HOST" -CurrentValue $ParentApiHost -EnvValues $envSettings.Values -BoundParameters $PSBoundParameters
$IKey = Resolve-AuditCredentialValue -ParameterName "IKey" -EnvVariableName "DUO_IKEY" -CurrentValue $IKey -EnvValues $envSettings.Values -BoundParameters $PSBoundParameters
$SKey = Resolve-AuditCredentialValue -ParameterName "SKey" -EnvVariableName "DUO_SKEY" -CurrentValue $SKey -EnvValues $envSettings.Values -BoundParameters $PSBoundParameters

if ([string]::IsNullOrWhiteSpace($ParentApiHost)) {
  throw "ParentApiHost cannot be empty. Supply -ParentApiHost or set DUO_PARENT_API_HOST in '$($envSettings.Path)'."
}
if ([string]::IsNullOrWhiteSpace($IKey)) {
  throw "IKey cannot be empty. Supply -IKey or set DUO_IKEY in '$($envSettings.Path)'."
}
if ([string]::IsNullOrWhiteSpace($SKey)) {
  throw "SKey cannot be empty. Supply -SKey or set DUO_SKEY in '$($envSettings.Path)'."
}

$OnlyAccountIds = Normalize-StringList -Values $OnlyAccountIds
$OnlyAccountNames = Normalize-StringList -Values $OnlyAccountNames
$ParentApiHost = Resolve-DuoHost -HostOrUrl $ParentApiHost

$accounts = @(Get-DuoAccounts -ApiHost $ParentApiHost)
if ((Get-ItemCount -Value $OnlyAccountIds) -gt 0) {
  $accounts = @($accounts | Where-Object { $OnlyAccountIds -contains ([string] $_.account_id) })
}
if ((Get-ItemCount -Value $OnlyAccountNames) -gt 0) {
  $accounts = @($accounts | Where-Object { $OnlyAccountNames -contains ([string] $_.name) })
}

$accounts = @(
  $accounts |
    Where-Object { $null -ne $_ } |
    Sort-Object @{ Expression = { [string] $_.name } }, @{ Expression = { [string] $_.account_id } }
)

$summary = [ordered]@{
  MatchesCsvPath                 = $MatchesCsvPath
  MissingCsvPath                 = $MissingCsvPath
  TotalAccounts                  = Get-ItemCount -Value $accounts
  AuditedAccounts                = 0
  AccountsWithExternalMfa        = 0
  AccountsMissingExternalMfa     = 0
  TotalExternalMfaApplications   = 0
  AccountsWithDuplicateExternalMfa = 0
  FailedAccounts                 = 0
  SkippedAccounts                = 0
}

$rawMatchRecords = @()
$missingRows = @()

if ((Get-ItemCount -Value $accounts) -eq 0) {
  Write-Warning "No child accounts matched the requested filters."
}
else {
  Write-Host ("Targeting {0} child account(s) for type '{1}'." -f $summary.TotalAccounts, $script:MicrosoftEamType)
  Write-Host ""

  foreach ($acct in $accounts) {
    $childId = [string] $acct.account_id
    $childName = [string] $acct.name
    $childHostRaw = [string] $acct.api_hostname

    if ([string]::IsNullOrWhiteSpace($childId) -or [string]::IsNullOrWhiteSpace($childHostRaw)) {
      $summary.SkippedAccounts++
      Write-Warning "Skipping account with missing account_id/api_hostname. Name='$childName'"
      continue
    }

    try {
      $childHost = Resolve-DuoHost -HostOrUrl $childHostRaw
    }
    catch {
      $summary.SkippedAccounts++
      Write-Warning "Skipping [$childName] ($childId): invalid child host '$childHostRaw'."
      continue
    }

    Write-Host "==> [$childName] ($childId) host=$childHost"

    try {
      $integrations = @(Get-DuoIntegrations -ApiHost $childHost -AccountId $childId)
      $summary.AuditedAccounts++

      $totalIntegrations = Get-ItemCount -Value $integrations
      $matches = @(
        $integrations |
          Where-Object { Test-IsMicrosoftEamIntegration -Integration $_ } |
          Sort-Object @{ Expression = { [string] (Get-PropertyValue -InputObject $_ -PropertyNames @("name")) } }, @{ Expression = { [string] (Get-PropertyValue -InputObject $_ -PropertyNames @("integration_key")) } }
      )

      if ((Get-ItemCount -Value $matches) -eq 0) {
        $summary.AccountsMissingExternalMfa++
        $missingRows += New-MissingRecord -AccountName $childName -AccountId $childId -ApiHost $childHost `
          -TotalIntegrations $totalIntegrations -AuditStatus "MissingExternalMfaApp" `
          -AuditNotes "No integrations of type '$($script:MicrosoftEamType)' were found in this account."
        Write-Host "    MissingExternalMfaApp"
        continue
      }

      $summary.AccountsWithExternalMfa++
      $summary.TotalExternalMfaApplications += (Get-ItemCount -Value $matches)

      $auditNotes = "Account contains an integration of type '$($script:MicrosoftEamType)'."
      if ((Get-ItemCount -Value $matches) -gt 1) {
        $summary.AccountsWithDuplicateExternalMfa++
        $auditNotes = "Duplicate integrations of type '$($script:MicrosoftEamType)' were found in this account."
      }

      Write-Host ("    FoundExternalMfaApp count={0}" -f (Get-ItemCount -Value $matches))

      for ($i = 0; $i -lt (Get-ItemCount -Value $matches); $i++) {
        $rawMatchRecords += New-MatchRecord -AccountName $childName -AccountId $childId -ApiHost $childHost `
          -TotalIntegrations $totalIntegrations -MicrosoftEamCount (Get-ItemCount -Value $matches) -MicrosoftEamMatchIndex ($i + 1) `
          -AuditStatus "FoundExternalMfaApp" -AuditNotes $auditNotes -Integration $matches[$i]
      }
    }
    catch {
      $summary.FailedAccounts++
      Write-Warning "Failed auditing [$childName] ($childId): $($_.Exception.Message)"
    }
  }
}

$rawMatchRecords = @(
  $rawMatchRecords |
    Sort-Object `
      @{ Expression = { [string] $_.Fixed.AccountName } }, `
      @{ Expression = { [string] $_.Fixed.AccountId } }, `
      @{ Expression = { [int] $_.Fixed.MicrosoftEamMatchIndex } }, `
      @{ Expression = { [string] $_.Fixed.IntegrationKey } }
)

$missingRows = @(
  $missingRows |
    Sort-Object AccountName, AccountId
)

$matchExport = Convert-MatchRecordsToExportRows -Records $rawMatchRecords
$matchRows = @($matchExport.Rows)
$matchColumns = @($script:MatchFixedColumns + $matchExport.ExtraColumnNames)

Write-CsvWithHeaders -Rows $matchRows -Path $MatchesCsvPath -Columns $matchColumns
Write-CsvWithHeaders -Rows $missingRows -Path $MissingCsvPath -Columns $script:MissingFixedColumns

Write-Host ""
Write-Host "Summary:"
$summary.GetEnumerator() | ForEach-Object {
  Write-Host ("  {0}: {1}" -f $_.Key, $_.Value)
}

[PSCustomObject] $summary
