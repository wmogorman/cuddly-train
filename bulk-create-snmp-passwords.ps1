#requires -Version 5.1
<#
.SYNOPSIS
  Create SNMPv3 Authentication and Privacy passphrase records in IT Glue for every organization.

.DESCRIPTION
  Paginates through all IT Glue organizations and creates two password records per org:
    - "SNMPv3 Authentication Passphrase" with notes "SHA"
    - "SNMPv3 Privacy Passphrase" with notes "AES"
  Each organization receives unique randomly-generated passphrases. Records are placed
  under the specified password category (default: Network).
  Supports -WhatIf for dry-run validation before committing writes.

.PARAMETER ApiKey
  IT Glue API key. Defaults to the ITGlueKey environment variable.

.PARAMETER Subdomain
  IT Glue account subdomain (x-account-subdomain header).

.PARAMETER BaseUri
  Base IT Glue API URL. Default: https://api.itglue.com

.PARAMETER PasswordCategoryName
  IT Glue password category to place records under. Default: Network

.PARAMETER PassphraseLength
  Length of generated passphrases. Default: 20 (minimum: 12)

.PARAMETER PageSize
  Number of organizations to fetch per page. Default: 50

.PARAMETER RateLimitChanges
  Maximum password creates allowed per rolling window. Default: 3000. Set to 0 to disable.

.PARAMETER RateLimitWindowSeconds
  Rolling window length in seconds. Default: 300 (5 minutes). Set to 0 to disable.

.EXAMPLE
  .\bulk-create-snmp-passwords.ps1 -Subdomain 'datamax' -WhatIf -Verbose

.EXAMPLE
  .\bulk-create-snmp-passwords.ps1 -Subdomain 'datamax' -WhatIf:$false -Verbose
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ApiKey = $env:ITGlueKey,

    [Parameter(Mandatory = $true)]
    [string]$Subdomain,

    [Parameter(Mandatory = $false)]
    [string]$BaseUri = 'https://api.itglue.com',

    [Parameter(Mandatory = $false)]
    [string]$PasswordCategoryName = 'Network Credentials',

    [Parameter(Mandatory = $false)]
    [int]$PassphraseLength = 20,

    [Parameter(Mandatory = $false)]
    [int]$PageSize = 50,

    [Parameter(Mandatory = $false)]
    [int]$RateLimitChanges = 3000,

    [Parameter(Mandatory = $false)]
    [int]$RateLimitWindowSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    throw 'Missing API key. Pass -ApiKey or set env var ITGlueKey.'
}

$BaseUri = $BaseUri.TrimEnd('/')
$throttleEnabled = ($RateLimitChanges -gt 0 -and $RateLimitWindowSeconds -gt 0)

