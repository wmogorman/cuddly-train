<#
.SYNOPSIS
  Configure External MFA rollout (Duo) in Entra ID:
   - Complete UCP migration
   - Create wrapper group DMX-ExternalMFA-Users
   - Nest "DMX Pilot Group" into wrapper
   - Create External Authentication Method configuration (Graph beta)
   - Target External method to wrapper group
   - (Optional) Bulk-register External method for wrapper-group users
   - Create Conditional Access policy requiring MFA for wrapper group

.PARAMETER Name
  Display name for the External Authentication Method configuration (e.g. "Cisco Duo - External MFA")

.PARAMETER ClientId
  OAuth clientId for the external auth method config (from provider)

.PARAMETER DiscoveryEndpoint
  OIDC discovery endpoint URL for the external provider (e.g. https://.../.well-known/openid-configuration)

.PARAMETER AppId
  Application (resource) AppId / identifier required by the external auth method configuration

.PARAMETER DisableMicrosoftAuthenticatorPolicy
  Disable the Microsoft Authenticator authentication method policy (best-effort) so users aren't offered Authenticator for MFA.

.PARAMETER DisableAuthenticatorRegistrationCampaign
  Disable the Authenticator registration campaign (best-effort) so users aren't prompted to register Microsoft Authenticator.

.PARAMETER DisableSystemPreferredMfa
  Disable system-preferred MFA (best-effort) so Entra doesn't steer users to Microsoft-preferred MFA methods.

.PARAMETER OffboardToMicrosoftPreferred
  Reverse the Duo rollout (best-effort): remove the Duo Conditional Access policy, disable the External Authentication Method configuration, and restore Microsoft-preferred MFA settings.

.NOTES
  Requires Microsoft.Graph PowerShell SDK.
  Uses Graph beta endpoints for External Authentication Methods + migration state in many tenants.
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
param(
  # External Authentication Method display name (Duo config name in Entra).
  [Parameter(Mandatory=$true)]
  [string]$Name,

  # Duo / external provider OIDC client identifier (rollout mode only).
  [Parameter(Mandatory=$false)]
  [string]$ClientId,

  # Duo / external provider OIDC discovery document URL (rollout mode only).
  [Parameter(Mandatory=$false)]
  [string]$DiscoveryEndpoint,

  # Provider-specific app/resource identifier expected by Entra EAM config (rollout mode only).
  [Parameter(Mandatory=$false)]
  [string]$AppId,

  [Parameter(Mandatory=$false)]
  [string]$PilotGroupName = "DMX Pilot Group",

  [Parameter(Mandatory=$false)]
  [string]$WrapperGroupName = "DMX-ExternalMFA-Users",

  [Parameter(Mandatory=$false)]
  [string]$CaPolicyName = "DMX - Require MFA (External MFA)",

  [Parameter(Mandatory=$false)]
  [bool]$DisableMicrosoftAuthenticatorPolicy = $true,

  [Parameter(Mandatory=$false)]
  [bool]$DisableAuthenticatorRegistrationCampaign = $true,

  [Parameter(Mandatory=$false)]
  [bool]$DisableSystemPreferredMfa = $true

  ,
  # Exclude the wrapper group from common Microsoft MFA methods (SMS/voice/Auth app/OATH)
  # so Conditional Access "require MFA" resolves to the external method for pilot users.
  [Parameter(Mandatory=$false)]
  [bool]$RestrictCommonMicrosoftMfaMethodsForWrapperGroup = $true,

  # Authentication method configuration IDs to exclude the wrapper group from.
  # Keep this focused on common MFA methods; leave break-glass/onboarding methods like TAP alone.
  [Parameter(Mandatory=$false)]
  [string[]]$WrapperGroupExcludedMethodIds = @(
    "microsoftAuthenticator",
    "sms",
    "voice",
    "softwareOath",
    "hardwareOath"
  ),

  # Optional: bulk-register the external auth method for transitive user members of the wrapper group.
  # This adds the per-user externalAuthenticationMethod registration (idempotent) but does not remove other registrations.
  [Parameter(Mandatory=$false)]
  [bool]$BulkRegisterExternalAuthMethodForWrapperGroupUsers = $false,

  # Optional: skip disabled accounts during bulk registration (recommended).
  [Parameter(Mandatory=$false)]
  [bool]$BulkRegisterSkipDisabledUsers = $true,

  # Optional: include guest accounts during bulk registration. Defaults to false to avoid noisy failures in mixed/guest-heavy tenants.
  [Parameter(Mandatory=$false)]
  [bool]$BulkRegisterIncludeGuestUsers = $false

  ,
  [Parameter(Mandatory=$false)]
  [switch]$OffboardToMicrosoftPreferred
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Consistent high-visibility console output for major stages.
function Write-Step($msg) {
  Write-Host "==> $msg" -ForegroundColor Cyan
}

# Placeholder object used during -WhatIf so later logic can continue without null-reference failures.
function New-PlannedGroupObject {
  param([Parameter(Mandatory=$true)][string]$DisplayName)
  return [pscustomobject]@{
    Id = $null
    DisplayName = $DisplayName
    IsPlanned = $true
  }
}

function Ensure-Module {
  param([string]$ModuleName)
  if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
    throw "Missing module '$ModuleName'. Install with: Install-Module $ModuleName -Scope CurrentUser"
  }
}

# Flattens nested exception chains so warnings include the full Graph error context.
function Get-ExceptionMessageText {
  param([Parameter(Mandatory=$true)]$ErrorObject)

  $exception = if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
    $ErrorObject.Exception
  }
  elseif ($ErrorObject -is [System.Exception]) {
    $ErrorObject
  }
  else {
    return [string]$ErrorObject
  }

  $messages = New-Object System.Collections.Generic.List[string]
  while ($null -ne $exception) {
    if (-not [string]::IsNullOrWhiteSpace($exception.Message)) {
      $messages.Add($exception.Message) | Out-Null
    }
    $exception = $exception.InnerException
  }

  return ($messages -join " | ")
}

# Heuristic only: Graph error text varies by tenant/API version.
# This helps print actionable guidance when migration completion is blocked by legacy SSPR config.
function Test-LooksLikeSsprMigrationBlocker {
  param([Parameter(Mandatory=$true)][string]$MessageText)

  if ([string]::IsNullOrWhiteSpace($MessageText)) {
    return $false
  }

  return (
    $MessageText -match "(?i)\bsspr\b" -or
    $MessageText -match "(?i)self[- ]service password reset" -or
    $MessageText -match "(?i)password reset" -or
    $MessageText -match "(?i)authentication methods.*migration" -or
    $MessageText -match "(?i)legacy.*authentication method"
  )
}

