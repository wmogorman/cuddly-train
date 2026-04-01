<#
USAGE NOTES - BREAK GLASS GROUP COMPLIANCE

Purpose
- Run from your MSP app registration context and verify each target tenant has a managed
  break-glass security group.
- The script is idempotent and safe to rerun. It creates the group if missing, but only
  remediates the sole direct member when exactly one eligible user is present.

What this script does per tenant
1) Connects to Microsoft Graph using app-only certificate auth.
2) Resolves the built-in Global Administrator role.
3) Finds or creates the managed break-glass group (default: "ActaMSP Break Glass").
4) Audits the group's direct membership.
5) If the group has exactly one eligible cloud user, enables the account if needed and
   assigns Global Administrator if missing.

What this script does not do
- It does not create the break-glass user.
- It does not auto-add a user to an empty group.
- It does not auto-remove extra members from the group.
- It does not audit or modify Conditional Access.

Prerequisites
- Microsoft Graph PowerShell modules installed (authentication, groups, users, directory management, partner as needed).
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
- -StopOnError: stop after first tenant failure (otherwise continue and summarize).

CSV format example
TenantId
9f50b569-9e79-47a5-bbe6-f362934d55a0
4f72c046-d654-4302-a801-f2da1ff40c2b

Examples
- Manual dry run:
  .\break-glass-group-compliance.ps1 -AutoDiscoverTenants:$false -TenantId "tenantA","tenantB" -DryRun

- Manual live run:
  .\break-glass-group-compliance.ps1 -AutoDiscoverTenants:$false -TenantId "tenantA","tenantB" -StopOnError

- CSV-driven dry run:
  .\break-glass-group-compliance.ps1 -AutoDiscoverTenants:$false -TenantListPath .\tenants.csv -DryRun

- Auto-discovery (GDAP + contracts), exclude known tenant(s):
  .\break-glass-group-compliance.ps1 -DiscoveryTenantId "mspTenantId" -ExcludeTenantId "tenantToSkip1","tenantToSkip2"

Exit behavior
- Returns non-zero exit code if one or more tenant checks fail.
- Prints a summary table at end showing status and action counts per tenant.
#>

param(
    [Parameter(Mandatory = $false)]
    [string[]]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$TenantListPath,

    [Parameter(Mandatory = $false)]
    [switch]$AutoDiscoverTenants,

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
    [string]$GroupDisplayName = "ActaMSP Break Glass",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$StopOnError
)

$ErrorActionPreference = "Stop"
$globalAdminTemplateId = "62e90394-69f5-4237-9190-012177145e10"
$script:TenantDisplayNameById = @{}
$script:ManagedGroupProperties = "id,displayName,description,groupTypes,securityEnabled,mailEnabled,mailNickname"
$script:BreakGlassGroupDescription = "Maintained by ActaMSP automation. Intended for a single emergency Global Administrator account."
$autoDiscoverTenantsEnabled = if ($PSBoundParameters.ContainsKey('AutoDiscoverTenants')) { [bool]$AutoDiscoverTenants } else { $true }

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

function Add-UniqueAction {
    param(
        [System.Collections.Generic.List[string]]$Actions,
        [string]$Action
    )

    if ($null -ne $Actions -and -not [string]::IsNullOrWhiteSpace($Action) -and -not $Actions.Contains($Action)) {
        $Actions.Add($Action) | Out-Null
    }
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

    $messageParts = @(Get-ExceptionMessageParts -ErrorObject $ErrorObject)
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
        $friendlyMessage = if ([string]::IsNullOrWhiteSpace($primaryMessage)) { "Tenant compliance run failed due to an unknown Graph error." } else { $primaryMessage }
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
        [string]$CertificateThumbprint
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

    $suffix = if ($details.Count -gt 0) { " [$($details -join '; ')]" } else { "" }
    return "$Operation failed. $primaryMessage$suffix"
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

    if ($null -eq $Object) {
        return $null
    }

    if ($null -ne $Object.Id) {
        return $Object.Id
    }

    if ($Object.PSObject.Properties.Name -contains "AdditionalProperties" -and $null -ne $Object.AdditionalProperties) {
        if ($Object.AdditionalProperties.ContainsKey("id")) {
            return $Object.AdditionalProperties["id"]
        }
    }

    return $null
}

