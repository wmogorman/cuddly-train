<#
USAGE NOTES - ENTERPRISE APP CONSENT WAVE TRACKER

Purpose
- Prepare and maintain a tenant-wide admin consent wave for the multi-tenant app registration
  `ActaMSP_GDAP_Application`.
- Keep the tenant list, consent URLs, manual rollout state, and app-only verification results in
  one place so the 47-tenant wave can be completed without relying on brittle delegated auth
  automation.

What this script does
1) Discovers customer tenants from the partner tenant when `-PartnerTenantId` is provided.
   Discovery uses the same app-only certificate path and discovery modes as `global-admin-audit.ps1`.
2) Resolves the final target list using discovery plus `-TenantListPath`, `-IncludeTenantId`,
   and `-ExcludeTenantId`.
3) Writes or updates an editable consent tracker CSV/JSON while preserving manual statuses/notes.
4) Verifies tenants already marked as approved by connecting app-only with the target app's
   certificate and checking that the service principal and required Graph application permissions
   exist.

What this script does not do
- It does not try to perform the customer-tenant admin consent itself.
- It does not depend on the custom delegated app as the critical path for the rollout.

Editable tracker fields
- `ConsentActor`: `Partner` or `Customer`
- `PartnerAttemptStatus`: recommended values
  - `NotStarted`
  - `PartnerApproved`
  - `CustomerFallback`
  - `CustomerApproved`
  - `BlockedByPolicy`
  - `MissingGdapRole`
  - `UnexpectedError`
- `FallbackRequired`: `True` / `False`
- `Notes`: free text

Verification behavior
- Unless `-SkipVerification` is used, verification probes all current target tenants on rerun so
  successful consents can be detected automatically.
- Verification uses app-only certificate auth and checks:
  - target service principal exists
  - required Graph application permissions are granted

Tracker reruns
- Rerunning the script refreshes discovery/system fields but preserves manual tracker fields.
- If you rerun against an existing `-OutputDirectory` without discovery inputs, the script will
  reuse the existing tracker and verify any rows already marked approved.

Examples
- Initial tracker generation from GDAP discovery:
  .\enterprise-app-onboard-all-partners.ps1 `
    -PartnerTenantId "partnerTenantGuid" `
    -DiscoveryMode GDAPAndContracts `
    -DiscoveryClientId "onboardingAppClientGuid" `
    -DiscoveryThumbprint "onboardingCertThumbprint"