# Human-friendly remediation steps for the common "migration blocked by legacy SSPR settings" scenario.
function Write-SsprMigrationBlockerGuidance {
  param([Parameter(Mandatory=$true)][string]$ErrorText)

  Write-Host "   Likely SSPR / legacy auth-method migration blocker detected." -ForegroundColor Yellow
  Write-Host "   Manual remediation (tenant-wide) to try before rerunning:" -ForegroundColor Yellow
  Write-Host "     1) Entra admin center -> Protection -> Password reset -> Authentication methods"
  Write-Host "        Review legacy SSPR method settings and temporarily disable conflicting legacy settings if needed."
  Write-Host "     2) Entra admin center -> Protection -> Password reset -> Registration"
  Write-Host "        Check legacy registration settings that may block Authentication Methods policy migration."
  Write-Host "     3) Entra admin center -> Protection -> Authentication methods -> Policies / Migration"
  Write-Host "        Confirm methods are configured in Authentication Methods policy and retry migration."
  Write-Host "     4) Rerun this script after the SSPR/legacy settings change."
  Write-Host "   Note: This script continues even when migration completion fails, but some tenants require the migration to complete for consistent behavior." -ForegroundColor Yellow
  Write-Host "   Error text (trimmed): $ErrorText" -ForegroundColor DarkYellow
}

# Escapes single quotes for OData string literals used in Graph filters.
function Escape-ODataStringLiteral {
  param([Parameter(Mandatory=$true)][string]$Value)
  return ($Value -replace "'", "''")
}

# Creates a valid/unique-ish mailNickname for security groups (Graph requires one even if mail is disabled).
function New-SafeMailNickname {
  param([Parameter(Mandatory=$true)][string]$DisplayName)

  $base = ($DisplayName -replace '[^a-zA-Z0-9]', '')
  if ([string]::IsNullOrWhiteSpace($base)) {
    $base = "group"
  }

  # mailNickname max length is 64; reserve a small suffix to avoid collisions.
  if ($base.Length -gt 56) {
    $base = $base.Substring(0, 56)
  }

  return ("{0}{1}" -f $base, ([guid]::NewGuid().ToString("N").Substring(0, 8)))
}

# Returns exactly one group by displayName, or throws on duplicates to avoid targeting the wrong object.
function Get-GroupByDisplayNameUnique {
  param([Parameter(Mandatory=$true)][string]$DisplayName)

  $escapedName = Escape-ODataStringLiteral -Value $DisplayName
  $matches = @(Get-MgGroup -Filter "displayName eq '$escapedName'" -ConsistencyLevel eventual -All)

  if ($matches.Count -gt 1) {
    $ids = ($matches | ForEach-Object { $_.Id }) -join ", "
    throw "Multiple groups found with displayName '$DisplayName'. Resolve duplicates first. IDs: $ids"
  }

  if ($matches.Count -eq 1) {
    return $matches[0]
  }

  return $null
}

function Invoke-Beta {
  param(
    [Parameter(Mandatory=$true)][ValidateSet("GET","POST","PATCH","PUT","DELETE")]
    [string]$Method,
    [Parameter(Mandatory=$true)]
    [string]$Uri,   # may be /v1.0/... or /beta/... (helper name kept for historical reasons)
    [Parameter(Mandatory=$false)]
    $Body
  )

  $params = @{
    Method = $Method
    Uri    = $Uri
  }
  if ($null -ne $Body) {
    $params["Body"] = ($Body | ConvertTo-Json -Depth 20)
    $params["ContentType"] = "application/json"
  }

  return Invoke-MgGraphRequest @params
}

function Invoke-GraphGetAllPages {
  param([Parameter(Mandatory=$true)][string]$InitialUri)

  $results = New-Object System.Collections.Generic.List[object]
  $nextUri = $InitialUri

  while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
    $response = Invoke-Beta -Method GET -Uri $nextUri

    $valueProp = $response.PSObject.Properties["value"]
    if ($null -ne $valueProp -and $null -ne $valueProp.Value) {
      foreach ($item in @($valueProp.Value)) {
        $results.Add($item) | Out-Null
      }
    }
    else {
      $results.Add($response) | Out-Null
    }

    $nextLinkProp = $response.PSObject.Properties["@odata.nextLink"]
    if ($null -ne $nextLinkProp -and -not [string]::IsNullOrWhiteSpace([string]$nextLinkProp.Value)) {
      $nextUri = [string]$nextLinkProp.Value
    }
    else {
      $nextUri = $null
    }
  }

  return @($results)
}

function Get-GroupTransitiveUsers {
  param([Parameter(Mandatory=$true)][string]$GroupId)

  $uri = "/v1.0/groups/$GroupId/transitiveMembers/microsoft.graph.user?`$select=id,displayName,userPrincipalName,accountEnabled,userType&`$top=999"
  $users = Invoke-GraphGetAllPages -InitialUri $uri

  return @(
    foreach ($u in @($users)) {
      [pscustomobject]@{
        Id              = [string]$u.id
        DisplayName     = [string]$u.displayName
        UserPrincipalName = [string]$u.userPrincipalName
        AccountEnabled  = if ($u.PSObject.Properties.Name -contains "accountEnabled") { [bool]$u.accountEnabled } else { $true }
        UserType        = if ($u.PSObject.Properties.Name -contains "userType") { [string]$u.userType } else { $null }
      }
    }
  )
}

function Test-UserHasExternalAuthMethodRegistration {
  param(
    [Parameter(Mandatory=$true)][string]$UserId,
    [Parameter(Mandatory=$true)][string]$ConfigurationId
  )

  $existing = Invoke-GraphGetAllPages -InitialUri "/v1.0/users/$UserId/authentication/externalAuthenticationMethods"
  return @(
    $existing | Where-Object {
      $configIdProp = $_.PSObject.Properties["configurationId"]
      ($null -ne $configIdProp) -and ([string]$configIdProp.Value -eq $ConfigurationId)
    }
  ).Count -gt 0
}

function Add-UserExternalAuthMethodRegistration {
  param(
    [Parameter(Mandatory=$true)][string]$UserId,
    [Parameter(Mandatory=$true)][string]$ConfigurationId,
    [Parameter(Mandatory=$true)][string]$DisplayName
  )

  Invoke-Beta -Method POST -Uri "/v1.0/users/$UserId/authentication/externalAuthenticationMethods" -Body @{
    "@odata.type"   = "#microsoft.graph.externalAuthenticationMethod"
    configurationId = $ConfigurationId
    displayName     = $DisplayName
  } | Out-Null
}

