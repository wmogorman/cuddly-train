<#
.SYNOPSIS
  Run Duo External MFA rollout across multiple tenants using a shared JSON configuration.

.DESCRIPTION
  Supports two execution modes:
  - Delegated: omit -ClientId/-Thumbprint and the core script will prompt for tenant-by-tenant sign-in.
  - App-only: provide -ClientId/-Thumbprint and the core script will connect certificate-authenticated per tenant.

  Auto-discovery is only supported in app-only mode. Discovered tenant IDs are filtered to entries present in the JSON config.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$TenantConfigPath,

  [Parameter(Mandatory=$false)]
  [switch]$AutoDiscoverTenants,

  [Parameter(Mandatory=$false)]
  [string]$DiscoveryTenantId,

  [Parameter(Mandatory=$false)]
  [ValidateSet("GDAP","GDAPAndContracts")]
  [string]$DiscoveryMode = "GDAPAndContracts",

  [Parameter(Mandatory=$false)]
  [string[]]$IncludeTenantId = @(),

  [Parameter(Mandatory=$false)]
  [string[]]$ExcludeTenantId = @(),

  [Parameter(Mandatory=$false)]
  [string]$ClientId,

  [Parameter(Mandatory=$false)]
  [string]$Thumbprint,

  [Parameter(Mandatory=$false)]
  [switch]$DryRun,

  [Parameter(Mandatory=$false)]
  [switch]$StopOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$coreScriptPath = Join-Path $scriptDir "external-mfa-rollout-core.ps1"

if (-not (Test-Path -LiteralPath $coreScriptPath)) {
  throw "Core rollout script not found: $coreScriptPath"
}

function Write-Log {
  param(
    [Parameter(Mandatory=$true)][string]$Message,
    [Parameter(Mandatory=$false)][ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
  )

  Write-Host ("[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message)
}

function Test-ObjectProperty {
  param(
    [Parameter(Mandatory=$false)]$Object,
    [Parameter(Mandatory=$true)][string]$Name
  )

  return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name)
}

function ConvertTo-Array {
  param([Parameter(Mandatory=$false)]$Value)

  if ($null -eq $Value) {
    return @()
  }

  if ($Value -is [string]) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
      return @()
    }

    return @($Value)
  }

  return @($Value)
}

function Get-NormalizedTenantIds {
  param([Parameter(Mandatory=$false)][string[]]$TenantIds)

  return @(
    ConvertTo-Array -Value $TenantIds |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { ([string]$_).Trim() } |
      Sort-Object -Unique
  )
}

