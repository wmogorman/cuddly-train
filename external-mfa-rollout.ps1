<#
.SYNOPSIS
  Configure External MFA rollout (Duo) in Entra ID:
   - Complete UCP migration
   - Create wrapper group DMX-ExternalMFA-Users
   - Nest "DMX Pilot Group" into wrapper
   - Create External Authentication Method configuration (Graph beta)
   - Target External method to wrapper group
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
  [Parameter(Mandatory=$true)]
  [string]$Name,

  [Parameter(Mandatory=$false)]
  [string]$ClientId,

  [Parameter(Mandatory=$false)]
  [string]$DiscoveryEndpoint,

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
  [Parameter(Mandatory=$false)]
  [switch]$OffboardToMicrosoftPreferred
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step($msg) {
  Write-Host "==> $msg" -ForegroundColor Cyan
}

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

function Escape-ODataStringLiteral {
  param([Parameter(Mandatory=$true)][string]$Value)
  return ($Value -replace "'", "''")
}

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
    [string]$Uri,   # may be /v1.0/... or /beta/...
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

function Get-ExternalAuthMethodConfigByName {
  param([Parameter(Mandatory=$true)][string]$DisplayName)

  $queryAttempts = @(
    "/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations",
    "/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations",
    "/v1.0/policies/authenticationMethodsPolicy?`$expand=authenticationMethodConfigurations",
    "/beta/policies/authenticationMethodsPolicy?`$expand=authenticationMethodConfigurations",
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

Connect-MgGraph -Scopes $scopes | Out-Null
if (Get-Command -Name "Select-MgProfile" -ErrorAction SilentlyContinue) {
  Select-MgProfile -Name "beta" | Out-Null
}
else {
  Write-Host "   Select-MgProfile not available (Microsoft.Graph SDK v2+). Continuing; beta calls use explicit /beta URIs." -ForegroundColor Yellow
}

$isOffboarding = [bool]$OffboardToMicrosoftPreferred
if ($isOffboarding) {
  Write-Step "Offboarding mode enabled: removing Duo CA and restoring Microsoft-preferred MFA settings (best-effort)."
}
else {
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
    # Check if already a member
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
$extConfigCollectionUri = "/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations"
$skipExternalAuthConfigDueToWhatIfQueryFailure = $false
try {
  $extLookup = Get-ExternalAuthMethodConfigByName -DisplayName $Name
  $extConfig = $extLookup.Item
  if ($extLookup.QueryUri -match "^(/v1\.0|/beta)/policies/authenticationMethodsPolicy/authenticationMethodConfigurations$") {
    $extConfigCollectionUri = $extLookup.QueryUri
  }
  elseif ($extLookup.QueryUri -match "^/beta/") {
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
  # Prefer current Graph schema; fall back to older preview shape if the tenant still expects it.
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
  Write-Host "  1) Entra -> Conditional Access: confirm '$CaPolicyName' is removed/disabled"
  Write-Host "  2) Entra -> Authentication methods -> External authentication methods: confirm '$Name' is disabled (or removed manually if preferred)"
  Write-Host "  3) Entra -> Authentication methods -> Policies -> Microsoft Authenticator: confirm enabled"
  Write-Host "  4) Entra -> Authentication methods -> Registration campaign: confirm enabled (if you left defaults)"
  Write-Host "  5) Entra -> Authentication methods -> System-preferred MFA: confirm enabled"
}
else {
  Write-Host "  1) Entra -> Authentication methods -> External authentication methods: confirm '$Name' enabled + targeted to '$WrapperGroupName'"
  Write-Host "  2) Entra -> Conditional Access: confirm '$CaPolicyName' enabled and scoped correctly"
  Write-Host "  3) Entra -> Authentication methods -> Policies -> Microsoft Authenticator: confirm disabled (if you left defaults)"
  Write-Host "  4) Entra -> Authentication methods -> Registration campaign: confirm disabled (if you left defaults)"
  Write-Host "  5) myaccount.microsoft.com -> Security info: confirm users in pilot get prompted with External method"
}
Write-Host ""
Write-Host "Note: This script changes tenant auth method policy settings (best-effort), but it does not remove or add per-user MFA registrations. If user prompts still look wrong, review the user's registered methods and tenant authentication method policies." -ForegroundColor Yellow