function Get-DirectoryObjectDisplay {
    param($Object)

    if ($null -eq $Object) {
        return "<unknown>"
    }

    if ($Object.PSObject.Properties.Name -contains "AdditionalProperties" -and $null -ne $Object.AdditionalProperties) {
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

    if ($null -ne $Object.UserPrincipalName) {
        return [string]$Object.UserPrincipalName
    }

    return "<unknown>"
}

function Get-GraphMemberValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $null
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) {
        return $prop.Value
    }

    return $null
}

function Test-GraphMemberExists {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }

    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-DirectoryObjectTypeName {
    param([Parameter(Mandatory = $true)]$Object)

    foreach ($propertyName in @("@odata.type", "OdataType")) {
        if (Test-GraphMemberExists -Object $Object -Name $propertyName) {
            $value = [string](Get-GraphMemberValue -Object $Object -Name $propertyName)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value.TrimStart("#")
            }
        }
    }

    if ($Object.PSObject.Properties.Name -contains "AdditionalProperties" -and $null -ne $Object.AdditionalProperties) {
        $odataType = [string]$Object.AdditionalProperties["@odata.type"]
        if (-not [string]::IsNullOrWhiteSpace($odataType)) {
            return $odataType.TrimStart("#")
        }
    }

    return $null
}

function Test-IsUserDirectoryObject {
    param([Parameter(Mandatory = $true)]$Object)

    $typeName = [string](Get-DirectoryObjectTypeName -Object $Object)
    if (-not [string]::IsNullOrWhiteSpace($typeName) -and $typeName -match "(?i)\.user$") {
        return $true
    }

    if ($Object.PSObject.Properties.Name -contains "AdditionalProperties" -and $null -ne $Object.AdditionalProperties) {
        if ($Object.AdditionalProperties.ContainsKey("userPrincipalName")) {
            return $true
        }
    }

    if ($Object.PSObject.Properties.Name -contains "UserPrincipalName" -and -not [string]::IsNullOrWhiteSpace([string]$Object.UserPrincipalName)) {
        return $true
    }

    return $false
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
                $targets.Add($entry.Trim()) | Out-Null
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
                $targets.Add($value.Trim()) | Out-Null
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
        "Get-MgUser",
        "Update-MgUser",
        "New-MgDirectoryRoleMemberByRef"
    ) | ForEach-Object { $requiredCmdlets.Add($_) | Out-Null }

    if ($RequireDiscoveryCmdlets) {
        $requiredCmdlets.Add("Get-MgTenantRelationshipDelegatedAdminRelationship") | Out-Null
        if ($DiscoveryMode -eq "GDAPAndContracts") {
            $requiredCmdlets.Add("Get-MgContract") | Out-Null
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
        $TenantIds |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() } |
        Sort-Object -Unique
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

function Escape-ODataStringLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)

    return ($Value -replace "'", "''")
}

function New-DeterministicMailNickname {
    param(
        [string]$DisplayName,
        [string]$TenantId
    )

    $base = ($DisplayName -replace "[^a-zA-Z0-9]", "").ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = "breakglass"
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

function Get-PartnerTenantTargets {
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
            $discovered.Add($DiscoveryTenantId) | Out-Null
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
                $discovered.Add($customerTenantId) | Out-Null
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

                $contractTenantId = [string]$contract.CustomerId
                if (-not [string]::IsNullOrWhiteSpace($contractTenantId)) {
                    $discovered.Add($contractTenantId) | Out-Null
                    $contractDiscoveredCount++

                    $contractDisplayName = [string]$contract.DisplayName
                    Register-TenantDisplayName -TenantId $contractTenantId -TenantName $contractDisplayName
                }
            }

            Write-Log -Tenant $discoveryTenantLabel -Message "Discovered $contractDiscoveredCount tenant(s) from active customer contracts."
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
            Write-Log -Level "WARN" -Tenant $discoveryTenantLabel -Message "Disconnect-MgGraph failed after discovery: $($_.Exception.Message)"
        }
    }

    return @($discovered | Sort-Object -Unique)
}

function Format-DirectoryObjectPreview {
    param(
        [object[]]$Objects,
        [int]$Limit = 5
    )

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($object in @($Objects | Select-Object -First $Limit)) {
        $display = Get-DirectoryObjectDisplay -Object $object
        $id = Get-DirectoryObjectId -Object $object
        if ([string]::IsNullOrWhiteSpace($id)) {
            $items.Add($display) | Out-Null
        }
        else {
            $items.Add("$display [$id]") | Out-Null
        }
    }

    if (@($Objects).Count -gt $Limit) {
        $items.Add("+$(@($Objects).Count - $Limit) more") | Out-Null
    }

    if ($items.Count -eq 0) {
        return "<none>"
    }

    return ($items -join ", ")
}

