<#
.SYNOPSIS
  Interactive entrypoint for the Duo External MFA rollout core.

.DESCRIPTION
  Keeps the original script path stable while delegating all argument handling and rollout behavior to
  external-mfa-rollout-core.ps1.
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
param(
  [Parameter(Mandatory=$true)]
  [string]$Name,

  [Parameter(Mandatory=$false)]
  [string]$ClientId,

  [Parameter(Mandatory=$false)]
  [string]$GuestClientId,

  [Parameter(Mandatory=$false)]
  [string]$DiscoveryEndpoint,

  [Parameter(Mandatory=$false)]
  [string]$AppId,

  [Parameter(Mandatory=$false)]
  [string]$ExternalAuthConfigId,

  [Parameter(Mandatory=$false)]
  [ValidateSet("PilotGlobalAdmins","FinalGroups")]
  [string]$Stage = "PilotGlobalAdmins",

  [Parameter(Mandatory=$false)]
  [ValidateSet("MirrorLegacy","AllApps","ExplicitApps")]
  [string]$CaScopeMode = "MirrorLegacy",

  [Parameter(Mandatory=$false)]
  [string]$PilotGroupName = "DMX-ExternalMFA-Pilot-GlobalAdmins",

  [Parameter(Mandatory=$false)]
  [string]$ExistingPilotGroupId,

  [Parameter(Mandatory=$false)]
  [string]$ExistingPilotGroupName,

  [Parameter(Mandatory=$false)]
  [string]$WrapperGroupName = "DMX-ExternalMFA-Users",

  [Parameter(Mandatory=$false)]
  [string]$CaPolicyName = "DMX - Require MFA (External MFA)",

  [Parameter(Mandatory=$false)]
  [string[]]$LegacyPolicyNames = @(),

  [Parameter(Mandatory=$false)]
  [string[]]$ExplicitAppIds = @(),

  [Parameter(Mandatory=$false)]
  [string[]]$FinalTargetGroupIds = @(),

  [Parameter(Mandatory=$false)]
  [string]$BreakGlassGroupId,

  [Parameter(Mandatory=$false)]
  [bool]$GuestSupport = $false,

  [Parameter(Mandatory=$false)]
  [bool]$DisableMicrosoftAuthenticatorPolicy = $false,

  [Parameter(Mandatory=$false)]
  [bool]$DisableAuthenticatorRegistrationCampaign = $true,

  [Parameter(Mandatory=$false)]
  [bool]$DisableSystemPreferredMfa = $true,

  [Parameter(Mandatory=$false)]
  [bool]$RestrictCommonMicrosoftMfaMethodsForWrapperGroup = $true,

  [Parameter(Mandatory=$false)]
  [string[]]$WrapperGroupExcludedMethodIds = @(
    "microsoftAuthenticator",
    "sms",
    "voice",
    "softwareOath",
    "hardwareOath"
  ),

  [Parameter(Mandatory=$false)]
  [bool]$BulkRegisterExternalAuthMethodForWrapperGroupUsers = $false,

  [Parameter(Mandatory=$false)]
  [bool]$BulkRegisterSkipDisabledUsers = $true,

  [Parameter(Mandatory=$false)]
  [bool]$BulkRegisterIncludeGuestUsers = $false,

  [Parameter(Mandatory=$false)]
  [bool]$AuditEamOnlyPilotReadiness = $true,

  [Parameter(Mandatory=$false)]
  [bool]$EnforceStrictExternalOnlyTenantPrereqs = $false,

  [Parameter(Mandatory=$false)]
  [bool]$DisableAdminSspr = $false,

  [Parameter(Mandatory=$false)]
  [switch]$PreflightOnly,

  [Parameter(Mandatory=$false)]
  [bool]$FailOnManualBlockers = $true,

  [Parameter(Mandatory=$false)]
  [string]$TargetTenantId,

  [Parameter(Mandatory=$false)]
  [string]$GraphAppClientId,

  [Parameter(Mandatory=$false)]
  [string]$GraphCertificateThumbprint,

  [Parameter(Mandatory=$false)]
  [switch]$SkipGraphConnect,

  [Parameter(Mandatory=$false)]
  [switch]$OffboardToMicrosoftPreferred
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$coreScriptPath = Join-Path $scriptDir "external-mfa-rollout-core.ps1"

if (-not (Test-Path -LiteralPath $coreScriptPath)) {
  throw "Core rollout script not found: $coreScriptPath"
}

$invokeParams = @{}
foreach ($entry in $MyInvocation.BoundParameters.GetEnumerator()) {
  $invokeParams[[string]$entry.Key] = $entry.Value
}

& $coreScriptPath @invokeParams
