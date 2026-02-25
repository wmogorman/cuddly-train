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

.NOTES
  Requires Microsoft.Graph PowerShell SDK.
  Uses Graph beta endpoints for External Authentication Methods + migration state in many tenants.
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
param(
  [Parameter(Mandatory=$true)]
  [string]$Name,

  [Parameter(Mandatory=$true)]
  [string]$ClientId,

  [Parameter(Mandatory=$true)]
  [string]$DiscoveryEndpoint,

  [Parameter(Mandatory=$true)]
  [string]$AppId,

  [Parameter(Mandatory=$false)]
  [string]$PilotGroupName = "DMX Pilot Group",

  [Parameter(Mandatory=$false)]
  [string]$WrapperGroupName = "DMX-ExternalMFA-Users",

  [Parameter(Mandatory=$false)]
  [string]$CaPolicyName = "DMX - Require MFA (External MFA Rollout)",

  [Parameter(Mandatory=$false)]
  [bool]$DisableMicrosoftAuthenticatorPolicy = $true,

  [Parameter(Mandatory=$false)]
  [bool]$DisableAuthenticatorRegistrationCampaign = $true,

  [Parameter(Mandatory=$false)]
  [bool]$DisableSystemPreferredMfa = $true
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
    [string]$Uri,   # must start with /beta/...
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

# --- 1) Complete Authentication Methods migration (UCP) ---
# This is tenant-dependent; in some tenants this property is writable via beta.
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
  Write-Warning "Could not set policyMigrationState. This may already be complete, or your tenant doesn't allow this via Graph. Details: $($_.Exception.Message)"
}

# --- 2) Ensure wrapper group exists ---
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

# --- 4) Create/Update External Authentication Method configuration ---
# Graph beta shape can vary by tenant/rollout. We:
#  - list existing external auth method configs
#  - match by displayName
#  - create if missing
Write-Step "Ensuring External Authentication Method configuration '$Name' exists (Graph beta)..."

$extConfig = $null
$skipExternalAuthConfigDueToWhatIfQueryFailure = $false
try {
  $configs = Invoke-Beta -Method GET -Uri "/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations"
  $extConfig = @($configs.value) | Where-Object { $_.'@odata.type' -match "externalAuthenticationMethod" -and $_.displayName -eq $Name } | Select-Object -First 1
}
catch {
  if ($WhatIfPreference) {
    $skipExternalAuthConfigDueToWhatIfQueryFailure = $true
    Write-Warning "Could not query authenticationMethodConfigurations (beta) during -WhatIf. This preview endpoint varies by tenant and may return BadRequest when unavailable. Continuing dry-run. Details: $($_.Exception.Message)"
  }
  else {
    throw "Failed to query authenticationMethodConfigurations (beta). Details: $($_.Exception.Message)"
  }
}

