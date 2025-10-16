#requires -Version 5.1
<#
.SYNOPSIS
  Bulk create IT Glue passwords from a CSV file.

.DESCRIPTION
  Reads a CSV that contains at minimum username, given name, email, and organization
  columns. For each row the script creates an IT Glue password and writes an output CSV
  that mirrors the input columns with an additional PasswordId column containing the
  newly created record identifier.

.PARAMETER InputCsvPath
  Path to the source CSV. Columns default to Username, GivenName, Email, and Organization.

.PARAMETER OutputCsvPath
  Destination CSV path. When omitted, "-with-password-ids" is appended to the source filename.

.PARAMETER ApiKey
  IT Glue API key. Defaults to the ITGlueKey environment variable.

.PARAMETER Subdomain
  IT Glue account subdomain (x-account-subdomain header).

.PARAMETER BaseUri
  Base IT Glue API URL. Default: https://api.itglue.com

.PARAMETER PasswordCategoryName
  Target password category name. Default: General

.PARAMETER PasswordLength
  Length of the generated passwords. Default: 20

.PARAMETER UsernameColumn
  Column name for usernames. Default: Username

.PARAMETER GivenNameColumn
  Column name for given names. Default: GivenName

.PARAMETER EmailColumn
  Column name for email addresses. Default: Email

.PARAMETER OrganizationColumn
  Column name for organization names. Default: Organization

.PARAMETER PasswordFolderId
  Optional IT Glue password folder ID to place the new records under.

.PARAMETER DryRun
  Parse the CSV and resolve organizations/categories, but do not create passwords.

.EXAMPLE
  .\bulk-create-passwords.ps1 -InputCsvPath .\users.csv -Subdomain 'contoso'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputCsvPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputCsvPath,

    [Parameter(Mandatory = $false)]
    [string]$ApiKey = $env:ITGlueKey,

    [Parameter(Mandatory = $true)]
    [string]$Subdomain,

    [Parameter(Mandatory = $false)]
    [string]$BaseUri = 'https://api.itglue.com',

    [Parameter(Mandatory = $false)]
    [string]$PasswordCategoryName = 'VPN',

    [Parameter(Mandatory = $false)]
    [Nullable[int]]$PasswordFolderId,

    [Parameter(Mandatory = $false)]
    [int]$PasswordLength = 20,

    [Parameter(Mandatory = $false)]
    [string]$UsernameColumn = 'Username',

    [Parameter(Mandatory = $false)]
    [string]$GivenNameColumn = 'GivenName',

    [Parameter(Mandatory = $false)]
    [string]$EmailColumn = 'Email',

    [Parameter(Mandatory = $false)]
    [string]$OrganizationColumn = 'Organization',

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    throw 'Missing API key. Pass -ApiKey or set env var ITGlueKey.'
}

$resolvedInput = Resolve-Path -LiteralPath $InputCsvPath -ErrorAction Stop
$InputCsvPath = $resolvedInput.ProviderPath

if (-not $OutputCsvPath) {
    $dir = [System.IO.Path]::GetDirectoryName($InputCsvPath)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($InputCsvPath)
    $ext = [System.IO.Path]::GetExtension($InputCsvPath)
    $OutputCsvPath = [System.IO.Path]::Combine($dir, ($name + '-with-password-ids' + $ext))
}

$BaseUri = $BaseUri.TrimEnd('/')

$csvRows = Import-Csv -Path $InputCsvPath
if (-not $csvRows) {
    throw "Input CSV '$InputCsvPath' is empty or unreadable."
}