- Target a smaller wave:
  .\enterprise-app-onboard-all-partners.ps1 `
    -PartnerTenantId "partnerTenantGuid" `
    -DiscoveryMode GDAPAndContracts `
    -IncludeTenantId "tenantGuid1","tenantGuid2" `
    -DiscoveryClientId "onboardingAppClientGuid" `
    -DiscoveryThumbprint "onboardingCertThumbprint"

- CSV-driven tracker generation without discovery:
  .\enterprise-app-onboard-all-partners.ps1 `
    -TenantListPath .\tenants.csv `
    -SkipVerification

- Verification-only rerun against an existing tracker directory:
  .\enterprise-app-onboard-all-partners.ps1 `
    -OutputDirectory ".\enterprise-app-onboard-wave-20260316-1"
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Low")]
param(
    [string]$TargetAppId = "f45ddef0-f613-4c3d-92d1-6b80bf00e6cf",
    [string]$PartnerTenantId,
    [ValidateSet("GDAP", "GDAPAndContracts")]
    [string]$DiscoveryMode = "GDAPAndContracts",
    [string]$TenantListPath,
    [string]$DelegatedClientId,
    [switch]$UseDeviceCode,
    [string[]]$IncludeTenantId,
    [string[]]$ExcludeTenantId,
    [string[]]$RequiredApplicationPermission = @(
        "Directory.Read.All",
        "RoleManagement.Read.Directory",
        "Group.ReadWrite.All"
    ),
    [string]$DiscoveryClientId = "9f2a8506-8c22-498f-9d9f-c778f2599da8",
    [string]$DiscoveryThumbprint = "D0278AED132F9C816A815A4BFFF0F48CE8FAECEF",
    [string]$VerificationClientId = "f45ddef0-f613-4c3d-92d1-6b80bf00e6cf",
    [string]$VerificationThumbprint = "D0278AED132F9C816A815A4BFFF0F48CE8FAECEF",
    [string]$OutputDirectory = (Join-Path -Path $PSScriptRoot -ChildPath ("enterprise-app-onboard-wave-" + (Get-Date -Format "yyyyMMdd-HHmmss"))),
    [switch]$SkipVerification,
    [switch]$StopOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$graphResourceAppId = "00000003-0000-0000-c000-000000000000"
$script:TrackerEditableFields = @(
    "ConsentActor",
    "PartnerAttemptStatus",
    "FallbackRequired",
    "Notes"
)

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

function Get-ExceptionMessageText {
    param([object]$ErrorObject)

    $exception = if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
        $ErrorObject.Exception
    }
    elseif ($ErrorObject -is [System.Exception]) {
        $ErrorObject
    }
    else {
        return [string]$ErrorObject
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

    return @(
        $messages |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    ) -join " | "
}

function Get-ExceptionMessageParts {
    param([object]$ErrorObject)

    $messageText = Get-ExceptionMessageText -ErrorObject $ErrorObject
    if ([string]::IsNullOrWhiteSpace($messageText)) {
        return @()
    }

    return @(
        $messageText -split '\s*\|\s*' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )
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

    [pscustomobject]@{
        PrimaryMessage = $primaryMessage
        ErrorCode      = $errorCode
        CorrelationId  = $correlationId
        TraceId        = $traceId
        Timestamp      = $timestamp
        FullText       = $fullText
    }
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

function Invoke-WithoutWhatIfPreference {
    param(
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    $originalWhatIfPreference = $WhatIfPreference
    $originalGlobalWhatIfPreference = $global:WhatIfPreference
    try {
        $WhatIfPreference = $false
        $global:WhatIfPreference = $false
        & $ScriptBlock @ArgumentList
    }
    finally {
        $WhatIfPreference = $originalWhatIfPreference
        $global:WhatIfPreference = $originalGlobalWhatIfPreference
    }
}

function Resolve-ModuleImportTarget {
    param([string]$ModuleName)

    $availableModule = Get-Module -Name $ModuleName -ListAvailable `
        | Sort-Object -Property Version -Descending `
        | Select-Object -First 1
    if ($availableModule) {
        return $availableModule.Path
    }

    $legacyUserModuleRoot = Join-Path -Path $HOME -ChildPath "Documents\WindowsPowerShell\Modules"
    if (-not (Test-Path -LiteralPath $legacyUserModuleRoot)) {
        return $null
    }

    $moduleRoot = Join-Path -Path $legacyUserModuleRoot -ChildPath $ModuleName
    if (-not (Test-Path -LiteralPath $moduleRoot)) {
        return $null
    }

    $manifest = Get-ChildItem -Path $moduleRoot -Recurse -Filter ($ModuleName + ".psd1") -File -ErrorAction SilentlyContinue `
        | Sort-Object -Property FullName -Descending `
        | Select-Object -First 1
    if ($manifest) {
        return $manifest.FullName
    }

    return $null
}

function Import-RequiredGraphModules {
    $requiredModules = @(
        "Microsoft.Graph.Authentication",
        "Microsoft.Graph.Applications",
        "Microsoft.Graph.Identity.DirectoryManagement",
        "Microsoft.Graph.Identity.Partner"
    )

    foreach ($moduleName in $requiredModules) {
        $moduleImportTarget = Resolve-ModuleImportTarget -ModuleName $moduleName
        if ([string]::IsNullOrWhiteSpace($moduleImportTarget)) {
            throw "Required Microsoft Graph module '$moduleName' was not found in the current PowerShell module path or legacy WindowsPowerShell module path."
        }

        Invoke-WithoutWhatIfPreference -ScriptBlock {
            param($RequiredModuleImportTarget)
            Import-Module -Name $RequiredModuleImportTarget -ErrorAction Stop | Out-Null
        } -ArgumentList @($moduleImportTarget)
    }
}

function Assert-RequiredGraphCmdlets {
    param(
        [switch]$RequireDiscovery,
        [ValidateSet("GDAP", "GDAPAndContracts")]
        [string]$DiscoveryMode
    )

    $requiredCmdlets = @(
        "Connect-MgGraph",
        "Disconnect-MgGraph",
        "Get-MgContext",
        "Get-MgOrganization",
        "Get-MgServicePrincipal",
        "Get-MgServicePrincipalAppRoleAssignment"
    )

    if ($RequireDiscovery) {
        $requiredCmdlets += "Get-MgTenantRelationshipDelegatedAdminRelationship"
        if ($DiscoveryMode -eq "GDAPAndContracts") {
            $requiredCmdlets += "Get-MgContract"
        }
    }

    $missing = @($requiredCmdlets | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) {
        throw "Missing Microsoft Graph cmdlets: $($missing -join ', '). Install/import the required Graph modules before running this script."
    }
}

function Configure-GraphLoginOptions {
    param([string]$DelegatedClientId)

    if ([string]::IsNullOrWhiteSpace($DelegatedClientId)) {
        return
    }

    $setGraphOption = Get-Command -Name "Set-MgGraphOption" -ErrorAction SilentlyContinue
    if (-not $setGraphOption) {
        return
    }

    try {
        Invoke-WithoutWhatIfPreference -ScriptBlock {
            Set-MgGraphOption -DisableLoginByWAM $true -ErrorAction Stop
        }
        Write-Log -Message "Applied Graph SDK login option: DisableLoginByWAM=True for custom delegated client auth."
    }
    catch {
        Write-Log -Level "WARN" -Message "Could not set Graph SDK login option DisableLoginByWAM: $($_.Exception.Message)"
    }
}

function Set-GraphProfileIfSupported {
    param(
        [string]$TenantId,
        [string]$TenantLabel = $TenantId
    )

    $selectProfile = Get-Command -Name "Select-MgProfile" -ErrorAction SilentlyContinue
    if (-not $selectProfile) {
        return
    }

    try {
        Select-MgProfile -Name "v1.0" -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log -Level "WARN" -Tenant $TenantLabel -Message "Could not select Graph profile v1.0: $($_.Exception.Message)"
    }
}

function Disconnect-GraphIfConnected {
    param(
        [string]$TenantLabel = "",
        [string]$Phase = "Graph"
    )

    try {
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if ($ctx) {
            Invoke-WithoutWhatIfPreference -ScriptBlock {
                Disconnect-MgGraph -ErrorAction Stop | Out-Null
            }
        }
    }
    catch {
        Write-Log -Level "WARN" -Tenant $TenantLabel -Message "$Phase disconnect failed: $($_.Exception.Message)"
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

function Get-TenantListTargets {
    param([string]$TenantListPath)

    if ([string]::IsNullOrWhiteSpace($TenantListPath)) {
        return @()
    }

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

    $displayColumn = $rows[0].PSObject.Properties.Name | Where-Object { $_ -imatch "^(customerdisplayname|displayname|tenantname)$" } | Select-Object -First 1
    $sourceColumn = $rows[0].PSObject.Properties.Name | Where-Object { $_ -imatch "^source$" } | Select-Object -First 1

    $targetsByTenant = @{}
    foreach ($row in $rows) {
        $tenantId = [string]$row.$tenantColumn
        if ([string]::IsNullOrWhiteSpace($tenantId)) {
            continue
        }

        $tenantId = $tenantId.Trim()
        $tenantKey = $tenantId.ToLowerInvariant()
        $displayName = if ($displayColumn) { [string]$row.$displayColumn } else { $null }
        $source = if ($sourceColumn) { [string]$row.$sourceColumn } else { $null }
        if ([string]::IsNullOrWhiteSpace($source)) {
            $source = "TenantList"
        }

        if (-not $targetsByTenant.ContainsKey($tenantKey)) {
            $targetsByTenant[$tenantKey] = [pscustomobject]@{
                TenantId            = $tenantId
                CustomerDisplayName = $displayName
                Source              = $source
                RelationshipId      = $null
                RelationshipEndDate = $null
            }
            continue
        }

        $existing = $targetsByTenant[$tenantKey]
        if ([string]::IsNullOrWhiteSpace([string]$existing.CustomerDisplayName) -and -not [string]::IsNullOrWhiteSpace($displayName)) {
            $existing.CustomerDisplayName = $displayName
        }
        if ([string]::IsNullOrWhiteSpace([string]$existing.Source) -and -not [string]::IsNullOrWhiteSpace($source)) {
            $existing.Source = $source
        }
    }

    return @($targetsByTenant.Values | Sort-Object -Property TenantId)
}

function Get-FirstNonEmptyValue {
    param([object[]]$Value)

    foreach ($candidate in $Value) {
        $text = [string]$candidate
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            return $text.Trim()
        }
    }

    return $null
}

function ConvertTo-TrackerBoolean {
    param(
        [object]$Value,
        [bool]$Default = $false
    )

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Default
    }

    switch -Regex ($text.Trim()) {
        '^(?i:true|yes|y|1)$' { return $true }
        '^(?i:false|no|n|0)$' { return $false }
        default { return $Default }
    }
}

function Get-AdminConsentUrl {
    param(
        [string]$TenantId,
        [string]$AppId
    )

    return "https://login.microsoftonline.com/$TenantId/adminconsent?client_id=$AppId"
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

function Test-ContextHasScope {
    param(
        [object]$Context,
        [string]$Scope
    )

    if ($null -eq $Context -or -not $Context.Scopes) {
        return $false
    }

    return @($Context.Scopes | Where-Object { [string]$_ -eq $Scope }).Count -gt 0
}

function Connect-GraphDelegated {
    param(
        [string]$TenantId,
        [string]$TenantLabel,
        [string[]]$Scopes,
        [string]$DelegatedClientId,
        [switch]$UseDeviceCode,
        [string]$Phase
    )

    $tenantLogLabel = if ([string]::IsNullOrWhiteSpace($TenantLabel)) { $TenantId } else { $TenantLabel }
    $existingContext = Get-MgContext -ErrorAction SilentlyContinue
    if (
        $existingContext -and
        $existingContext.AuthType -eq "Delegated" -and
        ([string]::IsNullOrWhiteSpace($TenantId) -or [string]$existingContext.TenantId -eq $TenantId)
    ) {
        $missingScopes = @($Scopes | Where-Object { -not (Test-ContextHasScope -Context $existingContext -Scope $_) })
        if ($missingScopes.Count -eq 0) {
            Write-Log -Tenant $tenantLogLabel -Message "Reusing existing delegated Microsoft Graph context."
            return [pscustomobject]@{
                ConnectedByScript = $false
                TenantId          = [string]$existingContext.TenantId
            }
        }
    }

    $connectParams = @{
        Scopes       = $Scopes
        NoWelcome    = $true
        ErrorAction  = "Stop"
        ContextScope = "Process"
    }
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $connectParams["TenantId"] = $TenantId
    }
    if (-not [string]::IsNullOrWhiteSpace($DelegatedClientId)) {
        $connectParams["ClientId"] = $DelegatedClientId
    }
    if ($UseDeviceCode) {
        $connectParams["UseDeviceCode"] = $true
    }

    try {
        Invoke-WithoutWhatIfPreference -ScriptBlock {
            param($Params)
            Connect-MgGraph @Params | Out-Null
        } -ArgumentList @($connectParams)

        $context = Get-MgContext -ErrorAction Stop
        return [pscustomobject]@{
            ConnectedByScript = $true
            TenantId          = [string]$context.TenantId
        }
    }
    catch {
        $message = Get-FormattedGraphAuthError `
            -ErrorObject $_ `
            -Operation "Delegated Graph connect" `
            -TenantId $TenantId `
            -ClientId $DelegatedClientId `
            -Scopes $Scopes
        $isAuthTimeout = $message -match "(?i)timed out after 120 seconds due to inactivity"
        if (-not [string]::IsNullOrWhiteSpace($DelegatedClientId)) {
            throw "Delegated discovery auth failed for custom client '$DelegatedClientId'. $message Re-run without -DelegatedClientId, or pre-connect manually with Connect-MgGraph and then rerun the script."
        }

        if ($isAuthTimeout) {
            throw "Delegated discovery auth timed out before interactive completion. Pre-connect manually in the same PowerShell 7 session with: Connect-MgGraph -TenantId '$TenantId' -Scopes '$($Scopes -join ''',''')' -NoWelcome. After it succeeds, rerun this script in the same session without -UseDeviceCode."
        }

        throw
    }
}

function Connect-GraphAppOnly {
    param(
        [string]$TenantId,
        [string]$TenantLabel,
        [string]$ClientId,
        [string]$CertificateThumbprint
    )

    $connectParams = @{
        ClientId              = $ClientId
        TenantId              = $TenantId
        CertificateThumbprint = $CertificateThumbprint
        NoWelcome             = $true
        ErrorAction           = "Stop"
        ContextScope          = "Process"
    }

    try {
        Invoke-WithoutWhatIfPreference -ScriptBlock {
            param($Params)
            Connect-MgGraph @Params | Out-Null
        } -ArgumentList @($connectParams)
    }
    catch {
        throw (Get-FormattedGraphAuthError `
                -ErrorObject $_ `
                -Operation "App-only Graph connect" `
                -TenantId $TenantId `
                -ClientId $ClientId `
                -CertificateThumbprint $CertificateThumbprint)
    }

    Set-GraphProfileIfSupported -TenantId $TenantId -TenantLabel $TenantLabel
}

function Invoke-WithRetry {
    param(
        [scriptblock]$Script,
        [string]$Operation,
        [string]$Tenant,
        [int]$MaxAttempts = 5
    )

    $attempt = 1
    while ($true) {
        try {
            return & $Script
        }
        catch {
            $message = Get-ExceptionMessageText -ErrorObject $_
            $statusCode = $null

            if ($_.Exception.PSObject.Properties.Name -contains "ResponseStatusCode") {
                $statusCode = [int]$_.Exception.ResponseStatusCode
            }

            $isRetryable = (
                ($statusCode -in @(429, 500, 502, 503, 504)) -or
                ($message -match "(?i)too many requests|temporarily unavailable|timeout|throttl|gateway|service unavailable")
            )

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

function Discover-ActiveGdapCustomers {
    param(
        [string]$PartnerTenantId,
        [ValidateSet("GDAP", "GDAPAndContracts")]
        [string]$DiscoveryMode,
        [string]$DiscoveryClientId,
        [string]$DiscoveryThumbprint
    )

    if ([string]::IsNullOrWhiteSpace($PartnerTenantId)) {
        return @()
    }

    $customersByTenant = @{}
    $discoveryTenantLabel = $PartnerTenantId

    try {
        Write-Log -Message "Connecting to Microsoft Graph for GDAP customer discovery."
        Connect-GraphAppOnly `
            -TenantId $PartnerTenantId `
            -TenantLabel $discoveryTenantLabel `
            -ClientId $DiscoveryClientId `
            -CertificateThumbprint $DiscoveryThumbprint

        $context = Get-MgContext -ErrorAction Stop
        $discoveryTenantLabel = Get-ConnectedTenantDisplayName -TenantId $context.TenantId -FallbackName $context.TenantId
        Write-Log -Tenant $discoveryTenantLabel -Message "Discovery connected."

        $gdapDiscoveredCount = 0
        $relationships = @(Invoke-WithRetry -Tenant $discoveryTenantLabel -Operation "Get GDAP relationships" -Script {
                Get-MgTenantRelationshipDelegatedAdminRelationship -All -ErrorAction Stop
            })

        foreach ($relationship in $relationships) {
            $status = [string]$relationship.Status
            if (-not ($status -match "^(?i)active$")) {
                continue
            }

            $tenantId = Get-CustomerTenantIdFromRelationship -Relationship $relationship
            if ([string]::IsNullOrWhiteSpace($tenantId)) {
                continue
            }

            $tenantKey = $tenantId.Trim().ToLowerInvariant()
            if ($customersByTenant.ContainsKey($tenantKey)) {
                continue
            }

            $customerDisplayName = $null
            if ($relationship.Customer) {
                if ($relationship.Customer.PSObject.Properties.Name -contains "DisplayName" -and -not [string]::IsNullOrWhiteSpace([string]$relationship.Customer.DisplayName)) {
                    $customerDisplayName = [string]$relationship.Customer.DisplayName
                }
                elseif ($relationship.Customer.PSObject.Properties.Name -contains "AdditionalProperties" -and $null -ne $relationship.Customer.AdditionalProperties) {
                    $customerDisplayName = [string]$relationship.Customer.AdditionalProperties["displayName"]
                }
            }

            $customersByTenant[$tenantKey] = [pscustomobject]@{
                TenantId            = $tenantId.Trim()
                CustomerDisplayName = $customerDisplayName
                Source              = "GDAP"
                RelationshipId      = [string]$relationship.Id
                RelationshipEndDate = [string]$relationship.EndDateTime
            }
            $gdapDiscoveredCount++
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

                $tenantId = [string]$contract.CustomerId
                if ([string]::IsNullOrWhiteSpace($tenantId)) {
                    continue
                }

                $tenantKey = $tenantId.Trim().ToLowerInvariant()
                if (-not $customersByTenant.ContainsKey($tenantKey)) {
                    $customersByTenant[$tenantKey] = [pscustomobject]@{
                        TenantId            = $tenantId.Trim()
                        CustomerDisplayName = [string]$contract.DisplayName
                        Source              = "Contract"
                        RelationshipId      = $null
                        RelationshipEndDate = $null
                    }
                }
                elseif (
                    [string]::IsNullOrWhiteSpace([string]$customersByTenant[$tenantKey].CustomerDisplayName) -and
                    -not [string]::IsNullOrWhiteSpace([string]$contract.DisplayName)
                ) {
                    $customersByTenant[$tenantKey].CustomerDisplayName = [string]$contract.DisplayName
                }

                $contractDiscoveredCount++
            }

            Write-Log -Tenant $discoveryTenantLabel -Message "Discovered $contractDiscoveredCount tenant(s) from active contracts."
        }
    }
    finally {
        Disconnect-GraphIfConnected -TenantLabel $discoveryTenantLabel -Phase "Discovery"
    }

    return @($customersByTenant.Values | Sort-Object -Property TenantId)
}

function Resolve-TargetTenants {
    param(
        [object[]]$DiscoveredTenants,
        [object[]]$TenantListTargets,
        [string[]]$IncludeTenantId,
        [string[]]$ExcludeTenantId
    )

    $targetsByTenant = @{}
    foreach ($entry in $DiscoveredTenants) {
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.TenantId)) {
            continue
        }

        $tenantId = [string]$entry.TenantId
        $tenantKey = $tenantId.ToLowerInvariant()
        if (-not $targetsByTenant.ContainsKey($tenantKey)) {
            $targetsByTenant[$tenantKey] = [pscustomobject]@{
                TenantId            = $tenantId
                CustomerDisplayName = [string]$entry.CustomerDisplayName
                Source              = [string]$entry.Source
                RelationshipId      = [string]$entry.RelationshipId
                RelationshipEndDate = [string]$entry.RelationshipEndDate
            }
        }
    }

    foreach ($entry in $TenantListTargets) {
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.TenantId)) {
            continue
        }

        $tenantId = [string]$entry.TenantId
        $tenantKey = $tenantId.ToLowerInvariant()
        if (-not $targetsByTenant.ContainsKey($tenantKey)) {
            $targetsByTenant[$tenantKey] = [pscustomobject]@{
                TenantId            = $tenantId
                CustomerDisplayName = [string]$entry.CustomerDisplayName
                Source              = [string]$entry.Source
                RelationshipId      = [string]$entry.RelationshipId
                RelationshipEndDate = [string]$entry.RelationshipEndDate
            }
            continue
        }

        $existing = $targetsByTenant[$tenantKey]
        $existing.CustomerDisplayName = Get-FirstNonEmptyValue @([string]$entry.CustomerDisplayName, [string]$existing.CustomerDisplayName, $tenantId)
        $existing.Source = Get-FirstNonEmptyValue @([string]$entry.Source, [string]$existing.Source, "")
        $existing.RelationshipId = Get-FirstNonEmptyValue @([string]$existing.RelationshipId, [string]$entry.RelationshipId, "")
        $existing.RelationshipEndDate = Get-FirstNonEmptyValue @([string]$existing.RelationshipEndDate, [string]$entry.RelationshipEndDate, "")
    }

    $resolved = @($targetsByTenant.Values | Sort-Object -Property TenantId)

    $includeNormalized = @(Get-NormalizedTenantIdList -TenantIds $IncludeTenantId)
    if ($includeNormalized.Count -gt 0) {
        $includeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($tenantId in $includeNormalized) {
            [void]$includeSet.Add($tenantId)
        }

        $resolved = @($resolved | Where-Object { $includeSet.Contains($_.TenantId) })

        foreach ($tenantId in $includeNormalized) {
            if (@($resolved | Where-Object { $_.TenantId -eq $tenantId }).Count -eq 0) {
                $resolved += [pscustomobject]@{
                    TenantId            = $tenantId
                    CustomerDisplayName = $null
                    Source              = "IncludeOverride"
                    RelationshipId      = $null
                    RelationshipEndDate = $null
                }
            }
        }
    }

    $excludeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tenantId in (Get-NormalizedTenantIdList -TenantIds $ExcludeTenantId)) {
        [void]$excludeSet.Add($tenantId)
    }

    if ($excludeSet.Count -gt 0) {
        $resolved = @($resolved | Where-Object { -not $excludeSet.Contains($_.TenantId) })
    }

    return @(
        $resolved |
        Sort-Object @{
            Expression = {
                if ([string]::IsNullOrWhiteSpace([string]$_.CustomerDisplayName)) {
                    [string]$_.TenantId
                }
                else {
                    [string]$_.CustomerDisplayName
                }
            }
        }, TenantId
    )
}

