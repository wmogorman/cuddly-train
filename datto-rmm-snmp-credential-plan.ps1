#requires -Version 5.1
<#
.SYNOPSIS
  Match IT Glue SNMPv3 passwords to Datto RMM sites and write a plan CSV.

.DESCRIPTION
  Queries IT Glue for the SNMPv3 Authentication and Privacy passphrases created under
  the Network Credentials category, then matches each IT Glue organization to a Datto
  RMM site by case-insensitive name. Writes a plan CSV to be reviewed before running
  the headless Playwright script that creates the credentials in the RMM UI.

  MatchStatus values in the output CSV:
    Matched           - IT Glue org matched a Datto RMM site; both passphrases present.
    Unmatched         - Both passphrases exist but no matching RMM site name found.
    MissingPassphrase - Org is present in IT Glue but is missing one or both passphrases.

  WARNING: The output CSV contains plaintext passphrases. It is written to the
  artifacts/ directory (gitignored). Treat it as sensitive and delete it after use.

.PARAMETER ITGlueApiKey
  IT Glue API key. Defaults to the ITGlueKey environment variable.

.PARAMETER ITGlueSubdomain
  IT Glue account subdomain (x-account-subdomain header).

.PARAMETER ITGlueBaseUri
  IT Glue API base URL. Default: https://api.itglue.com

.PARAMETER DattoRmmEnvFile
  Path to a .env file containing DATTO_RMM_API_KEY and DATTO_RMM_API_SECRET.
  Default: .\reports\datto-rmm.env

.PARAMETER DattoRmmApiUrl
  Datto RMM REST API base URL. Default: https://zinfandel-api.centrastage.net

.PARAMETER OutputCsvPath
  Output CSV path. Default: artifacts\datto-rmm\snmp-credential-plan.csv

.EXAMPLE
  .\datto-rmm-snmp-credential-plan.ps1 -ITGlueSubdomain 'datamax' -Verbose
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ITGlueApiKey = $env:ITGlueKey,

    [Parameter(Mandatory = $true)]
    [string]$ITGlueSubdomain,

    [Parameter(Mandatory = $false)]
    [string]$ITGlueBaseUri = 'https://api.itglue.com',

    [Parameter(Mandatory = $false)]
    [string]$DattoRmmEnvFile = (Join-Path $PSScriptRoot 'reports\datto-rmm.env'),

    [Parameter(Mandatory = $false)]
    [string]$DattoRmmApiUrl = 'https://zinfandel-api.centrastage.net',

    [Parameter(Mandatory = $false)]
    [string]$OutputCsvPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ITGlueApiKey)) {
    throw 'Missing IT Glue API key. Pass -ITGlueApiKey or set env var ITGlueKey.'
}

$ITGlueBaseUri  = $ITGlueBaseUri.TrimEnd('/')
$DattoRmmApiUrl = $DattoRmmApiUrl.TrimEnd('/')

if ([string]::IsNullOrWhiteSpace($OutputCsvPath)) {
    $artifactsDir = Join-Path $PSScriptRoot 'artifacts\datto-rmm'
    if (-not (Test-Path $artifactsDir)) { New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null }
    $OutputCsvPath = Join-Path $artifactsDir 'snmp-credential-plan.csv'
}

# ---------------------------------------------------------------------------
# IT Glue helper
# ---------------------------------------------------------------------------

function Invoke-ITGlue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][hashtable]$Query
    )

    $headers = @{
        'x-api-key'           = $ITGlueApiKey
        'x-account-subdomain' = $ITGlueSubdomain
        'Accept'              = 'application/vnd.api+json'
        'Content-Type'        = 'application/vnd.api+json'
    }

    $uriBuilder = [System.UriBuilder]::new(($ITGlueBaseUri + '/' + $Path.TrimStart('/')))
    if ($Query) {
        $pairs = @()
        foreach ($k in $Query.Keys) {
            $pairs += ('{0}={1}' -f [System.Uri]::EscapeDataString($k), [System.Uri]::EscapeDataString([string]$Query[$k]))
        }
        $uriBuilder.Query = [string]::Join('&', $pairs)
    }

    $attempt = 0
    $delay   = 2
    do {
        $attempt++
        try {
            return Invoke-RestMethod -Method GET -Uri $uriBuilder.Uri.AbsoluteUri -Headers $headers -ErrorAction Stop
        }
        catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 429 -or ($status -ge 500 -and $status -lt 600)) {
                if ($attempt -ge 4) { throw }
                Start-Sleep -Seconds $delay
                $delay = [Math]::Min(30, [int][Math]::Ceiling($delay * 1.5))
                continue
            }
            throw
        }
    } while ($attempt -le 4)
}

