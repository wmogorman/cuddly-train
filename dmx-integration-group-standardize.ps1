<#
Standardize the ActaMSP Integration Group across target tenants.
- Canonical name: ActaMSP Integration Group
- Dynamic rule: enabled internal members with at least one enabled assigned plan, excluding Department = NoSync
- Fallback: assigned security group with direct membership sync when dynamic membership is unavailable
#>

param(
    [string[]]$TenantId,
    [string]$TenantListPath,
    [switch]$AutoDiscoverTenants,
    [string]$DiscoveryTenantId,
    [ValidateSet("GDAP", "GDAPAndContracts")]
    [string]$DiscoveryMode = "GDAPAndContracts",
    [switch]$IncludeMspTenant,
    [string[]]$IncludeTenantId,
    [string[]]$ExcludeTenantId,
    [string]$ClientId = "f45ddef0-f613-4c3d-92d1-6b80bf00e6cf",
    [string]$Thumbprint = "D0278AED132F9C816A815A4BFFF0F48CE8FAECEF",
    [string]$GroupDisplayName = "ActaMSP Integration Group",
    [string[]]$LegacyGroupDisplayName = @("DMX Integration Group", "DMX_Integration_Group", "Datamax_Integration_Group", "Datamax Integration"),
    [string]$ExemptDepartmentValue = "NoSync",
    [switch]$DryRun,
    [switch]$StopOnError
)

$ErrorActionPreference = "Stop"
$script:TenantDisplayNameById = @{}
$script:ManagedGroupProperties = "id,displayName,description,groupTypes,membershipRule,membershipRuleProcessingState,securityEnabled,mailEnabled,mailNickname"
$script:DynamicGroupType = "DynamicMembership"
$script:ExemptDepartmentValue = if ([string]::IsNullOrWhiteSpace($ExemptDepartmentValue)) { $null } else { $ExemptDepartmentValue.Trim() }
$ruleClauses = [System.Collections.Generic.List[string]]::new()
$ruleClauses.Add('(user.userType -eq "Member")') | Out-Null
$ruleClauses.Add('(user.accountEnabled -eq true)') | Out-Null
if (-not [string]::IsNullOrWhiteSpace($script:ExemptDepartmentValue)) {
    $ruleClauses.Add(('(user.department -ne "{0}")' -f $script:ExemptDepartmentValue)) | Out-Null
}
$ruleClauses.Add('(user.assignedPlans -any (assignedPlan.capabilityStatus -eq "Enabled"))') | Out-Null
$script:DynamicMembershipRule = $ruleClauses -join ' and '
$script:DynamicGroupDescription = "Maintained by ActaMSP automation. Dynamic membership for enabled licensed internal users."
$script:AssignedFallbackDescription = "Maintained by ActaMSP automation. Assigned fallback where dynamic membership is unavailable. Direct members mirror enabled licensed internal users."
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

    return ($messages | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join " | "
}

function Get-FormattedGraphAuthError {
    param(
        [object]$ErrorObject,
        [string]$Operation,
        [string]$TenantId
    )

    $message = Get-ExceptionMessageText -ErrorObject $ErrorObject
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = "Microsoft Graph authentication failed."
    }

    return "$Operation failed for tenant '$TenantId'. $message"
}

function Get-TenantFailureMessage {
    param([object]$ErrorObject)

    $message = Get-ExceptionMessageText -ErrorObject $ErrorObject
    if ($message -match "(?i)AADSTS7000229|missing service principal in the tenant") {
        return "AADSTS7000229: automation app is not onboarded in this tenant (enterprise app/service principal missing)."
    }
    if ($message -match "(?i)authorization_requestdenied|insufficient privileges|admin consent|forbidden") {
        return "Authorization/consent error: confirm required app permissions and admin consent are granted in this tenant."
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        return "Tenant standardization failed due to an unknown Graph error."
    }

    return $message
}

