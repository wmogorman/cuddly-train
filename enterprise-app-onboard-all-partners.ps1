<#
USAGE NOTES - ENTERPRISE APP ONBOARDING (GDAP BATCH)

Purpose
- Onboard an existing multi-tenant app registration into customer tenants as an enterprise app
  (service principal) and grant required Microsoft Graph application permissions.
- Designed for phased rollout across GDAP customer tenants with clear per-tenant status output.

What this script does per tenant
1) Connects to Microsoft Graph using delegated auth.
2) Ensures the target app's service principal exists in the customer tenant.
3) Ensures required Graph app-role assignments are present for the target service principal.
4) Marks tenant as PendingManualConsent if grant operations are blocked by consent/policy.
5) Records tenant-level outcome and writes batch artifacts.

Prerequisites
- Microsoft Graph PowerShell modules installed (authentication, applications, service principal cmdlets).
- Delegated operator account has GDAP role access and can perform app/consent operations.
- For custom delegated sign-in app (`-DelegatedClientId`):
  - Multi-tenant app registration.
  - Public client flows enabled (if using device code).
  - Required delegated Graph permissions and admin consent in partner tenant.
- Target app registration (`-TargetAppId`) exists and is intended for cross-tenant onboarding.

Targeting behavior
- Primary source: active GDAP relationships discovered from `-PartnerTenantId` context.
- `-IncludeTenantId` filters to the specified tenants (and includes listed tenants even if not found in discovery).
- `-ExcludeTenantId` removes tenants after discovery/include resolution.

Safety and behavior flags
- `-WhatIf`: simulates create/grant operations.
- `-StopOnError`: stops batch at first Failed tenant.
- `-UseDeviceCode`: forces device-code sign-in path (with fallback handling in script).

Default required application permissions
- Directory.Read.All
- RoleManagement.Read.Directory
- Group.ReadWrite.All

Tenant statuses
- AlreadyCompliant: service principal and required grants already present.
- Onboarded: missing items created/granted (or planned in WhatIf).
- PendingManualConsent: app/consent operation blocked; admin consent follow-up required.
- Failed: unrecoverable per-tenant error.

Output artifacts
- batch-results.json: detailed per-tenant results.
- batch-results.csv: flattened per-tenant report.
- batch-summary.json: aggregate counters and timing.

Examples
- Dry run for two tenants:
  .\enterprise-app-onboard-all-partners.ps1 `
    -PartnerTenantId "mspTenantGuid" `
    -DelegatedClientId "delegatedClientAppGuid" `
    -TargetAppId "targetAutomationAppGuid" `
    -IncludeTenantId "tenantGuid1","tenantGuid2" `
    -WhatIf -UseDeviceCode

- Live wave with stop-on-first-failure:
  .\enterprise-app-onboard-all-partners.ps1 `
    -PartnerTenantId "mspTenantGuid" `
    -DelegatedClientId "delegatedClientAppGuid" `
    -TargetAppId "targetAutomationAppGuid" `
    -IncludeTenantId "tenantGuid1","tenantGuid2","tenantGuid3" `
    -StopOnError -UseDeviceCode
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [string]$TargetAppId = "f45ddef0-f613-4c3d-92d1-6b80bf00e6cf",
    [string]$PartnerTenantId,
    [string]$DelegatedClientId,
    [switch]$UseDeviceCode,
    [string[]]$IncludeTenantId,
    [string[]]$ExcludeTenantId,
    [string[]]$RequiredApplicationPermission = @(
        "Directory.Read.All",
        "RoleManagement.Read.Directory",
        "Group.ReadWrite.All"
    ),
    [string]$OutputDirectory = (Join-Path -Path $PSScriptRoot -ChildPath ("enterprise-app-onboard-batch-" + (Get-Date -Format "yyyyMMdd-HHmmss"))),
    [switch]$StopOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$graphResourceAppId = "00000003-0000-0000-c000-000000000000"

function Get-GraphAuthenticationModuleVersion {
    $module = Get-Module -Name "Microsoft.Graph.Authentication" -ListAvailable `
        | Sort-Object -Property Version -Descending `
        | Select-Object -First 1

    if ($null -eq $module) {
        return $null
    }

    return [Version]$module.Version
}

function Test-DesktopGraphAuthRuntimeRisk {
    if ($PSVersionTable.PSEdition -ne "Desktop") {
        return $false
    }

    $graphAuthVersion = Get-GraphAuthenticationModuleVersion
    if ($null -eq $graphAuthVersion) {
        return $false
    }

    return ($graphAuthVersion -ge [Version]"2.26.0")
}

