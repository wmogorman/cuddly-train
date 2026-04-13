<#
USAGE NOTES - MULTI-TENANT NOSYNC DEPARTMENT AUDIT

Purpose
- Run from your MSP app registration context and report users across target tenants whose
  Department is a NotSupport-like variant that should be corrected to NoSync.
- Script is read-only against Microsoft Entra ID. It only reads tenant/user data and writes
  a local CSV report.

What this script does per tenant
1) Connects to Microsoft Graph using app-only certificate auth.
2) Resolves the tenant display name.
3) Enumerates users with the required reporting properties.
4) Filters to member users whose normalized Department equals "notsupport".
5) Adds matching users to a detail CSV with SuggestedDepartment = "NoSync".

Targeting modes
- Manual tenant list: pass -TenantId (array).
- CSV tenant list: pass -TenantListPath with a "TenantId" column.
- Auto-discovery is enabled by default and prompts for -DiscoveryTenantId if not supplied.
  - DiscoveryMode GDAP: active GDAP relationships only.
  - DiscoveryMode GDAPAndContracts (default): active GDAP plus active customer contracts.
  - Use -IncludeMspTenant to include the MSP tenant itself in the run.
  - Use -IncludeTenantId and -ExcludeTenantId for overrides.
  - Use -AutoDiscoverTenants:$false to disable discovery and run manual/CSV targets only.

Behavior flags
- -StopOnError: stop after first tenant failure (otherwise continue and summarize).

Output
- Writes a detail CSV to -OutputPath or a timestamped default path in `artifacts/entra`.
- Prints a per-tenant summary table and a distinct raw-department count summary.
- Returns tenant summary objects on the pipeline.

CSV format example
TenantId
9f50b569-9e79-47a5-bbe6-f362934d55a0
4f72c046-d654-4302-a801-f2da1ff40c2b
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
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$StopOnError
)

