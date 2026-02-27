<#
.SYNOPSIS
  Push Duo Custom Branding (draft + optional publish) across child accounts.

.REQUIREMENTS
  - Windows PowerShell 5.1+ (or PowerShell 7+)
  - An Accounts API application in the parent account (ikey/skey/api host)
  - Child targeting via each child api_hostname + account_id parameter

.NOTES
  Duo Admin API Custom Branding endpoints:
    POST /admin/v1/branding/draft
    POST /admin/v1/branding/draft/publish

  Image constraints:
    - Logo: PNG, <= 200 KB
    - Background: PNG, <= 3 MB
#>

param(
  [Parameter(Mandatory)] [string] $ParentApiHost,
  [Parameter(Mandatory)] [string] $IKey,
  [Parameter(Mandatory)] [string] $SKey,

  [Parameter(Mandatory)] [string] $LogoPngPath,
  [Parameter()]          [string] $BackgroundPngPath,
  [Parameter()]          [ValidatePattern('^#[0-9A-Fa-f]{3}([0-9A-Fa-f]{3})?$')]
                       [string] $CardAccentColor = "#1F6FEB",
  [Parameter()]          [ValidatePattern('^#[0-9A-Fa-f]{3}([0-9A-Fa-f]{3})?$')]
                       [string] $PageBackgroundColor = "#0B1220",

  [string[]] $OnlyAccountIds,
  [string[]] $OnlyAccountNames,

  # Set -Publish:$false to stage only (draft without publishing).
  [switch] $Publish = $true,

  # Preview draft/publish requests while still reading account list.
  [switch] $WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Normalize-DuoHost {
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

  # Duo encoding: keep unreserved ASCII (A-Z, a-z, 0-9, _, ., ~, -), encode the rest.
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
    [Parameter(Mandatory)][string] $Host,
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
    $Host.ToLowerInvariant()
    $Path
    $paramsLine
  ) -join "`n"

  $hmac = New-Object System.Security.Cryptography.HMACSHA1 ([System.Text.Encoding]::UTF8.GetBytes($SKey))
  $sigBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canon))
  $sigHex = -join ($sigBytes | ForEach-Object { $_.ToString("x2") })

  $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$IKey`:$sigHex"))
  return @{
    "Date"          = $date
    "Authorization" = "Basic $basic"
    "Host"          = $Host
  }
}

function Invoke-DuoApi {
  param(
    [Parameter(Mandatory)][ValidateSet("GET","POST","DELETE")] [string] $Method,
    [Parameter(Mandatory)][string] $Host,
    [Parameter(Mandatory)][string] $Path,
    [hashtable] $Params = @{}
  )

  $headers = New-DuoAuthHeaders -Method $Method -Host $Host -Path $Path -Params $Params -IKey $IKey -SKey $SKey
  $uri = "https://$Host$Path"
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

function Assert-PngFile {
  param(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][Int64] $MaxBytes,
    [Parameter(Mandatory)][string] $Label
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "$Label file not found: $Path"
  }

  if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -ne ".png") {
    throw "$Label must be a .png file: $Path"
  }

  $file = Get-Item -LiteralPath $Path
  if ($file.Length -gt $MaxBytes) {
    throw "$Label file exceeds size limit ($($file.Length) bytes > $MaxBytes bytes): $Path"
  }
}

function Get-Base64Png {
  param([Parameter(Mandatory)][string] $Path)

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  return [Convert]::ToBase64String($bytes)
}

$ParentApiHost = Normalize-DuoHost -HostOrUrl $ParentApiHost
Assert-PngFile -Path $LogoPngPath -MaxBytes 204800 -Label "Logo"
if ($BackgroundPngPath) {
  Assert-PngFile -Path $BackgroundPngPath -MaxBytes 3145728 -Label "Background"
}

$accountsResp = Invoke-DuoApi -Method POST -Host $ParentApiHost -Path "/accounts/v1/account/list" -Params @{}
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

$logoB64 = Get-Base64Png -Path $LogoPngPath
$bgB64 = $null
if ($BackgroundPngPath) {
  $bgB64 = Get-Base64Png -Path $BackgroundPngPath
}

$summary = [ordered]@{
  Total     = $accounts.Count
  Drafted   = 0
  Published = 0
  Failed    = 0
  Skipped   = 0
}

Write-Host ("Targeting {0} child account(s). Publish={1} WhatIf={2}" -f $summary.Total, [bool]$Publish, [bool]$WhatIf)

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
    $childHost = Normalize-DuoHost -HostOrUrl $childHostRaw
  } catch {
    $summary.Skipped++
    Write-Warning "Skipping [$childName] ($childId): invalid child host '$childHostRaw'."
    continue
  }

  Write-Host "==> [$childName] ($childId) host=$childHost"

  try {
    $draftParams = @{
      account_id            = $childId
      logo                  = $logoB64
      card_accent_color     = $CardAccentColor
      page_background_color = $PageBackgroundColor
    }
    if ($bgB64) {
      $draftParams.background_img = $bgB64
    }

    $draftResp = Invoke-DuoApi -Method POST -Host $childHost -Path "/admin/v1/branding/draft" -Params $draftParams
    if ($draftResp -and $draftResp.stat -ne "OK") {
      throw "Draft update failed: $($draftResp | ConvertTo-Json -Depth 10)"
    }
    $summary.Drafted++

    if (-not $Publish) {
      Write-Host "    Draft updated (not published)."
      continue
    }

    $pubResp = Invoke-DuoApi -Method POST -Host $childHost -Path "/admin/v1/branding/draft/publish" -Params @{ account_id = $childId }
    if ($pubResp -and $pubResp.stat -ne "OK") {
      throw "Publish failed: $($pubResp | ConvertTo-Json -Depth 10)"
    }
    $summary.Published++
    Write-Host "    Published."
  } catch {
    $summary.Failed++
    Write-Warning "Failed for [$childName] ($childId): $($_.Exception.Message)"
  }
}

Write-Host ("Done. Total={0} Drafted={1} Published={2} Failed={3} Skipped={4}" -f $summary.Total, $summary.Drafted, $summary.Published, $summary.Failed, $summary.Skipped)
