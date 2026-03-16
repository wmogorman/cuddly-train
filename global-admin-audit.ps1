<#
USAGE NOTES - GLOBAL ADMIN AUDIT GROUP SYNC

Purpose
- Run from your MSP app registration context and keep a security group in each target tenant
  aligned to current "Global Administrator" role membership.
- Script is idempotent and safe to rerun. It adds missing members every run and removes stale
  members by default (disable with -RemoveStaleMembers:$false).

What this script does per tenant
1) Connects to Microsoft Graph using app-only certificate auth.
2) Resolves the built-in Global Administrator role.
3) Finds or creates the audit group (default: "ActaMSP Global Administrators Audit").
4) Adds missing global admins to the group.
5) Removes members no longer in Global Administrator (unless -RemoveStaleMembers:$false is used).

Prerequisites
- Microsoft Graph PowerShell modules installed (authentication, groups, directory management, partner as needed).
- App registration has required application permissions and admin consent in each target tenant.
- Certificate thumbprint in this script points to a valid cert available in current user/computer store.
- For auto-discovery, your MSP tenant must be queryable for GDAP relationships and optionally contracts.

Targeting modes
- Manual tenant list: pass -TenantId (array).
- CSV tenant list: pass -TenantListPath with a "TenantId" column.
- Auto-discovery is enabled by default and prompts for -DiscoveryTenantId if not supplied.
  - DiscoveryMode GDAP: active GDAP relationships only.
  - DiscoveryMode GDAPAndContracts (default): active GDAP plus active customer contracts.
  - Use -IncludeMspTenant to include the MSP tenant itself in the run.
  - Use -IncludeTenantId and -ExcludeTenantId for overrides.
  - Use -AutoDiscoverTenants:$false to disable discovery and run manual/CSV targets only.

Safety and behavior flags
- -DryRun: no write operations, logs intended actions only.
- -RemoveStaleMembers: enabled by default; set -RemoveStaleMembers:$false to skip stale-member removals.
- -StopOnError: stop after first tenant failure (otherwise continue and summarize).

CSV format example
TenantId
9f50b569-9e79-47a5-bbe6-f362934d55a0
4f72c046-d654-4302-a801-f2da1ff40c2b

Recommended run order
1) Dry run first.
2) For first live deployment, consider disabling removals with -RemoveStaleMembers:$false.
3) Run with default removals enabled once validated.

Examples
- Manual dry run:
  .\global-admin-audit.ps1 -AutoDiscoverTenants:$false -TenantId "tenantA","tenantB" -DryRun

- Manual live sync with stale cleanup:
  .\global-admin-audit.ps1 -AutoDiscoverTenants:$false -TenantId "tenantA","tenantB" -StopOnError

- Manual live sync without stale cleanup:
  .\global-admin-audit.ps1 -AutoDiscoverTenants:$false -TenantId "tenantA","tenantB" -RemoveStaleMembers:$false -StopOnError

- CSV-driven dry run:
  .\global-admin-audit.ps1 -AutoDiscoverTenants:$false -TenantListPath .\tenants.csv -DryRun

- Auto-discovery (GDAP only), include MSP tenant:
  .\global-admin-audit.ps1 -AutoDiscoverTenants -DiscoveryTenantId "mspTenantId" -DiscoveryMode GDAP -IncludeMspTenant -DryRun

- Auto-discovery (GDAP + contracts), exclude known tenant(s):
  .\global-admin-audit.ps1 -DiscoveryTenantId "mspTenantId" -ExcludeTenantId "tenantToSkip1","tenantToSkip2"

Exit behavior
- Returns non-zero exit code if one or more tenant syncs fail.
- Prints a summary table at end showing status/add/remove counts per tenant.
#>

param(
    [Parameter(Mandatory = $false)]
    [string[]]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$TenantListPath,

    [Parameter(Mandatory = $false)]
    [switch]$AutoDiscoverTenants = $true,

    [Parameter(Mandatory = $false)]
    [string]$DiscoveryTenantId,

    [Parameter(Mandatory = $false)]
    [ValidateSet("GDAP", "GDAPAndContracts")]
    [string]$DiscoveryMode = "GDAPAndContracts",

    [Parameter(Mandatory = $false)]
    [switch]$IncludeMspTenant,

    [Parameter(Mandatory = $false)]
    [string[]]$IncludeTenantId,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeTenantId,

    [Parameter(Mandatory = $false)]
    [string]$ClientId = "f45ddef0-f613-4c3d-92d1-6b80bf00e6cf",

    [Parameter(Mandatory = $false)]
    [string]$Thumbprint = "D0278AED132F9C816A815A4BFFF0F48CE8FAECEF",

    [Parameter(Mandatory = $false)]
    [string]$GroupDisplayName = "ActaMSP Global Administrators Audit",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$RemoveStaleMembers = $true,

    [Parameter(Mandatory = $false)]
    [switch]$StopOnError
)

$ErrorActionPreference = "Stop"
$globalAdminTemplateId = "62e90394-69f5-4237-9190-012177145e10"
$script:TenantDisplayNameById = @{}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO",
        [string]$Tenant = ""
    )

    $tenantPrefix = if ([string]::IsNullOrWhiteSpace($Tenant)) { "" } else { "[$Tenant] " }
    Write-Host ("[{0}] [{1}] {2}{3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $tenantPrefix, $Message)
}