function Invoke-ITGlue {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][hashtable]$Query,
        [Parameter(Mandatory = $false)]$Body,
        [int]$MaxRetries = 4
    )

    $headers = @{
        'x-api-key'           = $ApiKey
        'x-account-subdomain' = $Subdomain
        'Accept'              = 'application/vnd.api+json'
        'Content-Type'        = 'application/vnd.api+json'
    }

    $uriBuilder = [System.UriBuilder]::new(($BaseUri + '/' + $Path.TrimStart('/')))
    if ($Query) {
        $pairs = @()
        foreach ($k in $Query.Keys) {
            $pairs += ('{0}={1}' -f [System.Uri]::EscapeDataString($k), [System.Uri]::EscapeDataString([string]$Query[$k]))
        }
        $uriBuilder.Query = [string]::Join('&', $pairs)
    }

    $attempt = 0
    $delay = 2

    do {
        $attempt++
        try {
            $invokeParams = @{
                Method      = $Method
                Uri         = $uriBuilder.Uri.AbsoluteUri
                Headers     = $headers
                ErrorAction = 'Stop'
            }

            if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
                $invokeParams['Body'] = $Body
            }

            return Invoke-RestMethod @invokeParams
        }
        catch {
            $status = $null
            $bodyText = $null
            $bodySummary = $null

            if ($_.Exception -and $_.Exception.Response) {
                if ($_.Exception.Response.StatusCode) {
                    $status = [int]$_.Exception.Response.StatusCode
                }
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    if ($stream) {
                        $reader = New-Object System.IO.StreamReader($stream)
                        $bodyText = $reader.ReadToEnd()
                        $reader.Dispose()
                    }
                }
                catch {}
            }

            if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
                $bodySummary = $bodyText.Trim()
                try {
                    $json = $bodyText.Trim() | ConvertFrom-Json -ErrorAction Stop
                    $messages = @()
                    if ($json.errors) {
                        foreach ($err in $json.errors) {
                            $parts = @()
                            if ($err.title)  { $parts += [string]$err.title }
                            if ($err.detail) { $parts += [string]$err.detail }
                            if ($err.source -and $err.source.pointer) { $parts += "Pointer: $($err.source.pointer)" }
                            if ($parts.Count -gt 0) { $messages += ($parts -join ' | ') }
                        }
                    }
                    elseif ($json.error)   { $messages += [string]$json.error }
                    elseif ($json.message) { $messages += [string]$json.message }
                    if ($messages.Count -gt 0) { $bodySummary = ($messages -join '; ') }
                }
                catch {}
            }

            if (-not $bodySummary) { $bodySummary = '[no response body]' }

            if ($status -eq 429 -or ($status -ge 500 -and $status -lt 600)) {
                if ($attempt -ge $MaxRetries) {
                    throw (New-Object System.Exception("IT Glue request failed ($status). Body: $bodySummary", $_.Exception))
                }
                Start-Sleep -Seconds $delay
                $delay = [Math]::Min(30, [int][Math]::Ceiling($delay * 1.5))
                continue
            }

            throw (New-Object System.Exception("IT Glue request failed ($status). Body: $bodySummary", $_.Exception))
        }
    } while ($attempt -le $MaxRetries)
}

function New-RandomPassphrase {
    param([int]$Length = 20)

    if ($Length -lt 12) { throw 'PassphraseLength must be at least 12.' }

    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghijkmnopqrstuvwxyz'
    $digits  = '23456789'
    $symbols = '!@#$%^&*()-_=+[]{}<>?'
    $all     = $upper + $lower + $digits + $symbols

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] $Length
        $rng.GetBytes($bytes)

        $sb = New-Object System.Text.StringBuilder
        $classIndex = 0
        foreach ($class in @($upper, $lower, $digits, $symbols)) {
            $null = $sb.Append($class[$bytes[$classIndex] % $class.Length])
            $classIndex++
        }
        for ($i = $sb.Length; $i -lt $Length; $i++) {
            $null = $sb.Append($all[$bytes[$i] % $all.Length])
        }

        $chars = $sb.ToString().ToCharArray()
        for ($i = $chars.Length - 1; $i -gt 0; $i--) {
            $swap = New-Object byte[] 1
            $rng.GetBytes($swap)
            $j = $swap[0] % ($i + 1)
            if ($j -ne $i) {
                $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
            }
        }
        return -join $chars
    }
    finally {
        $rng.Dispose()
    }
}

