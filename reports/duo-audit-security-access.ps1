<#
.SYNOPSIS
  Audit Duo child accounts for external (non-MSP) admin accounts and active bypass codes.

.DESCRIPTION
  Enumerates managed Duo child accounts via the Accounts API and for each child:

  1. Retrieves all administrators and classifies them as MspAdmin (email domain
     matches -MspEmailDomain) or ExternalAdmin (customer-side staff given portal
     access). Outputs to -AdminCsvPath.

  2. Retrieves all users in bypass status and their associated bypass codes,
     flagging codes with no expiration as Indefinite. Outputs to -BypassCsvPath.

  This script is read-only. It does not modify Duo configuration.

.REQUIREMENTS
  - Windows PowerShell 5.1+ (or PowerShell 7+)
  - Parent Accounts API application credentials (IKey/SKey/ParentApiHost)
  - Parent Accounts API app must be authorized for child Admin API access

.EXAMPLES
  .\duo-audit-security-access.ps1

  .\duo-audit-security-access.ps1 -OnlyAccountNames "Alliance Rubber"

  .\duo-audit-security-access.ps1 -MspEmailDomain "actamsp.com"

  .\duo-audit-security-access.ps1 -SelfTest
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
  [string] $MspEmailDomain = "actamsp.com",

  [Parameter(ParameterSetName = "Audit")]
  [string] $AdminCsvPath,

  [Parameter(ParameterSetName = "Audit")]
  [string] $BypassCsvPath,

  [Parameter(Mandatory, ParameterSetName = "SelfTest")]
  [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ScriptRoot = Split-Path -Parent $PSCommandPath

if ([string]::IsNullOrWhiteSpace($AdminCsvPath)) {
  $AdminCsvPath = Join-Path -Path $script:ScriptRoot -ChildPath "artifacts\duo\duo-admin-access-audit.csv"
}
if ([string]::IsNullOrWhiteSpace($BypassCsvPath)) {
  $BypassCsvPath = Join-Path -Path $script:ScriptRoot -ChildPath "artifacts\duo\duo-bypass-codes-audit.csv"
}

$script:AdminColumns = @(
  "AccountName",
  "AccountId",
  "ApiHost",
  "TotalAdmins",
  "AdminName",
  "AdminEmail",
  "AdminRole",
  "AdminEmailDomain",
  "AdminStatus",
  "AdminCreated",
  "AuditStatus",
  "AuditNotes"
)

$script:BypassColumns = @(
  "AccountName",
  "AccountId",
  "ApiHost",
  "UserName",
  "UserId",
  "UserEmail",
  "BypassCodeId",
  "BypassCreated",
  "BypassExpiration",
  "BypassReuseCount",
  "AuditStatus",
  "AuditNotes"
)

# ---------------------------------------------------------------------------
# Shared utility functions (consistent with other duo-audit-*.ps1 scripts)
# ---------------------------------------------------------------------------

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

function Get-ItemCount {
  param($Value)

  if ($null -eq $Value) {
    return 0
  }

  return @($Value).Count
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

# ---------------------------------------------------------------------------
# New functions specific to this audit
# ---------------------------------------------------------------------------

function ConvertFrom-UnixTimestamp {
  param($Value)

  if ($null -eq $Value) {
    return "Never"
  }

  $int = 0
  if (-not [int64]::TryParse([string] $Value, [ref] $int) -or $int -eq 0) {
    return "Never"
  }

  return ([System.DateTimeOffset]::FromUnixTimeSeconds($int)).ToString("o")
}

function Get-AdminEmailDomain {
  param([string] $Email)

  if ([string]::IsNullOrWhiteSpace($Email)) {
    return ""
  }

  $at = $Email.IndexOf('@')
  if ($at -lt 0 -or $at -eq ($Email.Length - 1)) {
    return ""
  }

  return $Email.Substring($at + 1).Trim().ToLowerInvariant()
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

function Get-DuoAdmins {
  param(
    [Parameter(Mandatory)][string] $ApiHost,
    [Parameter(Mandatory)][string] $AccountId,
    [int] $Limit = 300,
    [scriptblock] $Invoker
  )

  $all = @()
  $offset = 0

  while ($true) {
    $params = @{
      account_id = $AccountId
      limit      = $Limit
      offset     = $offset
    }

    $resp = if ($null -ne $Invoker) {
      & $Invoker "GET" $ApiHost "/admin/v1/admins" $params
    } else {
      Invoke-DuoApi -Method "GET" -ApiHost $ApiHost -Path "/admin/v1/admins" -Params $params
    }

    if ($resp.stat -ne "OK") {
      throw "List admins failed: $($resp | ConvertTo-Json -Depth 10)"
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

function Get-DuoAllUsers {
  param(
    [Parameter(Mandatory)][string] $ApiHost,
    [Parameter(Mandatory)][string] $AccountId,
    [int] $Limit = 300,
    [scriptblock] $Invoker
  )

  $all = @()
  $offset = 0

  while ($true) {
    $params = @{
      account_id = $AccountId
      limit      = $Limit
      offset     = $offset
    }

    $resp = if ($null -ne $Invoker) {
      & $Invoker "GET" $ApiHost "/admin/v1/users" $params
    } else {
      Invoke-DuoApi -Method "GET" -ApiHost $ApiHost -Path "/admin/v1/users" -Params $params
    }

    if ($resp.stat -ne "OK") {
      throw "List users failed: $($resp | ConvertTo-Json -Depth 10)"
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

  return @($all | Where-Object {
    ([string] (Get-PropertyValue -InputObject $_ -PropertyNames @("status"))) -ieq "bypass"
  })
}

function Get-DuoUserBypassCodes {
  param(
    [Parameter(Mandatory)][string] $ApiHost,
    [Parameter(Mandatory)][string] $AccountId,
    [Parameter(Mandatory)][string] $UserId,
    [scriptblock] $Invoker
  )

  $params = @{ account_id = $AccountId }

  $resp = if ($null -ne $Invoker) {
    & $Invoker "GET" $ApiHost "/admin/v1/users/$UserId/bypass_codes" $params
  } else {
    Invoke-DuoApi -Method "GET" -ApiHost $ApiHost -Path "/admin/v1/users/$UserId/bypass_codes" -Params $params
  }

  if ($resp.stat -ne "OK") {
    throw "List bypass codes failed for user '$UserId': $($resp | ConvertTo-Json -Depth 10)"
  }

  return @($resp.response | Where-Object { $null -ne $_ })
}

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

function Invoke-SelfTest {
  $results = New-Object System.Collections.Generic.List[object]

  try {
    Add-SelfTestResult -Results $results -Test "Resolve raw Duo host" -Passed ((Resolve-DuoHost -HostOrUrl "api-123.duosecurity.com") -eq "api-123.duosecurity.com")
    Add-SelfTestResult -Results $results -Test "Resolve Duo host from URL" -Passed ((Resolve-DuoHost -HostOrUrl "https://api-123.duosecurity.com/admin") -eq "api-123.duosecurity.com")

    # ConvertFrom-UnixTimestamp
    Add-SelfTestResult -Results $results -Test "UnixTimestamp null returns Never" -Passed ((ConvertFrom-UnixTimestamp -Value $null) -eq "Never")
    Add-SelfTestResult -Results $results -Test "UnixTimestamp zero returns Never" -Passed ((ConvertFrom-UnixTimestamp -Value 0) -eq "Never")
    Add-SelfTestResult -Results $results -Test "UnixTimestamp string zero returns Never" -Passed ((ConvertFrom-UnixTimestamp -Value "0") -eq "Never")
    $ts = ConvertFrom-UnixTimestamp -Value 1680307200
    Add-SelfTestResult -Results $results -Test "UnixTimestamp valid epoch converts to ISO8601" -Passed ($ts -match '^\d{4}-\d{2}-\d{2}T')

    # Get-AdminEmailDomain
    Add-SelfTestResult -Results $results -Test "EmailDomain extracts domain" -Passed ((Get-AdminEmailDomain -Email "sward@alliance-rubber.com") -eq "alliance-rubber.com")
    Add-SelfTestResult -Results $results -Test "EmailDomain lowercases result" -Passed ((Get-AdminEmailDomain -Email "user@ActaMSP.COM") -eq "actamsp.com")
    Add-SelfTestResult -Results $results -Test "EmailDomain empty for no at-sign" -Passed ((Get-AdminEmailDomain -Email "nodomain") -eq "")
    Add-SelfTestResult -Results $results -Test "EmailDomain empty for null" -Passed ((Get-AdminEmailDomain -Email "") -eq "")
    Add-SelfTestResult -Results $results -Test "EmailDomain empty for trailing at" -Passed ((Get-AdminEmailDomain -Email "user@") -eq "")

    # Get-DuoAdmins pagination
    $adminCalls = New-Object System.Collections.Generic.List[object]
    $adminResponses = New-Object 'System.Collections.Generic.Queue[object]'
    $adminResponses.Enqueue([PSCustomObject]@{
      stat     = "OK"
      response = @(
        [PSCustomObject]@{ admin_id = "A1"; email = "a@actamsp.com"; role = "Owner" },
        [PSCustomObject]@{ admin_id = "A2"; email = "b@client.com"; role = "Help Desk" }
      )
      metadata = [PSCustomObject]@{ next_offset = 2 }
    })
    $adminResponses.Enqueue([PSCustomObject]@{
      stat     = "OK"
      response = @(
        [PSCustomObject]@{ admin_id = "A3"; email = "c@actamsp.com"; role = "Help Desk" }
      )
      metadata = [PSCustomObject]@{}
    })
    $adminInvoker = {
      param($Method, $ApiHost, $Path, $Params)
      $adminCalls.Add([PSCustomObject]@{ Offset = [int] $Params["offset"] }) | Out-Null
      return $adminResponses.Dequeue()
    }.GetNewClosure()
    $pagedAdmins = @(Get-DuoAdmins -ApiHost "api-123.duosecurity.com" -AccountId "DA123" -Limit 2 -Invoker $adminInvoker)
    Add-SelfTestResult -Results $results -Test "Get-DuoAdmins paginates via metadata next_offset" -Passed (($pagedAdmins.Count -eq 3) -and ($adminCalls[1].Offset -eq 2))

    # Get-DuoAllUsers filters bypass client-side
    $bypassResponses = New-Object 'System.Collections.Generic.Queue[object]'
    $bypassResponses.Enqueue([PSCustomObject]@{
      stat     = "OK"
      response = @(
        [PSCustomObject]@{ user_id = "U1"; username = "kwelker"; status = "bypass" }
        [PSCustomObject]@{ user_id = "U2"; username = "jdoe";    status = "active" }
        [PSCustomObject]@{ user_id = "U3"; username = "asmith";  status = "disabled" }
      )
      metadata = [PSCustomObject]@{}
    })
    $bypassInvoker = {
      param($Method, $ApiHost, $Path, $Params)
      return $bypassResponses.Dequeue()
    }.GetNewClosure()
    $bypassUsers = @(Get-DuoAllUsers -ApiHost "api-123.duosecurity.com" -AccountId "DA123" -Invoker $bypassInvoker)
    Add-SelfTestResult -Results $results -Test "Get-DuoAllUsers filters bypass users client-side" -Passed (($bypassUsers.Count -eq 1) -and ($bypassUsers[0].user_id -eq "U1"))

    # Get-DuoUserBypassCodes
    $codeResponse = [PSCustomObject]@{
      stat     = "OK"
      response = @(
        [PSCustomObject]@{ bypass_code_id = "BC1"; expiration = $null; reuse_count = 0 }
      )
    }
    $codeInvoker = { param($Method, $ApiHost, $Path, $Params); return $codeResponse }.GetNewClosure()
    $codes = @(Get-DuoUserBypassCodes -ApiHost "api-123.duosecurity.com" -AccountId "DA123" -UserId "U1" -Invoker $codeInvoker)
    Add-SelfTestResult -Results $results -Test "Get-DuoUserBypassCodes returns codes" -Passed ($codes.Count -eq 1)

    # Env file
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
    }
    finally {
      if (Test-Path -LiteralPath $tempEnvPath) {
        Remove-Item -LiteralPath $tempEnvPath -Force -ErrorAction SilentlyContinue
      }
    }
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

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq "SelfTest") {
  Invoke-SelfTest
  return
}

if ([string]::IsNullOrWhiteSpace($AdminCsvPath)) {
  throw "AdminCsvPath cannot be empty."
}
if ([string]::IsNullOrWhiteSpace($BypassCsvPath)) {
  throw "BypassCsvPath cannot be empty."
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

if ([string]::IsNullOrWhiteSpace($MspEmailDomain)) {
  throw "MspEmailDomain cannot be empty."
}
$MspEmailDomain = $MspEmailDomain.Trim().ToLowerInvariant()

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
  AdminCsvPath          = $AdminCsvPath
  BypassCsvPath         = $BypassCsvPath
  MspEmailDomain        = $MspEmailDomain
  TotalAccounts         = Get-ItemCount -Value $accounts
  AuditedAccounts       = 0
  FailedAccounts        = 0
  TotalAdmins           = 0
  MspAdmins             = 0
  ExternalAdmins        = 0
  TotalBypassUsers      = 0
  TotalBypassCodes      = 0
  IndefiniteBypassCodes = 0
  ExpiringBypassCodes   = 0
}

$adminRows = @()
$bypassRows = @()

if ((Get-ItemCount -Value $accounts) -eq 0) {
  Write-Warning "No child accounts matched the requested filters."
}
else {
  Write-Host ("Targeting {0} child account(s). MSP domain: {1}" -f $summary.TotalAccounts, $MspEmailDomain)
  Write-Host ""

  foreach ($acct in $accounts) {
    $childId   = [string] $acct.account_id
    $childName = [string] $acct.name
    $childHostRaw = [string] $acct.api_hostname

    if ([string]::IsNullOrWhiteSpace($childId) -or [string]::IsNullOrWhiteSpace($childHostRaw)) {
      Write-Warning "Skipping account with missing account_id/api_hostname. Name='$childName'"
      continue
    }

    try {
      $childHost = Resolve-DuoHost -HostOrUrl $childHostRaw
    }
    catch {
      Write-Warning "Skipping [$childName] ($childId): invalid child host '$childHostRaw'."
      continue
    }

    Write-Host "==> [$childName] ($childId) host=$childHost"

    $accountFailed = $false

    # --- Admins ---
    try {
      $admins = @(Get-DuoAdmins -ApiHost $childHost -AccountId $childId)
      $totalAdmins = Get-ItemCount -Value $admins
      $summary.TotalAdmins += $totalAdmins

      Write-Host ("    Admins: {0}" -f $totalAdmins)

      foreach ($admin in $admins) {
        $adminEmail  = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $admin -PropertyNames @("email"))
        $adminDomain = Get-AdminEmailDomain -Email $adminEmail
        $auditStatus = if ($adminDomain -eq $MspEmailDomain) { "MspAdmin" } else { "ExternalAdmin" }
        $auditNotes  = if ($auditStatus -eq "ExternalAdmin") {
          "Admin email domain '$adminDomain' does not match MSP domain '$MspEmailDomain'. Verify this access is intentional."
        }
        else {
          "Admin email domain matches MSP domain."
        }

        if ($auditStatus -eq "MspAdmin") { $summary.MspAdmins++ } else { $summary.ExternalAdmins++ }

        $adminRows += [PSCustomObject][ordered]@{
          AccountName     = $childName
          AccountId       = $childId
          ApiHost         = $childHost
          TotalAdmins     = $totalAdmins
          AdminName       = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $admin -PropertyNames @("name"))
          AdminEmail      = $adminEmail
          AdminRole       = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $admin -PropertyNames @("role"))
          AdminEmailDomain = $adminDomain
          AdminStatus     = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $admin -PropertyNames @("status"))
          AdminCreated    = ConvertFrom-UnixTimestamp -Value (Get-PropertyValue -InputObject $admin -PropertyNames @("created"))
          AuditStatus     = $auditStatus
          AuditNotes      = $auditNotes
        }
      }
    }
    catch {
      $accountFailed = $true
      Write-Warning "Failed fetching admins for [$childName] ($childId): $($_.Exception.Message)"
      $adminRows += [PSCustomObject][ordered]@{
        AccountName      = $childName
        AccountId        = $childId
        ApiHost          = $childHost
        TotalAdmins      = ""
        AdminName        = ""
        AdminEmail       = ""
        AdminRole        = ""
        AdminEmailDomain = ""
        AdminStatus      = ""
        AdminCreated     = ""
        AuditStatus      = "Error"
        AuditNotes       = $_.Exception.Message
      }
    }

    # --- Bypass codes ---
    try {
      $bypassUsers = @(Get-DuoAllUsers -ApiHost $childHost -AccountId $childId)
      $totalBypassUsers = Get-ItemCount -Value $bypassUsers
      $summary.TotalBypassUsers += $totalBypassUsers

      Write-Host ("    Bypass users: {0}" -f $totalBypassUsers)

      foreach ($user in $bypassUsers) {
        $userId    = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $user -PropertyNames @("user_id"))
        $userName  = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $user -PropertyNames @("username"))
        $userEmail = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $user -PropertyNames @("email"))

        try {
          $codes = @(Get-DuoUserBypassCodes -ApiHost $childHost -AccountId $childId -UserId $userId)
          $summary.TotalBypassCodes += (Get-ItemCount -Value $codes)

          if ((Get-ItemCount -Value $codes) -eq 0) {
            # User is in bypass mode but has no codes stored — report the user with no code details
            $summary.IndefiniteBypassCodes++
            $bypassRows += [PSCustomObject][ordered]@{
              AccountName      = $childName
              AccountId        = $childId
              ApiHost          = $childHost
              UserName         = $userName
              UserId           = $userId
              UserEmail        = $userEmail
              BypassCodeId     = ""
              BypassCreated    = ""
              BypassExpiration = "Never"
              BypassReuseCount = ""
              AuditStatus      = "Indefinite"
              AuditNotes       = "User is in bypass status but no bypass codes were returned by the API."
            }
            continue
          }

          foreach ($code in $codes) {
            $expRaw  = Get-PropertyValue -InputObject $code -PropertyNames @("expiration")
            $expText = ConvertFrom-UnixTimestamp -Value $expRaw
            $auditStatus = if ($expText -eq "Never") { "Indefinite" } else { "Expiring" }
            $auditNotes  = if ($auditStatus -eq "Indefinite") {
              "Bypass code has no expiration. Verify this is intentional."
            }
            else {
              "Bypass code expires $expText."
            }

            if ($auditStatus -eq "Indefinite") { $summary.IndefiniteBypassCodes++ } else { $summary.ExpiringBypassCodes++ }

            $bypassRows += [PSCustomObject][ordered]@{
              AccountName      = $childName
              AccountId        = $childId
              ApiHost          = $childHost
              UserName         = $userName
              UserId           = $userId
              UserEmail        = $userEmail
              BypassCodeId     = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $code -PropertyNames @("bypass_code_id"))
              BypassCreated    = ConvertFrom-UnixTimestamp -Value (Get-PropertyValue -InputObject $code -PropertyNames @("created"))
              BypassExpiration = $expText
              BypassReuseCount = ConvertTo-ScalarText -Value (Get-PropertyValue -InputObject $code -PropertyNames @("reuse_count"))
              AuditStatus      = $auditStatus
              AuditNotes       = $auditNotes
            }
          }
        }
        catch {
          Write-Warning "Failed fetching bypass codes for user '$userName' ($userId) in [$childName]: $($_.Exception.Message)"
          $bypassRows += [PSCustomObject][ordered]@{
            AccountName      = $childName
            AccountId        = $childId
            ApiHost          = $childHost
            UserName         = $userName
            UserId           = $userId
            UserEmail        = $userEmail
            BypassCodeId     = ""
            BypassCreated    = ""
            BypassExpiration = ""
            BypassReuseCount = ""
            AuditStatus      = "Error"
            AuditNotes       = $_.Exception.Message
          }
        }
      }
    }
    catch {
      $accountFailed = $true
      Write-Warning "Failed fetching bypass users for [$childName] ($childId): $($_.Exception.Message)"
      $bypassRows += [PSCustomObject][ordered]@{
        AccountName      = $childName
        AccountId        = $childId
        ApiHost          = $childHost
        UserName         = ""
        UserId           = ""
        UserEmail        = ""
        BypassCodeId     = ""
        BypassCreated    = ""
        BypassExpiration = ""
        BypassReuseCount = ""
        AuditStatus      = "Error"
        AuditNotes       = $_.Exception.Message
      }
    }

    if ($accountFailed) {
      $summary.FailedAccounts++
    }
    else {
      $summary.AuditedAccounts++
    }
  }
}

$adminRows  = @($adminRows  | Sort-Object AccountName, AccountId, AdminEmail)
$bypassRows = @($bypassRows | Sort-Object AccountName, AccountId, UserName, BypassCodeId)

Write-CsvWithHeaders -Rows $adminRows  -Path $AdminCsvPath  -Columns $script:AdminColumns
Write-CsvWithHeaders -Rows $bypassRows -Path $BypassCsvPath -Columns $script:BypassColumns

Write-Host ""
Write-Host "Summary:"
$summary.GetEnumerator() | ForEach-Object {
  Write-Host ("  {0}: {1}" -f $_.Key, $_.Value)
}

[PSCustomObject] $summary