function Register-TenantDisplayName {
    param([string]$TenantId, [string]$TenantName)

    if (-not [string]::IsNullOrWhiteSpace($TenantId) -and -not [string]::IsNullOrWhiteSpace($TenantName)) {
        $script:TenantDisplayNameById[$TenantId.Trim().ToLowerInvariant()] = $TenantName.Trim()
    }
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
    param([string]$TenantId, [string]$FallbackName)

    try {
        $org = @(Get-MgOrganization -Property "displayName" -ErrorAction Stop | Select-Object -First 1)
        if ($org.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$org[0].DisplayName)) {
            Register-TenantDisplayName -TenantId $TenantId -TenantName ([string]$org[0].DisplayName)
            return [string]$org[0].DisplayName
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
    param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Name)

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
    param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Name)

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
    param([string[]]$TenantId, [string]$TenantListPath, [switch]$AllowEmpty)

    $targets = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($TenantId)) {
        if (-not [string]::IsNullOrWhiteSpace($entry)) {
            $targets.Add($entry.Trim()) | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($TenantListPath)) {
        if (-not (Test-Path -LiteralPath $TenantListPath)) {
            throw "Tenant list file not found: $TenantListPath"
        }
        $rows = @(Import-Csv -LiteralPath $TenantListPath)
        if ($rows.Count -eq 0) {
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
    param([switch]$RequireDiscoveryCmdlets, [string]$DiscoveryMode)

    $required = @(
        "Connect-MgGraph",
        "Disconnect-MgGraph",
        "Get-MgContext",
        "Get-MgOrganization",
        "Get-MgUser",
        "Get-MgGroup",
        "New-MgGroup",
        "Update-MgGroup",
        "Get-MgGroupMember",
        "New-MgGroupMemberByRef",
        "Remove-MgGroupMemberByRef"
    )

    if ($RequireDiscoveryCmdlets) {
        $required += "Get-MgTenantRelationshipDelegatedAdminRelationship"
        if ($DiscoveryMode -eq "GDAPAndContracts") {
            $required += "Get-MgContract"
        }
    }

    $missing = @($required | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) {
        throw "Missing Microsoft Graph cmdlets: $($missing -join ', '). Install/import the required Graph modules before running this script."
    }
}

function Get-NormalizedTenantIdList {
    param([string[]]$TenantIds)

    return @(
        @($TenantIds) |
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
            $tenantIdValue = [string]$customer.AdditionalProperties["tenantId"]
            if (-not [string]::IsNullOrWhiteSpace($tenantIdValue)) {
                return $tenantIdValue
            }
        }
    }

    return $null
}

function Set-GraphProfileIfSupported {
    param([string]$TenantId, [string]$TenantLabel = $TenantId)

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
    param([string]$DisplayName, [string]$TenantId)

    $base = ($DisplayName -replace "[^a-zA-Z0-9]", "").ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = "dmxintegrationgroup"
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
    return "$base$hash"
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
            throw (Get-FormattedGraphAuthError -ErrorObject $_ -Operation "Partner discovery Graph connect" -TenantId $DiscoveryTenantId)
        }

        Set-GraphProfileIfSupported -TenantId $DiscoveryTenantId -TenantLabel $discoveryTenantLabel
        $discoveryTenantLabel = Get-ConnectedTenantDisplayName -TenantId $DiscoveryTenantId -FallbackName $DiscoveryTenantId
        Register-TenantDisplayName -TenantId $DiscoveryTenantId -TenantName $discoveryTenantLabel

        if ($IncludeMspTenant) {
            $discovered.Add($DiscoveryTenantId) | Out-Null
            Write-Log -Tenant $discoveryTenantLabel -Message "Including MSP tenant in target list."
        }

        $gdapRelationships = @(Invoke-WithRetry -Tenant $discoveryTenantLabel -Operation "Get GDAP relationships" -Script {
                Get-MgTenantRelationshipDelegatedAdminRelationship -All -ErrorAction Stop
            })

        foreach ($relationship in $gdapRelationships) {
            if ([string]$relationship.Status -notmatch "^(?i)active$") {
                continue
            }

            $customerTenantId = Get-CustomerTenantIdFromRelationship -Relationship $relationship
            if (-not [string]::IsNullOrWhiteSpace($customerTenantId)) {
                $discovered.Add($customerTenantId) | Out-Null
                if ($relationship.Customer -and $relationship.Customer.PSObject.Properties.Name -contains "DisplayName") {
                    Register-TenantDisplayName -TenantId $customerTenantId -TenantName ([string]$relationship.Customer.DisplayName)
                }
            }
        }

        if ($DiscoveryMode -eq "GDAPAndContracts") {
            $contracts = @(Invoke-WithRetry -Tenant $discoveryTenantLabel -Operation "Get customer contracts" -Script {
                    Get-MgContract -All -ErrorAction Stop
                })

            foreach ($contract in $contracts) {
                if ($null -ne $contract.DeletedDateTime) {
                    continue
                }

                $customerTenantId = [string]$contract.CustomerId
                if (-not [string]::IsNullOrWhiteSpace($customerTenantId)) {
                    $discovered.Add($customerTenantId) | Out-Null
                }
            }
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

function Test-IsDynamicGroupLicenseConstraintError {
    param([object]$ErrorObject)

    $message = Get-ExceptionMessageText -ErrorObject $ErrorObject
    if ([string]::IsNullOrWhiteSpace($message)) {
        return $false
    }

    if ($message -match "(?i)\bNoLicenseForOperation\b") {
        return $true
    }

    if ($message -match "(?i)tenant does not have proper license") {
        return $true
    }

    return (
        $message -match "(?i)(dynamic|membershiprule|membership rule|group type)" -and
        $message -match "(?i)(premium|p1|license|licensing|sku|subscription|unsupported)"
    )
}

function New-PlannedGroupObject {
    param(
        [string]$DisplayName,
        [string[]]$GroupTypes = @(),
        [string]$MembershipRule,
        [string]$MembershipRuleProcessingState
    )

    return [pscustomobject]@{
        Id                            = "<dry-run-group>"
        DisplayName                   = $DisplayName
        GroupTypes                    = @($GroupTypes)
        MembershipRule                = $MembershipRule
        MembershipRuleProcessingState = $MembershipRuleProcessingState
        SecurityEnabled               = $true
        MailEnabled                   = $false
    }
}

function Get-ManagedGroupById {
    param([string]$GroupId, [string]$TenantLabel)

    return Invoke-WithRetry -Tenant $TenantLabel -Operation "Get group by id" -Script {
        Get-MgGroup -GroupId $GroupId -Property $script:ManagedGroupProperties -ErrorAction Stop
    }
}

function Set-ManagedGroupDisplayNameIfStale {
    param(
        [Parameter(Mandatory = $true)]$Group,
        [string]$ExpectedDisplayName,
        [string]$TenantLabel,
        [string]$Reason = "an earlier update"
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedDisplayName)) {
        return $Group
    }

    if ([string]$Group.DisplayName -ne $ExpectedDisplayName) {
        Write-Log -Level "WARN" -Tenant $TenantLabel -Message "Group display name has not propagated through Graph reads after $Reason; continuing with '$ExpectedDisplayName' locally."
        $Group | Add-Member -NotePropertyName DisplayName -NotePropertyValue $ExpectedDisplayName -Force
    }

    return $Group
}

function Get-ManagedIntegrationGroupCandidates {
    param([string]$CanonicalDisplayName, [string[]]$LegacyDisplayNames, [string]$TenantLabel)

    $searchNames = @(
        @($CanonicalDisplayName)
        @($LegacyDisplayNames)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
    $matchesById = @{}

    foreach ($name in $searchNames) {
        $escapedName = Escape-ODataStringLiteral -Value $name
        $groups = @(Invoke-WithRetry -Tenant $TenantLabel -Operation "Get group by display name '$name'" -Script {
                Get-MgGroup -Filter "displayName eq '$escapedName'" -ConsistencyLevel eventual -All -Property $script:ManagedGroupProperties -ErrorAction Stop
            })

        foreach ($group in $groups) {
            if (-not $matchesById.ContainsKey($group.Id)) {
                $matchesById[$group.Id] = $group
            }
        }
    }

    return @($matchesById.Values | Sort-Object DisplayName, Id)
}

function Find-ManagedGroupByMailNickname {
    param([string]$MailNickname, [string]$TenantLabel)

    $escapedNickname = Escape-ODataStringLiteral -Value $MailNickname
    return @(Invoke-WithRetry -Tenant $TenantLabel -Operation "Get group by mailNickname '$MailNickname'" -Script {
            Get-MgGroup -Filter "mailNickname eq '$escapedNickname'" -ConsistencyLevel eventual -All -Property $script:ManagedGroupProperties -ErrorAction Stop
        })
}

function Get-GroupTypesArray {
    param([Parameter(Mandatory = $true)]$Group)

    return @(
        @($Group.GroupTypes) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { [string]$_ }
    )
}

function Rename-ManagedGroupToCanonical {
    param([Parameter(Mandatory = $true)]$Group, [string]$DisplayName, [string]$TenantLabel)

    if ($DryRun) {
        Write-Log -Tenant $TenantLabel -Message "DRY RUN: would rename group '$($Group.DisplayName)' [$($Group.Id)] to '$DisplayName'"
        return [pscustomobject]@{
            Id                            = $Group.Id
            DisplayName                   = $DisplayName
            GroupTypes                    = @($Group.GroupTypes)
            MembershipRule                = $Group.MembershipRule
            MembershipRuleProcessingState = $Group.MembershipRuleProcessingState
            SecurityEnabled               = $Group.SecurityEnabled
            MailEnabled                   = $Group.MailEnabled
            MailNickname                  = $Group.MailNickname
        }
    }

    Invoke-WithRetry -Tenant $TenantLabel -Operation "Rename group" -Script {
        Update-MgGroup -GroupId $Group.Id -DisplayName $DisplayName -ErrorAction Stop
    } | Out-Null

    Write-Log -Tenant $TenantLabel -Message "Renamed group '$($Group.DisplayName)' [$($Group.Id)] to '$DisplayName'"
    $updated = Get-ManagedGroupById -GroupId $Group.Id -TenantLabel $TenantLabel
    return Set-ManagedGroupDisplayNameIfStale -Group $updated -ExpectedDisplayName $DisplayName -TenantLabel $TenantLabel -Reason "the rename"
}

function New-ManagedSecurityGroup {
    param(
        [string]$DisplayName,
        [string]$TenantId,
        [string]$TenantLabel,
        [string]$Description,
        [ValidateSet("Assigned", "Dynamic")]
        [string]$Mode
    )

    $mailNickname = New-DeterministicMailNickname -DisplayName $DisplayName -TenantId $TenantId
    if ($DryRun) {
        if ($Mode -eq "Dynamic") {
            Write-Log -Tenant $TenantLabel -Message "DRY RUN: would create dynamic group '$DisplayName'"
            return New-PlannedGroupObject -DisplayName $DisplayName -GroupTypes @($script:DynamicGroupType) -MembershipRule $script:DynamicMembershipRule -MembershipRuleProcessingState "On"
        }

        Write-Log -Tenant $TenantLabel -Message "DRY RUN: would create assigned group '$DisplayName'"
        return New-PlannedGroupObject -DisplayName $DisplayName
    }

    try {
        if ($Mode -eq "Dynamic") {
            $group = Invoke-WithRetry -Tenant $TenantLabel -Operation "Create dynamic group" -Script {
                New-MgGroup -DisplayName $DisplayName -Description $Description -MailEnabled:$false -MailNickname $mailNickname -SecurityEnabled:$true -GroupTypes @($script:DynamicGroupType) -MembershipRule $script:DynamicMembershipRule -MembershipRuleProcessingState "On" -ErrorAction Stop
            }
        }
        else {
            $group = Invoke-WithRetry -Tenant $TenantLabel -Operation "Create assigned group" -Script {
                New-MgGroup -DisplayName $DisplayName -Description $Description -MailEnabled:$false -MailNickname $mailNickname -SecurityEnabled:$true -ErrorAction Stop
            }
        }

        Write-Log -Tenant $TenantLabel -Message "Created $($Mode.ToLowerInvariant()) group '$($group.DisplayName)' [$($group.Id)]"
        return $group
    }
    catch {
        if ($_.Exception.Message -match "(?i)mailnickname|already exists|objectconflict|another object with the same value") {
            Write-Log -Level "WARN" -Tenant $TenantLabel -Message "Group create reported mailNickname conflict for '$mailNickname'; attempting to locate existing group."
            $byNickname = @(Find-ManagedGroupByMailNickname -MailNickname $mailNickname -TenantLabel $TenantLabel)
            if ($byNickname.Count -ge 1) {
                $group = $byNickname[0]
                Write-Log -Tenant $TenantLabel -Message "Using existing group '$($group.DisplayName)' [$($group.Id)] found by mailNickname."
                return $group
            }
        }

        throw
    }
}

function Update-DynamicGroupSettings {
    param([Parameter(Mandatory = $true)]$Group, [string]$TenantLabel)

    $patch = @{}
    if ($Group.MembershipRule -ne $script:DynamicMembershipRule) {
        $patch["MembershipRule"] = $script:DynamicMembershipRule
    }
    if ($Group.MembershipRuleProcessingState -ne "On") {
        $patch["MembershipRuleProcessingState"] = "On"
    }
    if ($patch.Count -eq 0) {
        return $Group
    }

    if ($DryRun) {
        Write-Log -Tenant $TenantLabel -Message "DRY RUN: would update dynamic group settings for '$($Group.DisplayName)' [$($Group.Id)]"
        return [pscustomobject]@{
            Id                            = $Group.Id
            DisplayName                   = $Group.DisplayName
            GroupTypes                    = @($Group.GroupTypes)
            MembershipRule                = $script:DynamicMembershipRule
            MembershipRuleProcessingState = "On"
            SecurityEnabled               = $Group.SecurityEnabled
            MailEnabled                   = $Group.MailEnabled
            MailNickname                  = $Group.MailNickname
        }
    }

    Invoke-WithRetry -Tenant $TenantLabel -Operation "Update dynamic group settings" -Script {
        Update-MgGroup -GroupId $Group.Id @patch -ErrorAction Stop
    } | Out-Null

    Write-Log -Tenant $TenantLabel -Message "Updated dynamic membership settings for '$($Group.DisplayName)' [$($Group.Id)]"
    $updated = Get-ManagedGroupById -GroupId $Group.Id -TenantLabel $TenantLabel
    return Set-ManagedGroupDisplayNameIfStale -Group $updated -ExpectedDisplayName ([string]$Group.DisplayName) -TenantLabel $TenantLabel -Reason "the dynamic settings update"
}

function Convert-GroupToDynamic {
    param([Parameter(Mandatory = $true)]$Group, [string]$TenantLabel)

    $typesToApply = @(Get-GroupTypesArray -Group $Group)
    if ($typesToApply -notcontains $script:DynamicGroupType) {
        $typesToApply = @($typesToApply + $script:DynamicGroupType)
    }

    if ($DryRun) {
        Write-Log -Tenant $TenantLabel -Message "DRY RUN: would convert assigned group '$($Group.DisplayName)' [$($Group.Id)] to dynamic membership"
        return [pscustomobject]@{
            Id                            = $Group.Id
            DisplayName                   = $Group.DisplayName
            GroupTypes                    = $typesToApply
            MembershipRule                = $script:DynamicMembershipRule
            MembershipRuleProcessingState = "On"
            SecurityEnabled               = $Group.SecurityEnabled
            MailEnabled                   = $Group.MailEnabled
            MailNickname                  = $Group.MailNickname
        }
    }

    Invoke-WithRetry -Tenant $TenantLabel -Operation "Convert group to dynamic" -Script {
        Update-MgGroup -GroupId $Group.Id -GroupTypes $typesToApply -MembershipRuleProcessingState "On" -MembershipRule $script:DynamicMembershipRule -ErrorAction Stop
    } | Out-Null

    Write-Log -Tenant $TenantLabel -Message "Converted group '$($Group.DisplayName)' [$($Group.Id)] to dynamic membership"
    $updated = Get-ManagedGroupById -GroupId $Group.Id -TenantLabel $TenantLabel
    return Set-ManagedGroupDisplayNameIfStale -Group $updated -ExpectedDisplayName ([string]$Group.DisplayName) -TenantLabel $TenantLabel -Reason "the dynamic conversion"
}

function Convert-GroupToAssigned {
    param([Parameter(Mandatory = $true)]$Group, [string]$TenantLabel)

    $typesToApply = @(
        @(Get-GroupTypesArray -Group $Group) |
        Where-Object { $_ -ne $script:DynamicGroupType }
    )

    Invoke-WithRetry -Tenant $TenantLabel -Operation "Convert group to assigned" -Script {
        Update-MgGroup -GroupId $Group.Id -GroupTypes $typesToApply -MembershipRuleProcessingState "Paused" -ErrorAction Stop
    } | Out-Null

    Write-Log -Tenant $TenantLabel -Message "Converted group '$($Group.DisplayName)' [$($Group.Id)] to assigned membership"
    $updated = Get-ManagedGroupById -GroupId $Group.Id -TenantLabel $TenantLabel
    return Set-ManagedGroupDisplayNameIfStale -Group $updated -ExpectedDisplayName ([string]$Group.DisplayName) -TenantLabel $TenantLabel -Reason "the assigned fallback conversion"
}

function Test-UserHasEnabledAssignedPlan {
    param([Parameter(Mandatory = $true)]$User)

    $assignedPlans = @()
    if ($User.PSObject.Properties.Name -contains "AssignedPlans" -and $null -ne $User.AssignedPlans) {
        $assignedPlans = @($User.AssignedPlans)
    }
    elseif ($User.PSObject.Properties.Name -contains "AdditionalProperties" -and $null -ne $User.AdditionalProperties) {
        if ($User.AdditionalProperties.ContainsKey("assignedPlans")) {
            $assignedPlans = @($User.AdditionalProperties["assignedPlans"])
        }
    }

    foreach ($assignedPlan in $assignedPlans) {
        if ($null -eq $assignedPlan) {
            continue
        }

        $capabilityStatus = [string](Get-GraphMemberValue -Object $assignedPlan -Name "CapabilityStatus")
        if ([string]::IsNullOrWhiteSpace($capabilityStatus)) {
            $capabilityStatus = [string](Get-GraphMemberValue -Object $assignedPlan -Name "capabilityStatus")
        }

        if ($capabilityStatus -match "^(?i)enabled$") {
            return $true
        }
    }

    return $false
}

function Test-UserMatchesIntegrationRule {
    param([Parameter(Mandatory = $true)]$User)

    if ([string]::IsNullOrWhiteSpace([string]$User.Id)) {
        return $false
    }

    $userType = [string]$User.UserType
    if ([string]::IsNullOrWhiteSpace($userType) -and $User.PSObject.Properties.Name -contains "AdditionalProperties" -and $null -ne $User.AdditionalProperties) {
        $userType = [string]$User.AdditionalProperties["userType"]
    }
    if ($userType -notmatch "^(?i)member$") {
        return $false
    }

    $accountEnabled = $null
    if ($User.PSObject.Properties.Name -contains "AccountEnabled") {
        $accountEnabled = [bool]$User.AccountEnabled
    }
    elseif ($User.PSObject.Properties.Name -contains "AdditionalProperties" -and $null -ne $User.AdditionalProperties -and $User.AdditionalProperties.ContainsKey("accountEnabled")) {
        $accountEnabled = [bool]$User.AdditionalProperties["accountEnabled"]
    }
    if ($accountEnabled -ne $true) {
        return $false
    }

    $department = [string]$User.Department
    if ([string]::IsNullOrWhiteSpace($department) -and $User.PSObject.Properties.Name -contains "AdditionalProperties" -and $null -ne $User.AdditionalProperties) {
        $department = [string]$User.AdditionalProperties["department"]
    }
    if (-not [string]::IsNullOrWhiteSpace($script:ExemptDepartmentValue) -and -not [string]::IsNullOrWhiteSpace($department) -and $department.Trim() -ieq $script:ExemptDepartmentValue) {
        return $false
    }

    return (Test-UserHasEnabledAssignedPlan -User $User)
}

function Get-DesiredIntegrationUsers {
    param([string]$TenantLabel)

    $desiredUsersById = @{}
    $users = @(Invoke-WithRetry -Tenant $TenantLabel -Operation "Get users for rule evaluation" -Script {
            Get-MgUser -All -Property "id,displayName,userPrincipalName,accountEnabled,userType,department,assignedPlans" -ErrorAction Stop
        })

    foreach ($user in $users) {
        if (Test-UserMatchesIntegrationRule -User $user) {
            $desiredUsersById[[string]$user.Id] = $user
        }
    }

    return $desiredUsersById
}

function Get-GroupMemberSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Group,
        [string]$TenantLabel,
        [switch]$RetryOnNotFound
    )

    if ([string]::IsNullOrWhiteSpace([string]$Group.Id) -or $Group.Id -eq "<dry-run-group>") {
        return [pscustomobject]@{
            AllMembers      = @()
            UserMembersById = @{}
            UserCount       = 0
            NonUserMembers  = @()
        }
    }

    $members = @(Invoke-WithRetry -Tenant $TenantLabel -Operation "Get group members" -RetryOnNotFound:$RetryOnNotFound -Script {
            Get-MgGroupMember -GroupId $Group.Id -All -ErrorAction Stop
        })

    $userMembersById = @{}
    $nonUserMembers = [System.Collections.Generic.List[object]]::new()

    foreach ($member in $members) {
        $memberId = Get-DirectoryObjectId -Object $member
        if ([string]::IsNullOrWhiteSpace([string]$memberId)) {
            continue
        }

        if (Test-IsUserDirectoryObject -Object $member) {
            $userMembersById[$memberId] = $member
        }
        else {
            $nonUserMembers.Add($member) | Out-Null
        }
    }

    return [pscustomobject]@{
        AllMembers      = @($members)
        UserMembersById = $userMembersById
        UserCount       = $userMembersById.Count
        NonUserMembers  = @($nonUserMembers.ToArray())
    }
}