function Get-PasswordCategoryId {
    param([string]$Name)

    $response = Invoke-ITGlue -Method GET -Path 'password_categories' -Query @{ 'filter[name]' = $Name; 'page[size]' = 2 }
    $candidate = $null

    if ($response.data) {
        foreach ($item in $response.data) {
            if ([string]::Equals($item.attributes.name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $candidate = [string]$item.id
                break
            }
        }
        if (-not $candidate) { $candidate = [string](@($response.data)[0].id) }
    }

    if (-not $candidate) {
        throw "Password category '$Name' not found in IT Glue."
    }
    return $candidate
}

function New-SNMPPassword {
    param(
        [string]$OrgId,
        [string]$CategoryId,
        [string]$Name,
        [string]$Password,
        [string]$Notes
    )

    $body = @{
        data = @{
            type       = 'passwords'
            attributes = @{
                name                   = $Name
                password               = $Password
                notes                  = $Notes
                'organization_id'      = [long]$OrgId
                'password_category_id' = [long]$CategoryId
            }
        }
    } | ConvertTo-Json -Depth 10

    return Invoke-ITGlue -Method POST -Path 'passwords' -Body $body
}

# --- Main ---

Write-Verbose "Resolving password category '$PasswordCategoryName'..."
$categoryId = Get-PasswordCategoryId -Name $PasswordCategoryName
Write-Verbose "Category '$PasswordCategoryName' => ID $categoryId"

$windowStart     = Get-Date
$windowCount     = 0
$orgsProcessed   = 0
$passwordsCreated = 0
$errors          = [System.Collections.Generic.List[string]]::new()

$pageNumber = 1
$hasMore    = $true

while ($hasMore) {
    $response = Invoke-ITGlue -Method GET -Path 'organizations' -Query @{
        'page[size]'   = $PageSize
        'page[number]' = $pageNumber
        'sort'         = 'id'
    }

    $orgs = @($response.data)
    if ($orgs.Count -eq 0) { break }

    foreach ($org in $orgs) {
        $orgId   = [string]$org.id
        $orgName = [string]$org.attributes.name
        $orgsProcessed++

        try {
            $authTarget = "org '$orgName' (ID=$orgId) — SNMPv3 Authentication Passphrase"
            if ($PSCmdlet.ShouldProcess($authTarget, 'Create IT Glue password')) {
                $authPass = New-RandomPassphrase -Length $PassphraseLength
                $r = New-SNMPPassword -OrgId $orgId -CategoryId $categoryId `
                    -Name 'SNMPv3 Authentication Passphrase' -Password $authPass -Notes 'SHA'
                if (-not $r.data -or -not $r.data.id) { throw 'Unexpected API response for auth passphrase.' }
                $passwordsCreated++
                $windowCount++
                Write-Verbose "[CREATED] Auth passphrase (ID=$($r.data.id)) for '$orgName'"
            }

            if ($throttleEnabled -and $windowCount -ge $RateLimitChanges) {
                $elapsed   = (Get-Date) - $windowStart
                $remaining = [int][Math]::Ceiling($RateLimitWindowSeconds - $elapsed.TotalSeconds)
                if ($remaining -gt 0) {
                    Write-Verbose "Rate limit reached ($windowCount creates). Sleeping $remaining s."
                    Start-Sleep -Seconds $remaining
                }
                $windowStart = Get-Date
                $windowCount = 0
            }

            $privTarget = "org '$orgName' (ID=$orgId) — SNMPv3 Privacy Passphrase"
            if ($PSCmdlet.ShouldProcess($privTarget, 'Create IT Glue password')) {
                $privPass = New-RandomPassphrase -Length $PassphraseLength
                $r = New-SNMPPassword -OrgId $orgId -CategoryId $categoryId `
                    -Name 'SNMPv3 Privacy Passphrase' -Password $privPass -Notes 'AES'
                if (-not $r.data -or -not $r.data.id) { throw 'Unexpected API response for privacy passphrase.' }
                $passwordsCreated++
                $windowCount++
                Write-Verbose "[CREATED] Privacy passphrase (ID=$($r.data.id)) for '$orgName'"
            }

            if ($throttleEnabled -and $windowCount -ge $RateLimitChanges) {
                $elapsed   = (Get-Date) - $windowStart
                $remaining = [int][Math]::Ceiling($RateLimitWindowSeconds - $elapsed.TotalSeconds)
                if ($remaining -gt 0) {
                    Write-Verbose "Rate limit reached ($windowCount creates). Sleeping $remaining s."
                    Start-Sleep -Seconds $remaining
                }
                $windowStart = Get-Date
                $windowCount = 0
            }
        }
        catch {
            $msg = $_.Exception.Message
            $errors.Add("Org '$orgName' (ID=$orgId): $msg")
            Write-Warning "Skipping org '$orgName' (ID=$orgId): $msg"
        }
    }

    $hasMore = ($orgs.Count -eq $PageSize)
    $pageNumber++
}

Write-Output ("Run complete. Orgs processed: {0} | Passwords created: {1} | Errors: {2}" -f $orgsProcessed, $passwordsCreated, $errors.Count)

if ($errors.Count -gt 0) {
    Write-Warning ("Completed with {0} error(s):" -f $errors.Count)
    foreach ($e in $errors) {
        Write-Warning "  $e"
    }
}