function Invoke-BulkRegisterExternalAuthMethodForWrapperGroupUsers {
  param(
    [Parameter(Mandatory=$true)][string]$WrapperGroupId,
    [Parameter(Mandatory=$true)][string]$ConfigurationId,
    [Parameter(Mandatory=$true)][string]$ConfigurationDisplayName,
    [Parameter(Mandatory=$true)][bool]$SkipDisabledUsers,
    [Parameter(Mandatory=$true)][bool]$IncludeGuestUsers
  )

  $users = @()
  try {
    $users = @(Get-GroupTransitiveUsers -GroupId $WrapperGroupId)
  }
  catch {
    throw "Could not enumerate transitive users in wrapper group '$WrapperGroupId'. Details: $($_.Exception.Message)"
  }

  if ($users.Count -eq 0) {
    Write-Host "   No transitive user members found in wrapper group." -ForegroundColor Yellow
    return
  }

  $eligibleUsers = @()
  foreach ($u in $users) {
    if ($SkipDisabledUsers -and -not $u.AccountEnabled) {
      Write-Host "   Skipping disabled user: $($u.UserPrincipalName)" -ForegroundColor DarkYellow
      continue
    }

    if (-not $IncludeGuestUsers -and -not [string]::IsNullOrWhiteSpace($u.UserType) -and $u.UserType -eq "Guest") {
      Write-Host "   Skipping guest user: $($u.UserPrincipalName)" -ForegroundColor DarkYellow
      continue
    }

    $eligibleUsers += $u
  }

  if ($eligibleUsers.Count -eq 0) {
    Write-Host "   No eligible users to register after filters (disabled/guest)." -ForegroundColor Yellow
    return
  }

  $registeredCount = 0
  $alreadyCount = 0
  $failedCount = 0

  foreach ($u in $eligibleUsers) {
    $label = if (-not [string]::IsNullOrWhiteSpace($u.UserPrincipalName)) { $u.UserPrincipalName } else { $u.Id }
    try {
      if (Test-UserHasExternalAuthMethodRegistration -UserId $u.Id -ConfigurationId $ConfigurationId) {
        $alreadyCount++
        Write-Host "   Already registered: $label" -ForegroundColor Green
        continue
      }

      if ($PSCmdlet.ShouldProcess($label, "Add external auth method registration '$ConfigurationDisplayName'")) {
        Add-UserExternalAuthMethodRegistration -UserId $u.Id -ConfigurationId $ConfigurationId -DisplayName $ConfigurationDisplayName
        $registeredCount++
        Write-Host "   Registered external auth method for: $label" -ForegroundColor Green
      }
      else {
        Write-Host "   Planned external auth registration for: $label" -ForegroundColor Yellow
      }
    }
    catch {
      $failedCount++
      Write-Warning "Could not register external auth method for '$label'. Continuing. Details: $($_.Exception.Message)"
    }
  }

  Write-Host "   Bulk registration summary: eligible=$($eligibleUsers.Count), added=$registeredCount, alreadyPresent=$alreadyCount, failed=$failedCount" -ForegroundColor Cyan
}

function Get-AuthenticationMethodConfigurationsCollection {
  $attempts = @(
    "/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations",
    "/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations"
  )

  $errors = New-Object System.Collections.Generic.List[string]
  foreach ($uri in $attempts) {
    try {
      $resp = Invoke-Beta -Method GET -Uri $uri
      return [pscustomobject]@{
        CollectionUri = $uri
        Items         = @($resp.value)
      }
    }
    catch {
      $errors.Add(("{0} => {1}" -f $uri, $_.Exception.Message)) | Out-Null
    }
  }

  throw ("Failed to query authentication method configurations. Attempts: {0}" -f ($errors -join " || "))
}

# Adds/removes a wrapper-group exclusion on selected auth method policy configs, without deleting user registrations.
function Set-WrapperGroupExclusionOnAuthMethodConfigs {
  param(
    [Parameter(Mandatory=$true)][string]$WrapperGroupId,
    [Parameter(Mandatory=$true)][string[]]$MethodIds,
    [Parameter(Mandatory=$true)][ValidateSet("Add","Remove")][string]$Mode
  )

  if ([string]::IsNullOrWhiteSpace($WrapperGroupId)) {
    throw "WrapperGroupId is required."
  }

  $requestedIds = @($MethodIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($requestedIds.Count -eq 0) {
    Write-Host "   No authentication method IDs were specified for wrapper-group exclusions." -ForegroundColor Yellow
    return
  }

  $configCollection = Get-AuthenticationMethodConfigurationsCollection
  $configList = @($configCollection.Items)
  $configById = @{}
  foreach ($cfg in $configList) {
    $idProp = $cfg.PSObject.Properties["id"]
    if ($null -eq $idProp -or [string]::IsNullOrWhiteSpace([string]$idProp.Value)) {
      continue
    }

    $configById[[string]$idProp.Value] = $cfg
    $configById[[string]$idProp.Value.ToString().ToLowerInvariant()] = $cfg
  }

  foreach ($requestedId in $requestedIds) {
    $lookupKey = [string]$requestedId
    $config = $null
    if ($configById.ContainsKey($lookupKey)) {
      $config = $configById[$lookupKey]
    }
    elseif ($configById.ContainsKey($lookupKey.ToLowerInvariant())) {
      $config = $configById[$lookupKey.ToLowerInvariant()]
    }

    if (-not $config) {
      Write-Warning "Authentication method config '$requestedId' was not found in this tenant; skipping."
      continue
    }

    $configId = [string]$config.id
    $currentExcludeTargets = @()
    if (($config.PSObject.Properties.Name -contains "excludeTargets") -and $null -ne $config.excludeTargets) {
      $currentExcludeTargets = @($config.excludeTargets)
    }

    $groupExcluded = @(
      $currentExcludeTargets | Where-Object {
        $targetTypeProp = $_.PSObject.Properties["targetType"]
        $idProp = $_.PSObject.Properties["id"]
        ($null -ne $targetTypeProp) -and ([string]$targetTypeProp.Value -eq "group") -and
        ($null -ne $idProp) -and ([string]$idProp.Value -eq $WrapperGroupId)
      }
    ).Count -gt 0

    if ($Mode -eq "Add" -and $groupExcluded) {
      Write-Host "   Auth method '$configId' already excludes wrapper group." -ForegroundColor Green
      continue
    }
    if ($Mode -eq "Remove" -and -not $groupExcluded) {
      Write-Host "   Auth method '$configId' does not exclude wrapper group; nothing to remove." -ForegroundColor Green
      continue
    }

    $newExcludeTargets = @()
    foreach ($target in $currentExcludeTargets) {
      $targetTypeProp = $target.PSObject.Properties["targetType"]
      $idProp = $target.PSObject.Properties["id"]
      $isWrapperTarget =
        ($null -ne $targetTypeProp) -and ([string]$targetTypeProp.Value -eq "group") -and
        ($null -ne $idProp) -and ([string]$idProp.Value -eq $WrapperGroupId)

      if ($Mode -eq "Remove" -and $isWrapperTarget) {
        continue
      }

      $targetHash = @{}
      foreach ($prop in $target.PSObject.Properties) {
        $targetHash[$prop.Name] = $prop.Value
      }
      $newExcludeTargets += $targetHash
    }

    if ($Mode -eq "Add") {
      $newExcludeTargets += @{
        targetType = "group"
        id         = $WrapperGroupId
      }
    }

    $patchBody = @{
      excludeTargets = @($newExcludeTargets)
    }
    $odataTypeProp = $config.PSObject.Properties["@odata.type"]
    if ($null -ne $odataTypeProp -and -not [string]::IsNullOrWhiteSpace([string]$odataTypeProp.Value)) {
      $patchBody["@odata.type"] = [string]$odataTypeProp.Value
    }

    $verb = if ($Mode -eq "Add") { "Add wrapper-group exclusion" } else { "Remove wrapper-group exclusion" }
    $patchUri = ($configCollection.CollectionUri.TrimEnd("/") + "/$configId")
    try {
      if ($PSCmdlet.ShouldProcess("authenticationMethodConfigurations/$configId", "$verb for wrapper group '$WrapperGroupId'")) {
        Invoke-Beta -Method PATCH -Uri $patchUri -Body $patchBody | Out-Null
        $resultWord = if ($Mode -eq "Add") { "Added" } else { "Removed" }
        Write-Host "   $resultWord wrapper-group exclusion on auth method '$configId'." -ForegroundColor Green
      }
      else {
        Write-Host "   Planned $($verb.ToLowerInvariant()) on auth method '$configId'." -ForegroundColor Yellow
      }
    }
    catch {
      Write-Warning "Could not update auth method '$configId' exclusions. Continuing. Details: $($_.Exception.Message)"
    }
  }
}

# External Authentication Method endpoints/schema vary by tenant rollout and Graph version.
# This helper tries a few shapes and returns the first successful match by displayName.
function Get-ExternalAuthMethodConfigByName {
  param([Parameter(Mandatory=$true)][string]$DisplayName)

  $queryAttempts = @(
    # Preferred direct collection endpoints.
    "/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations",
    "/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations",
    # Fallback: policy GET with expanded children (some tenants reject the collection endpoint).
    "/v1.0/policies/authenticationMethodsPolicy?`$expand=authenticationMethodConfigurations",
    "/beta/policies/authenticationMethodsPolicy?`$expand=authenticationMethodConfigurations",
    # Last resort: plain policy GET (often not enough, but harmless to try).
    "/v1.0/policies/authenticationMethodsPolicy",
    "/beta/policies/authenticationMethodsPolicy"
  )

  $errors = New-Object System.Collections.Generic.List[string]

  foreach ($queryUri in $queryAttempts) {
    try {
      $response = Invoke-Beta -Method GET -Uri $queryUri

      $items = @()
      if ($queryUri -match "/authenticationMethodConfigurations$") {
        $items = @($response.value)
      }
      elseif ($null -ne $response.authenticationMethodConfigurations) {
        $items = @($response.authenticationMethodConfigurations)
      }

      $match = @(
        $items | Where-Object {
          # StrictMode-safe property access: not every auth method config object has every field.
          $displayNameProp = $_.PSObject.Properties["displayName"]
          $odataTypeProp = $_.PSObject.Properties["@odata.type"]
          $hasExternalShape =
            ($_.PSObject.Properties.Name -contains "openIdConnectSetting") -or
            ($_.PSObject.Properties.Name -contains "appId") -or
            ($null -ne $odataTypeProp -and [string]$odataTypeProp.Value -match "externalAuthenticationMethod")

          ($null -ne $displayNameProp) -and ([string]$displayNameProp.Value -eq $DisplayName) -and $hasExternalShape
        }
      ) | Select-Object -First 1

      return [pscustomobject]@{
        Item     = $match
        QueryUri = $queryUri
      }
    }
    catch {
      $errors.Add(("{0} => {1}" -f $queryUri, $_.Exception.Message)) | Out-Null
    }
  }

  throw ("Failed to query external authentication method configurations. Attempts: {0}" -f ($errors -join " || "))
}

# --- Prereqs ---
Ensure-Module -ModuleName "Microsoft.Graph"

Write-Step "Connecting to Microsoft Graph..."
$scopes = @(
  "Policy.ReadWrite.AuthenticationMethod",
  "Policy.ReadWrite.ConditionalAccess",
  "Group.ReadWrite.All",
  "Directory.ReadWrite.All" # helps with group nesting + lookups in some tenants
)

if ($BulkRegisterExternalAuthMethodForWrapperGroupUsers) {
  # Needed to create/list externalAuthenticationMethods on users.
  $scopes += "UserAuthMethod-External.ReadWrite.All"
}

Connect-MgGraph -Scopes $scopes | Out-Null
if (Get-Command -Name "Select-MgProfile" -ErrorAction SilentlyContinue) {
  # Older Graph SDKs require profile selection for beta cmdlets; v2+ may not expose this command.
  Select-MgProfile -Name "beta" | Out-Null
}
else {
  Write-Host "   Select-MgProfile not available (Microsoft.Graph SDK v2+). Continuing; beta calls use explicit /beta URIs." -ForegroundColor Yellow
}

# Single script supports two modes:
# - Rollout (default): create/update Duo EAM + CA + hardening
# - Offboarding: disable Duo EAM, remove CA, restore Microsoft-preferred settings
$isOffboarding = [bool]$OffboardToMicrosoftPreferred
if ($isOffboarding) {
  Write-Step "Offboarding mode enabled: removing Duo CA and restoring Microsoft-preferred MFA settings (best-effort)."
}
else {
  # Only require Duo/EAM creation inputs when we are rolling forward.
  foreach ($requiredParamName in @("ClientId","DiscoveryEndpoint","AppId")) {
    $value = Get-Variable -Name $requiredParamName -ValueOnly
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
      throw "Parameter -$requiredParamName is required unless -OffboardToMicrosoftPreferred is specified."
    }
  }
}