function Format-DirectoryObjectPreview {
    param([Parameter(Mandatory = $true)][object[]]$Objects, [int]$MaxItems = 5)

    $items = @($Objects | Select-Object -First $MaxItems | ForEach-Object {
            "{0} [{1}]" -f (Get-DirectoryObjectDisplay -Object $_), (Get-DirectoryObjectId -Object $_)
        })

    if ($Objects.Count -gt $MaxItems) {
        $items += "... +$($Objects.Count - $MaxItems) more"
    }

    return ($items -join "; ")
}

function Sync-AssignedGroupMembers {
    param(
        [Parameter(Mandatory = $true)]$Group,
        [Parameter(Mandatory = $true)][hashtable]$DesiredUsersById,
        [string]$TenantLabel,
        $InitialSnapshot,
        [switch]$GroupJustCreated
    )

    $snapshot = if ($null -ne $InitialSnapshot) { $InitialSnapshot } else { Get-GroupMemberSnapshot -Group $Group -TenantLabel $TenantLabel -RetryOnNotFound:$GroupJustCreated }
    if (@($snapshot.NonUserMembers).Count -gt 0) {
        $preview = Format-DirectoryObjectPreview -Objects $snapshot.NonUserMembers
        throw "Manual review required: assigned group '$($Group.DisplayName)' [$($Group.Id)] has direct non-user members. Preview: $preview"
    }

    $added = 0
    $removed = 0
    $warningCount = 0
    $currentUserMembersById = $snapshot.UserMembersById

    $idsToAdd = @($DesiredUsersById.Keys | Where-Object { -not $currentUserMembersById.ContainsKey($_) } | Sort-Object)
    foreach ($id in $idsToAdd) {
        $display = Get-DirectoryObjectDisplay -Object $DesiredUsersById[$id]
        if ($DryRun) {
            Write-Log -Tenant $TenantLabel -Message "DRY RUN: would add '$display' [$id] to assigned fallback group"
            continue
        }

        try {
            Invoke-WithRetry -Tenant $TenantLabel -Operation "Add group member" -RetryOnNotFound:$GroupJustCreated -Script {
                New-MgGroupMemberByRef -GroupId $Group.Id -BodyParameter @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$id" } -ErrorAction Stop
            } | Out-Null
            Write-Log -Tenant $TenantLabel -Message "Added '$display' [$id] to assigned fallback group"
            $added++
        }
        catch {
            if ($_.Exception.Message -match "(?i)added object references already exist|already exist") {
                Write-Log -Level "WARN" -Tenant $TenantLabel -Message "Member '$display' [$id] already exists in group."
                $warningCount++
            }
            else {
                throw
            }
        }
    }

    $idsToRemove = @($currentUserMembersById.Keys | Where-Object { -not $DesiredUsersById.ContainsKey($_) } | Sort-Object)
    foreach ($id in $idsToRemove) {
        $display = Get-DirectoryObjectDisplay -Object $currentUserMembersById[$id]
        if ($DryRun) {
            Write-Log -Tenant $TenantLabel -Message "DRY RUN: would remove '$display' [$id] from assigned fallback group"
            continue
        }

        try {
            Invoke-WithRetry -Tenant $TenantLabel -Operation "Remove group member" -RetryOnNotFound:$GroupJustCreated -Script {
                Remove-MgGroupMemberByRef -GroupId $Group.Id -DirectoryObjectId $id -ErrorAction Stop
            } | Out-Null
            Write-Log -Tenant $TenantLabel -Message "Removed '$display' [$id] from assigned fallback group"
            $removed++
        }
        catch {
            if ($_.Exception.Message -match "(?i)does not exist|resource.*not found|could not find") {
                Write-Log -Level "WARN" -Tenant $TenantLabel -Message "Member '$display' [$id] is already absent from the group."
                $warningCount++
            }
            else {
                throw
            }
        }
    }

    return [pscustomobject]@{
        Snapshot     = $snapshot
        Added        = $added
        Removed      = $removed
        WarningCount = $warningCount
    }
}