# ---------------------------------------------------------------------------
# Datto RMM helpers
# ---------------------------------------------------------------------------

function Read-EnvFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Env file not found: $Path" }
    $vars = @{}
    foreach ($line in (Get-Content $Path)) {
        $line = $line.Trim()
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^([^=]+)=(.*)$') { $vars[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    return $vars
}

function Get-OAuthToken {
    param([string]$BaseUrl, [string]$Key, [string]$Secret)
    $b64  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('public-client:public'))
    $body = "grant_type=password&username=$([Uri]::EscapeDataString($Key))&password=$([Uri]::EscapeDataString($Secret))"
    try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/auth/oauth/token" -Method POST `
            -Headers @{ Authorization = "Basic $b64" } -Body $body `
            -ContentType 'application/x-www-form-urlencoded'
        return $r.access_token
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        throw "Datto RMM authentication failed (HTTP $status). Check API key and secret."
    }
}

function Get-AllRmmSites {
    param([string]$Token)
    $all  = [System.Collections.Generic.List[object]]::new()
    $page = 0
    do {
        $uri      = "$DattoRmmApiUrl/api/v2/account/sites?max=250&page=$page"
        $response = Invoke-RestMethod -Uri $uri -Method GET `
            -Headers @{ Authorization = "Bearer $Token" } -ContentType 'application/json'
        if ($response.sites) { foreach ($s in $response.sites) { $all.Add($s) } }
        $nextUrl = if ($null -ne $response.pageDetails) { $response.pageDetails.nextPageUrl } else { $null }
        $page++
    } while (-not [string]::IsNullOrWhiteSpace($nextUrl))
    return $all
}

# ---------------------------------------------------------------------------
# Step 1: Build IT Glue org map
# ---------------------------------------------------------------------------

Write-Verbose 'Fetching IT Glue organizations...'
$orgMap = @{}  # orgId (string) -> orgName
$pageNum = 1
$hasMore = $true
while ($hasMore) {
    $response = Invoke-ITGlue -Path 'organizations' -Query @{
        'page[size]'   = 50
        'page[number]' = $pageNum
        'sort'         = 'id'
    }
    $batch = @($response.data)
    if ($batch.Count -eq 0) { break }
    foreach ($org in $batch) { $orgMap[[string]$org.id] = [string]$org.attributes.name }
    $hasMore = ($batch.Count -eq 50)
    $pageNum++
}
Write-Verbose "  Found $($orgMap.Count) IT Glue organizations."

# ---------------------------------------------------------------------------
# Step 2: Fetch SNMPv3 passwords from IT Glue
# ---------------------------------------------------------------------------

$snmpCategoryId = '369935'  # Network Credentials

$authMap = @{}   # orgId -> passphrase
$privMap = @{}   # orgId -> passphrase

# IT Glue list endpoint omits the password value — page through IDs then fetch each individually.
foreach ($credName in @('SNMPv3 Authentication Passphrase', 'SNMPv3 Privacy Passphrase')) {
    $isAuth  = ($credName -eq 'SNMPv3 Authentication Passphrase')
    $pageNum = 1
    $hasMore = $true
    $found   = 0
    Write-Verbose "Paging IT Glue '$credName' IDs..."
    while ($hasMore) {
        $response = Invoke-ITGlue -Path 'passwords' -Query @{
            'filter[name]'                 = $credName
            'filter[password_category_id]' = $snmpCategoryId
            'page[size]'                   = 100
            'page[number]'                 = $pageNum
            'sort'                         = 'id'
        }
        $batch = @($response.data)
        if ($batch.Count -eq 0) { break }
        foreach ($pw in $batch) {
            if (-not $pw) { continue }
            $orgId  = [string]$pw.attributes.'organization-id'
            if ([string]::IsNullOrWhiteSpace($orgId)) { $orgId = [string]$pw.attributes.'organization_id' }
            $pwName = [string]$pw.attributes.name
            if (-not ($pwName -ieq $credName) -or [string]::IsNullOrWhiteSpace($orgId)) { continue }
            $pwId   = [string]$pw.id
            $found++
            Write-Verbose "  Fetching passphrase for record $pwId (org $orgId)"
            $single    = Invoke-ITGlue -Path "passwords/$pwId"
            $passValue = [string]$single.data.attributes.password
            if ($isAuth) { $authMap[$orgId] = $passValue } else { $privMap[$orgId] = $passValue }
        }
        $hasMore = ($batch.Count -eq 100)
        $pageNum++
    }
    Write-Verbose "  '$credName': fetched $found passphrase(s)."
}