# --- 1) Complete Authentication Methods migration (UCP) ---
# This is tenant-dependent; in some tenants this property is writable via beta.
if (-not $isOffboarding) {
  Write-Step "Setting Authentication Methods policy migration state to 'migrationComplete' (best-effort)..."
  try {
    # Try PATCH to authenticationMethodsPolicy (beta)
    if ($PSCmdlet.ShouldProcess("policies/authenticationMethodsPolicy", "Set policyMigrationState to migrationComplete")) {
      Invoke-Beta -Method PATCH -Uri "/beta/policies/authenticationMethodsPolicy" -Body @{
        policyMigrationState = "migrationComplete"
      } | Out-Null
      Write-Host "   Migration state PATCH submitted." -ForegroundColor Green
    }
    else {
      Write-Host "   Planned migration state PATCH." -ForegroundColor Yellow
    }
  }
  catch {
    $migrationErrorText = Get-ExceptionMessageText -ErrorObject $_
    Write-Warning "Could not set policyMigrationState. This may already be complete, or your tenant doesn't allow this via Graph. Details: $migrationErrorText"
    if (Test-LooksLikeSsprMigrationBlocker -MessageText $migrationErrorText) {
      Write-SsprMigrationBlockerGuidance -ErrorText $migrationErrorText
    }
    else {
      Write-Host "   If the error references SSPR / self-service password reset, review legacy SSPR settings and Authentication Methods migration settings before rerunning." -ForegroundColor Yellow
    }
  }
}
else {
  Write-Host "==> Skipping UCP migration state change in offboarding mode." -ForegroundColor Cyan
}