function Get-ExistingTrackerRows {
    param([string]$TrackerCsvPath)

    if (-not (Test-Path -LiteralPath $TrackerCsvPath)) {
        return @()
    }

    return @(Import-Csv -Path $TrackerCsvPath)
}

function Resolve-FinalState {
    param(
        [string]$PartnerAttemptStatus,
        [string]$ConsentActor,
        [bool]$FallbackRequired,
        [string]$VerifiedStatus
    )

    if ($VerifiedStatus -eq "Verified") {
        return "Verified"
    }

    if ($PartnerAttemptStatus -eq "BlockedByPolicy") {
        return "BlockedByPolicy"
    }

    if ($FallbackRequired -or $ConsentActor -eq "Customer" -or $PartnerAttemptStatus -eq "CustomerFallback") {
        return "CustomerFallback"
    }

    return "NeedsInvestigation"
}

function New-ConsentTrackerRow {
    param(
        [string]$TenantId,
        [string]$CustomerDisplayName,
        [string]$Source,
        [string]$RelationshipId,
        [string]$RelationshipEndDate,
        [bool]$IsCurrentTarget,
        [object]$ExistingRow,
        [string]$TargetAppId,
        [string]$PreparedAt
    )

    $existingConsentActor = $null
    $existingPartnerAttemptStatus = $null
    $existingVerifiedStatus = $null
    $existingFallbackRequired = $null
    $existingNotes = $null
    $existingCustomerDisplayName = $null
    $existingSource = $null
    $existingRelationshipId = $null
    $existingRelationshipEndDate = $null
    $existingServicePrincipalId = $null
    $existingMissingPermissions = $null
    $existingVerificationError = $null
    $existingVerifiedAt = $null

    if ($null -ne $ExistingRow) {
        $existingConsentActor = $ExistingRow.ConsentActor
        $existingPartnerAttemptStatus = $ExistingRow.PartnerAttemptStatus
        $existingVerifiedStatus = $ExistingRow.VerifiedStatus
        $existingFallbackRequired = $ExistingRow.FallbackRequired
        $existingNotes = $ExistingRow.Notes
        $existingCustomerDisplayName = $ExistingRow.CustomerDisplayName
        $existingSource = $ExistingRow.Source
        $existingRelationshipId = $ExistingRow.RelationshipId
        $existingRelationshipEndDate = $ExistingRow.RelationshipEndDate
        $existingServicePrincipalId = $ExistingRow.ServicePrincipalId
        $existingMissingPermissions = $ExistingRow.MissingPermissions
        $existingVerificationError = $ExistingRow.VerificationError
        $existingVerifiedAt = $ExistingRow.VerifiedAt
    }

    $consentActor = Get-FirstNonEmptyValue @($existingConsentActor, "Partner")
    $partnerAttemptStatus = Get-FirstNonEmptyValue @($existingPartnerAttemptStatus, "NotStarted")
    $verifiedStatus = Get-FirstNonEmptyValue @($existingVerifiedStatus, "NotChecked")
    $fallbackRequired = ConvertTo-TrackerBoolean -Value $existingFallbackRequired -Default $false
    $notes = Get-FirstNonEmptyValue @($existingNotes, "")
    if ($null -eq $notes) {
        $notes = ""
    }

    $resolvedDisplayName = Get-FirstNonEmptyValue @($CustomerDisplayName, $existingCustomerDisplayName, $TenantId)
    $resolvedSource = Get-FirstNonEmptyValue @($Source, $existingSource, "")
    $resolvedRelationshipId = Get-FirstNonEmptyValue @($RelationshipId, $existingRelationshipId, "")
    $resolvedRelationshipEndDate = Get-FirstNonEmptyValue @($RelationshipEndDate, $existingRelationshipEndDate, "")
    $servicePrincipalId = Get-FirstNonEmptyValue @($existingServicePrincipalId, "")
    $missingPermissions = Get-FirstNonEmptyValue @($existingMissingPermissions, "")
    $verificationError = Get-FirstNonEmptyValue @($existingVerificationError, "")
    $verifiedAt = Get-FirstNonEmptyValue @($existingVerifiedAt, "")
    $finalState = Resolve-FinalState `
        -PartnerAttemptStatus $partnerAttemptStatus `
        -ConsentActor $consentActor `
        -FallbackRequired $fallbackRequired `
        -VerifiedStatus $verifiedStatus

    return [pscustomobject][ordered]@{
        TenantId             = $TenantId
        CustomerDisplayName  = $resolvedDisplayName
        ConsentUrl           = Get-AdminConsentUrl -TenantId $TenantId -AppId $TargetAppId
        ConsentActor         = $consentActor
        PartnerAttemptStatus = $partnerAttemptStatus
        FallbackRequired     = $fallbackRequired
        VerifiedStatus       = $verifiedStatus
        Notes                = $notes
        IsCurrentTarget      = $IsCurrentTarget
        Source               = $resolvedSource
        RelationshipId       = $resolvedRelationshipId
        RelationshipEndDate  = $resolvedRelationshipEndDate
        FinalState           = $finalState
        ServicePrincipalId   = $servicePrincipalId
        MissingPermissions   = $missingPermissions
        VerificationError    = $verificationError
        VerifiedAt           = $verifiedAt
        LastPreparedAt       = $PreparedAt
    }
}