function Standardize-TenantIntegrationGroup {
    param([string]$TargetTenantId)

    $summary = [ordered]@{
        TenantId       = $TargetTenantId
        TenantName     = $TargetTenantId
        Status         = "Success"
        GroupId        = $null
        FinalGroupName = $null
        Mode           = $null
        Action         = $null
        DesiredUsers   = 0
        CurrentUsers   = 0
        Added          = 0
        Removed        = 0
        WarningCount   = 0
        Error          = $null
    }

    $tenantLogLabel = $summary.TenantName
    $cachedTenantName = Get-TenantDisplayNameFromCache -TenantId $TargetTenantId
    if (-not [string]::IsNullOrWhiteSpace($cachedTenantName)) {
        $summary.TenantName = $cachedTenantName
        $tenantLogLabel = $cachedTenantName
    }

    $actions = [System.Collections.Generic.List[string]]::new()
    $selectedGroup = $null
    $currentSnapshot = $null
    $groupJustCreated = $false

    try {
        Write-Log -Tenant $tenantLogLabel -Message "Connecting to Microsoft Graph"
        try {
            Connect-MgGraph -ClientId $ClientId -TenantId $TargetTenantId -CertificateThumbprint $Thumbprint -NoWelcome -ErrorAction Stop | Out-Null
        }
        catch {
            throw (Get-FormattedGraphAuthError -ErrorObject $_ -Operation "Tenant standardization Graph connect" -TenantId $TargetTenantId)
        }

        Set-GraphProfileIfSupported -TenantId $TargetTenantId -TenantLabel $tenantLogLabel
        $summary.TenantName = Get-ConnectedTenantDisplayName -TenantId $TargetTenantId -FallbackName $summary.TenantName
        $tenantLogLabel = $summary.TenantName

        $ctx = Get-MgContext -ErrorAction Stop
        Write-Log -Tenant $tenantLogLabel -Message "Connected. Tenant: $($summary.TenantName) AppId: $($ctx.ClientId) AuthType: $($ctx.AuthType)"

        $desiredUsersById = Get-DesiredIntegrationUsers -TenantLabel $tenantLogLabel
        $summary.DesiredUsers = $desiredUsersById.Count
        Write-Log -Tenant $tenantLogLabel -Message "Desired integration users matching standard rule: $($summary.DesiredUsers)"

        $candidateGroups = @(Get-ManagedIntegrationGroupCandidates -CanonicalDisplayName $GroupDisplayName -LegacyDisplayNames $LegacyGroupDisplayName -TenantLabel $tenantLogLabel)
        if ($candidateGroups.Count -gt 1) {
            Add-UniqueAction -Actions $actions -Action "FailedManualReview"
            $preview = Format-DirectoryObjectPreview -Objects $candidateGroups
            throw "Manual review required: multiple matching integration groups found. Preview: $preview"
        }

        if ($candidateGroups.Count -eq 1) {
            $selectedGroup = $candidateGroups[0]
            Write-Log -Tenant $tenantLogLabel -Message "Using existing group '$($selectedGroup.DisplayName)' [$($selectedGroup.Id)]"
            $summary.GroupId = $selectedGroup.Id
            $summary.FinalGroupName = $selectedGroup.DisplayName

            if ($selectedGroup.DisplayName -ne $GroupDisplayName) {
                $selectedGroup = Rename-ManagedGroupToCanonical -Group $selectedGroup -DisplayName $GroupDisplayName -TenantLabel $tenantLogLabel
                Add-UniqueAction -Actions $actions -Action "Renamed"
                $summary.FinalGroupName = $selectedGroup.DisplayName
            }

            $currentSnapshot = Get-GroupMemberSnapshot -Group $selectedGroup -TenantLabel $tenantLogLabel
            $summary.CurrentUsers = $currentSnapshot.UserCount
        }
        else {
            Write-Log -Tenant $tenantLogLabel -Message "Integration group not found: $GroupDisplayName"
            $summary.FinalGroupName = $GroupDisplayName
        }

        $useAssignedFallback = $false
        $assignedFallbackNeedsCreate = $false

        if ($null -eq $selectedGroup) {
            if ($DryRun) {
                $selectedGroup = New-ManagedSecurityGroup -DisplayName $GroupDisplayName -TenantId $TargetTenantId -TenantLabel $tenantLogLabel -Description $script:DynamicGroupDescription -Mode Dynamic
                $summary.Mode = "Dynamic"
                Add-UniqueAction -Actions $actions -Action "CreatedDynamic"
            }
            else {
                try {
                    $selectedGroup = New-ManagedSecurityGroup -DisplayName $GroupDisplayName -TenantId $TargetTenantId -TenantLabel $tenantLogLabel -Description $script:DynamicGroupDescription -Mode Dynamic
                    $groupJustCreated = $true
                    $summary.Mode = "Dynamic"
                    Add-UniqueAction -Actions $actions -Action "CreatedDynamic"
                }
                catch {
                    if (Test-IsDynamicGroupLicenseConstraintError -ErrorObject $_) {
                        Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Dynamic group creation is unavailable in this tenant. Falling back to assigned group sync. Details: $($_.Exception.Message)"
                        $summary.WarningCount++
                        $useAssignedFallback = $true
                        $assignedFallbackNeedsCreate = $true
                    }
                    else {
                        throw
                    }
                }
            }
        }
        elseif (@($selectedGroup.GroupTypes) -contains $script:DynamicGroupType) {
            $summary.Mode = "Dynamic"
            $needsDynamicUpdate = ($selectedGroup.MembershipRule -ne $script:DynamicMembershipRule -or $selectedGroup.MembershipRuleProcessingState -ne "On")
            if ($needsDynamicUpdate) {
                if ($DryRun) {
                    $selectedGroup = Update-DynamicGroupSettings -Group $selectedGroup -TenantLabel $tenantLogLabel
                    Add-UniqueAction -Actions $actions -Action "UpdatedRule"
                }
                else {
                    try {
                        $selectedGroup = Update-DynamicGroupSettings -Group $selectedGroup -TenantLabel $tenantLogLabel
                        Add-UniqueAction -Actions $actions -Action "UpdatedRule"
                    }
                    catch {
                        if (Test-IsDynamicGroupLicenseConstraintError -ErrorObject $_) {
                            Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Dynamic group update is unavailable in this tenant. Falling back to assigned group sync. Details: $($_.Exception.Message)"
                            $summary.WarningCount++
                            $useAssignedFallback = $true
                        }
                        else {
                            throw
                        }
                    }
                }
            }
        }
        else {
            if (@($currentSnapshot.NonUserMembers).Count -gt 0) {
                Add-UniqueAction -Actions $actions -Action "FailedManualReview"
                $preview = Format-DirectoryObjectPreview -Objects $currentSnapshot.NonUserMembers
                throw "Manual review required: assigned group '$($selectedGroup.DisplayName)' [$($selectedGroup.Id)] has direct non-user members. Preview: $preview"
            }

            if ($DryRun) {
                $selectedGroup = Convert-GroupToDynamic -Group $selectedGroup -TenantLabel $tenantLogLabel
                $summary.Mode = "Dynamic"
                Add-UniqueAction -Actions $actions -Action "ConvertedToDynamic"
            }
            else {
                try {
                    $selectedGroup = Convert-GroupToDynamic -Group $selectedGroup -TenantLabel $tenantLogLabel
                    $summary.Mode = "Dynamic"
                    Add-UniqueAction -Actions $actions -Action "ConvertedToDynamic"
                }
                catch {
                    if (Test-IsDynamicGroupLicenseConstraintError -ErrorObject $_) {
                        Write-Log -Level "WARN" -Tenant $tenantLogLabel -Message "Dynamic membership is unavailable in this tenant. Keeping the existing group assigned and syncing members instead. Details: $($_.Exception.Message)"
                        $summary.WarningCount++
                        $useAssignedFallback = $true
                    }
                    else {
                        throw
                    }
                }
            }
        }

        if ($useAssignedFallback) {
            if ($assignedFallbackNeedsCreate) {
                $selectedGroup = New-ManagedSecurityGroup -DisplayName $GroupDisplayName -TenantId $TargetTenantId -TenantLabel $tenantLogLabel -Description $script:AssignedFallbackDescription -Mode Assigned
                $groupJustCreated = $true
                Add-UniqueAction -Actions $actions -Action "CreatedAssignedFallback"
            }
            elseif (@($selectedGroup.GroupTypes) -contains $script:DynamicGroupType) {
                $selectedGroup = Convert-GroupToAssigned -Group $selectedGroup -TenantLabel $tenantLogLabel
            }

            $summary.Mode = "Assigned"
            $syncResult = Sync-AssignedGroupMembers -Group $selectedGroup -DesiredUsersById $desiredUsersById -TenantLabel $tenantLogLabel -InitialSnapshot $currentSnapshot -GroupJustCreated:$groupJustCreated
            if ($DryRun) {
                $summary.CurrentUsers = $syncResult.Snapshot.UserCount
            }
            else {
                $summary.CurrentUsers = $syncResult.Snapshot.UserCount + $syncResult.Added - $syncResult.Removed
            }
            $summary.Added += $syncResult.Added
            $summary.Removed += $syncResult.Removed
            $summary.WarningCount += $syncResult.WarningCount
            Add-UniqueAction -Actions $actions -Action "SyncedAssigned"
        }

        if ($null -ne $selectedGroup) {
            $summary.GroupId = $selectedGroup.Id
            $summary.FinalGroupName = $selectedGroup.DisplayName
        }
        if ($actions.Count -eq 0) {
            Add-UniqueAction -Actions $actions -Action "AlreadyCompliant"
        }

        Write-Log -Tenant $tenantLogLabel -Message "Tenant standardization complete. Mode=$($summary.Mode) Action=$($actions -join '+')"
    }
    catch {
        $summary.Status = "Failed"
        $summary.Error = Get-TenantFailureMessage -ErrorObject $_
        if ($summary.Error -match "(?i)^Manual review required:") {
            Add-UniqueAction -Actions $actions -Action "FailedManualReview"
        }
        Write-Log -Level "ERROR" -Tenant $tenantLogLabel -Message "Tenant standardization failed: $($summary.Error)"
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

    $discoveredTargets = Get-PartnerTenantTargets -DiscoveryTenantId $resolvedDiscoveryTenantId -DiscoveryMode $DiscoveryMode -IncludeMspTenant:$IncludeMspTenant
}

$targetTenants = @($discoveredTargets + $manualTargets + $extraIncludeTargets | Sort-Object -Unique)
if ($excludeTargets.Count -gt 0) {
    $targetTenants = @($targetTenants | Where-Object { $excludeTargets -notcontains $_ })
}
if ($targetTenants.Count -eq 0) {
    throw "No target tenants resolved after discovery/include/exclude processing."
}

Write-Log -Message ("Starting standardization for {0} tenant(s)." -f $targetTenants.Count)

$results = [System.Collections.Generic.List[object]]::new()
foreach ($target in $targetTenants) {
    $result = Standardize-TenantIntegrationGroup -TargetTenantId $target
    $results.Add($result) | Out-Null

    if ($StopOnError -and $result.Status -eq "Failed") {
        Write-Log -Level "WARN" -Message "Stopping early because -StopOnError was specified."
        break
    }
}

Write-Log -Message "Run summary:"
$results |
    Sort-Object TenantName |
    Format-Table TenantName, Status, Mode, Action, DesiredUsers, CurrentUsers, Added, Removed, WarningCount -AutoSize |
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