# --- 2) Ensure wrapper group exists ---
if (-not $isOffboarding) {
  Write-Step "Ensuring wrapper group '$WrapperGroupName' exists..."
  $wrapper = Get-GroupByDisplayNameUnique -DisplayName $WrapperGroupName
  if (-not $wrapper) {
    if ($PSCmdlet.ShouldProcess($WrapperGroupName, "Create security group")) {
      $wrapper = New-MgGroup -DisplayName $WrapperGroupName `
        -MailEnabled:$false `
        -MailNickname (New-SafeMailNickname -DisplayName $WrapperGroupName) `
        -SecurityEnabled:$true
      Write-Host "   Created group: $($wrapper.Id)" -ForegroundColor Green
    }
    else {
      $wrapper = New-PlannedGroupObject -DisplayName $WrapperGroupName
      Write-Host "   Planned group creation." -ForegroundColor Yellow
    }
  } else {
    Write-Host "   Found group: $($wrapper.Id)" -ForegroundColor Green
  }

  # --- 3) Ensure Pilot group exists and nest it ---
  Write-Step "Ensuring pilot group '$PilotGroupName' exists..."
  $pilot = Get-GroupByDisplayNameUnique -DisplayName $PilotGroupName
  if (-not $pilot) {
    if ($PSCmdlet.ShouldProcess($PilotGroupName, "Create security group")) {
      $pilot = New-MgGroup -DisplayName $PilotGroupName `
        -MailEnabled:$false `
        -MailNickname (New-SafeMailNickname -DisplayName $PilotGroupName) `
        -SecurityEnabled:$true
      Write-Host "   Created pilot group: $($pilot.Id)" -ForegroundColor Green
    }
    else {
      $pilot = New-PlannedGroupObject -DisplayName $PilotGroupName
      Write-Host "   Planned pilot group creation." -ForegroundColor Yellow
    }
  } else {
    Write-Host "   Found pilot group: $($pilot.Id)" -ForegroundColor Green
  }

  Write-Step "Nesting pilot group into wrapper group (best-effort, idempotent)..."
  try {
    if (-not $wrapper.Id -or -not $pilot.Id) {
      Write-Host "   Skipping membership check/nesting because one or more groups are planned only (-WhatIf)." -ForegroundColor Yellow
    }
    else {
      # Group nesting is idempotent only if we check first; duplicate add attempts can error.
      $members = Get-MgGroupMember -GroupId $wrapper.Id -All
      $already = $members | Where-Object { $_.Id -eq $pilot.Id }
      if ($already) {
        Write-Host "   Pilot group is already nested." -ForegroundColor Green
      } else {
        if ($PSCmdlet.ShouldProcess("$($wrapper.DisplayName) [$($wrapper.Id)]", "Add nested group '$($pilot.DisplayName)' [$($pilot.Id)]")) {
          New-MgGroupMemberByRef -GroupId $wrapper.Id -BodyParameter @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($pilot.Id)"
          } | Out-Null
          Write-Host "   Nested pilot group into wrapper." -ForegroundColor Green
        }
        else {
          Write-Host "   Planned nesting pilot group into wrapper." -ForegroundColor Yellow
        }
      }
    }
  }
  catch {
    Write-Warning "Could not nest group (some tenants restrict group nesting / role requirements). You can instead add pilot users directly to '$WrapperGroupName'. Details: $($_.Exception.Message)"
  }
}
else {
  Write-Host "==> Skipping wrapper/pilot group creation and nesting in offboarding mode." -ForegroundColor Cyan
}

# --- 4) Create/Update External Authentication Method configuration ---
# Graph beta shape can vary by tenant/rollout. We:
#  - list existing external auth method configs
#  - match by displayName
#  - create if missing
if (-not $isOffboarding) {
  Write-Step "Ensuring External Authentication Method configuration '$Name' exists (Graph beta)..."
}
else {
  Write-Step "Ensuring External Authentication Method configuration '$Name' is disabled (Graph beta, best-effort)..."
}

$extConfig = $null
# Use v1.0 by default, but switch to beta if the successful lookup came from beta endpoints.
$extConfigCollectionUri = "/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations"
$skipExternalAuthConfigDueToWhatIfQueryFailure = $false
try {
  $extLookup = Get-ExternalAuthMethodConfigByName -DisplayName $Name
  $extConfig = $extLookup.Item
  if ($extLookup.QueryUri -match "^(/v1\.0|/beta)/policies/authenticationMethodsPolicy/authenticationMethodConfigurations$") {
    $extConfigCollectionUri = $extLookup.QueryUri
  }
  elseif ($extLookup.QueryUri -match "^/beta/") {
    # If policy lookup only worked in beta, keep writes in beta as well.
    $extConfigCollectionUri = "/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations"
  }
}
catch {
  if ($WhatIfPreference) {
    $skipExternalAuthConfigDueToWhatIfQueryFailure = $true
    Write-Warning "Could not query authenticationMethodConfigurations (beta) during -WhatIf. This preview endpoint varies by tenant and may return BadRequest when unavailable. Continuing dry-run. Details: $($_.Exception.Message)"
  }
  elseif ($isOffboarding) {
    $skipExternalAuthConfigDueToWhatIfQueryFailure = $true
    Write-Warning "Could not query authenticationMethodConfigurations (beta) while offboarding. Continuing with CA removal and Microsoft MFA restoration. Details: $($_.Exception.Message)"
  }
  else {
    throw "Failed to query authenticationMethodConfigurations (beta). Details: $($_.Exception.Message)"
  }
}

if ($skipExternalAuthConfigDueToWhatIfQueryFailure) {
  if ($WhatIfPreference) {
    Write-Host "   Planned external auth method configuration create/update (query skipped in -WhatIf)." -ForegroundColor Yellow
  }
  else {
    Write-Host "   Skipped external auth method config disable because query failed in offboarding mode." -ForegroundColor Yellow
  }
}
elseif ($isOffboarding) {
  if (-not $extConfig) {
    Write-Host "   External auth method config '$Name' not found. Nothing to disable." -ForegroundColor Green
  }
  elseif ($extConfig.state -eq "disabled") {
    Write-Host "   External auth method config '$Name' is already disabled." -ForegroundColor Green
  }
  else {
    try {
      if ($PSCmdlet.ShouldProcess($Name, "Disable External Authentication Method configuration '$($extConfig.id)'")) {
        $extConfigPatchUri = ($extConfigCollectionUri.TrimEnd("/") + "/$($extConfig.id)")
        Invoke-Beta -Method PATCH -Uri $extConfigPatchUri -Body @{
          state = "disabled"
        } | Out-Null
        Write-Host "   Disabled external auth method config id: $($extConfig.id)" -ForegroundColor Green
      }
      else {
        Write-Host "   Planned external auth method config disable." -ForegroundColor Yellow
      }
    }
    catch {
      Write-Warning "Could not disable external auth method config. You may need to adjust fields for your tenant. Details: $($_.Exception.Message)"
    }
  }
}
elseif (-not $extConfig) {
  Write-Step "Creating External Authentication Method configuration..."
  # Prefer current Graph schema; keep a legacy preview payload as a fallback for older tenants.
  $body = @{
    "@odata.type" = "#microsoft.graph.externalAuthenticationMethodConfiguration"
    displayName   = $Name
    state         = "enabled"
    appId         = $AppId
    openIdConnectSetting = @{
      clientId     = $ClientId
      discoveryUrl = $DiscoveryEndpoint
    }
    includeTargets = @(
      @{
        targetType = "group"
        id         = $wrapper.Id
      }
    )
  }

  # Legacy preview payload shape used in some older tenants/rollouts.
  $legacyBody = @{
    "@odata.type"     = "#microsoft.graph.externalAuthenticationMethodConfiguration"
    displayName       = $Name
    state             = "enabled"
    clientId          = $ClientId
    discoveryEndpoint = $DiscoveryEndpoint
    appId             = $AppId
    # includeTarget is common for auth method configurations
    includeTarget     = @{
      targetType = "group"
      id         = $wrapper.Id
    }
  }

  try {
    if ($PSCmdlet.ShouldProcess($Name, "Create External Authentication Method configuration")) {
      try {
        $created = Invoke-Beta -Method POST -Uri $extConfigCollectionUri -Body $body
      }
      catch {
        # If the tenant rejects the newer payload shape, retry once with the legacy format.
        Write-Warning "Primary external auth config create payload failed; trying legacy preview payload shape. Details: $($_.Exception.Message)"
        $created = Invoke-Beta -Method POST -Uri $extConfigCollectionUri -Body $legacyBody
      }

      $extConfig = $created
      Write-Host "   Created external auth method config id: $($extConfig.id)" -ForegroundColor Green
    }
    else {
      $extConfig = [pscustomobject]@{ id = $null; displayName = $Name; IsPlanned = $true }
      Write-Host "   Planned external auth method config creation." -ForegroundColor Yellow
    }
  }
  catch {
    throw @"
Failed to create external auth method configuration.
This endpoint/shape varies by tenant. The error usually tells you the exact missing/invalid fields.
Details: $($_.Exception.Message)
"@
  }
}
else {
  Write-Step "Updating External Authentication Method configuration targeting + enablement (best-effort)..."
  $extConfigPatchUri = ($extConfigCollectionUri.TrimEnd("/") + "/$($extConfig.id)")
  # Current schema patch payload (preferred).
  $patchBody = @{
    state = "enabled"
    includeTargets = @(
      @{
        targetType = "group"
        id         = $wrapper.Id
      }
    )
    openIdConnectSetting = @{
      clientId     = $ClientId
      discoveryUrl = $DiscoveryEndpoint
    }
    appId = $AppId
  }
  # Legacy preview schema patch payload fallback.
  $legacyPatchBody = @{
    state = "enabled"
    includeTarget = @{
      targetType = "group"
      id         = $wrapper.Id
    }
    clientId          = $ClientId
    discoveryEndpoint = $DiscoveryEndpoint
    appId             = $AppId
  }
  try {
    if ($PSCmdlet.ShouldProcess($Name, "Update External Authentication Method configuration '$($extConfig.id)'")) {
      try {
        Invoke-Beta -Method PATCH -Uri $extConfigPatchUri -Body $patchBody | Out-Null
      }
      catch {
        # Retry legacy patch shape for tenants still on older preview schema behavior.
        Write-Warning "Primary external auth config PATCH payload failed; trying legacy preview payload shape. Details: $($_.Exception.Message)"
        Invoke-Beta -Method PATCH -Uri $extConfigPatchUri -Body $legacyPatchBody | Out-Null
      }
      Write-Host "   Updated external auth method config id: $($extConfig.id)" -ForegroundColor Green
    }
    else {
      Write-Host "   Planned external auth method config update." -ForegroundColor Yellow
    }
  }
  catch {
    Write-Warning "Could not PATCH external auth method config. You may need to adjust fields for your tenant. Details: $($_.Exception.Message)"
  }
}

