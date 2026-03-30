<#
.SYNOPSIS
  Interactive entrypoint for the Duo External MFA rollout core.

.DESCRIPTION
  Keeps the original script path stable while delegating all argument handling and rollout behavior to
  external-mfa-rollout-core.ps1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$coreScriptPath = Join-Path $scriptDir "external-mfa-rollout-core.ps1"

if (-not (Test-Path -LiteralPath $coreScriptPath)) {
  throw "Core rollout script not found: $coreScriptPath"
}

& $coreScriptPath @args