Write-Verbose ("Loaded {0} row(s) from {1}" -f $csvRows.Count, $InputCsvPath)

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

    $uriBuilder = [System.UriBuilder]::new(($BaseUri.TrimEnd('/') + '/' + $Path.TrimStart('/')))
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
                    $responseStream = $_.Exception.Response.GetResponseStream()
                    if ($responseStream) {
                        $reader = New-Object System.IO.StreamReader($responseStream)
                        $bodyText = $reader.ReadToEnd()
                        $reader.Dispose()
                    }
                }
                catch {}
            }

            if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
                $trimmedBody = $bodyText.Trim()
                $bodySummary = $trimmedBody
                try {
                    $json = $trimmedBody | ConvertFrom-Json -ErrorAction Stop
                    $messages = @()

                    if ($json.errors) {
                        foreach ($err in $json.errors) {
                            $parts = @()
                            if ($err.title) { $parts += [string]$err.title }
                            if ($err.detail) { $parts += [string]$err.detail }
                            if ($err.source -and $err.source.pointer) {
                                $parts += ("Pointer: {0}" -f [string]$err.source.pointer)
                            }
                            if ($parts.Count -gt 0) {
                                $messages += ($parts -join ' | ')
                            }
                        }
                    }
                    elseif ($json.error) {
                        $messages += [string]$json.error
                    }
                    elseif ($json.message) {
                        $messages += [string]$json.message
                    }

                    if ($messages.Count -gt 0) {
                        $bodySummary = ($messages -join '; ')
                    }
                }
                catch {}
            }

            if (-not $bodySummary) {
                $bodySummary = '[no response body]'
            }

            if ($status -eq 429 -or ($status -ge 500 -and $status -lt 600)) {
                if ($attempt -ge $MaxRetries) {
                    throw (New-Object System.Exception(("IT Glue request failed ({0}). Body: {1}" -f $status, $bodySummary), $_.Exception))
                }
                Start-Sleep -Seconds $delay
                $delay = [Math]::Min(30, [int][Math]::Ceiling($delay * 1.5))
                continue
            }

            throw (New-Object System.Exception(("IT Glue request failed ({0}). Body: {1}" -f $status, $bodySummary), $_.Exception))
        }
    } while ($attempt -le $MaxRetries)
}

function Get-ColumnValue {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Row,
        [Parameter(Mandatory = $true)][string]$Column
    )

    $property = $Row.PSObject.Properties |
        Where-Object { $_.Name -eq $Column }

    if (-not $property) {
        $property = $Row.PSObject.Properties |
            Where-Object { $_.Name -ieq $Column }
    }

    if ($property) {
        return [string]$property.Value
    }

    return $null
}

function New-RandomPassword {
    param([int]$Length = 20)

    if ($Length -lt 12) {
        throw 'PasswordLength must be at least 12 characters.'
    }

    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digits = '23456789'
    $symbols = '!@#$%^&*()-_=+[]{}<>?'
    $allChars = ($upper + $lower + $digits + $symbols)

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $bytes = New-Object byte[] $Length
        $rng.GetBytes($bytes)

        $result = New-Object System.Text.StringBuilder
        $classes = @($upper, $lower, $digits, $symbols)
        $classIndex = 0

        # Ensure at least one of each character class
        foreach ($class in $classes) {
            $idx = $bytes[$classIndex] % $class.Length
            $null = $result.Append($class[$idx])
            $classIndex++
        }

        for ($i = $result.Length; $i -lt $Length; $i++) {
            $idx = $bytes[$i] % $allChars.Length
            $null = $result.Append($allChars[$idx])
        }

        # Shuffle with Fisher-Yates using cryptographic RNG
        $chars = $result.ToString().ToCharArray()
        for ($i = $chars.Length - 1; $i -gt 0; $i--) {
            $swapByte = New-Object byte[] 1
            $rng.GetBytes($swapByte)
            $swapIndex = $swapByte[0] % ($i + 1)
            if ($swapIndex -ne $i) {
                $temp = $chars[$i]
                $chars[$i] = $chars[$swapIndex]
                $chars[$swapIndex] = $temp
            }
        }

        return -join $chars
    }
    finally {
        $rng.Dispose()
    }
}

$orgCache = @{}
function Get-OrganizationId {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'Organization name is missing.'
    }

    if ($orgCache.ContainsKey($Name)) {
        return $orgCache[$Name]
    }

    $response = Invoke-ITGlue -Method GET -Path 'organizations' -Query @{ 'filter[name]' = $Name; 'page[size]' = 2 }
    $candidate = $null

    if ($response.data) {
        foreach ($item in $response.data) {
            if ([string]::Equals($item.attributes.name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $candidate = [string]$item.id
                break
            }
        }

        if (-not $candidate) {
            $candidate = [string]$response.data[0].id
        }
    }

    if (-not $candidate) {
        throw ("Organization '{0}' was not found in IT Glue." -f $Name)
    }

    $orgCache[$Name] = $candidate
    return $candidate
}