# --- 4b) Exclude wrapper group from common Microsoft MFA methods (best-effort) ---
if ($RestrictCommonMicrosoftMfaMethodsForWrapperGroup) {
  $restrictionMode = if ($isOffboarding) { "Remove" } else { "Add" }
  $restrictionVerb = if ($isOffboarding) { "Removing" } else { "Applying" }
  Write-Step "$restrictionVerb wrapper-group exclusions on common Microsoft MFA methods (best-effort)..."

  $wrapperForMethodRestrictions = $null
  if (Get-Variable -Name "wrapper" -ErrorAction SilentlyContinue) {
    $wrapperForMethodRestrictions = $wrapper
  }

  if (-not $wrapperForMethodRestrictions -or -not $wrapperForMethodRestrictions.Id) {
    try {
      $wrapperForMethodRestrictions = Get-GroupByDisplayNameUnique -DisplayName $WrapperGroupName
    }
    catch {
      Write-Warning "Could not resolve wrapper group '$WrapperGroupName' for auth method exclusions. Continuing. Details: $($_.Exception.Message)"
    }
  }

  if (-not $wrapperForMethodRestrictions) {
    if ($isOffboarding) {
      Write-Host "   Wrapper group '$WrapperGroupName' not found; skipping auth method exclusion cleanup." -ForegroundColor Yellow
    }
    else {
      Write-Warning "Wrapper group '$WrapperGroupName' not found; skipping common Microsoft MFA method restrictions."
    }
  }
  elseif (-not $wrapperForMethodRestrictions.Id) {
    Write-Host "   Skipping auth method exclusion updates because wrapper group is planned only (-WhatIf)." -ForegroundColor Yellow
  }
  else {
    try {
      Set-WrapperGroupExclusionOnAuthMethodConfigs `
        -WrapperGroupId $wrapperForMethodRestrictions.Id `
        -MethodIds $WrapperGroupExcludedMethodIds `
        -Mode $restrictionMode
    }
    catch {
      if ($WhatIfPreference) {
        Write-Warning "Could not query/update auth method exclusions during -WhatIf. Continuing dry-run. Details: $($_.Exception.Message)"
      }
      else {
        Write-Warning "Could not apply wrapper-group auth method exclusions. Continuing. Details: $($_.Exception.Message)"
      }
    }
  }
}
else {
  Write-Host "==> Skipping wrapper-group exclusions on common Microsoft MFA methods by parameter." -ForegroundColor Cyan
}

# --- 4c) Optional bulk per-user registration of the external auth method (best-effort) ---
if ($BulkRegisterExternalAuthMethodForWrapperGroupUsers) {
  if ($isOffboarding) {
    Write-Host "==> Skipping bulk external auth registration in offboarding mode." -ForegroundColor Cyan
  }
  else {
    Write-Step "Bulk-registering external auth method for eligible wrapper-group users (best-effort, idempotent)..."

    $wrapperForBulkRegistration = $null
    if (Get-Variable -Name "wrapper" -ErrorAction SilentlyContinue) {
      $wrapperForBulkRegistration = $wrapper
    }

    if (-not $wrapperForBulkRegistration -or -not $wrapperForBulkRegistration.Id) {
      try {
        $wrapperForBulkRegistration = Get-GroupByDisplayNameUnique -DisplayName $WrapperGroupName
      }
      catch {
        Write-Warning "Could not resolve wrapper group '$WrapperGroupName' for bulk registration. Continuing. Details: $($_.Exception.Message)"
      }
    }

    if (-not $wrapperForBulkRegistration) {
      Write-Warning "Wrapper group '$WrapperGroupName' not found; skipping bulk external auth registration."
    }
    elseif (-not $wrapperForBulkRegistration.Id) {
      Write-Host "   Skipping bulk registration because wrapper group is planned only (-WhatIf)." -ForegroundColor Yellow
    }
    elseif (-not $extConfig -or -not $extConfig.id) {
      if ($WhatIfPreference) {
        Write-Host "   Planned bulk external auth registration for wrapper-group users (external config is planned only in -WhatIf)." -ForegroundColor Yellow
      }
      else {
        Write-Warning "External auth method configuration ID is unavailable; skipping bulk user registration."
      }
    }
    else {
      try {
        $configDisplayName = if ($extConfig.PSObject.Properties.Name -contains "displayName" -and -not [string]::IsNullOrWhiteSpace([string]$extConfig.displayName)) {
          [string]$extConfig.displayName
        }
        else {
          $Name
        }

        Invoke-BulkRegisterExternalAuthMethodForWrapperGroupUsers `
          -WrapperGroupId $wrapperForBulkRegistration.Id `
          -ConfigurationId ([string]$extConfig.id) `
          -ConfigurationDisplayName $configDisplayName `
          -SkipDisabledUsers $BulkRegisterSkipDisabledUsers `
          -IncludeGuestUsers $BulkRegisterIncludeGuestUsers
      }
      catch {
        if ($WhatIfPreference) {
          Write-Warning "Could not bulk-register external auth method during -WhatIf. Continuing dry-run. Details: $($_.Exception.Message)"
        }
        else {
          Write-Warning "Could not bulk-register external auth method for wrapper-group users. Continuing. Details: $($_.Exception.Message)"
        }
      }
    }
  }
}
else {
  Write-Host "==> Skipping bulk external auth registration for wrapper-group users by parameter." -ForegroundColor Cyan
}