function Get-ConfigTenants {
  param([Parameter(Mandatory=$true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Tenant config file not found: $Path"
  }

  $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
  $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
  $tenants = if ($parsed -is [System.Array]) {
    @($parsed)
  }
  elseif (Test-ObjectProperty -Object $parsed -Name "tenants") {
    @($parsed.tenants)
  }
  else {
    throw "Tenant config JSON must be either an array of tenant objects or an object with a 'tenants' array."
  }

  $normalized = New-Object System.Collections.Generic.List[object]
  foreach ($tenant in $tenants) {
    $tenantId = [string]$tenant.tenantId
    if ([string]::IsNullOrWhiteSpace($tenantId)) {
      throw "Each tenant config entry must include tenantId."
    }

    $normalized.Add($tenant) | Out-Null
  }

  return @($normalized.ToArray())
}

function Get-CustomerTenantIdFromRelationship {
  param($Relationship)

  if ($null -eq $Relationship) {
    return $null
  }

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

function Get-PartnerTenantTargets {
  param(
    [Parameter(Mandatory=$true)][string]$DiscoveryTenantId,
    [Parameter(Mandatory=$true)][ValidateSet("GDAP","GDAPAndContracts")][string]$DiscoveryMode,
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$Thumbprint
  )

  $targets = New-Object System.Collections.Generic.List[string]
  try {
    Connect-MgGraph `
      -ClientId $ClientId `
      -TenantId $DiscoveryTenantId `
      -CertificateThumbprint $Thumbprint `
      -NoWelcome `
      -ErrorAction Stop | Out-Null

    $selectProfile = Get-Command -Name "Select-MgProfile" -ErrorAction SilentlyContinue
    if ($selectProfile) {
      Select-MgProfile -Name "v1.0" | Out-Null
    }

    $relationships = @(Get-MgTenantRelationshipDelegatedAdminRelationship -All -ErrorAction Stop)
    foreach ($relationship in $relationships) {
      if ([string]$relationship.Status -notmatch "^(?i)active$") {
        continue
      }

      $tenantId = Get-CustomerTenantIdFromRelationship -Relationship $relationship
      if (-not [string]::IsNullOrWhiteSpace($tenantId) -and -not $targets.Contains($tenantId)) {
        $targets.Add($tenantId) | Out-Null
      }
    }

    if ($DiscoveryMode -eq "GDAPAndContracts") {
      $contracts = @(Get-MgContract -All -ErrorAction Stop)
      foreach ($contract in $contracts) {
        $tenantId = [string]$contract.CustomerId
        if (-not [string]::IsNullOrWhiteSpace($tenantId) -and -not $targets.Contains($tenantId)) {
          $targets.Add($tenantId) | Out-Null
        }
      }
    }
  }
  finally {
    try {
      Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
      # Ignore discovery disconnect errors.
    }
  }

  return @($targets | Sort-Object -Unique)
}

function Get-ConfigValue {
  param(
    [Parameter(Mandatory=$false)]$Object,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$false)]$Default = $null
  )

  if (Test-ObjectProperty -Object $Object -Name $Name) {
    return $Object.$Name
  }

  return $Default
}

$configTenants = @(Get-ConfigTenants -Path $TenantConfigPath)
$tenantById = @{}
foreach ($tenant in $configTenants) {
  $tenantById[[string]$tenant.tenantId] = $tenant
}

$appOnlyMode = (-not [string]::IsNullOrWhiteSpace($ClientId) -or -not [string]::IsNullOrWhiteSpace($Thumbprint))
if ($appOnlyMode -and ([string]::IsNullOrWhiteSpace($ClientId) -or [string]::IsNullOrWhiteSpace($Thumbprint))) {
  throw "App-only mode requires both -ClientId and -Thumbprint."
}

if ($AutoDiscoverTenants -and -not $appOnlyMode) {
  throw "AutoDiscoverTenants currently requires app-only mode with -ClientId and -Thumbprint."
}

$targetTenantIds = @()
if ($AutoDiscoverTenants) {
  if ([string]::IsNullOrWhiteSpace($DiscoveryTenantId)) {
    throw "AutoDiscoverTenants requires -DiscoveryTenantId."
  }

  Write-Log -Message "Discovering partner tenants from '$DiscoveryTenantId' using $DiscoveryMode mode."
  $targetTenantIds = @(Get-PartnerTenantTargets -DiscoveryTenantId $DiscoveryTenantId -DiscoveryMode $DiscoveryMode -ClientId $ClientId -Thumbprint $Thumbprint)
}
else {
  $targetTenantIds = @($tenantById.Keys)
}

$targetTenantIds = @($targetTenantIds + (Get-NormalizedTenantIds -TenantIds $IncludeTenantId) | Sort-Object -Unique)
$excludedTenantIds = @(Get-NormalizedTenantIds -TenantIds $ExcludeTenantId)
if ($excludedTenantIds.Count -gt 0) {
  $targetTenantIds = @($targetTenantIds | Where-Object { $excludedTenantIds -notcontains $_ })
}

$resolvedTargets = New-Object System.Collections.Generic.List[object]
foreach ($tenantId in $targetTenantIds) {
  if ($tenantById.ContainsKey($tenantId)) {
    $resolvedTargets.Add($tenantById[$tenantId]) | Out-Null
  }
  else {
    Write-Log -Level "WARN" -Message "Skipping tenant '$tenantId' because it has no matching config entry."
  }
}

if ($resolvedTargets.Count -eq 0) {
  throw "No target tenants resolved after config/discovery/include/exclude processing."
}

Write-Log -Message ("Starting rollout for {0} tenant(s)." -f $resolvedTargets.Count)

$results = New-Object System.Collections.Generic.List[object]
foreach ($tenant in $resolvedTargets) {
  $tenantId = [string]$tenant.tenantId
  $tenantDuo = Get-ConfigValue -Object $tenant -Name "duo"
  $rolloutParams = @{
    Name = [string](Get-ConfigValue -Object $tenant -Name "name" -Default $(Get-ConfigValue -Object $tenantDuo -Name "name" -Default "Cisco Duo"))
    ClientId = [string](Get-ConfigValue -Object $tenantDuo -Name "clientId")
    GuestClientId = [string](Get-ConfigValue -Object $tenantDuo -Name "guestClientId")
    DiscoveryEndpoint = [string](Get-ConfigValue -Object $tenantDuo -Name "discoveryEndpoint")
    AppId = [string](Get-ConfigValue -Object $tenantDuo -Name "appId")
    ExternalAuthConfigId = [string](Get-ConfigValue -Object $tenantDuo -Name "externalAuthConfigId")
    Stage = [string](Get-ConfigValue -Object $tenant -Name "stage" -Default "PilotGlobalAdmins")
    CaScopeMode = [string](Get-ConfigValue -Object $tenant -Name "caScopeMode" -Default "MirrorLegacy")
    LegacyPolicyNames = @(ConvertTo-Array -Value (Get-ConfigValue -Object $tenant -Name "legacyPolicyNames"))
    ExplicitAppIds = @(ConvertTo-Array -Value (Get-ConfigValue -Object $tenant -Name "explicitAppIds"))
    FinalTargetGroupIds = @(ConvertTo-Array -Value (Get-ConfigValue -Object $tenant -Name "finalTargetGroupIds"))
    BreakGlassGroupId = [string](Get-ConfigValue -Object $tenant -Name "breakGlassGroupId")
    GuestSupport = [bool](Get-ConfigValue -Object $tenant -Name "guestSupport" -Default $false)
    BulkRegisterExternalAuthMethodForWrapperGroupUsers = [bool](Get-ConfigValue -Object $tenant -Name "bulkRegisterExternalAuth" -Default $false)
    DisableMicrosoftAuthenticatorPolicy = [bool](Get-ConfigValue -Object $tenant -Name "disableMicrosoftAuthenticatorPolicy" -Default $false)
    DisableAuthenticatorRegistrationCampaign = [bool](Get-ConfigValue -Object $tenant -Name "disableAuthenticatorRegistrationCampaign" -Default $true)
    DisableSystemPreferredMfa = [bool](Get-ConfigValue -Object $tenant -Name "disableSystemPreferredMfa" -Default $true)
    RestrictCommonMicrosoftMfaMethodsForWrapperGroup = [bool](Get-ConfigValue -Object $tenant -Name "restrictCommonMicrosoftMfaMethodsForWrapperGroup" -Default $true)
    AuditEamOnlyPilotReadiness = [bool](Get-ConfigValue -Object $tenant -Name "auditEamOnlyPilotReadiness" -Default $true)
    EnforceStrictExternalOnlyTenantPrereqs = [bool](Get-ConfigValue -Object $tenant -Name "enforceStrictExternalOnlyTenantPrereqs" -Default $false)
    FailOnManualBlockers = [bool](Get-ConfigValue -Object $tenant -Name "failOnManualBlockers" -Default $true)
    PilotGroupName = [string](Get-ConfigValue -Object $tenant -Name "pilotGroupName" -Default "DMX-ExternalMFA-Pilot-GlobalAdmins")
    ExistingPilotGroupId = [string](Get-ConfigValue -Object $tenant -Name "existingPilotGroupId")
    ExistingPilotGroupName = [string](Get-ConfigValue -Object $tenant -Name "existingPilotGroupName")
    WrapperGroupName = [string](Get-ConfigValue -Object $tenant -Name "wrapperGroupName" -Default "DMX-ExternalMFA-Users")
    CaPolicyName = [string](Get-ConfigValue -Object $tenant -Name "caPolicyName" -Default "DMX - Require MFA (External MFA)")
    TargetTenantId = $tenantId
    Confirm = $false
  }

  if ($appOnlyMode) {
    $rolloutParams["GraphAppClientId"] = $ClientId
    $rolloutParams["GraphCertificateThumbprint"] = $Thumbprint
  }

  if ($DryRun) {
    $rolloutParams["WhatIf"] = $true
  }

  Write-Log -Message "Running rollout for tenant '$tenantId'."
  try {
    $result = & $coreScriptPath @rolloutParams
    if ($null -eq $result) {
      $result = [pscustomobject]@{
        Tenant = $tenantId
        Status = "Success"
        Stage = $rolloutParams.Stage
        CaScopeMode = $rolloutParams.CaScopeMode
        ManualBlockers = 0
        AutoFixable = 0
      }
    }

    $results.Add($result) | Out-Null
  }
  catch {
    $failure = [pscustomobject]@{
      Tenant = $tenantId
      Status = "Failed"
      Stage = $rolloutParams.Stage
      CaScopeMode = $rolloutParams.CaScopeMode
      ManualBlockers = $null
      AutoFixable = $null
      Error = $_.Exception.Message
    }
    $results.Add($failure) | Out-Null
    Write-Log -Level "ERROR" -Message "Tenant '$tenantId' failed: $($_.Exception.Message)"

    if ($StopOnError) {
      Write-Log -Level "WARN" -Message "Stopping early because -StopOnError was specified."
      break
    }
  }
}

Write-Log -Message "Run summary:"
$results |
  Select-Object Tenant, Status, Stage, CaScopeMode, ManualBlockers, AutoFixable |
  Format-Table -AutoSize |
  Out-String |
  ForEach-Object { $_.TrimEnd() } |
  Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
  ForEach-Object { Write-Host $_ }

$failedCount = @($results | Where-Object { $_.Status -eq "Failed" }).Count
if ($failedCount -gt 0) {
  exit 1
}

$results