$script:passwordCategoryId = $null
function Get-PasswordCategoryId {
    param([string]$Name)

    if ($script:passwordCategoryId) {
        return $script:passwordCategoryId
    }

    $response = Invoke-ITGlue -Method GET -Path 'password_categories' -Query @{ 'filter[name]' = $Name; 'page[size]' = 2 }
    $candidate = $null

    if ($response.data) {
        foreach ($item in $response.data) {
            if ([string]::Equals($item.attributes.name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $candidate = [string]$item.id
                break
            }
        }

        if (-not $candidate) {
            $candidate = [string]$response.data[0].id
        }
    }

    if (-not $candidate) {
        throw ("Password category '{0}' not found." -f $Name)
    }

    $script:passwordCategoryId = $candidate
    return $candidate
}

function New-ITGluePassword {
    param(
        [string]$OrgId,
        [string]$CategoryId,
        [string]$Name,
        [string]$Username,
        [string]$Password,
        [string]$Notes
    )

    $attributes = @{
        name     = $Name
        username = $Username
        password = $Password
        'organization_id' = [long]$OrgId
        'password_category_id' = [long]$CategoryId
    }

    if (-not [string]::IsNullOrWhiteSpace($Notes)) {
        $attributes['notes'] = $Notes
    }

    if ($PasswordFolderId.HasValue) {
        $attributes['password_folder_id'] = [long]$PasswordFolderId.Value
    }

    $body = @{
        data = @{
            type          = 'passwords'
            attributes    = $attributes
        }
    } | ConvertTo-Json -Depth 10

    return Invoke-ITGlue -Method POST -Path 'passwords' -Body $body
}

$categoryId = Get-PasswordCategoryId -Name $PasswordCategoryName

$outputRows = @()
$errors = @()

$rowNumber = 0
foreach ($row in $csvRows) {
    $rowNumber++

    $username = Get-ColumnValue -Row $row -Column $UsernameColumn
    $given = Get-ColumnValue -Row $row -Column $GivenNameColumn
    $email = Get-ColumnValue -Row $row -Column $EmailColumn
    $orgName = Get-ColumnValue -Row $row -Column $OrganizationColumn

    $passwordIdOutput = $null

    try {
        if ([string]::IsNullOrWhiteSpace($email)) {
            throw 'Email is missing.'
        }

        if (-not [System.Text.RegularExpressions.Regex]::IsMatch($email, '^[^@\s]+@[^@\s]+\.[^@\s]+$')) {
            throw ("Email '{0}' is not valid." -f $email)
        }

        $orgId = Get-OrganizationId -Name $orgName

        $nameParts = @()
        if (-not [string]::IsNullOrWhiteSpace($given)) { $nameParts += $given.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($username)) { $nameParts += $username.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($email)) { $nameParts += $email.Trim() }
        if ($nameParts.Count -eq 0) { $nameParts += 'New Password' }

        $displayName = ($nameParts -join ' / ')

        $notes = "Provisioned via bulk-create-passwords.ps1 on {0:yyyy-MM-dd} for {1}" -f (Get-Date), $email
        $notes = $notes.Trim()

        if ($DryRun) {
            $passwordIdOutput = '[dry-run]'
        }
        else {
            $passwordValue = New-RandomPassword -Length $PasswordLength
            $passwordResponse = New-ITGluePassword -OrgId $orgId -CategoryId $categoryId -Name $displayName -Username $username -Password $passwordValue -Notes $notes

            if (-not $passwordResponse.data -or -not $passwordResponse.data.id) {
                throw 'Password creation returned an unexpected response.'
            }

            $passwordIdOutput = [string]$passwordResponse.data.id
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        $errors += "Row $rowNumber ($email): $errorMessage"
        Write-Warning ("Row {0}: {1}" -f $rowNumber, $errorMessage)
        if (-not $passwordIdOutput) {
            $cleanMessage = ($errorMessage -replace '\s+', ' ').Trim()
            if (-not $cleanMessage) { $cleanMessage = 'See console log for details.' }
            $passwordIdOutput = "ERROR: $cleanMessage"
        }
    }

    $outputRow = [ordered]@{}
    foreach ($prop in $row.PSObject.Properties) {
        $outputRow[$prop.Name] = $prop.Value
    }
    $outputRow['PasswordId'] = $passwordIdOutput

    $outputRows += [pscustomobject]$outputRow
}

$outputRows | Export-Csv -Path $OutputCsvPath -NoTypeInformation
Write-Host ("Output written to {0} (see PasswordId column for results)" -f $OutputCsvPath)

if ($errors.Count -gt 0) {
    Write-Warning ("Completed with {0} error(s). Review the Status column and console warnings." -f $errors.Count)
}