# --- 5) Create/Remove Conditional Access policy for Duo rollout ---
Write-Step "Ensuring Conditional Access policy '$CaPolicyName' exists..."
$existingCa = $null
$skipCaDueToWhatIfQueryFailure = $false
try {
  $caList = Invoke-Beta -Method GET -Uri "/beta/identity/conditionalAccess/policies"
  $existingCa = @($caList.value) | Where-Object { $_.displayName -eq $CaPolicyName } | Select-Object -First 1
}
catch {
  if ($WhatIfPreference) {
    $skipCaDueToWhatIfQueryFailure = $true
    Write-Warning "Could not query Conditional Access policies (beta) during -WhatIf. Continuing dry-run. Details: $($_.Exception.Message)"
  }
  else {
    throw "Failed to list Conditional Access policies (beta). Details: $($_.Exception.Message)"
  }
}

if ($skipCaDueToWhatIfQueryFailure) {
  Write-Host "   Planned CA policy create/update check skipped in -WhatIf due to query failure." -ForegroundColor Yellow
}
elseif ($isOffboarding) {
  if (-not $existingCa) {
    Write-Host "   CA policy not found. Nothing to remove." -ForegroundColor Green
  }
  else {
    Write-Step "Removing Conditional Access policy '$CaPolicyName'..."
    try {
      if ($PSCmdlet.ShouldProcess($CaPolicyName, "Remove Conditional Access policy '$($existingCa.id)'")) {
        Invoke-Beta -Method DELETE -Uri "/beta/identity/conditionalAccess/policies/$($existingCa.id)" | Out-Null
        Write-Host "   Removed CA policy id: $($existingCa.id)" -ForegroundColor Green
      }
      else {
        Write-Host "   Planned CA policy removal." -ForegroundColor Yellow
      }
    }
    catch {
      throw "Failed to remove CA policy. Details: $($_.Exception.Message)"
    }
  }
}
elseif (-not $existingCa) {
  Write-Step "Creating Conditional Access policy (Require MFA) targeting '$WrapperGroupName'..."
  $caBody = @{
    displayName = $CaPolicyName
    state       = "enabled"  # set to "reportOnly" if you want safer rollout
    conditions  = @{
      users = @{
        includeGroups = @($wrapper.Id)
        excludeUsers  = @() # add break-glass IDs here if desired
      }
      applications = @{
        includeApplications = @("All")
      }
      clientAppTypes = @("all")
    }
    grantControls = @{
      operator = "AND"
      builtInControls = @("mfa")
    }
    # Match the requested UI setting: periodic reauthentication every 90 days.
    sessionControls = @{
      signInFrequency = @{
        value     = 90
        type      = "days"
        isEnabled = $true
      }
    }
  }

  try {
    if ($PSCmdlet.ShouldProcess($CaPolicyName, "Create Conditional Access policy")) {
      $newCa = Invoke-Beta -Method POST -Uri "/beta/identity/conditionalAccess/policies" -Body $caBody
      Write-Host "   Created CA policy id: $($newCa.id)" -ForegroundColor Green
    }
    else {
      Write-Host "   Planned CA policy creation." -ForegroundColor Yellow
    }
  }
  catch {
    throw "Failed to create CA policy. Details: $($_.Exception.Message)"
  }
}
else {
  # Keep existing policy but normalize the sign-in frequency so reruns converge to the same result.
  Write-Host "   CA policy already exists (id: $($existingCa.id)). Ensuring session sign-in frequency = 90 days..." -ForegroundColor Green
  try {
    if ($PSCmdlet.ShouldProcess($CaPolicyName, "Update Conditional Access policy session sign-in frequency to 90 days")) {
      Invoke-Beta -Method PATCH -Uri "/beta/identity/conditionalAccess/policies/$($existingCa.id)" -Body @{
        sessionControls = @{
          signInFrequency = @{
            value     = 90
            type      = "days"
            isEnabled = $true
          }
        }
      } | Out-Null
      Write-Host "   Set CA session sign-in frequency to 90 days." -ForegroundColor Green
    }
    else {
      Write-Host "   Planned CA session sign-in frequency update to 90 days." -ForegroundColor Yellow
    }
  }
  catch {
    Write-Warning "Could not update CA session sign-in frequency. Continuing. Details: $($_.Exception.Message)"
  }
}

$desiredMsAuthState = if ($isOffboarding) { "enabled" } else { "disabled" }
$desiredRegistrationCampaignState = if ($isOffboarding) { "enabled" } else { "disabled" }
$desiredSystemPreferredMfaState = if ($isOffboarding) { "enabled" } else { "disabled" }
$uxModeLabel = if ($isOffboarding) { "Restoring Microsoft-preferred MFA UX settings" } else { "Applying MFA UX hardening for Duo rollout" }

# --- 6) MFA UX policy settings ---
# This section intentionally changes tenant-wide auth method UX settings to make Duo External MFA
# more likely/cleaner during rollout (or restores Microsoft-preferred defaults during offboarding).
Write-Step "$uxModeLabel (best-effort)..."

if ($DisableMicrosoftAuthenticatorPolicy) {
  Write-Step "Ensuring Microsoft Authenticator authentication method policy is $desiredMsAuthState..."
  try {
    $msAuthConfig = Invoke-Beta -Method GET -Uri "/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/microsoftAuthenticator"
    if ($msAuthConfig.state -eq $desiredMsAuthState) {
      Write-Host "   Microsoft Authenticator method policy is already $desiredMsAuthState." -ForegroundColor Green
    }
    else {
      $verb = if ($desiredMsAuthState -eq "disabled") { "Disable" } else { "Enable" }
      if ($PSCmdlet.ShouldProcess("microsoftAuthenticator method policy", "$verb Microsoft Authenticator authentication method policy")) {
        # Disabling Authenticator here does not delete user registrations; it disables method usage policy.
        Invoke-Beta -Method PATCH -Uri "/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/microsoftAuthenticator" -Body @{
          "@odata.type" = "#microsoft.graph.microsoftAuthenticatorAuthenticationMethodConfiguration"
          state         = $desiredMsAuthState
        } | Out-Null
        Write-Host "   Set Microsoft Authenticator method policy to $desiredMsAuthState." -ForegroundColor Green
      }
      else {
        Write-Host "   Planned Microsoft Authenticator method policy state change to $desiredMsAuthState." -ForegroundColor Yellow
      }
    }
  }
  catch {
    if ($WhatIfPreference) {
      Write-Warning "Could not query/update Microsoft Authenticator method policy during -WhatIf. Continuing dry-run. Details: $($_.Exception.Message)"
    }
    else {
      Write-Warning "Could not disable Microsoft Authenticator method policy. Continuing. Details: $($_.Exception.Message)"
    }
  }
}
else {
  Write-Host "   Skipping Microsoft Authenticator method policy change by parameter." -ForegroundColor Yellow
}