function Merge-ConsentTrackerRows {
    param(
        [object[]]$Targets,
        [object[]]$ExistingRows,
        [string]$TargetAppId,
        [string]$PreparedAt
    )

    $existingByTenant = @{}
    foreach ($existingRow in $ExistingRows) {
        $tenantId = [string]$existingRow.TenantId
        if ([string]::IsNullOrWhiteSpace($tenantId)) {
            continue
        }

        $existingByTenant[$tenantId.ToLowerInvariant()] = $existingRow
    }

    $merged = [System.Collections.Generic.List[object]]::new()
    $currentTenantKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($Targets.Count -gt 0) {
        foreach ($target in $Targets) {
            $tenantId = [string]$target.TenantId
            $tenantKey = $tenantId.ToLowerInvariant()
            [void]$currentTenantKeys.Add($tenantKey)

            $existingRow = $null
            if ($existingByTenant.ContainsKey($tenantKey)) {
                $existingRow = $existingByTenant[$tenantKey]
            }

            $merged.Add((New-ConsentTrackerRow `
                        -TenantId $tenantId `
                        -CustomerDisplayName ([string]$target.CustomerDisplayName) `
                        -Source ([string]$target.Source) `
                        -RelationshipId ([string]$target.RelationshipId) `
                        -RelationshipEndDate ([string]$target.RelationshipEndDate) `
                        -IsCurrentTarget $true `
                        -ExistingRow $existingRow `
                        -TargetAppId $TargetAppId `
                        -PreparedAt $PreparedAt))
        }

        foreach ($existingRow in $ExistingRows) {
            $tenantId = [string]$existingRow.TenantId
            if ([string]::IsNullOrWhiteSpace($tenantId)) {
                continue
            }

            if ($currentTenantKeys.Contains($tenantId)) {
                continue
            }

            $merged.Add((New-ConsentTrackerRow `
                        -TenantId $tenantId `
                        -CustomerDisplayName ([string]$existingRow.CustomerDisplayName) `
                        -Source ([string]$existingRow.Source) `
                        -RelationshipId ([string]$existingRow.RelationshipId) `
                        -RelationshipEndDate ([string]$existingRow.RelationshipEndDate) `
                        -IsCurrentTarget $false `
                        -ExistingRow $existingRow `
                        -TargetAppId $TargetAppId `
                        -PreparedAt $PreparedAt))
        }
    }
    else {
        foreach ($existingRow in $ExistingRows) {
            $tenantId = [string]$existingRow.TenantId
            if ([string]::IsNullOrWhiteSpace($tenantId)) {
                continue
            }

            $merged.Add((New-ConsentTrackerRow `
                        -TenantId $tenantId `
                        -CustomerDisplayName ([string]$existingRow.CustomerDisplayName) `
                        -Source ([string]$existingRow.Source) `
                        -RelationshipId ([string]$existingRow.RelationshipId) `
                        -RelationshipEndDate ([string]$existingRow.RelationshipEndDate) `
                        -IsCurrentTarget (ConvertTo-TrackerBoolean -Value $existingRow.IsCurrentTarget -Default $true) `
                        -ExistingRow $existingRow `
                        -TargetAppId $TargetAppId `
                        -PreparedAt $PreparedAt))
        }
    }

    return @($merged)
}

function Should-VerifyTrackerRow {
    param([object]$TrackerRow)

    return $true
}

function Resolve-GraphAppRoleId {
    param(
        [object]$GraphSp,
        [string]$PermissionValue
    )

    $role = $GraphSp.AppRoles | Where-Object {
        $_.Value -eq $PermissionValue -and $_.AllowedMemberTypes -contains "Application" -and $_.IsEnabled -eq $true
    } | Select-Object -First 1

    if (-not $role) {
        throw "Graph application permission not found in tenant service principal: $PermissionValue"
    }

    return $role.Id
}

function Assert-VerificationPrerequisites {
    param([string]$CertificateThumbprint)

    $matchingCertificates = @(Get-ChildItem Cert:\CurrentUser\My,Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
            $_.Thumbprint -eq $CertificateThumbprint
        })

    if ($matchingCertificates.Count -eq 0) {
        throw "Verification certificate thumbprint '$CertificateThumbprint' was not found in Cert:\CurrentUser\My or Cert:\LocalMachine\My."
    }
}

function Test-TenantConsentVerification {
    param(
        [object]$TrackerRow,
        [string]$VerificationClientId,
        [string]$VerificationThumbprint,
        [string]$TargetAppId,
        [string[]]$RequiredApplicationPermission
    )

    $tenantId = [string]$TrackerRow.TenantId
    $tenantLabel = Get-FirstNonEmptyValue @($TrackerRow.CustomerDisplayName, $tenantId)
    $result = [ordered]@{
        TenantId            = $tenantId
        CustomerDisplayName = $tenantLabel
        VerifiedStatus      = "VerificationFailed"
        ServicePrincipalId  = ""
        MissingPermissions  = ""
        VerificationError   = ""
        VerifiedAt          = (Get-Date).ToString("o")
        FinalState          = $null
        ShouldStop          = $false
    }

    try {
        Write-Log -Tenant $tenantLabel -Message "Verifying app consent via app-only Graph connection."
        Connect-GraphAppOnly `
            -TenantId $tenantId `
            -TenantLabel $tenantLabel `
            -ClientId $VerificationClientId `
            -CertificateThumbprint $VerificationThumbprint

        $resolvedTenantName = Get-ConnectedTenantDisplayName -TenantId $tenantId -FallbackName $tenantLabel
        $result.CustomerDisplayName = $resolvedTenantName
        $tenantLabel = $resolvedTenantName

        $targetSpMatches = @(Invoke-WithRetry -Tenant $tenantLabel -Operation "Get target service principal" -Script {
                Get-MgServicePrincipal -Filter "appId eq '$TargetAppId'" -All -Property "id,appId,displayName" -ErrorAction Stop
            })
        if ($targetSpMatches.Count -eq 0) {
            $result.VerifiedStatus = "MissingServicePrincipal"
            $result.VerificationError = "Target service principal not found."
            return [pscustomobject]$result
        }
        if ($targetSpMatches.Count -gt 1) {
            $result.VerifiedStatus = "VerificationFailed"
            $result.VerificationError = "Multiple service principals found for appId $TargetAppId."
            $result.ShouldStop = $true
            return [pscustomobject]$result
        }

        $targetSp = $targetSpMatches[0]
        $result.ServicePrincipalId = [string]$targetSp.Id

        $graphSpMatches = @(Invoke-WithRetry -Tenant $tenantLabel -Operation "Get Microsoft Graph service principal" -Script {
                Get-MgServicePrincipal -Filter "appId eq '$graphResourceAppId'" -All -Property "id,appId,displayName,appRoles" -ErrorAction Stop
            })
        if ($graphSpMatches.Count -eq 0) {
            throw "Microsoft Graph resource service principal not found in tenant."
        }
        if ($graphSpMatches.Count -gt 1) {
            throw "Multiple Microsoft Graph resource service principals found in tenant."
        }

        $graphSp = $graphSpMatches[0]
        $existingAssignments = @(Invoke-WithRetry -Tenant $tenantLabel -Operation "Get target app role assignments" -Script {
                Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $targetSp.Id -All -ErrorAction Stop
            })

        $assignmentKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($assignment in $existingAssignments) {
            [void]$assignmentKeys.Add("$($assignment.ResourceId)|$($assignment.AppRoleId)")
        }

        $missingPermissions = [System.Collections.Generic.List[string]]::new()
        foreach ($permission in $RequiredApplicationPermission) {
            $roleId = Resolve-GraphAppRoleId -GraphSp $graphSp -PermissionValue $permission
            $assignmentKey = "$($graphSp.Id)|$roleId"
            if (-not $assignmentKeys.Contains($assignmentKey)) {
                $missingPermissions.Add($permission) | Out-Null
            }
        }

        if ($missingPermissions.Count -eq 0) {
            $result.VerifiedStatus = "Verified"
            $result.VerificationError = ""
            $result.MissingPermissions = ""
        }
        else {
            $result.VerifiedStatus = "MissingPermissions"
            $result.VerificationError = "Missing required application permissions."
            $result.MissingPermissions = (@($missingPermissions) -join ";")
        }
    }
    catch {
        $errorMessage = Get-ExceptionMessageText -ErrorObject $_
        if ($errorMessage -match "(?i)AADSTS7000229|missing service principal in the tenant") {
            $result.VerifiedStatus = "MissingServicePrincipal"
            $result.VerificationError = "Target app is not onboarded in this tenant."
        }
        else {
            $result.VerifiedStatus = "VerificationFailed"
            $result.VerificationError = $errorMessage
        }
    }
    finally {
        Disconnect-GraphIfConnected -TenantLabel $tenantLabel -Phase "Verification"
    }

    return [pscustomobject]$result
}

function Ensure-OutputDirectory {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        return
    }

    Invoke-WithoutWhatIfPreference -ScriptBlock {
        param($DirectoryPath)
        New-Item -Path $DirectoryPath -ItemType Directory -Force | Out-Null
    } -ArgumentList @($Path)
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$InputObject,
        [int]$Depth = 10
    )

    Invoke-WithoutWhatIfPreference -ScriptBlock {
        param($JsonPath, $JsonInputObject, $JsonDepth)
        $JsonInputObject | ConvertTo-Json -Depth $JsonDepth | Set-Content -Path $JsonPath -Encoding UTF8
    } -ArgumentList @($Path, $InputObject, $Depth)
}

function Write-CsvFile {
    param(
        [string]$Path,
        [object[]]$InputObject
    )

    Invoke-WithoutWhatIfPreference -ScriptBlock {
        param($CsvPath, $CsvInputObject)
        $CsvInputObject | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    } -ArgumentList @($Path, $InputObject)
}

function Get-CountsByPropertyValue {
    param(
        [object[]]$Rows,
        [string]$PropertyName
    )

    $counts = [ordered]@{}
    foreach ($row in $Rows) {
        $value = [string]$row.$PropertyName
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = "<blank>"
        }

        if (-not $counts.Contains($value)) {
            $counts[$value] = 0
        }
        $counts[$value]++
    }

    return $counts
}

Import-RequiredGraphModules

$requireDiscovery = -not [string]::IsNullOrWhiteSpace($PartnerTenantId)
Assert-RequiredGraphCmdlets -RequireDiscovery:$requireDiscovery -DiscoveryMode $DiscoveryMode
if (-not [string]::IsNullOrWhiteSpace($DelegatedClientId) -or $UseDeviceCode) {
    Write-Log -Level "WARN" -Message "Delegated discovery inputs are ignored. Discovery now uses app-only certificate auth, matching global-admin-audit.ps1."
}

$requiredPermissionBaseline = @(
    $RequiredApplicationPermission |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim() } |
    Sort-Object -Unique
)
if ($requiredPermissionBaseline.Count -eq 0) {
    throw "At least one value must be supplied to -RequiredApplicationPermission."
}

Ensure-OutputDirectory -Path $OutputDirectory

$trackerCsvPath = Join-Path -Path $OutputDirectory -ChildPath "consent-tracker.csv"
$trackerJsonPath = Join-Path -Path $OutputDirectory -ChildPath "consent-tracker.json"
$verificationCsvPath = Join-Path -Path $OutputDirectory -ChildPath "verification-results.csv"
$verificationJsonPath = Join-Path -Path $OutputDirectory -ChildPath "verification-results.json"
$summaryPath = Join-Path -Path $OutputDirectory -ChildPath "consent-summary.json"

$batchStart = Get-Date
$preparedAt = $batchStart.ToString("o")
$existingTrackerRows = @(Get-ExistingTrackerRows -TrackerCsvPath $trackerCsvPath)
$tenantListTargets = @(Get-TenantListTargets -TenantListPath $TenantListPath)
if ($tenantListTargets.Count -gt 0) {
    Write-Log -Message "Loaded $($tenantListTargets.Count) tenant(s) from tenant list '$TenantListPath'."
}

$discoveredCustomers = @()
if ($requireDiscovery) {
    if ([string]::IsNullOrWhiteSpace($DiscoveryClientId)) {
        throw "DiscoveryClientId is required for app-only discovery when -PartnerTenantId is supplied."
    }

    Assert-VerificationPrerequisites -CertificateThumbprint $DiscoveryThumbprint
    $discoveredCustomers = @(Discover-ActiveGdapCustomers `
            -PartnerTenantId $PartnerTenantId `
            -DiscoveryMode $DiscoveryMode `
            -DiscoveryClientId $DiscoveryClientId `
            -DiscoveryThumbprint $DiscoveryThumbprint)
    Write-Log -Message "Discovered $($discoveredCustomers.Count) customer tenant(s) using discovery mode '$DiscoveryMode'."
}
elseif ([string]::IsNullOrWhiteSpace($TenantListPath)) {
    Write-Log -Level "WARN" -Message "PartnerTenantId not supplied. Discovery skipped."
}

$targets = @(Resolve-TargetTenants `
        -DiscoveredTenants $discoveredCustomers `
        -TenantListTargets $tenantListTargets `
        -IncludeTenantId $IncludeTenantId `
        -ExcludeTenantId $ExcludeTenantId)
if ($targets.Count -eq 0 -and $existingTrackerRows.Count -eq 0) {
    throw "No target tenants resolved. Supply -PartnerTenantId for discovery, -TenantListPath for CSV-driven targets, -IncludeTenantId for explicit tenants, or reuse an existing tracker."
}

if ($targets.Count -eq 0 -and $existingTrackerRows.Count -gt 0) {
    Write-Log -Level "WARN" -Message "No current targets resolved. Reusing the existing tracker in '$OutputDirectory'."
}
else {
    Write-Log -Message ("Prepared {0} current target tenant(s)." -f $targets.Count)
}

$trackerRows = @(Merge-ConsentTrackerRows `
        -Targets $targets `
        -ExistingRows $existingTrackerRows `
        -TargetAppId $TargetAppId `
        -PreparedAt $preparedAt)

$rowsToVerify = @($trackerRows | Where-Object { $_.IsCurrentTarget -and (Should-VerifyTrackerRow -TrackerRow $_) })
if ($SkipVerification) {
    Write-Log -Message "Verification skipped by request."
}
elseif ($rowsToVerify.Count -eq 0) {
    Write-Log -Message "No tracker rows are currently marked approved for verification."
}
else {
    Assert-VerificationPrerequisites -CertificateThumbprint $VerificationThumbprint
}

$verificationResults = [System.Collections.Generic.List[object]]::new()
if (-not $SkipVerification) {
    foreach ($trackerRow in $rowsToVerify) {
        $verificationResult = Test-TenantConsentVerification `
            -TrackerRow $trackerRow `
            -VerificationClientId $VerificationClientId `
            -VerificationThumbprint $VerificationThumbprint `
            -TargetAppId $TargetAppId `
            -RequiredApplicationPermission $requiredPermissionBaseline

        $trackerRow.CustomerDisplayName = $verificationResult.CustomerDisplayName
        if (
            $verificationResult.VerifiedStatus -eq "Verified" -and
            [string]$trackerRow.PartnerAttemptStatus -eq "NotStarted"
        ) {
            if ([string]$trackerRow.ConsentActor -eq "Customer") {
                $trackerRow.PartnerAttemptStatus = "CustomerApproved"
            }
            else {
                $trackerRow.PartnerAttemptStatus = "PartnerApproved"
            }
        }
        $trackerRow.VerifiedStatus = $verificationResult.VerifiedStatus
        $trackerRow.ServicePrincipalId = $verificationResult.ServicePrincipalId
        $trackerRow.MissingPermissions = $verificationResult.MissingPermissions
        $trackerRow.VerificationError = $verificationResult.VerificationError
        $trackerRow.VerifiedAt = $verificationResult.VerifiedAt
        $trackerRow.FinalState = Resolve-FinalState `
            -PartnerAttemptStatus ([string]$trackerRow.PartnerAttemptStatus) `
            -ConsentActor ([string]$trackerRow.ConsentActor) `
            -FallbackRequired ([bool]$trackerRow.FallbackRequired) `
            -VerifiedStatus ([string]$trackerRow.VerifiedStatus)

        $verificationResults.Add([pscustomobject][ordered]@{
                TenantId             = $trackerRow.TenantId
                CustomerDisplayName  = $trackerRow.CustomerDisplayName
                PartnerAttemptStatus = $trackerRow.PartnerAttemptStatus
                VerifiedStatus       = $trackerRow.VerifiedStatus
                FinalState           = $trackerRow.FinalState
                ServicePrincipalId   = $trackerRow.ServicePrincipalId
                MissingPermissions   = $trackerRow.MissingPermissions
                VerificationError    = $trackerRow.VerificationError
                VerifiedAt           = $trackerRow.VerifiedAt
            })

        if ($StopOnError -and $verificationResult.ShouldStop) {
            Write-Log -Level "WARN" -Message "Stopping early because -StopOnError was specified."
            break
        }
    }
}

foreach ($trackerRow in $trackerRows) {
    $trackerRow.FinalState = Resolve-FinalState `
        -PartnerAttemptStatus ([string]$trackerRow.PartnerAttemptStatus) `
        -ConsentActor ([string]$trackerRow.ConsentActor) `
        -FallbackRequired ([bool]$trackerRow.FallbackRequired) `
        -VerifiedStatus ([string]$trackerRow.VerifiedStatus)
}

$batchEnd = Get-Date
$currentTargetRows = @($trackerRows | Where-Object { $_.IsCurrentTarget })
$summary = [ordered]@{
    PartnerTenantId            = $PartnerTenantId
    DiscoveryMode              = $DiscoveryMode
    TenantListPath             = $TenantListPath
    TargetAppId                = $TargetAppId
    DiscoveryClientId          = $DiscoveryClientId
    VerificationClientId       = $VerificationClientId
    OutputDirectory            = $OutputDirectory
    BatchStartTime             = $batchStart.ToString("o")
    BatchEndTime               = $batchEnd.ToString("o")
    DurationSeconds            = [Math]::Round(($batchEnd - $batchStart).TotalSeconds, 2)
    TrackerRowCount            = $trackerRows.Count
    CurrentTargetCount         = $currentTargetRows.Count
    VerificationSkipped        = [bool]$SkipVerification
    ApprovedForVerification    = $rowsToVerify.Count
    VerifiedCount              = @($currentTargetRows | Where-Object { $_.VerifiedStatus -eq "Verified" }).Count
    FinalStateCounts           = Get-CountsByPropertyValue -Rows $currentTargetRows -PropertyName "FinalState"
    PartnerAttemptStatusCounts = Get-CountsByPropertyValue -Rows $currentTargetRows -PropertyName "PartnerAttemptStatus"
    VerifiedStatusCounts       = Get-CountsByPropertyValue -Rows $currentTargetRows -PropertyName "VerifiedStatus"
}

Write-CsvFile -Path $trackerCsvPath -InputObject $trackerRows
Write-JsonFile -Path $trackerJsonPath -InputObject $trackerRows -Depth 10
Write-CsvFile -Path $verificationCsvPath -InputObject @($verificationResults)
Write-JsonFile -Path $verificationJsonPath -InputObject @($verificationResults) -Depth 10
Write-JsonFile -Path $summaryPath -InputObject $summary -Depth 10

Write-Log -Message "Consent wave summary:"
$currentTargetRows |
Sort-Object CustomerDisplayName, TenantId |
Select-Object CustomerDisplayName, TenantId, ConsentActor, PartnerAttemptStatus, VerifiedStatus, FinalState |
Format-Table -AutoSize |
Out-String |
ForEach-Object { $_.TrimEnd() } |
ForEach-Object {
    if (-not [string]::IsNullOrWhiteSpace($_)) {
        Write-Host $_
    }
}

Write-Log -Message "Artifacts written:"
Write-Host "  $trackerCsvPath"
Write-Host "  $trackerJsonPath"
Write-Host "  $verificationCsvPath"
Write-Host "  $verificationJsonPath"
Write-Host "  $summaryPath"

Write-Log -Message "Editable tracker fields preserved on rerun: $($script:TrackerEditableFields -join ', ')"
Write-Log -Message "Complete."
