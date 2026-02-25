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

.NOTES
  Requires Microsoft.Graph PowerShell SDK.
  Uses Graph beta endpoints for External Authentication Methods + migration state in many tenants.
#>

[CmdletBinding()]
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
  [string]$CaPolicyName = "DMX - Require MFA (External MFA Rollout)"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step($msg) {
  Write-Host "==> $msg" -ForegroundColor Cyan
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
Select-MgProfile -Name "beta" | Out-Null

# --- 1) Complete Authentication Methods migration (UCP) ---
# This is tenant-dependent; in some tenants this property is writable via beta.
Write-Step "Setting Authentication Methods policy migration state to 'migrationComplete' (best-effort)..."
try {
  # Try PATCH to authenticationMethodsPolicy (beta)
  Invoke-Beta -Method PATCH -Uri "/beta/policies/authenticationMethodsPolicy" -Body @{
    policyMigrationState = "migrationComplete"
  } | Out-Null
  Write-Host "   Migration state PATCH submitted." -ForegroundColor Green
}
catch {
  Write-Warning "Could not set policyMigrationState. This may already be complete, or your tenant doesn't allow this via Graph. Details: $($_.Exception.Message)"
}

# --- 2) Ensure wrapper group exists ---
Write-Step "Ensuring wrapper group '$WrapperGroupName' exists..."
$wrapper = Get-GroupByDisplayNameUnique -DisplayName $WrapperGroupName
if (-not $wrapper) {
  $wrapper = New-MgGroup -DisplayName $WrapperGroupName `
    -MailEnabled:$false `
    -MailNickname (New-SafeMailNickname -DisplayName $WrapperGroupName) `
    -SecurityEnabled:$true
  Write-Host "   Created group: $($wrapper.Id)" -ForegroundColor Green
} else {
  Write-Host "   Found group: $($wrapper.Id)" -ForegroundColor Green
}

# --- 3) Ensure Pilot group exists and nest it ---
Write-Step "Ensuring pilot group '$PilotGroupName' exists..."
$pilot = Get-GroupByDisplayNameUnique -DisplayName $PilotGroupName
if (-not $pilot) {
  $pilot = New-MgGroup -DisplayName $PilotGroupName `
    -MailEnabled:$false `
    -MailNickname (New-SafeMailNickname -DisplayName $PilotGroupName) `
    -SecurityEnabled:$true
  Write-Host "   Created pilot group: $($pilot.Id)" -ForegroundColor Green
} else {
  Write-Host "   Found pilot group: $($pilot.Id)" -ForegroundColor Green
}

Write-Step "Nesting pilot group into wrapper group (best-effort, idempotent)..."
try {
  # Check if already a member
  $members = Get-MgGroupMember -GroupId $wrapper.Id -All
  $already = $members | Where-Object { $_.Id -eq $pilot.Id }
  if ($already) {
    Write-Host "   Pilot group is already nested." -ForegroundColor Green
  } else {
    New-MgGroupMemberByRef -GroupId $wrapper.Id -BodyParameter @{
      "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($pilot.Id)"
    } | Out-Null
    Write-Host "   Nested pilot group into wrapper." -ForegroundColor Green
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
try {
  $configs = Invoke-Beta -Method GET -Uri "/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations"
  $extConfig = @($configs.value) | Where-Object { $_.'@odata.type' -match "externalAuthenticationMethod" -and $_.displayName -eq $Name } | Select-Object -First 1
}
catch {
  throw "Failed to query authenticationMethodConfigurations (beta). Details: $($_.Exception.Message)"
}

if (-not $extConfig) {
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
    $created = Invoke-Beta -Method POST -Uri "/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations" -Body $body
    $extConfig = $created
    Write-Host "   Created external auth method config id: $($extConfig.id)" -ForegroundColor Green
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
  catch {
    Write-Warning "Could not PATCH external auth method config. You may need to adjust fields for your tenant. Details: $($_.Exception.Message)"
  }
}

# --- 5) Create Conditional Access policy requiring MFA for wrapper group ---
Write-Step "Ensuring Conditional Access policy '$CaPolicyName' exists..."
$existingCa = $null
try {
  $caList = Invoke-Beta -Method GET -Uri "/beta/identity/conditionalAccess/policies"
  $existingCa = @($caList.value) | Where-Object { $_.displayName -eq $CaPolicyName } | Select-Object -First 1
}
catch {
  throw "Failed to list Conditional Access policies (beta). Details: $($_.Exception.Message)"
}

if (-not $existingCa) {
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
    $newCa = Invoke-Beta -Method POST -Uri "/beta/identity/conditionalAccess/policies" -Body $caBody
    Write-Host "   Created CA policy id: $($newCa.id)" -ForegroundColor Green
  }
  catch {
    throw "Failed to create CA policy. Details: $($_.Exception.Message)"
  }
}
else {
  Write-Host "   CA policy already exists (id: $($existingCa.id)). Skipping create." -ForegroundColor Green
}

Write-Step "Done."

Write-Host ""
Write-Host "Next validation checks:" -ForegroundColor Yellow
Write-Host "  1) Entra -> Authentication methods -> External authentication methods: confirm '$Name' enabled + targeted to '$WrapperGroupName'"
Write-Host "  2) Entra -> Conditional Access: confirm '$CaPolicyName' enabled and scoped correctly"
Write-Host "  3) myaccount.microsoft.com -> Security info: confirm users in pilot get prompted with External method"
Write-Host ""
Write-Host "If you want to prevent Microsoft Authenticator from being chosen, also disable it under Authentication methods -> Policies -> Microsoft Authenticator (or remove registrations), as you tested." -ForegroundColor Yellow