function Get-DesktopGraphAuthRuntimeGuidance {
    $graphAuthVersion = Get-GraphAuthenticationModuleVersion
    $graphAuthVersionText = if ($null -eq $graphAuthVersion) { "unknown" } else { $graphAuthVersion.ToString() }

    return "Microsoft Graph PowerShell authentication is unstable in Windows PowerShell 5.1 with Microsoft.Graph.Authentication $graphAuthVersionText. Run this script in PowerShell 7+, or downgrade the Graph PowerShell modules to a known-good 5.1 version such as 2.24.x/2.25.x before retrying."
}

function Invoke-WithoutWhatIfPreference {
    param(
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    $originalWhatIfPreference = $WhatIfPreference
    try {
        $WhatIfPreference = $false
        & $ScriptBlock @ArgumentList
    }
    finally {
        $WhatIfPreference = $originalWhatIfPreference
    }
}

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
        $exception = $exception.InnerException
    }

    if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
        if ($ErrorObject.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorObject.ErrorDetails.Message)) {
            $messages.Add($ErrorObject.ErrorDetails.Message) | Out-Null
        }
    }

    return @($messages | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join " | "
}

function Test-IsManualConsentRequiredError {
    param([object]$ErrorObject)

    $message = Get-ExceptionMessageText -ErrorObject $ErrorObject
    if ([string]::IsNullOrWhiteSpace($message)) {
        return $false
    }

    return ($message -match "(?i)authorization_requestdenied|insufficient privileges|forbidden|access denied|consent|admin consent|permission grant|does not have permission")
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
        return
    }
    catch {
        $message = Get-ExceptionMessageText -ErrorObject $_
        $isUnauthorizedGraphPsClient = $message -match "(?i)AADSTS90099|Microsoft Graph Command Line Tools|has not been authorized in the tenant"
        $isListenerIssue = $message -match "(?i)writing to a listener|EventSourceException"
        $isWamWindowIssue = $message -match "(?i)window handle|wam"
        $hasDesktopGraphAuthRisk = Test-DesktopGraphAuthRuntimeRisk

        if ($isUnauthorizedGraphPsClient -and [string]::IsNullOrWhiteSpace($DelegatedClientId)) {
            throw "Delegated auth failed because the default Graph PowerShell client app (14d82eec-204b-4c2f-b7e8-296a70dab67e) is not authorized in tenant '$TenantId' (AADSTS90099). Re-run with -DelegatedClientId '<your partner-approved app client id>'."
        }

        if ($isListenerIssue -and $hasDesktopGraphAuthRisk) {
            throw (Get-DesktopGraphAuthRuntimeGuidance)
        }

        if ($UseDeviceCode -and $isListenerIssue) {
            Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "$Phase device-code sign-in hit a listener error; retrying with default interactive sign-in."
            $retryParams = @{} + $connectParams
            [void]$retryParams.Remove("UseDeviceCode")
            Invoke-WithoutWhatIfPreference -ScriptBlock {
                param($Params)
                Connect-MgGraph @Params | Out-Null
            } -ArgumentList @($retryParams)
            return
        }

        if ($UseDeviceCode -or -not $isWamWindowIssue) {
            if (-not $UseDeviceCode -and $isListenerIssue) {
                Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "$Phase interactive sign-in hit a listener error; retrying with device code."
                $retryParams = @{} + $connectParams
                $retryParams["UseDeviceCode"] = $true
                Invoke-WithoutWhatIfPreference -ScriptBlock {
                    param($Params)
                    Connect-MgGraph @Params | Out-Null
                } -ArgumentList @($retryParams)
                return
            }
            throw
        }

        Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "$Phase interactive sign-in via WAM failed; retrying with device code."
        $connectParams["UseDeviceCode"] = $true
        Invoke-WithoutWhatIfPreference -ScriptBlock {
            param($Params)
            Connect-MgGraph @Params | Out-Null
        } -ArgumentList @($connectParams)
    }
}

function Import-RequiredGraphModules {
    $requiredModules = @(
        "Microsoft.Graph.Authentication",
        "Microsoft.Graph.Applications",
        "Microsoft.Graph.Identity.Partner"
    )

    foreach ($moduleName in $requiredModules) {
        Invoke-WithoutWhatIfPreference -ScriptBlock {
            param($RequiredModuleName)
            Import-Module -Name $RequiredModuleName -ErrorAction Stop | Out-Null
        } -ArgumentList @($moduleName)
    }
}