$ErrorActionPreference = "Stop"
$script:TenantDisplayNameById = @{}
$script:TargetDepartmentNormalized = "notsupport"
$script:SuggestedDepartmentValue = "NoSync"
$script:DetailColumns = @(
    "TenantName",
    "TenantId",
    "UserId",
    "DisplayName",
    "UserPrincipalName",
    "Department",
    "NormalizedDepartment",
    "SuggestedDepartment",
    "AccountEnabled",
    "OnPremisesSyncEnabled"
)
$autoDiscoverTenantsEnabled = if ($PSBoundParameters.ContainsKey("AutoDiscoverTenants")) { [bool]$AutoDiscoverTenants } else { $true }

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path -Path $PSScriptRoot -ChildPath ("artifacts\entra\nosync-department-audit-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
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
        return "Tenant audit failed due to an unknown Graph error."
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

function Resolve-TenantTargets {
    param(
        [string[]]$TenantId,
        [string]$TenantListPath,
        [switch]$AllowEmpty
    )

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
    param(
        [switch]$RequireDiscoveryCmdlets,
        [ValidateSet("GDAP", "GDAPAndContracts")]
        [string]$DiscoveryMode
    )

    $required = @(
        "Connect-MgGraph",
        "Disconnect-MgGraph",
        "Get-MgContext",
        "Get-MgOrganization",
        "Get-MgUser"
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
            $message = $_.Exception.Message
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

        $gdapDiscoveredCount = 0
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
                    $discovered.Add($customerTenantId) | Out-Null
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

function Get-GraphPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }

    if ($Object.PSObject.Properties.Name -contains "AdditionalProperties" -and $null -ne $Object.AdditionalProperties) {
        foreach ($name in $Names) {
            if ($Object.AdditionalProperties.ContainsKey($name)) {
                return $Object.AdditionalProperties[$name]
            }

            foreach ($key in $Object.AdditionalProperties.Keys) {
                if ([string]$key -ieq $name) {
                    return $Object.AdditionalProperties[$key]
                }
            }
        }
    }

    return $null
}

function Get-GraphPropertyString {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    $value = Get-GraphPropertyValue -Object $Object -Names $Names
    if ($null -eq $value) {
        return $null
    }

    return [string]$value
}

function ConvertTo-NullableBoolean {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    switch -Regex ($text.Trim()) {
        "^(?i:true|1|yes)$" { return $true }
        "^(?i:false|0|no)$" { return $false }
        default { return [bool]$Value }
    }
}

function Get-GraphPropertyNullableBoolean {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    $value = Get-GraphPropertyValue -Object $Object -Names $Names
    return (ConvertTo-NullableBoolean -Value $value)
}

function Get-NormalizedDepartmentValue {
    param([string]$Department)

    if ([string]::IsNullOrWhiteSpace($Department)) {
        return $null
    }

    $trimmed = $Department.Trim().ToLowerInvariant()
    return ([regex]::Replace($trimmed, "[^a-z0-9]", ""))
}

function Get-TenantDepartmentMatches {
    param(
        [string]$TenantId,
        [string]$TenantLabel
    )

    $matchedRows = [System.Collections.Generic.List[object]]::new()
    $users = @(Invoke-WithRetry -Tenant $TenantLabel -Operation "Get users for department audit" -Script {
            Get-MgUser -All -Property "id,displayName,userPrincipalName,department,userType,accountEnabled,onPremisesSyncEnabled" -ErrorAction Stop
        })

    foreach ($user in $users) {
        $userType = Get-GraphPropertyString -Object $user -Names @("UserType", "userType")
        if ($userType -notmatch "^(?i)member$") {
            continue
        }

        $department = Get-GraphPropertyString -Object $user -Names @("Department", "department")
        if ([string]::IsNullOrWhiteSpace($department)) {
            continue
        }

        $normalizedDepartment = Get-NormalizedDepartmentValue -Department $department
        if ($normalizedDepartment -ne $script:TargetDepartmentNormalized) {
            continue
        }

        $matchedRows.Add([pscustomobject]@{
                TenantName            = $TenantLabel
                TenantId              = $TenantId
                UserId                = Get-GraphPropertyString -Object $user -Names @("Id", "id")
                DisplayName           = Get-GraphPropertyString -Object $user -Names @("DisplayName", "displayName")
                UserPrincipalName     = Get-GraphPropertyString -Object $user -Names @("UserPrincipalName", "userPrincipalName")
                Department            = $department
                NormalizedDepartment  = $normalizedDepartment
                SuggestedDepartment   = $script:SuggestedDepartmentValue
                AccountEnabled        = Get-GraphPropertyNullableBoolean -Object $user -Names @("AccountEnabled", "accountEnabled")
                OnPremisesSyncEnabled = Get-GraphPropertyNullableBoolean -Object $user -Names @("OnPremisesSyncEnabled", "onPremisesSyncEnabled")
            }) | Out-Null
    }

    return [pscustomobject]@{
        UsersScanned = $users.Count
        Matches      = @($matchedRows.ToArray())
    }
}

function Write-FormattedTable {
    param([Parameter(Mandatory = $true)]$InputObject)

    $InputObject |
        Out-String |
        ForEach-Object { $_.TrimEnd() } |
        ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) {
                Write-Host $_
            }
        }
}

function Write-DetailCsv {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if ($Rows.Count -gt 0) {
        $Rows |
            Sort-Object TenantName, UserPrincipalName, DisplayName |
            Select-Object $script:DetailColumns |
            Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
        return
    }

    $headerLine = '"' + ($script:DetailColumns -join '","') + '"'
    Set-Content -LiteralPath $Path -Value $headerLine -Encoding UTF8
}