function Get-ExceptionMessageParts {
    param([object]$ErrorObject)

    $exception = if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
        $ErrorObject.Exception
    }
    elseif ($ErrorObject -is [System.Exception]) {
        $ErrorObject
    }
    else {
        return @([string]$ErrorObject)
    }

    $messages = [System.Collections.Generic.List[string]]::new()
    while ($exception) {
        if (-not [string]::IsNullOrWhiteSpace($exception.Message)) {
            $messages.Add($exception.Message) | Out-Null
        }

        if ($exception.PSObject.Properties.Name -contains "ResponseBody") {
            $responseBody = [string]$exception.ResponseBody
            if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
                $messages.Add($responseBody) | Out-Null
            }
        }

        $exception = $exception.InnerException
    }

    if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
        if ($ErrorObject.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorObject.ErrorDetails.Message)) {
            $messages.Add($ErrorObject.ErrorDetails.Message) | Out-Null
        }
    }

    return @($messages | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-GraphErrorContext {
    param([string[]]$MessageParts)

    $parts = @($MessageParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $primaryMessage = $null
    $errorCode = $null
    $correlationId = $null
    $traceId = $null
    $timestamp = $null
    $jsonErrorDescription = $null

    foreach ($part in $parts) {
        $trimmed = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if (-not $primaryMessage -and -not ($trimmed.StartsWith("{") -or $trimmed.StartsWith("["))) {
            $primaryMessage = $trimmed
        }

        if ($trimmed.StartsWith("{")) {
            try {
                $parsed = $trimmed | ConvertFrom-Json -ErrorAction Stop
                if ($parsed.error_description -and [string]::IsNullOrWhiteSpace($jsonErrorDescription)) {
                    $jsonErrorDescription = [string]$parsed.error_description
                }
                if ($parsed.correlation_id -and [string]::IsNullOrWhiteSpace($correlationId)) {
                    $correlationId = [string]$parsed.correlation_id
                }
                if ($parsed.trace_id -and [string]::IsNullOrWhiteSpace($traceId)) {
                    $traceId = [string]$parsed.trace_id
                }
                if ($parsed.timestamp -and [string]::IsNullOrWhiteSpace($timestamp)) {
                    $timestamp = [string]$parsed.timestamp
                }
                if ($parsed.error_codes -and $parsed.error_codes.Count -gt 0 -and [string]::IsNullOrWhiteSpace($errorCode)) {
                    $firstCode = [string]$parsed.error_codes[0]
                    if (-not [string]::IsNullOrWhiteSpace($firstCode)) {
                        $errorCode = "AADSTS$firstCode"
                    }
                }
            }
            catch {
                # Ignore non-JSON text that only looks like JSON.
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($primaryMessage) -and -not [string]::IsNullOrWhiteSpace($jsonErrorDescription)) {
        $primaryMessage = $jsonErrorDescription
    }

    if (-not [string]::IsNullOrWhiteSpace($primaryMessage) -and $primaryMessage -match "(?i)Original exception:\s*(.+)$") {
        $primaryMessage = [string]$Matches[1]
    }

    $fullText = ($parts -join " | ")
    $searchText = if ([string]::IsNullOrWhiteSpace($primaryMessage)) { $fullText } else { "$primaryMessage | $fullText" }

    if ([string]::IsNullOrWhiteSpace($errorCode) -and $searchText -match "(?i)\b(AADSTS\d{4,})\b") {
        $errorCode = [string]$Matches[1].ToUpperInvariant()
    }
    if ([string]::IsNullOrWhiteSpace($correlationId) -and $searchText -match "(?i)Correlation ID:\s*([0-9a-f-]{36})") {
        $correlationId = [string]$Matches[1]
    }
    if ([string]::IsNullOrWhiteSpace($traceId) -and $searchText -match "(?i)Trace ID:\s*([0-9a-f-]{36})") {
        $traceId = [string]$Matches[1]
    }
    if ([string]::IsNullOrWhiteSpace($timestamp) -and $searchText -match "(?i)Timestamp:\s*([0-9:\-\.TZ]+)") {
        $timestamp = [string]$Matches[1]
    }

    if (-not [string]::IsNullOrWhiteSpace($primaryMessage)) {
        $primaryMessage = $primaryMessage -replace "(?i)\s*Trace ID:\s*[0-9a-f-]{36}", ""
        $primaryMessage = $primaryMessage -replace "(?i)\s*Correlation ID:\s*[0-9a-f-]{36}", ""
        $primaryMessage = $primaryMessage -replace "(?i)\s*Timestamp:\s*[0-9:\-\.TZ]+", ""
        $primaryMessage = $primaryMessage -replace "\s{2,}", " "
        $primaryMessage = $primaryMessage.Trim(" ", "|", ".")
    }

    return [pscustomobject]@{
        PrimaryMessage = $primaryMessage
        ErrorCode      = $errorCode
        CorrelationId  = $correlationId
        TraceId        = $traceId
        Timestamp      = $timestamp
        FullText       = $fullText
    }
}

function Get-TenantFailureMessage {
    param([object]$ErrorObject)

    $messageParts = Get-ExceptionMessageParts -ErrorObject $ErrorObject
    $errorContext = Get-GraphErrorContext -MessageParts $messageParts
    $fullText = [string]$errorContext.FullText
    $errorCode = [string]$errorContext.ErrorCode
    $primaryMessage = [string]$errorContext.PrimaryMessage
    $friendlyMessage = $null
    $contextDetails = [System.Collections.Generic.List[string]]::new()

    if ($errorCode -eq "AADSTS7000229" -or $fullText -match "(?i)missing service principal in the tenant") {
        $friendlyMessage = "AADSTS7000229: Audit app is not onboarded in this tenant (enterprise app/service principal missing). Run enterprise-app-onboard-all-partners.ps1 for this tenant."
    }
    elseif ($fullText -match "(?i)authorization_requestdenied|insufficient privileges|admin consent|forbidden") {
        $friendlyMessage = "Authorization/consent error: confirm required app permissions and admin consent are granted in this tenant."
    }
    else {
        $friendlyMessage = if ([string]::IsNullOrWhiteSpace($primaryMessage)) { "Tenant sync failed due to an unknown Graph authentication error." } else { $primaryMessage }
    }

    if (-not [string]::IsNullOrWhiteSpace($errorCode)) {
        $contextDetails.Add("Code=$errorCode") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($errorContext.CorrelationId)) {
        $contextDetails.Add("CorrelationId=$($errorContext.CorrelationId)") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($errorContext.TraceId)) {
        $contextDetails.Add("TraceId=$($errorContext.TraceId)") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($errorContext.Timestamp)) {
        $contextDetails.Add("Timestamp=$($errorContext.Timestamp)") | Out-Null
    }

    if ($contextDetails.Count -gt 0) {
        return "$friendlyMessage [$($contextDetails -join '; ')]"
    }

    return $friendlyMessage
}

function Get-FormattedGraphAuthError {
    param(
        [object]$ErrorObject,
        [string]$Operation,
        [string]$TenantId,
        [string]$ClientId,
        [string]$CertificateThumbprint,
        [string[]]$Scopes
    )

    $messageParts = @(Get-ExceptionMessageParts -ErrorObject $ErrorObject)
    $errorContext = Get-GraphErrorContext -MessageParts $messageParts
    $details = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $details.Add("TenantId=$TenantId") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($ClientId)) {
        $details.Add("ClientId=$ClientId") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
        $details.Add("Thumbprint=$CertificateThumbprint") | Out-Null
    }
    if ($Scopes -and $Scopes.Count -gt 0) {
        $details.Add("Scopes=$($Scopes -join ',')") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($errorContext.ErrorCode)) {
        $details.Add("Code=$($errorContext.ErrorCode)") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($errorContext.CorrelationId)) {
        $details.Add("CorrelationId=$($errorContext.CorrelationId)") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($errorContext.TraceId)) {
        $details.Add("TraceId=$($errorContext.TraceId)") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($errorContext.Timestamp)) {
        $details.Add("Timestamp=$($errorContext.Timestamp)") | Out-Null
    }

    $primaryMessage = [string]$errorContext.PrimaryMessage
    if ([string]::IsNullOrWhiteSpace($primaryMessage)) {
        $primaryMessage = "Microsoft Graph authentication failed."
    }

    $rawText = [string]$errorContext.FullText
    $isGenericCertificateError = (
        $rawText -match "(?i)ClientCertificateCredential authentication failed" -and
        [string]::IsNullOrWhiteSpace($errorContext.ErrorCode)
    )

    $suffix = if ($details.Count -gt 0) { " [$($details -join '; ')]" } else { "" }
    $message = "$Operation failed. $primaryMessage$suffix"

    if ($isGenericCertificateError) {
        $message += " Possible causes: the app registration is missing the uploaded public certificate, the uploaded certificate does not match the local private key, the wrong app or tenant ID was used, or certificate propagation has not completed yet."
    }

    if (-not [string]::IsNullOrWhiteSpace($rawText) -and $rawText -ne $primaryMessage) {
        $message += " RawAuthError: $rawText"
    }

    return $message
}

function Register-TenantDisplayName {
    param(
        [string]$TenantId,
        [string]$TenantName
    )

    if ([string]::IsNullOrWhiteSpace($TenantId) -or [string]::IsNullOrWhiteSpace($TenantName)) {
        return
    }

    $script:TenantDisplayNameById[$TenantId.Trim().ToLowerInvariant()] = $TenantName.Trim()
}

function Get-TenantDisplayNameFromCache {
    param([string]$TenantId)

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        return $null
    }

    $key = $TenantId.Trim().ToLowerInvariant()
    if ($script:TenantDisplayNameById.ContainsKey($key)) {
        return [string]$script:TenantDisplayNameById[$key]
    }

    return $null
}

function Get-ConnectedTenantDisplayName {
    param(
        [string]$TenantId,
        [string]$FallbackName
    )

    try {
        $org = @(Get-MgOrganization -Property "displayName" -ErrorAction Stop | Select-Object -First 1)
        if ($org.Count -gt 0) {
            $displayName = [string]$org[0].DisplayName
            if (-not [string]::IsNullOrWhiteSpace($displayName)) {
                Register-TenantDisplayName -TenantId $TenantId -TenantName $displayName
                return $displayName.Trim()
            }
        }
    }
    catch {
        Write-Log -Level "WARN" -Tenant $TenantId -Message "Could not resolve tenant display name: $($_.Exception.Message)"
    }

    if (-not [string]::IsNullOrWhiteSpace($FallbackName)) {
        return $FallbackName
    }

    return $TenantId
}

function Get-DirectoryObjectId {
    param($Object)

    if ($null -ne $Object.Id) {
        return $Object.Id
    }

    if ($null -ne $Object.AdditionalProperties -and $Object.AdditionalProperties.ContainsKey("id")) {
        return $Object.AdditionalProperties["id"]
    }

    return $null
}

function Get-DirectoryObjectDisplay {
    param($Object)

    if ($null -ne $Object.AdditionalProperties) {
        if ($Object.AdditionalProperties.ContainsKey("displayName")) {
            return [string]$Object.AdditionalProperties["displayName"]
        }
        if ($Object.AdditionalProperties.ContainsKey("userPrincipalName")) {
            return [string]$Object.AdditionalProperties["userPrincipalName"]
        }
        if ($Object.AdditionalProperties.ContainsKey("appId")) {
            return "ServicePrincipal:$($Object.AdditionalProperties['appId'])"
        }
    }

    if ($null -ne $Object.DisplayName) {
        return [string]$Object.DisplayName
    }

    return "<unknown>"
}

function Resolve-TenantTargets {
    param(
        [string[]]$TenantId,
        [string]$TenantListPath,
        [switch]$AllowEmpty
    )

    $targets = [System.Collections.Generic.List[string]]::new()

    if ($TenantId) {
        foreach ($entry in $TenantId) {
            if (-not [string]::IsNullOrWhiteSpace($entry)) {
                $targets.Add($entry.Trim())
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($TenantListPath)) {
        if (-not (Test-Path -LiteralPath $TenantListPath)) {
            throw "Tenant list file not found: $TenantListPath"
        }

        $rows = @(Import-Csv -LiteralPath $TenantListPath)
        if (-not $rows -or $rows.Count -eq 0) {
            throw "Tenant list file is empty: $TenantListPath"
        }

        $tenantColumn = $rows[0].PSObject.Properties.Name | Where-Object { $_ -imatch "^tenantid$" } | Select-Object -First 1
        if (-not $tenantColumn) {
            throw "Tenant list file must include a 'TenantId' column: $TenantListPath"
        }

        foreach ($row in $rows) {
            $value = [string]$row.$tenantColumn
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $targets.Add($value.Trim())
            }
        }
    }

    $uniqueTargets = @($targets | Sort-Object -Unique)
    if (-not $AllowEmpty -and $uniqueTargets.Count -eq 0) {
        throw "No target tenants supplied. Use -TenantId and/or -TenantListPath."
    }

    return $uniqueTargets
}

function Assert-RequiredGraphCmdlets {
    param(
        [switch]$RequireDiscoveryCmdlets,
        [ValidateSet("GDAP", "GDAPAndContracts")]
        [string]$DiscoveryMode
    )

    $requiredCmdlets = [System.Collections.Generic.List[string]]::new()
    @(
        "Connect-MgGraph",
        "Disconnect-MgGraph",
        "Get-MgContext",
        "Get-MgOrganization",
        "Get-MgDirectoryRole",
        "Get-MgDirectoryRoleMember",
        "Get-MgGroup",
        "New-MgGroup",
        "Get-MgGroupMember",
        "New-MgGroupMemberByRef",
        "Remove-MgGroupMemberByRef"
    ) | ForEach-Object { $requiredCmdlets.Add($_) }

    if ($RequireDiscoveryCmdlets) {
        $requiredCmdlets.Add("Get-MgTenantRelationshipDelegatedAdminRelationship")
        if ($DiscoveryMode -eq "GDAPAndContracts") {
            $requiredCmdlets.Add("Get-MgContract")
        }
    }

    $missing = @($requiredCmdlets | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) {
        throw "Missing Microsoft Graph cmdlets: $($missing -join ', '). Install/import the required Graph modules before running this script."
    }
}

function Get-NormalizedTenantIdList {
    param([string[]]$TenantIds)

    if (-not $TenantIds) {
        return @()
    }

    return @(
        $TenantIds `
        | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } `
        | ForEach-Object { $_.Trim() } `
        | Sort-Object -Unique
    )
}

function Get-CustomerTenantIdFromRelationship {
    param($Relationship)

    $customer = $Relationship.Customer
    if ($customer) {
        if ($customer.PSObject.Properties.Name -contains "TenantId" -and -not [string]::IsNullOrWhiteSpace([string]$customer.TenantId)) {
            return [string]$customer.TenantId
        }
        if ($customer.PSObject.Properties.Name -contains "AdditionalProperties" -and $null -ne $customer.AdditionalProperties) {
            $tenantIdValue = $customer.AdditionalProperties["tenantId"]
            if (-not [string]::IsNullOrWhiteSpace([string]$tenantIdValue)) {
                return [string]$tenantIdValue
            }
        }
    }

    if ($null -ne $Relationship.AdditionalProperties -and $Relationship.AdditionalProperties.ContainsKey("customer")) {
        $rawCustomer = $Relationship.AdditionalProperties["customer"]
        if ($rawCustomer -is [System.Collections.IDictionary] -and $rawCustomer.Contains("tenantId")) {
            $tenantIdValue = [string]$rawCustomer["tenantId"]
            if (-not [string]::IsNullOrWhiteSpace($tenantIdValue)) {
                return $tenantIdValue
            }
        }
    }

    return $null
}

function Set-GraphProfileIfSupported {
    param(
        [string]$TenantId,
        [string]$TenantLabel = $TenantId
    )

    $selectProfile = Get-Command -Name "Select-MgProfile" -ErrorAction SilentlyContinue
    if ($selectProfile) {
        Select-MgProfile -Name "v1.0" -ErrorAction Stop | Out-Null
        Write-Log -Tenant $TenantLabel -Message "Selected Microsoft Graph profile v1.0."
    }
    else {
        Write-Log -Level "WARN" -Tenant $TenantLabel -Message "Select-MgProfile not available in this SDK version; using default Graph profile."
    }
}

function New-DeterministicMailNickname {
    param(
        [string]$DisplayName,
        [string]$TenantId
    )

    $base = ($DisplayName -replace "[^a-zA-Z0-9]", "").ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = "globaladminaudit"
    }

    if ($base.Length -gt 48) {
        $base = $base.Substring(0, 48)
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$TenantId|$DisplayName"))
    }
    finally {
        $sha.Dispose()
    }

    $hash = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant().Substring(0, 8)
    $nickname = "$base$hash"
    if ($nickname.Length -gt 64) {
        $nickname = $nickname.Substring(0, 64)
    }

    return $nickname
}

function Invoke-WithRetry {
    param(
        [scriptblock]$Script,
        [string]$Operation,
        [string]$Tenant,
        [int]$MaxAttempts = 5,
        [switch]$RetryOnNotFound
    )

    $attempt = 1
    while ($true) {
        try {
            return & $Script
        }
        catch {
            $message = $_.Exception.Message
            $statusCode = $null

            if ($_.Exception.PSObject.Properties.Name -contains "ResponseStatusCode") {
                $statusCode = [int]$_.Exception.ResponseStatusCode
            }

            $isRetryable = (
                ($statusCode -in @(429, 500, 502, 503, 504)) -or
                ($message -match "(?i)too many requests|temporarily unavailable|timeout|throttl|gateway|service unavailable")
            )
            if ($RetryOnNotFound) {
                $isRetryable = $isRetryable -or (
                    ($statusCode -eq 404) -or
                    ($message -match "(?i)request_resourcenotfound|resource .* does not exist|reference-property objects are not present|not found")
                )
            }

            if (-not $isRetryable -or $attempt -ge $MaxAttempts) {
                throw
            }

            $delaySeconds = [Math]::Min([int][Math]::Pow(2, $attempt), 30) + (Get-Random -Minimum 0 -Maximum 3)
            Write-Log -Level "WARN" -Tenant $Tenant -Message "$Operation failed (attempt $attempt/$MaxAttempts): $message. Retrying in $delaySeconds second(s)."
            Start-Sleep -Seconds $delaySeconds
            $attempt++
        }
    }
}

function Discover-PartnerTenantTargets {
    param(
        [string]$DiscoveryTenantId,
        [ValidateSet("GDAP", "GDAPAndContracts")]
        [string]$DiscoveryMode,
        [switch]$IncludeMspTenant
    )

    $discovered = [System.Collections.Generic.List[string]]::new()
    $discoveryTenantLabel = $DiscoveryTenantId

    try {
        Write-Log -Tenant $discoveryTenantLabel -Message "Connecting to discovery tenant for partner relationship lookup."
        try {
            Connect-MgGraph `
                -ClientId $ClientId `
                -TenantId $DiscoveryTenantId `
                -CertificateThumbprint $Thumbprint `
                -NoWelcome `
                -ErrorAction Stop | Out-Null
        }
        catch {
            throw (Get-FormattedGraphAuthError `
                    -ErrorObject $_ `
                    -Operation "Partner discovery Graph connect" `
                    -TenantId $DiscoveryTenantId `
                    -ClientId $ClientId `
                    -CertificateThumbprint $Thumbprint)
        }

        Set-GraphProfileIfSupported -TenantId $DiscoveryTenantId -TenantLabel $discoveryTenantLabel
        $discoveryTenantLabel = Get-ConnectedTenantDisplayName -TenantId $DiscoveryTenantId -FallbackName $DiscoveryTenantId
        Register-TenantDisplayName -TenantId $DiscoveryTenantId -TenantName $discoveryTenantLabel

        if ($IncludeMspTenant) {
            $discovered.Add($DiscoveryTenantId)
            Write-Log -Tenant $discoveryTenantLabel -Message "Including MSP tenant in target list."
        }

        $gdapDiscoveredCount = 0
        $gdapRelationships = @(Invoke-WithRetry -Tenant $discoveryTenantLabel -Operation "Get GDAP relationships" -Script {
                Get-MgTenantRelationshipDelegatedAdminRelationship -All -ErrorAction Stop
            })

        foreach ($relationship in $gdapRelationships) {
            $status = [string]$relationship.Status
            if (-not ($status -match "^(?i)active$")) {
                continue
            }

            $customerTenantId = Get-CustomerTenantIdFromRelationship -Relationship $relationship
            if (-not [string]::IsNullOrWhiteSpace($customerTenantId)) {
                $discovered.Add($customerTenantId)
                $gdapDiscoveredCount++

                $customerDisplayName = $null
                if ($relationship.Customer) {
                    if ($relationship.Customer.PSObject.Properties.Name -contains "DisplayName") {
                        $customerDisplayName = [string]$relationship.Customer.DisplayName
                    }
                    elseif ($relationship.Customer.PSObject.Properties.Name -contains "AdditionalProperties" -and $null -ne $relationship.Customer.AdditionalProperties) {
                        $customerDisplayName = [string]$relationship.Customer.AdditionalProperties["displayName"]
                    }
                }
                Register-TenantDisplayName -TenantId $customerTenantId -TenantName $customerDisplayName
            }
        }

        Write-Log -Tenant $discoveryTenantLabel -Message "Discovered $gdapDiscoveredCount tenant(s) from active GDAP relationships."

        if ($DiscoveryMode -eq "GDAPAndContracts") {
            $contractDiscoveredCount = 0
            $contracts = @(Invoke-WithRetry -Tenant $discoveryTenantLabel -Operation "Get customer contracts" -Script {
                    Get-MgContract -All -ErrorAction Stop
                })

            foreach ($contract in $contracts) {
                if ($null -ne $contract.DeletedDateTime) {
                    continue
                }

                $customerTenantId = [string]$contract.CustomerId
                if (-not [string]::IsNullOrWhiteSpace($customerTenantId)) {
                    $discovered.Add($customerTenantId)
                    $contractDiscoveredCount++
                }
            }

            Write-Log -Tenant $discoveryTenantLabel -Message "Discovered $contractDiscoveredCount tenant(s) from active contracts."
        }
    }
    finally {
        try {
            $ctx = Get-MgContext -ErrorAction SilentlyContinue
            if ($ctx) {
                Disconnect-MgGraph -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Write-Log -Level "WARN" -Tenant $discoveryTenantLabel -Message "Discovery disconnect failed: $($_.Exception.Message)"
        }
    }

    return @($discovered | Sort-Object -Unique)
}

function Sync-TenantAuditGroup {
    param([string]$TargetTenantId)

    $summary = [ordered]@{
        TenantId      = $TargetTenantId
        TenantName    = $TargetTenantId
        Status        = "Success"
        GlobalAdmins  = 0
        GroupMembers  = 0
        Added         = 0
        Removed       = 0
        WarningCount  = 0
        Error         = $null
    }
    $tenantLogLabel = $summary.TenantName
    $cachedTenantName = Get-TenantDisplayNameFromCache -TenantId $TargetTenantId
    if (-not [string]::IsNullOrWhiteSpace($cachedTenantName)) {
        $summary.TenantName = $cachedTenantName
        $tenantLogLabel = $cachedTenantName
    }

    try {
        Write-Log -Tenant $tenantLogLabel -Message "Connecting to Microsoft Graph"
        try {
            Connect-MgGraph `
                -ClientId $ClientId `
                -TenantId $TargetTenantId `
                -CertificateThumbprint $Thumbprint `
                -NoWelcome `
                -ErrorAction Stop | Out-Null
        }
        catch {
            throw (Get-FormattedGraphAuthError `
                    -ErrorObject $_ `
                    -Operation "Tenant sync Graph connect" `
                    -TenantId $TargetTenantId `
                    -ClientId $ClientId `
                    -CertificateThumbprint $Thumbprint)
        }

        Set-GraphProfileIfSupported -TenantId $TargetTenantId -TenantLabel $tenantLogLabel
        $summary.TenantName = Get-ConnectedTenantDisplayName -TenantId $TargetTenantId -FallbackName $summary.TenantName
        $tenantLogLabel = $summary.TenantName
        $ctx = Get-MgContext -ErrorAction Stop
        Write-Log -Tenant $tenantLogLabel -Message "Connected. Tenant: $($summary.TenantName) AppId: $($ctx.ClientId) AuthType: $($ctx.AuthType)"

        $matchingRoles = @(Invoke-WithRetry -Tenant $tenantLogLabel -Operation "Get directory roles" -Script {
                Get-MgDirectoryRole -All -ErrorAction Stop | Where-Object {
                    $_.RoleTemplateId -eq $globalAdminTemplateId -or $_.DisplayName -eq "Global Administrator"
                }
            })

        if ($matchingRoles.Count -eq 0) {
            throw "Could not find the Global Administrator directory role in tenant."
        }

        if ($matchingRoles.Count -gt 1) {
            Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Multiple matching Global Administrator roles found; using the first."
            $summary.WarningCount++
        }

        $role = $matchingRoles[0]
        Write-Log -Tenant $tenantLogLabel -Message "Resolved role: $($role.DisplayName) [$($role.Id)]"

        $globalAdmins = @(Invoke-WithRetry -Tenant $tenantLogLabel -Operation "Get role members" -Script {
                Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All -ErrorAction Stop
            })

        $globalAdminIds = @{}
        foreach ($admin in $globalAdmins) {
            $id = Get-DirectoryObjectId -Object $admin
            if ($id) {
                $globalAdminIds[$id] = $admin
            }
        }

        $summary.GlobalAdmins = $globalAdminIds.Count
        Write-Log -Tenant $tenantLogLabel -Message "Found $($globalAdminIds.Count) Global Administrator member(s)."

        $escapedName = $GroupDisplayName.Replace("'", "''")
        $matchingGroups = @(Invoke-WithRetry -Tenant $tenantLogLabel -Operation "Get audit group by display name" -Script {
                Get-MgGroup -Filter "displayName eq '$escapedName'" -ConsistencyLevel eventual -All -ErrorAction Stop
            })

        $group = $null
        $groupJustCreated = $false
        if ($matchingGroups.Count -gt 1) {
            $group = $matchingGroups | Sort-Object CreatedDateTime | Select-Object -First 1
            Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Multiple groups named '$GroupDisplayName' found. Using '$($group.Id)'."
            $summary.WarningCount++
        }
        elseif ($matchingGroups.Count -eq 1) {
            $group = $matchingGroups[0]
            Write-Log -Tenant $tenantLogLabel -Message "Using existing group '$($group.DisplayName)' [$($group.Id)]"
        }
        else {
            Write-Log -Tenant $tenantLogLabel -Message "Audit group not found: $GroupDisplayName"
            if ($DryRun) {
                Write-Log -Tenant $tenantLogLabel -Message "DRY RUN: would create group '$GroupDisplayName'"
                $group = [pscustomobject]@{
                    Id          = "<dry-run-group>"
                    DisplayName = $GroupDisplayName
                }
            }
            else {
                $mailNickname = New-DeterministicMailNickname -DisplayName $GroupDisplayName -TenantId $TargetTenantId
                try {
                    $group = Invoke-WithRetry -Tenant $tenantLogLabel -Operation "Create audit group" -Script {
                        New-MgGroup `
                            -DisplayName $GroupDisplayName `
                            -Description "Maintained by ActaMSP automation. Mirrors current Global Administrator role membership." `
                            -MailEnabled:$false `
                            -MailNickname $mailNickname `
                            -SecurityEnabled:$true `
                            -ErrorAction Stop
                    }
                    Write-Log -Tenant $tenantLogLabel -Message "Created group '$($group.DisplayName)' [$($group.Id)]"
                    $groupJustCreated = $true
                }
                catch {
                    if ($_.Exception.Message -match "(?i)mailnickname|already exists|objectconflict|another object with the same value") {
                        Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Group create reported conflict for mailNickname '$mailNickname'; attempting to locate existing group."
                        $summary.WarningCount++
                        $groupByNickname = @(Get-MgGroup -Filter "mailNickname eq '$mailNickname'" -ConsistencyLevel eventual -All -ErrorAction Stop)
                        if ($groupByNickname.Count -ge 1) {
                            $group = $groupByNickname[0]
                            Write-Log -Tenant $tenantLogLabel -Message "Using existing group '$($group.DisplayName)' [$($group.Id)] found by mailNickname."
                        }
                        else {
                            throw
                        }
                    }
                    else {
                        throw
                    }
                }
            }
        }

        $currentMembers = @()
        if ($group.Id -ne "<dry-run-group>") {
            if ($groupJustCreated) {
                Write-Log -Tenant $tenantLogLabel -Message "Waiting for newly created group to become queryable."
            }

            $currentMembers = @(Invoke-WithRetry -Tenant $tenantLogLabel -Operation "Get group members" -RetryOnNotFound:$groupJustCreated -Script {
                    Get-MgGroupMember -GroupId $group.Id -All -ErrorAction Stop
                })
        }

        $currentMemberIds = @{}
        foreach ($member in $currentMembers) {
            $id = Get-DirectoryObjectId -Object $member
            if ($id) {
                $currentMemberIds[$id] = $member
            }
        }

        $summary.GroupMembers = $currentMemberIds.Count
        Write-Log -Tenant $tenantLogLabel -Message "Current audit group member count: $($currentMemberIds.Count)"

        $idsToAdd = @($globalAdminIds.Keys | Where-Object { -not $currentMemberIds.ContainsKey($_) })
        foreach ($id in $idsToAdd) {
            $display = Get-DirectoryObjectDisplay -Object $globalAdminIds[$id]
            if ($DryRun) {
                Write-Log -Tenant $tenantLogLabel -Message "DRY RUN: would add '$display' [$id] to audit group"
            }
            else {
                try {
                    Invoke-WithRetry -Tenant $tenantLogLabel -Operation "Add group member" -RetryOnNotFound:$groupJustCreated -Script {
                        New-MgGroupMemberByRef -GroupId $group.Id -BodyParameter @{
                            "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$id"
                        } -ErrorAction Stop
                    } | Out-Null
                    Write-Log -Tenant $tenantLogLabel -Message "Added '$display' [$id] to audit group"
                    $summary.Added++
                }
                catch {
                    if ($_.Exception.Message -match "(?i)added object references already exist|already exist") {
                        Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Member '$display' [$id] already exists in group."
                        $summary.WarningCount++
                    }
                    else {
                        throw
                    }
                }
            }
        }

        if ($RemoveStaleMembers) {
            $idsToRemove = @($currentMemberIds.Keys | Where-Object { -not $globalAdminIds.ContainsKey($_) })
            foreach ($id in $idsToRemove) {
                $display = Get-DirectoryObjectDisplay -Object $currentMemberIds[$id]
                if ($DryRun) {
                    Write-Log -Tenant $tenantLogLabel -Message "DRY RUN: would remove '$display' [$id] from audit group"
                }
                else {
                    try {
                        Invoke-WithRetry -Tenant $tenantLogLabel -Operation "Remove group member" -RetryOnNotFound:$groupJustCreated -Script {
                            Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $id -ErrorAction Stop
                        } | Out-Null
                        Write-Log -Tenant $tenantLogLabel -Message "Removed '$display' [$id] from audit group"
                        $summary.Removed++
                    }
                    catch {
                        if ($_.Exception.Message -match "(?i)does not exist|resource.*not found|could not find") {
                            Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Member '$display' [$id] is already absent from the group."
                            $summary.WarningCount++
                        }
                        else {
                            throw
                        }
                    }
                }
            }
        }

        Write-Log -Tenant $tenantLogLabel -Message "Tenant sync complete."
    }
    catch {
        $summary.Status = "Failed"
        $summary.Error = Get-TenantFailureMessage -ErrorObject $_
        Write-Log -Level "ERROR" -Tenant $tenantLogLabel -Message "Tenant sync failed: $($summary.Error)"
    }
    finally {
        try {
            $ctx = Get-MgContext -ErrorAction SilentlyContinue
            if ($ctx) {
                Disconnect-MgGraph -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Disconnect-MgGraph failed: $($_.Exception.Message)"
        }
    }

    return [pscustomobject]$summary
}

Assert-RequiredGraphCmdlets -RequireDiscoveryCmdlets:$AutoDiscoverTenants -DiscoveryMode $DiscoveryMode

$manualTargets = Resolve-TenantTargets -TenantId $TenantId -TenantListPath $TenantListPath -AllowEmpty
$extraIncludeTargets = Get-NormalizedTenantIdList -TenantIds $IncludeTenantId
$excludeTargets = Get-NormalizedTenantIdList -TenantIds $ExcludeTenantId

$resolvedDiscoveryTenantId = $DiscoveryTenantId
$discoveredTargets = @()
if ($AutoDiscoverTenants) {
    if ([string]::IsNullOrWhiteSpace($resolvedDiscoveryTenantId)) {
        $resolvedDiscoveryTenantId = [string](Read-Host "Enter discovery tenant ID/domain for auto-discovery")
        if ([string]::IsNullOrWhiteSpace($resolvedDiscoveryTenantId)) {
            throw "Auto-discovery requires -DiscoveryTenantId. Re-run with -DiscoveryTenantId or provide a value at the prompt."
        }
        $resolvedDiscoveryTenantId = $resolvedDiscoveryTenantId.Trim()
        Write-Log -Message "Using prompted discovery tenant '$resolvedDiscoveryTenantId'."
    }

    $discoveredTargets = Discover-PartnerTenantTargets `
        -DiscoveryTenantId $resolvedDiscoveryTenantId `
        -DiscoveryMode $DiscoveryMode `
        -IncludeMspTenant:$IncludeMspTenant
}

$targetTenants = @($discoveredTargets + $manualTargets + $extraIncludeTargets | Sort-Object -Unique)

if ($excludeTargets.Count -gt 0) {
    $targetTenants = @($targetTenants | Where-Object { $excludeTargets -notcontains $_ })
}

if ($targetTenants.Count -eq 0) {
    throw "No target tenants resolved after discovery/include/exclude processing."
}

Write-Log -Message ("Starting sync for {0} tenant(s)." -f $targetTenants.Count)

$results = [System.Collections.Generic.List[object]]::new()
foreach ($target in $targetTenants) {
    $result = Sync-TenantAuditGroup -TargetTenantId $target
    $results.Add($result)

    if ($StopOnError -and $result.Status -eq "Failed") {
        Write-Log -Level "WARN" -Message "Stopping early because -StopOnError was specified."
        break
    }
}

Write-Log -Message "Run summary:"
$results `
| Sort-Object TenantName `
| Format-Table TenantName, Status, GlobalAdmins, GroupMembers, Added, Removed, WarningCount -AutoSize `
| Out-String `
| ForEach-Object { $_.TrimEnd() } `
| ForEach-Object {
    if (-not [string]::IsNullOrWhiteSpace($_)) {
        Write-Host $_
    }
}

$failedCount = @($results | Where-Object { $_.Status -eq "Failed" }).Count
if ($failedCount -gt 0) {
    Write-Log -Level "ERROR" -Message "$failedCount tenant(s) failed."
    exit 1
}

Write-Log -Message "Complete."
$results
