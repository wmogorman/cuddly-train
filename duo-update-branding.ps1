<#
.SYNOPSIS
  Push Duo Custom Branding (draft + publish) across all child accounts (MSP parent/child).

.REQUIREMENTS
  - Windows PowerShell 5.1+ (or PowerShell 7+, should work)
  - An Accounts API application in the PARENT account (ikey/skey/api host)
  - That same Accounts API app is used to call Admin API in CHILD accounts by:
      - Sending to each child api_hostname
      - Including account_id=CHILDID in request parameters  (per Duo docs)
.NOTES
  Duo Admin API Custom Branding endpoints:
    POST /admin/v1/branding/draft
    POST /admin/v1/branding/draft/publish
  Image constraints (from Duo docs): PNG, base64; logo <= 200KB, background <= 3MB, size constraints.
#>

param(
  [Parameter(Mandatory)] [string] $ParentApiHost, # e.g. api-xxxxxx.duosecurity.com (Accounts API app host)
  [Parameter(Mandatory)] [string] $IKey,
  [Parameter(Mandatory)] [string] $SKey,

  [Parameter(Mandatory)] [string] $LogoPngPath,        # PNG logo file
  [Parameter()]          [string] $BackgroundPngPath,  # optional PNG background
  [Parameter()]          [ValidatePattern('^#[0-9A-Fa-f]{3}([0-9A-Fa-f]{3})?$')]
                       [string] $CardAccentColor = "#1F6FEB",
  [Parameter()]          [ValidatePattern('^#[0-9A-Fa-f]{3}([0-9A-Fa-f]{3})?$')]
                       [string] $PageBackgroundColor = "#0B1220",

  # Optional targeting
  [string[]] $OnlyAccountIds,
  [string[]] $OnlyAccountNames,

  # If you want to stage (draft only) first, set -Publish:$false
  [switch] $Publish = $true,

  # If you want to just preview what would happen:
  [switch] $WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-DuoUrlEncode {
  param([Parameter(Mandatory)][string] $Value)

  # Duo encoding rules: encode all bytes except ASCII letters/digits/underscore/period/tilde/hyphen.
  # Use uppercase hex A-F. :contentReference[oaicite:4]{index=4}
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
  $sb = New-Object System.Text.StringBuilder

  foreach ($b in $bytes) {
    $ch = [char]$b
    $isUnreserved =
      ($b -ge 0x41 -and $b -le 0x5A) -or # A-Z
      ($b -ge 0x61 -and $b -le 0x7A) -or # a-z
      ($b -ge 0x30 -and $b -le 0x39) -or # 0-9
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

  # Lexicographically sort by key; key/value are URL-encoded.
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

  # Date must be RFC 2822 and must match what’s signed. :contentReference[oaicite:5]{index=5}
  $date = [System.DateTimeOffset]::UtcNow.ToString("r") # RFC1123 == RFC2822-style used by Duo

  $paramsLine = Get-DuoParamsString -Params $Params  # may be empty string
  $canon = @(
    $date
    $Method.ToUpperInvariant()
    $Host.ToLowerInvariant()
    $Path
    $paramsLine
  ) -join "`n"

  $hmac = New-Object System.Security.Cryptography.HMACSHA1 ([System.Text.Encoding]::UTF8.GetBytes($SKey))
  $sigBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canon))
  $sigHex = -join ($sigBytes | ForEach-Object { $_.ToString("x2") }) # hex ASCII

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

  if ($WhatIf) {
    $paramsPreview = Get-DuoParamsString -Params $Params
    Write-Host "[WHATIF] $Method $uri  params: $paramsPreview"
    return $null
  }

  if ($Method -in @("GET","DELETE")) {
    $qs = Get-DuoParamsString -Params $Params
    if ($qs) { $uri = "$uri`?$qs" }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
  }

  # POST: send x-www-form-urlencoded body; params must be same ones used for signing. :contentReference[oaicite:6]{index=6}
  $body = Get-DuoParamsString -Params $Params
  return Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -ContentType "application/x-www-form-urlencoded" -Body $body
}

function Get-Base64Png {
  param([Parameter(Mandatory)][string] $Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  return [Convert]::ToBase64String($bytes)
}

# --- 1) Retrieve child accounts from parent via Accounts API :contentReference[oaicite:7]{index=7}
$accountsResp = Invoke-DuoApi -Method POST -Host $ParentApiHost -Path "/accounts/v1/account/list" -Params @{}
if (-not $accountsResp) { return }

if ($accountsResp.stat -ne "OK") {
  throw "Accounts API returned FAIL: $($accountsResp | ConvertTo-Json -Depth 10)"
}

# Duo returns response as either array or object depending on implementation;
# normalize to array of accounts.
$accounts = $accountsResp.response
if ($accounts -isnot [System.Collections.IEnumerable] -or $accounts -is [string]) {
  $accounts = @($accounts)
}

# Optional filters
if ($OnlyAccountIds) {
  $accounts = $accounts | Where-Object { $OnlyAccountIds -contains $_.account_id }
}
if ($OnlyAccountNames) {
  $accounts = $accounts | Where-Object { $OnlyAccountNames -contains $_.name }
}

# --- 2) Prepare branding payload (base64 PNGs, colors)
$logoB64 = Get-Base64Png -Path $LogoPngPath
$bgB64 = $null
if ($BackgroundPngPath) { $bgB64 = Get-Base64Png -Path $BackgroundPngPath }

# --- 3) For each child: send Admin API calls to child's api_hostname with account_id param :contentReference[oaicite:8]{index=8}
foreach ($acct in $accounts) {
  $childId = [string]$acct.account_id
  $childHost = [string]$acct.api_hostname
  $childName = [string]$acct.name

  Write-Host "==> [$childName] ($childId) host=$childHost"

  # 3a) Set draft branding :contentReference[oaicite:9]{index=9}
  $draftParams = @{
    account_id            = $childId
    logo                  = $logoB64
    card_accent_color     = $CardAccentColor
    page_background_color = $PageBackgroundColor
  }
  if ($bgB64) { $draftParams.background_img = $bgB64 }

  $draftResp = Invoke-DuoApi -Method POST -Host $childHost -Path "/admin/v1/branding/draft" -Params $draftParams
  if ($draftResp -and $draftResp.stat -ne "OK") {
    Write-Warning "Draft update FAIL for [$childName]: $($draftResp | ConvertTo-Json -Depth 10)"
    continue
  }

  if (-not $Publish) { continue }

  # 3b) Publish draft branding :contentReference[oaicite:10]{index=10}
  # Admin API doc says no parameters, but for child-targeting we include account_id (per Accounts API “with Admin API”). :contentReference[oaicite:11]{index=11}
  $pubResp = Invoke-DuoApi -Method POST -Host $childHost -Path "/admin/v1/branding/draft/publish" -Params @{ account_id = $childId }
  if ($pubResp -and $pubResp.stat -ne "OK") {
    Write-Warning "Publish FAIL for [$childName]: $($pubResp | ConvertTo-Json -Depth 10)"
    continue
  }

  Write-Host "    Published."
}

Write-Host "Done."