function Get-GroupTypesArray {
    param($Group)

    if ($null -eq $Group) {
        return @()
    }

    $groupTypes = [System.Collections.Generic.List[string]]::new()

    foreach ($value in @($Group.GroupTypes)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $groupTypes.Add([string]$value) | Out-Null
        }
    }

    if ($groupTypes.Count -eq 0 -and $Group.PSObject.Properties.Name -contains "AdditionalProperties" -and $null -ne $Group.AdditionalProperties) {
        $rawGroupTypes = $Group.AdditionalProperties["groupTypes"]
        foreach ($value in @($rawGroupTypes)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                $groupTypes.Add([string]$value) | Out-Null
            }
        }
    }

    return @($groupTypes | Sort-Object -Unique)
}

function Test-IsAssignedSecurityGroup {
    param($Group)

    if ($null -eq $Group) {
        return [pscustomobject]@{
            IsValid = $false
            Reason  = "Group object is null."
        }
    }

    $groupTypes = @(Get-GroupTypesArray -Group $Group)
    if ($Group.SecurityEnabled -ne $true) {
        return [pscustomobject]@{
            IsValid = $false
            Reason  = "securityEnabled is not true."
        }
    }

    if ($Group.MailEnabled -eq $true) {
        return [pscustomobject]@{
            IsValid = $false
            Reason  = "mailEnabled is true."
        }
    }

    if ($groupTypes.Count -gt 0) {
        return [pscustomobject]@{
            IsValid = $false
            Reason  = "groupTypes is not empty ($($groupTypes -join ', '))."
        }
    }

    return [pscustomobject]@{
        IsValid = $true
        Reason  = $null
    }
}

function Get-SoleMemberUserPosture {
    param(
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][string]$TenantLabel
    )

    $user = Invoke-WithRetry -Tenant $TenantLabel -Operation "Get sole member user posture" -Script {
        Get-MgUser -UserId $UserId -Property "id,displayName,userPrincipalName,accountEnabled,userType,onPremisesSyncEnabled" -ErrorAction Stop
    }

    return [pscustomobject]@{
        Id                    = [string]$user.Id
        DisplayName           = [string]$user.DisplayName
        UserPrincipalName     = [string]$user.UserPrincipalName
        AccountEnabled        = [bool]$user.AccountEnabled
        UserType              = [string]$user.UserType
        OnPremisesSyncEnabled = if ($null -eq $user.OnPremisesSyncEnabled) { $null } else { [bool]$user.OnPremisesSyncEnabled }
    }
}