function Invoke-TenantDepartmentAudit {
    param([string]$TargetTenantId)

    $summary = [ordered]@{
        TenantId            = $TargetTenantId
        TenantName          = $TargetTenantId
        Status              = "Success"
        UsersScanned        = 0
        MatchCount          = 0
        DistinctDepartments = 0
        Error               = $null
    }
    $detailRows = @()

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
            throw (Get-FormattedGraphAuthError -ErrorObject $_ -Operation "Tenant department audit Graph connect" -TenantId $TargetTenantId)
        }

        Set-GraphProfileIfSupported -TenantId $TargetTenantId -TenantLabel $tenantLogLabel
        $summary.TenantName = Get-ConnectedTenantDisplayName -TenantId $TargetTenantId -FallbackName $summary.TenantName
        $tenantLogLabel = $summary.TenantName

        $ctx = Get-MgContext -ErrorAction Stop
        Write-Log -Tenant $tenantLogLabel -Message "Connected. Tenant: $($summary.TenantName) AppId: $($ctx.ClientId) AuthType: $($ctx.AuthType)"

        $auditData = Get-TenantDepartmentMatches -TenantId $TargetTenantId -TenantLabel $tenantLogLabel
        $detailRows = @($auditData.Matches)
        $summary.UsersScanned = [int]$auditData.UsersScanned
        $summary.MatchCount = $detailRows.Count
        $summary.DistinctDepartments = @($detailRows | Select-Object -ExpandProperty Department -Unique).Count

        Write-Log -Tenant $tenantLogLabel -Message "Scanned $($summary.UsersScanned) user(s); found $($summary.MatchCount) matching member user(s)."
    }
    catch {
        $summary.Status = "Failed"
        $summary.Error = Get-TenantFailureMessage -ErrorObject $_
        Write-Log -Level "ERROR" -Tenant $tenantLogLabel -Message "Tenant audit failed: $($summary.Error)"
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

    return [pscustomobject]@{
        Summary = [pscustomobject]$summary
        Details = $detailRows
    }
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

Write-Log -Message ("Starting department audit for {0} tenant(s)." -f $targetTenants.Count)
Write-Log -Message "Detail CSV output path: $OutputPath"

$results = [System.Collections.Generic.List[object]]::new()
$detailRows = [System.Collections.Generic.List[object]]::new()

foreach ($target in $targetTenants) {
    $tenantResult = Invoke-TenantDepartmentAudit -TargetTenantId $target
    $results.Add($tenantResult.Summary) | Out-Null

    foreach ($detailRow in @($tenantResult.Details)) {
        $detailRows.Add($detailRow) | Out-Null
    }

    if ($StopOnError -and $tenantResult.Summary.Status -eq "Failed") {
        Write-Log -Level "WARN" -Message "Stopping early because -StopOnError was specified."
        break
    }
}

Write-DetailCsv -Rows @($detailRows.ToArray()) -Path $OutputPath
Write-Log -Message ("Wrote {0} matching row(s) to {1}" -f $detailRows.Count, $OutputPath)

Write-Log -Message "Tenant summary:"
Write-FormattedTable -InputObject (
    $results |
        Sort-Object TenantName |
        Format-Table TenantName, Status, UsersScanned, MatchCount, DistinctDepartments -AutoSize
)

Write-Log -Message "Department variant summary:"
if ($detailRows.Count -gt 0) {
    Write-FormattedTable -InputObject (
        $detailRows |
            Group-Object Department |
            Sort-Object Count, Name -Descending |
            Select-Object @{ Name = "Department"; Expression = { $_.Name } }, Count |
            Format-Table -AutoSize
    )
}
else {
    Write-Log -Message "No matching NotSupport-like department values were found."
}

$tenantSummaryOutput = @($results.ToArray()) | Sort-Object TenantName
$tenantSummaryOutput

$failedCount = @($tenantSummaryOutput | Where-Object { $_.Status -eq "Failed" }).Count
if ($failedCount -gt 0) {
    Write-Log -Level "ERROR" -Message "$failedCount tenant(s) failed."
    exit 1
}

Write-Log -Message "Complete."