if ($DisableAuthenticatorRegistrationCampaign) {
  Write-Step "Ensuring Microsoft Authenticator registration campaign is $desiredRegistrationCampaignState..."
  try {
    $authMethodsPolicyV1 = Invoke-Beta -Method GET -Uri "/v1.0/policies/authenticationMethodsPolicy"
    # Registration campaign nudges users into Microsoft Authenticator; disabling reduces prompt churn during Duo rollout.
    $registrationCampaign = $authMethodsPolicyV1.registrationEnforcement.authenticationMethodsRegistrationCampaign

    if ($null -eq $registrationCampaign) {
      Write-Host "   Registration campaign settings not present in policy response; nothing to disable." -ForegroundColor Yellow
    }
    elseif ($registrationCampaign.state -eq $desiredRegistrationCampaignState) {
      Write-Host "   Registration campaign is already $desiredRegistrationCampaignState." -ForegroundColor Green
    }
    else {
      $campaignPatch = @{
        registrationEnforcement = @{
          authenticationMethodsRegistrationCampaign = @{
            state = $desiredRegistrationCampaignState
          }
        }
      }

      $verb = if ($desiredRegistrationCampaignState -eq "disabled") { "Disable" } else { "Enable" }
      if ($PSCmdlet.ShouldProcess("authenticationMethodsPolicy.registrationEnforcement.authenticationMethodsRegistrationCampaign", "$verb Authenticator registration campaign")) {
        Invoke-Beta -Method PATCH -Uri "/v1.0/policies/authenticationMethodsPolicy" -Body $campaignPatch | Out-Null
        Write-Host "   Set Authenticator registration campaign to $desiredRegistrationCampaignState." -ForegroundColor Green
      }
      else {
        Write-Host "   Planned registration campaign state change to $desiredRegistrationCampaignState." -ForegroundColor Yellow
      }
    }
  }
  catch {
    if ($WhatIfPreference) {
      Write-Warning "Could not query/update registration campaign during -WhatIf. Continuing dry-run. Details: $($_.Exception.Message)"
    }
    else {
      Write-Warning "Could not disable registration campaign. Continuing. Details: $($_.Exception.Message)"
    }
  }
}
else {
  Write-Host "   Skipping registration campaign change by parameter." -ForegroundColor Yellow
}

if ($DisableSystemPreferredMfa) {
  Write-Step "Ensuring system-preferred MFA is $desiredSystemPreferredMfaState..."
  try {
    $authMethodsPolicyBeta = Invoke-Beta -Method GET -Uri "/beta/policies/authenticationMethodsPolicy"
    # systemCredentialPreferences controls Microsoft "system-preferred MFA" behavior (beta property in many tenants).
    $systemPref = $authMethodsPolicyBeta.systemCredentialPreferences

    if ($null -eq $systemPref) {
      Write-Host "   systemCredentialPreferences not returned by this tenant/endpoint; skipping." -ForegroundColor Yellow
    }
    elseif ($systemPref.state -eq $desiredSystemPreferredMfaState) {
      Write-Host "   System-preferred MFA is already $desiredSystemPreferredMfaState." -ForegroundColor Green
    }
    else {
      $verb = if ($desiredSystemPreferredMfaState -eq "disabled") { "Disable" } else { "Enable" }
      if ($PSCmdlet.ShouldProcess("authenticationMethodsPolicy.systemCredentialPreferences", "$verb system-preferred MFA")) {
        Invoke-Beta -Method PATCH -Uri "/beta/policies/authenticationMethodsPolicy" -Body @{
          systemCredentialPreferences = @{
            state = $desiredSystemPreferredMfaState
          }
        } | Out-Null
        Write-Host "   Set system-preferred MFA to $desiredSystemPreferredMfaState." -ForegroundColor Green
      }
      else {
        Write-Host "   Planned system-preferred MFA state change to $desiredSystemPreferredMfaState." -ForegroundColor Yellow
      }
    }
  }
  catch {
    if ($WhatIfPreference) {
      Write-Warning "Could not query/update system-preferred MFA during -WhatIf. Continuing dry-run. Details: $($_.Exception.Message)"
    }
    else {
      Write-Warning "Could not disable system-preferred MFA. Continuing. Details: $($_.Exception.Message)"
    }
  }
}
else {
  Write-Host "   Skipping system-preferred MFA change by parameter." -ForegroundColor Yellow
}

Write-Step "Done."

Write-Host ""
Write-Host "Next validation checks:" -ForegroundColor Yellow
if ($isOffboarding) {
  # Offboarding checklist: confirm Duo requirements are removed and Microsoft defaults restored.
  Write-Host "  1) Entra -> Conditional Access: confirm '$CaPolicyName' is removed/disabled"
  Write-Host "  2) Entra -> Authentication methods -> External authentication methods: confirm '$Name' is disabled (or removed manually if preferred)"
  Write-Host "  3) Entra -> Authentication methods -> Policies -> Microsoft Authenticator: confirm enabled"
  Write-Host "  4) Entra -> Authentication methods -> Registration campaign: confirm enabled (if you left defaults)"
  Write-Host "  5) Entra -> Authentication methods -> System-preferred MFA: confirm enabled"
  Write-Host "  6) Entra -> Authentication methods -> Policies: confirm wrapper-group exclusions were removed from common Microsoft MFA methods (if enabled)"
}
else {
  # Rollout checklist: confirm Duo is active and Microsoft prompts are no longer preferred.
  Write-Host "  1) Entra -> Authentication methods -> External authentication methods: confirm '$Name' enabled + targeted to '$WrapperGroupName'"
  Write-Host "  2) Entra -> Conditional Access: confirm '$CaPolicyName' enabled and scoped correctly"
  Write-Host "  3) Entra -> Authentication methods -> Policies -> Microsoft Authenticator: confirm disabled (if you left defaults)"
  Write-Host "  4) Entra -> Authentication methods -> Registration campaign: confirm disabled (if you left defaults)"
  Write-Host "  5) Entra -> Authentication methods -> Policies: confirm common Microsoft MFA methods exclude '$WrapperGroupName' (if enabled)"
  Write-Host "  6) If bulk registration was enabled: Entra/myaccount -> Security info: confirm wrapper-group users have '$Name' registered"
  Write-Host "  7) myaccount.microsoft.com -> Security info: confirm users in pilot get prompted with External method"
}
Write-Host ""
Write-Host "Note: This script changes tenant auth method policy settings (best-effort). It only adds per-user External Authentication Method registrations when -BulkRegisterExternalAuthMethodForWrapperGroupUsers is enabled; it does not remove other per-user MFA registrations. If user prompts still look wrong, review the user's registered methods and tenant authentication method policies." -ForegroundColor Yellow
Write-Host "Note: Bulk per-user registration requires delegated Graph scope 'UserAuthMethod-External.ReadWrite.All' (requested automatically when that option is enabled)." -ForegroundColor Yellow