function Invoke-TenantBreakGlassCompliance {
    param([string]$TargetTenantId)

    $summary = [ordered]@{
        TenantId                    = $TargetTenantId
        TenantName                  = $TargetTenantId
        Status                      = "Success"
        GroupId                     = $null
        GroupName                   = $null
        MemberCount                 = 0
        SoleMemberUserPrincipalName = $null
        AccountEnabled              = $null
        IsGlobalAdmin               = $null
        Action                      = $null
        WarningCount                = 0
        Error                       = $null
    }

    $tenantLogLabel = $summary.TenantName
    $cachedTenantName = Get-TenantDisplayNameFromCache -TenantId $TargetTenantId
    if (-not [string]::IsNullOrWhiteSpace($cachedTenantName)) {
        $summary.TenantName = $cachedTenantName
        $tenantLogLabel = $cachedTenantName
    }

    $actions = [System.Collections.Generic.List[string]]::new()
    $groupJustCreated = $false
    $group = $null

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
                    -Operation "Tenant compliance Graph connect" `
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

        $globalAdminMembers = @(Invoke-WithRetry -Tenant $tenantLogLabel -Operation "Get Global Administrator role members" -Script {
                Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All -ErrorAction Stop
            })

        $globalAdminIds = @{}
        foreach ($member in $globalAdminMembers) {
            $id = Get-DirectoryObjectId -Object $member
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $globalAdminIds[$id] = $member
            }
        }

        Write-Log -Tenant $tenantLogLabel -Message "Current Global Administrator role member count: $($globalAdminIds.Count)"

        $escapedName = Escape-ODataStringLiteral -Value $GroupDisplayName
        $matchingGroups = @(Invoke-WithRetry -Tenant $tenantLogLabel -Operation "Get break-glass group by display name" -Script {
                Get-MgGroup -Filter "displayName eq '$escapedName'" -ConsistencyLevel eventual -All -Property $script:ManagedGroupProperties -ErrorAction Stop
            })

        if ($matchingGroups.Count -gt 1) {
            $preview = Format-DirectoryObjectPreview -Objects $matchingGroups
            Add-UniqueAction -Actions $actions -Action "ManualReviewRequired"
            throw "Manual review required: multiple groups named '$GroupDisplayName' found. Preview: $preview"
        }

        if ($matchingGroups.Count -eq 1) {
            $group = $matchingGroups[0]
            $summary.GroupId = $group.Id
            $summary.GroupName = $group.DisplayName
            Write-Log -Tenant $tenantLogLabel -Message "Using existing group '$($group.DisplayName)' [$($group.Id)]"

            $groupValidation = Test-IsAssignedSecurityGroup -Group $group
            if (-not $groupValidation.IsValid) {
                Add-UniqueAction -Actions $actions -Action "ManualReviewRequired"
                throw "Manual review required: group '$($group.DisplayName)' [$($group.Id)] is not an assigned security group. $($groupValidation.Reason)"
            }
        }
        else {
            Write-Log -Tenant $tenantLogLabel -Message "Break-glass group not found: $GroupDisplayName"

            if ($DryRun) {
                Add-UniqueAction -Actions $actions -Action "CreatedGroup"
                Write-Log -Tenant $tenantLogLabel -Message "DRY RUN: would create group '$GroupDisplayName'"
                $group = [pscustomobject]@{
                    Id              = "<dry-run-group>"
                    DisplayName     = $GroupDisplayName
                    SecurityEnabled = $true
                    MailEnabled     = $false
                    GroupTypes      = @()
                }
            }
            else {
                $mailNickname = New-DeterministicMailNickname -DisplayName $GroupDisplayName -TenantId $TargetTenantId
                try {
                    $group = Invoke-WithRetry -Tenant $tenantLogLabel -Operation "Create break-glass group" -Script {
                        New-MgGroup `
                            -DisplayName $GroupDisplayName `
                            -Description $script:BreakGlassGroupDescription `
                            -MailEnabled:$false `
                            -MailNickname $mailNickname `
                            -SecurityEnabled:$true `
                            -ErrorAction Stop
                    }
                    $groupJustCreated = $true
                    Add-UniqueAction -Actions $actions -Action "CreatedGroup"
                    Write-Log -Tenant $tenantLogLabel -Message "Created group '$($group.DisplayName)' [$($group.Id)]"
                }
                catch {
                    if ($_.Exception.Message -match "(?i)mailnickname|already exists|objectconflict|another object with the same value") {
                        Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Group creation reported a mailNickname conflict for '$mailNickname'; attempting to locate the existing object."
                        $summary.WarningCount++

                        $exactMatchesAfterConflict = @(Get-MgGroup -Filter "displayName eq '$escapedName'" -ConsistencyLevel eventual -All -Property $script:ManagedGroupProperties -ErrorAction Stop)
                        if ($exactMatchesAfterConflict.Count -gt 1) {
                            $preview = Format-DirectoryObjectPreview -Objects $exactMatchesAfterConflict
                            Add-UniqueAction -Actions $actions -Action "ManualReviewRequired"
                            throw "Manual review required: multiple groups named '$GroupDisplayName' found after creation conflict. Preview: $preview"
                        }
                        if ($exactMatchesAfterConflict.Count -eq 1) {
                            $group = $exactMatchesAfterConflict[0]
                            Write-Log -Tenant $tenantLogLabel -Message "Using existing group '$($group.DisplayName)' [$($group.Id)] found after creation conflict."
                        }
                        else {
                            $escapedNickname = Escape-ODataStringLiteral -Value $mailNickname
                            $groupsByNickname = @(Get-MgGroup -Filter "mailNickname eq '$escapedNickname'" -ConsistencyLevel eventual -All -Property $script:ManagedGroupProperties -ErrorAction Stop)
                            if ($groupsByNickname.Count -ne 1) {
                                Add-UniqueAction -Actions $actions -Action "ManualReviewRequired"
                                throw "Manual review required: mailNickname conflict occurred, but the existing group for '$mailNickname' could not be uniquely resolved."
                            }

                            $group = $groupsByNickname[0]
                            if ($group.DisplayName -ne $GroupDisplayName) {
                                Add-UniqueAction -Actions $actions -Action "ManualReviewRequired"
                                throw "Manual review required: existing object with mailNickname '$mailNickname' has displayName '$($group.DisplayName)' instead of '$GroupDisplayName'."
                            }

                            Write-Log -Tenant $tenantLogLabel -Message "Using existing group '$($group.DisplayName)' [$($group.Id)] found by mailNickname."
                        }
                    }
                    else {
                        throw
                    }
                }
            }

            $summary.GroupId = $group.Id
            $summary.GroupName = $group.DisplayName

            $groupValidation = Test-IsAssignedSecurityGroup -Group $group
            if (-not $groupValidation.IsValid) {
                Add-UniqueAction -Actions $actions -Action "ManualReviewRequired"
                throw "Manual review required: group '$($group.DisplayName)' [$($group.Id)] is not an assigned security group. $($groupValidation.Reason)"
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

        $summary.MemberCount = @($currentMembers).Count
        Write-Log -Tenant $tenantLogLabel -Message "Current break-glass group direct member count: $($summary.MemberCount)"

        if ($summary.MemberCount -eq 0) {
            Add-UniqueAction -Actions $actions -Action "GroupEmpty"
            $summary.WarningCount++
            Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Break-glass group '$GroupDisplayName' is empty. Assign one user manually."
        }
        elseif ($summary.MemberCount -gt 1) {
            Add-UniqueAction -Actions $actions -Action "ManualReviewRequired"
            $summary.WarningCount++
            $preview = Format-DirectoryObjectPreview -Objects $currentMembers
            Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Break-glass group '$GroupDisplayName' has more than one direct member. Manual review required. Preview: $preview"
        }
        else {
            $soleMember = $currentMembers[0]
            $soleMemberId = Get-DirectoryObjectId -Object $soleMember

            if ([string]::IsNullOrWhiteSpace($soleMemberId)) {
                Add-UniqueAction -Actions $actions -Action "ManualReviewRequired"
                $summary.WarningCount++
                Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Could not resolve the sole group member's directory object ID. Manual review required."
            }
            elseif (-not (Test-IsUserDirectoryObject -Object $soleMember)) {
                Add-UniqueAction -Actions $actions -Action "ManualReviewRequired"
                $summary.WarningCount++
                Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Sole group member '$([string](Get-DirectoryObjectDisplay -Object $soleMember))' [$soleMemberId] is not a user object. Manual review required."
            }
            else {
                $user = Get-SoleMemberUserPosture -UserId $soleMemberId -TenantLabel $tenantLogLabel
                $summary.SoleMemberUserPrincipalName = $user.UserPrincipalName
                $summary.AccountEnabled = $user.AccountEnabled
                $summary.IsGlobalAdmin = $globalAdminIds.ContainsKey($user.Id)

                $isGuest = ($user.UserType -match "^(?i)guest$")
                $isHybridSynced = ($user.OnPremisesSyncEnabled -eq $true)
                if ($isGuest -or $isHybridSynced) {
                    Add-UniqueAction -Actions $actions -Action "ManualReviewRequired"
                    $summary.WarningCount++

                    $reasonParts = [System.Collections.Generic.List[string]]::new()
                    if ($isGuest) {
                        $reasonParts.Add("userType=Guest") | Out-Null
                    }
                    if ($isHybridSynced) {
                        $reasonParts.Add("onPremisesSyncEnabled=true") | Out-Null
                    }

                    Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Sole member '$($user.UserPrincipalName)' is not an eligible self-heal target ($($reasonParts -join '; ')). Manual review required; skipping account and role changes."
                }
                else {
                    if ($user.AccountEnabled -ne $true) {
                        if ($DryRun) {
                            Write-Log -Tenant $tenantLogLabel -Message "DRY RUN: would enable break-glass user '$($user.UserPrincipalName)' [$($user.Id)]"
                        }
                        else {
                            Invoke-WithRetry -Tenant $tenantLogLabel -Operation "Enable break-glass user" -Script {
                                Update-MgUser -UserId $user.Id -AccountEnabled:$true -ErrorAction Stop
                            } | Out-Null
                            Write-Log -Tenant $tenantLogLabel -Message "Enabled break-glass user '$($user.UserPrincipalName)' [$($user.Id)]"
                        }

                        Add-UniqueAction -Actions $actions -Action "EnabledUser"
                        $summary.AccountEnabled = $true
                    }

                    if (-not $summary.IsGlobalAdmin) {
                        if ($DryRun) {
                            Write-Log -Tenant $tenantLogLabel -Message "DRY RUN: would assign Global Administrator to '$($user.UserPrincipalName)' [$($user.Id)]"
                        }
                        else {
                            try {
                                Invoke-WithRetry -Tenant $tenantLogLabel -Operation "Assign Global Administrator role" -Script {
                                    New-MgDirectoryRoleMemberByRef -DirectoryRoleId $role.Id -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)" -ErrorAction Stop
                                } | Out-Null
                                Write-Log -Tenant $tenantLogLabel -Message "Assigned Global Administrator to '$($user.UserPrincipalName)' [$($user.Id)]"
                            }
                            catch {
                                if ($_.Exception.Message -match "(?i)added object references already exist|already exist") {
                                    Write-Log -Tenant $tenantLogLabel -Message "User '$($user.UserPrincipalName)' [$($user.Id)] is already a Global Administrator."
                                }
                                else {
                                    throw
                                }
                            }
                        }

                        Add-UniqueAction -Actions $actions -Action "AssignedGlobalAdmin"
                        $summary.IsGlobalAdmin = $true
                    }
                }
            }
        }

        if ($actions.Count -eq 0) {
            Add-UniqueAction -Actions $actions -Action "AlreadyCompliant"
        }

        Write-Log -Tenant $tenantLogLabel -Message "Tenant compliance complete. Action=$($actions -join '+')"
    }
    catch {
        $summary.Status = "Failed"
        $summary.Error = Get-TenantFailureMessage -ErrorObject $_
        if ($summary.Error -match "(?i)^Manual review required:") {
            Add-UniqueAction -Actions $actions -Action "ManualReviewRequired"
        }
        Write-Log -Level "ERROR" -Tenant $tenantLogLabel -Message "Tenant compliance failed: $($summary.Error)"
    }
    finally {
        $summary.Action = if ($actions.Count -gt 0) { $actions -join "+" } elseif ($summary.Status -eq "Failed") { "Failed" } else { $summary.Action }

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

Assert-RequiredGraphCmdlets -RequireDiscoveryCmdlets:$autoDiscoverTenantsEnabled -DiscoveryMode $DiscoveryMode

$manualTargets = Resolve-TenantTargets -TenantId $TenantId -TenantListPath $TenantListPath -AllowEmpty
$extraIncludeTargets = Get-NormalizedTenantIdList -TenantIds $IncludeTenantId
$excludeTargets = Get-NormalizedTenantIdList -TenantIds $ExcludeTenantId

$resolvedDiscoveryTenantId = $DiscoveryTenantId
$discoveredTargets = @()
if ($autoDiscoverTenantsEnabled) {
    if ([string]::IsNullOrWhiteSpace($resolvedDiscoveryTenantId)) {
        $resolvedDiscoveryTenantId = [string](Read-Host "Enter discovery tenant ID/domain for auto-discovery")
        if ([string]::IsNullOrWhiteSpace($resolvedDiscoveryTenantId)) {
            throw "Auto-discovery requires -DiscoveryTenantId. Re-run with -DiscoveryTenantId or provide a value at the prompt."
        }

        $resolvedDiscoveryTenantId = $resolvedDiscoveryTenantId.Trim()
        Write-Log -Message "Using prompted discovery tenant '$resolvedDiscoveryTenantId'."
    }

    $discoveredTargets = Get-PartnerTenantTargets `
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

Write-Log -Message ("Starting break-glass compliance for {0} tenant(s)." -f $targetTenants.Count)

$results = [System.Collections.Generic.List[object]]::new()
foreach ($target in $targetTenants) {
    $result = Invoke-TenantBreakGlassCompliance -TargetTenantId $target
    $results.Add($result) | Out-Null

    if ($StopOnError -and $result.Status -eq "Failed") {
        Write-Log -Level "WARN" -Message "Stopping early because -StopOnError was specified."
        break
    }
}

Write-Log -Message "Run summary:"
$results |
    Sort-Object TenantName |
    Format-Table TenantName, Status, GroupName, MemberCount, SoleMemberUserPrincipalName, AccountEnabled, IsGlobalAdmin, Action, WarningCount -AutoSize |
    Out-String |
    ForEach-Object { $_.TrimEnd() } |
    ForEach-Object {
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