function Assert-RequiredGraphCmdlets {
    $requiredCmdlets = @(
        "Connect-MgGraph",
        "Disconnect-MgGraph",
        "Get-MgContext",
        "Get-MgOrganization",
        "Get-MgTenantRelationshipDelegatedAdminRelationship",
        "Get-MgServicePrincipal",
        "New-MgServicePrincipal",
        "Get-MgServicePrincipalAppRoleAssignment",
        "New-MgServicePrincipalAppRoleAssignment"
    )

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
    if ($selectProfile) {
        Select-MgProfile -Name "v1.0" -ErrorAction Stop | Out-Null
        Write-Log -Tenant $TenantLabel -Message "Selected Microsoft Graph profile v1.0."
    }
    else {
        Write-Log -Level "WARN" -Tenant $TenantLabel -Message "Select-MgProfile not available in this SDK version; using default Graph profile."
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

function Disconnect-GraphIfConnected {
    param(
        [string]$TenantId,
        [string]$TenantLabel = $TenantId,
        [string]$Phase
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

function Discover-ActiveGdapCustomers {
    param([string]$PartnerTenantId)

    $discoveryScopes = @("DelegatedAdminRelationship.Read.All")
    $customersByTenant = @{}
    $discoveryTenantLabel = if ([string]::IsNullOrWhiteSpace($PartnerTenantId)) { "" } else { $PartnerTenantId }

    try {
        Write-Log -Message "Connecting to Microsoft Graph for GDAP customer discovery."
        Connect-GraphDelegated -TenantId $PartnerTenantId -TenantLabel $discoveryTenantLabel -Scopes $discoveryScopes -DelegatedClientId $DelegatedClientId -UseDeviceCode:$UseDeviceCode -Phase "Discovery"

        $context = Get-MgContext -ErrorAction Stop
        $discoveryTenantLabel = Get-ConnectedTenantDisplayName -TenantId $context.TenantId -FallbackName $context.TenantId
        Set-GraphProfileIfSupported -TenantId $context.TenantId -TenantLabel $discoveryTenantLabel
        Write-Log -Tenant $discoveryTenantLabel -Message "Discovery connected."

        $relationships = @(Get-MgTenantRelationshipDelegatedAdminRelationship -All -ErrorAction Stop)
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
            if (-not $customersByTenant.ContainsKey($tenantKey)) {
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
                    TenantId             = $tenantId.Trim()
                    CustomerDisplayName  = $customerDisplayName
                    Source               = "GDAP"
                    RelationshipId       = [string]$relationship.Id
                    RelationshipEndDate  = [string]$relationship.EndDateTime
                }
            }
        }
    }
    finally {
        Disconnect-GraphIfConnected -TenantId $PartnerTenantId -TenantLabel $discoveryTenantLabel -Phase "Discovery"
    }

    return @($customersByTenant.Values | Sort-Object -Property TenantId)
}

function Resolve-TargetTenants {
    param(
        [object[]]$DiscoveredTenants,
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
            }
        }
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

    return $resolved
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

function Invoke-TenantEnterpriseAppOnboarding {
    param(
        [object]$TenantTarget,
        [string]$TargetAppId,
        [string[]]$RequiredApplicationPermission
    )

    $tenantId = [string]$TenantTarget.TenantId
    $result = [ordered]@{
        TenantId                    = $tenantId
        TenantName                  = if ([string]::IsNullOrWhiteSpace([string]$TenantTarget.CustomerDisplayName)) { $tenantId } else { [string]$TenantTarget.CustomerDisplayName }
        CustomerDisplayName         = [string]$TenantTarget.CustomerDisplayName
        Source                      = [string]$TenantTarget.Source
        Status                      = "Failed"
        ServicePrincipalId          = $null
        ServicePrincipalCreated     = $false
        RequiredPermissions         = @($RequiredApplicationPermission | Sort-Object -Unique)
        MissingPermissionsBefore    = @()
        GrantedPermissions          = @()
        PendingPermissions          = @()
        ActionLog                   = @()
        AdminConsentUrl             = $null
        Error                       = $null
        StartTime                   = (Get-Date).ToString("o")
        EndTime                     = $null
        DurationSeconds             = $null
        WhatIf                      = [bool]$WhatIfPreference
    }

    $changesApplied = $false
    $changesPlanned = $false
    $manualConsentBlocked = $false
    $manualConsentErrors = [System.Collections.Generic.List[string]]::new()
    $tenantLogLabel = $result.TenantName
    $onboardingScopes = @(
        "Application.ReadWrite.All",
        "AppRoleAssignment.ReadWrite.All",
        "Directory.Read.All"
    )

    try {
        Write-Log -Tenant $tenantLogLabel -Message "Connecting to customer tenant for enterprise app onboarding."
        Connect-GraphDelegated -TenantId $tenantId -TenantLabel $tenantLogLabel -Scopes $onboardingScopes -DelegatedClientId $DelegatedClientId -UseDeviceCode:$UseDeviceCode -Phase "Tenant"
        $context = Get-MgContext -ErrorAction Stop
        $result.TenantName = Get-ConnectedTenantDisplayName -TenantId $tenantId -FallbackName $tenantLogLabel
        if ([string]::IsNullOrWhiteSpace($result.CustomerDisplayName)) {
            $result.CustomerDisplayName = $result.TenantName
        }
        $tenantLogLabel = $result.TenantName
        Set-GraphProfileIfSupported -TenantId $tenantId -TenantLabel $tenantLogLabel
        Write-Log -Tenant $tenantLogLabel -Message "Connected. AuthType: $($context.AuthType)"

        $targetSpMatches = @(Get-MgServicePrincipal -Filter "appId eq '$TargetAppId'" -All -Property "id,appId,displayName")
        if ($targetSpMatches.Count -gt 1) {
            $ids = ($targetSpMatches | ForEach-Object { $_.Id }) -join ", "
            throw "Multiple service principals found for appId $TargetAppId. Resolve duplicates before continuing. IDs: $ids"
        }

        $targetSp = $null
        if ($targetSpMatches.Count -eq 1) {
            $targetSp = $targetSpMatches[0]
            $result.ServicePrincipalId = [string]$targetSp.Id
            $result.ActionLog += "ServicePrincipalAlreadyPresent"
        }
        else {
            $result.ActionLog += "ServicePrincipalMissing"
            if ($PSCmdlet.ShouldProcess($tenantId, "Create service principal for appId $TargetAppId")) {
                try {
                    $targetSp = New-MgServicePrincipal -AppId $TargetAppId -ErrorAction Stop
                    $result.ServicePrincipalId = [string]$targetSp.Id
                    $result.ServicePrincipalCreated = $true
                    $result.ActionLog += "ServicePrincipalCreated"
                    $changesApplied = $true
                }
                catch {
                    if (Test-IsManualConsentRequiredError -ErrorObject $_) {
                        $manualConsentBlocked = $true
                        $result.ActionLog += "ServicePrincipalCreateBlockedPendingManualConsent"
                        $manualConsentErrors.Add((Get-ExceptionMessageText -ErrorObject $_)) | Out-Null
                    }
                    else {
                        throw
                    }
                }
            }
            else {
                $changesPlanned = $true
                $result.ActionLog += "PlannedServicePrincipalCreate"
            }
        }

        if (-not $targetSp -and $manualConsentBlocked) {
            $result.PendingPermissions = @($result.RequiredPermissions)
            $result.AdminConsentUrl = Get-AdminConsentUrl -TenantId $tenantId -AppId $TargetAppId
            $result.Status = "PendingManualConsent"
            $result.Error = ($manualConsentErrors | Select-Object -Unique) -join " | "
            return [pscustomobject]$result
        }

        if (-not $targetSp) {
            $result.MissingPermissionsBefore = @($result.RequiredPermissions)
            $result.ActionLog += "PermissionChecksSkippedNoServicePrincipal"
            $result.Status = if ($changesPlanned) { "Onboarded" } else { "Failed" }
            if (-not $changesPlanned) {
                $result.Error = "Service principal does not exist and was not created."
            }
            return [pscustomobject]$result
        }

        $graphSpMatches = @(Get-MgServicePrincipal -Filter "appId eq '$graphResourceAppId'" -All -Property "id,appId,displayName,appRoles")
        if ($graphSpMatches.Count -eq 0) {
            throw "Microsoft Graph resource service principal not found in tenant."
        }
        if ($graphSpMatches.Count -gt 1) {
            throw "Multiple Microsoft Graph resource service principals found in tenant."
        }
        $graphSp = $graphSpMatches[0]

        $existingAssignments = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $targetSp.Id -All -ErrorAction Stop)
        $assignmentKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($assignment in $existingAssignments) {
            [void]$assignmentKeys.Add("$($assignment.ResourceId)|$($assignment.AppRoleId)")
        }

        $missingPermissions = [System.Collections.Generic.List[string]]::new()
        $permissionRoleMap = @{}
        foreach ($permission in $result.RequiredPermissions) {
            $roleId = Resolve-GraphAppRoleId -GraphSp $graphSp -PermissionValue $permission
            $permissionRoleMap[$permission] = $roleId
            $assignmentKey = "$($graphSp.Id)|$roleId"
            if (-not $assignmentKeys.Contains($assignmentKey)) {
                $missingPermissions.Add($permission) | Out-Null
            }
        }
        $result.MissingPermissionsBefore = @($missingPermissions)

        foreach ($permission in $missingPermissions) {
            $roleId = $permissionRoleMap[$permission]
            $assignmentKey = "$($graphSp.Id)|$roleId"
            if ($PSCmdlet.ShouldProcess($tenantId, "Grant application permission '$permission' to appId $TargetAppId")) {
                try {
                    New-MgServicePrincipalAppRoleAssignment `
                        -ServicePrincipalId $targetSp.Id `
                        -PrincipalId $targetSp.Id `
                        -ResourceId $graphSp.Id `
                        -AppRoleId $roleId `
                        -ErrorAction Stop | Out-Null

                    [void]$assignmentKeys.Add($assignmentKey)
                    $result.GrantedPermissions += $permission
                    $changesApplied = $true
                    $result.ActionLog += "Granted:$permission"
                }
                catch {
                    if ($_.Exception.Message -match "(?i)already exists|added object references already exist") {
                        [void]$assignmentKeys.Add($assignmentKey)
                        $result.ActionLog += "AlreadyGranted:$permission"
                        continue
                    }

                    if (Test-IsManualConsentRequiredError -ErrorObject $_) {
                        $manualConsentBlocked = $true
                        $result.PendingPermissions += $permission
                        $result.ActionLog += "GrantBlockedPendingManualConsent:$permission"
                        $manualConsentErrors.Add((Get-ExceptionMessageText -ErrorObject $_)) | Out-Null
                    }
                    else {
                        throw
                    }
                }
            }
            else {
                $changesPlanned = $true
                $result.ActionLog += "PlannedGrant:$permission"
            }
        }

        if ($manualConsentBlocked -or $result.PendingPermissions.Count -gt 0) {
            $result.Status = "PendingManualConsent"
            $result.AdminConsentUrl = Get-AdminConsentUrl -TenantId $tenantId -AppId $TargetAppId
            $result.Error = ($manualConsentErrors | Select-Object -Unique) -join " | "
        }
        elseif ($changesApplied -or $changesPlanned -or $result.MissingPermissionsBefore.Count -gt 0) {
            $result.Status = "Onboarded"
        }
        else {
            $result.Status = "AlreadyCompliant"
        }
    }
    catch {
        $result.Status = "Failed"
        $result.Error = Get-ExceptionMessageText -ErrorObject $_
    }
    finally {
        $endTime = Get-Date
        $result.EndTime = $endTime.ToString("o")
        $start = [DateTimeOffset]::Parse($result.StartTime)
        $result.DurationSeconds = [Math]::Round(($endTime - $start.DateTime).TotalSeconds, 2)
        Disconnect-GraphIfConnected -TenantId $tenantId -TenantLabel $tenantLogLabel -Phase "Tenant"
    }

    return [pscustomobject]$result
}

Import-RequiredGraphModules
Assert-RequiredGraphCmdlets
Configure-GraphLoginOptions -DelegatedClientId $DelegatedClientId

$requiredPermissionBaseline = @(
    $RequiredApplicationPermission `
    | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } `
    | ForEach-Object { $_.Trim() } `
    | Sort-Object -Unique
)
if ($requiredPermissionBaseline.Count -eq 0) {
    throw "At least one value must be supplied to -RequiredApplicationPermission."
}

$batchStart = Get-Date
$discoveredCustomers = @(Discover-ActiveGdapCustomers -PartnerTenantId $PartnerTenantId)
Write-Log -Message "Discovered $($discoveredCustomers.Count) active GDAP customer tenant(s)."

$targets = @(Resolve-TargetTenants -DiscoveredTenants $discoveredCustomers -IncludeTenantId $IncludeTenantId -ExcludeTenantId $ExcludeTenantId)
if ($targets.Count -eq 0) {
    throw "No target tenants resolved after discovery/include/exclude processing."
}

Write-Log -Message ("Starting enterprise app onboarding for {0} tenant(s)." -f $targets.Count)

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($target in $targets) {
    $tenantResult = Invoke-TenantEnterpriseAppOnboarding `
        -TenantTarget $target `
        -TargetAppId $TargetAppId `
        -RequiredApplicationPermission $requiredPermissionBaseline

    $results.Add($tenantResult)

    if ($tenantResult.Status -eq "PendingManualConsent" -and -not [string]::IsNullOrWhiteSpace($tenantResult.AdminConsentUrl)) {
        Write-Log -Level "WARN" -Tenant $tenantResult.TenantName -Message ("Manual consent required. URL: {0}" -f $tenantResult.AdminConsentUrl)
    }

    if ($StopOnError -and $tenantResult.Status -eq "Failed") {
        Write-Log -Level "WARN" -Message "Stopping early because -StopOnError was specified."
        break
    }
}

$batchEnd = Get-Date
$summary = [ordered]@{
    PartnerTenantId       = $PartnerTenantId
    TargetAppId           = $TargetAppId
    BatchStartTime        = $batchStart.ToString("o")
    BatchEndTime          = $batchEnd.ToString("o")
    DurationSeconds       = [Math]::Round(($batchEnd - $batchStart).TotalSeconds, 2)
    Total                 = $results.Count
    AlreadyCompliant      = @($results | Where-Object { $_.Status -eq "AlreadyCompliant" }).Count
    Onboarded             = @($results | Where-Object { $_.Status -eq "Onboarded" }).Count
    PendingManualConsent  = @($results | Where-Object { $_.Status -eq "PendingManualConsent" }).Count
    Failed                = @($results | Where-Object { $_.Status -eq "Failed" }).Count
    WhatIf                = [bool]$WhatIfPreference
}

$resultsJsonPath = Join-Path -Path $OutputDirectory -ChildPath "batch-results.json"
$resultsCsvPath = Join-Path -Path $OutputDirectory -ChildPath "batch-results.csv"
$summaryPath = Join-Path -Path $OutputDirectory -ChildPath "batch-summary.json"

$results | ConvertTo-Json -Depth 20 | Set-Content -Path $resultsJsonPath -Encoding UTF8

$csvRows = $results | ForEach-Object {
    [pscustomobject]@{
        TenantName               = $_.TenantName
        TenantId                 = $_.TenantId
        CustomerDisplayName      = $_.CustomerDisplayName
        Source                   = $_.Source
        Status                   = $_.Status
        ServicePrincipalId       = $_.ServicePrincipalId
        ServicePrincipalCreated  = $_.ServicePrincipalCreated
        RequiredPermissions      = (@($_.RequiredPermissions) -join ";")
        MissingPermissionsBefore = (@($_.MissingPermissionsBefore) -join ";")
        GrantedPermissions       = (@($_.GrantedPermissions) -join ";")
        PendingPermissions       = (@($_.PendingPermissions) -join ";")
        AdminConsentUrl          = $_.AdminConsentUrl
        Error                    = $_.Error
        StartTime                = $_.StartTime
        EndTime                  = $_.EndTime
        DurationSeconds          = $_.DurationSeconds
        WhatIf                   = $_.WhatIf
    }
}
$csvRows | Export-Csv -Path $resultsCsvPath -NoTypeInformation -Encoding UTF8
$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryPath -Encoding UTF8

Write-Log -Message "Run summary:"
$results `
| Sort-Object TenantName `
| Select-Object TenantName, Status, `
    @{ Name = "Missing"; Expression = { @($_.MissingPermissionsBefore).Count } }, `
    @{ Name = "Granted"; Expression = { @($_.GrantedPermissions).Count } }, `
    @{ Name = "Pending"; Expression = { @($_.PendingPermissions).Count } } `
| Format-Table -AutoSize `
| Out-String `
| ForEach-Object { $_.TrimEnd() } `
| ForEach-Object {
    if (-not [string]::IsNullOrWhiteSpace($_)) {
        Write-Host $_
    }
}

Write-Log -Message "Artifacts written:"
Write-Host "  $resultsJsonPath"
Write-Host "  $resultsCsvPath"
Write-Host "  $summaryPath"

if ($summary.Failed -gt 0) {
    Write-Log -Level "ERROR" -Message "$($summary.Failed) tenant(s) failed."
    exit 1
}

if ($summary.PendingManualConsent -gt 0) {
    Write-Log -Level "WARN" -Message "$($summary.PendingManualConsent) tenant(s) require manual consent follow-up."
}

Write-Log -Message "Complete."