if ($skipExternalAuthConfigDueToWhatIfQueryFailure) {
  Write-Host "   Planned external auth method configuration create/update (query skipped in -WhatIf)." -ForegroundColor Yellow
}
elseif (-not $extConfig) {
  Write-Step "Creating External Authentication Method configuration..."
  # This payload is the common schema used in many tenants; if your tenant expects different fields,
  # Graph will return a helpful error specifying required properties.
  $body = @{
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
      $created = Invoke-Beta -Method POST -Uri "/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations" -Body $body
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
  try {
    if ($PSCmdlet.ShouldProcess($Name, "Update External Authentication Method configuration '$($extConfig.id)'")) {
      Invoke-Beta -Method PATCH -Uri "/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/$($extConfig.id)" -Body @{
        state = "enabled"
        includeTarget = @{
          targetType = "group"
          id         = $wrapper.Id
        }
        clientId          = $ClientId
        discoveryEndpoint = $DiscoveryEndpoint
        appId             = $AppId
      } | Out-Null
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

# --- 5) Create Conditional Access policy requiring MFA for wrapper group ---
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
  Write-Host "   CA policy already exists (id: $($existingCa.id)). Skipping create." -ForegroundColor Green
}

# --- 6) Reduce Microsoft MFA steering so users follow External MFA (Duo) ---
Write-Step "Applying MFA UX hardening for Duo rollout (best-effort)..."

if ($DisableMicrosoftAuthenticatorPolicy) {
  Write-Step "Ensuring Microsoft Authenticator authentication method policy is disabled..."
  try {
    $msAuthConfig = Invoke-Beta -Method GET -Uri "/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/microsoftAuthenticator"
    if ($msAuthConfig.state -eq "disabled") {
      Write-Host "   Microsoft Authenticator method policy is already disabled." -ForegroundColor Green
    }
    else {
      if ($PSCmdlet.ShouldProcess("microsoftAuthenticator method policy", "Disable Microsoft Authenticator authentication method policy")) {
        Invoke-Beta -Method PATCH -Uri "/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/microsoftAuthenticator" -Body @{
          "@odata.type" = "#microsoft.graph.microsoftAuthenticatorAuthenticationMethodConfiguration"
          state         = "disabled"
        } | Out-Null
        Write-Host "   Disabled Microsoft Authenticator method policy." -ForegroundColor Green
      }
      else {
        Write-Host "   Planned disable of Microsoft Authenticator method policy." -ForegroundColor Yellow
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
  Write-Step "Ensuring Microsoft Authenticator registration campaign is disabled..."
  try {
    $authMethodsPolicyV1 = Invoke-Beta -Method GET -Uri "/v1.0/policies/authenticationMethodsPolicy"
    $registrationCampaign = $authMethodsPolicyV1.registrationEnforcement.authenticationMethodsRegistrationCampaign

    if ($null -eq $registrationCampaign) {
      Write-Host "   Registration campaign settings not present in policy response; nothing to disable." -ForegroundColor Yellow
    }
    elseif ($registrationCampaign.state -eq "disabled") {
      Write-Host "   Registration campaign is already disabled." -ForegroundColor Green
    }
    else {
      $campaignPatch = @{
        registrationEnforcement = @{
          authenticationMethodsRegistrationCampaign = @{
            state = "disabled"
          }
        }
      }

      if ($PSCmdlet.ShouldProcess("authenticationMethodsPolicy.registrationEnforcement.authenticationMethodsRegistrationCampaign", "Disable Authenticator registration campaign")) {
        Invoke-Beta -Method PATCH -Uri "/v1.0/policies/authenticationMethodsPolicy" -Body $campaignPatch | Out-Null
        Write-Host "   Disabled Authenticator registration campaign." -ForegroundColor Green
      }
      else {
        Write-Host "   Planned disable of Authenticator registration campaign." -ForegroundColor Yellow
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
  Write-Step "Ensuring system-preferred MFA is disabled..."
  try {
    $authMethodsPolicyBeta = Invoke-Beta -Method GET -Uri "/beta/policies/authenticationMethodsPolicy"
    $systemPref = $authMethodsPolicyBeta.systemCredentialPreferences

    if ($null -eq $systemPref) {
      Write-Host "   systemCredentialPreferences not returned by this tenant/endpoint; skipping." -ForegroundColor Yellow
    }
    elseif ($systemPref.state -eq "disabled") {
      Write-Host "   System-preferred MFA is already disabled." -ForegroundColor Green
    }
    else {
      if ($PSCmdlet.ShouldProcess("authenticationMethodsPolicy.systemCredentialPreferences", "Disable system-preferred MFA")) {
        Invoke-Beta -Method PATCH -Uri "/beta/policies/authenticationMethodsPolicy" -Body @{
          systemCredentialPreferences = @{
            state = "disabled"
          }
        } | Out-Null
        Write-Host "   Disabled system-preferred MFA." -ForegroundColor Green
      }
      else {
        Write-Host "   Planned disable of system-preferred MFA." -ForegroundColor Yellow
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
Write-Host "  1) Entra -> Authentication methods -> External authentication methods: confirm '$Name' enabled + targeted to '$WrapperGroupName'"
Write-Host "  2) Entra -> Conditional Access: confirm '$CaPolicyName' enabled and scoped correctly"
Write-Host "  3) Entra -> Authentication methods -> Policies -> Microsoft Authenticator: confirm disabled (if you left defaults)"
Write-Host "  4) Entra -> Authentication methods -> Registration campaign: confirm disabled (if you left defaults)"
Write-Host "  5) myaccount.microsoft.com -> Security info: confirm users in pilot get prompted with External method"
Write-Host ""
Write-Host "Note: This script changes tenant auth method policy settings (best-effort), but it does not remove existing user MFA registrations. If a user still lands on an unexpected method, review the user's registered methods and tenant authentication method policies." -ForegroundColor Yellow