Write-Verbose "Auth passphrases: $($authMap.Count) | Privacy passphrases: $($privMap.Count)"

# ---------------------------------------------------------------------------
# Step 3: Fetch Datto RMM sites
# ---------------------------------------------------------------------------

Write-Verbose 'Authenticating with Datto RMM...'
$rmmVars   = Read-EnvFile -Path $DattoRmmEnvFile
$rmmKey    = if ($rmmVars.ContainsKey('DATTO_RMM_API_KEY'))    { $rmmVars['DATTO_RMM_API_KEY'] }    else { $env:DATTO_RMM_API_KEY }
$rmmSecret = if ($rmmVars.ContainsKey('DATTO_RMM_API_SECRET')) { $rmmVars['DATTO_RMM_API_SECRET'] } else { $env:DATTO_RMM_API_SECRET }

if ([string]::IsNullOrWhiteSpace($rmmKey))    { throw 'DATTO_RMM_API_KEY not found in env file or environment.' }
if ([string]::IsNullOrWhiteSpace($rmmSecret)) { throw 'DATTO_RMM_API_SECRET not found in env file or environment.' }

$rmmToken = Get-OAuthToken -BaseUrl $DattoRmmApiUrl -Key $rmmKey -Secret $rmmSecret
Write-Verbose 'Token obtained.'

Write-Verbose 'Fetching Datto RMM sites...'
$rmmSites = Get-AllRmmSites -Token $rmmToken
$siteMap  = @{}  # lowerName -> @{name; uid}
foreach ($site in $rmmSites) {
    $key = ([string]$site.name).ToLowerInvariant()
    if (-not $siteMap.ContainsKey($key)) {
        $siteMap[$key] = @{ name = [string]$site.name; uid = [string]$site.uid }
    }
}
Write-Verbose "  Found $($rmmSites.Count) Datto RMM sites."

# ---------------------------------------------------------------------------
# Step 4: Match and build output rows
# ---------------------------------------------------------------------------

$rows          = [System.Collections.Generic.List[PSCustomObject]]::new()
$countMatched  = 0
$countUnmatched = 0
$countMissing  = 0

foreach ($orgId in ($orgMap.Keys | Sort-Object)) {
    $orgName = $orgMap[$orgId]
    $hasAuth = $authMap.ContainsKey($orgId)
    $hasPriv = $privMap.ContainsKey($orgId)

    # Skip orgs that never had SNMP passwords created at all
    if (-not $hasAuth -and -not $hasPriv) { continue }

    $siteName = ''
    $siteUid  = ''
    $status   = ''

    if (-not $hasAuth -or -not $hasPriv) {
        $status = 'MissingPassphrase'
        $countMissing++
    } else {
        $lowerName = $orgName.ToLowerInvariant()
        if ($siteMap.ContainsKey($lowerName)) {
            $matched  = $siteMap[$lowerName]
            $siteName = $matched.name
            $siteUid  = $matched.uid
            $status   = 'Matched'
            $countMatched++
        } else {
            $status = 'Unmatched'
            $countUnmatched++
        }
    }

    $rows.Add([PSCustomObject]@{
        OrgName        = $orgName
        DattoSiteName  = $siteName
        DattoSiteUid   = $siteUid
        AuthPassphrase = if ($hasAuth) { $authMap[$orgId] } else { '' }
        PrivPassphrase = if ($hasPriv) { $privMap[$orgId] } else { '' }
        MatchStatus    = $status
    })
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

$rows | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Encoding UTF8

Write-Host ("Plan CSV written to: {0}" -f $OutputCsvPath)
Write-Host ("  Matched: {0} | Unmatched: {1} | MissingPassphrase: {2}" -f $countMatched, $countUnmatched, $countMissing)
Write-Host "  Review the CSV before running the headless Playwright script."
Write-Host "  CAUTION: CSV contains plaintext passphrases — delete after use."

if ($countUnmatched -gt 0) {
    Write-Warning ("$countUnmatched IT Glue org(s) have SNMP passwords but no matching Datto RMM site name." +
        " Review the Unmatched rows in the CSV to identify naming discrepancies.")
}
