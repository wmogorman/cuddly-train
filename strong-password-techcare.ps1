<#
.SYNOPSIS
Sets domain password policy and password expiry warning in Default Domain Policy.

.DESCRIPTION
Applies password settings to the domain default password policy and sets
`PasswordExpiryWarning` in the Default Domain Policy GPO.
Use `-SkipConfirmation` for non-interactive automation (for example Datto RMM)
to prevent `ShouldProcess` confirmation prompts from hanging execution.

.EXAMPLE
.\strong-password-techcare.ps1 -SkipConfirmation -SkipPdcCheck -NoVerify
#>
#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateRange(1, 3650)]
    [int]$MaxPasswordAgeDays = 365,

    [ValidateRange(0, 3650)]
    [int]$MinPasswordAgeDays = 1,

    [ValidateRange(8, 128)]
    [int]$MinPasswordLength = 8,

    [ValidateRange(0, 24)]
    [int]$PasswordHistoryCount = 5,

    [bool]$ComplexityEnabled = $true,

    [ValidateRange(5, 14)]
    [int]$PasswordExpiryWarningDays = 14,

    [switch]$NoVerify,

    [switch]$SkipPdcCheck,

    [switch]$SkipConfirmation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($SkipConfirmation) {
    # Prevent interactive confirmation prompts (useful for non-interactive automation such as RMM components).
    $ConfirmPreference = 'None'
}

if ($MinPasswordAgeDays -ge $MaxPasswordAgeDays) {
    throw "MinPasswordAgeDays ($MinPasswordAgeDays) must be less than MaxPasswordAgeDays ($MaxPasswordAgeDays)."
}

Import-Module ActiveDirectory -ErrorAction Stop
Import-Module GroupPolicy -ErrorAction Stop

# --- Verify this DC is the PDC Emulator (recommended target for domain policy changes) ---
$domain = Get-ADDomain -ErrorAction Stop
$localDc = Get-ADDomainController -Identity $env:COMPUTERNAME -ErrorAction Stop
$pdcHost = $domain.PDCEmulator

if (-not $SkipPdcCheck) {
    $isPdc = $localDc.OperationMasterRoles -contains 'PDCEmulator'
    if (-not $isPdc) {
        throw "This machine is not the PDC Emulator. PDC is: $pdcHost. Run this script there (or use -SkipPdcCheck intentionally)."
    }

    Write-Host "Running on PDC Emulator: $($localDc.HostName)" -ForegroundColor Green
}
else {
    Write-Host "Skipping PDC Emulator check by request. Domain PDC is: $pdcHost" -ForegroundColor Yellow
}

# --- Configure the domain default password policy (domain attributes) ---
# These are the effective domain password settings (commonly managed through Default Domain Policy UI).
$domainPolicyTarget = $domain.DistinguishedName

if ($PSCmdlet.ShouldProcess($domain.DNSRoot, "Set default domain password policy")) {
    Set-ADDefaultDomainPasswordPolicy `
        -Identity $domainPolicyTarget `
        -MaxPasswordAge (New-TimeSpan -Days $MaxPasswordAgeDays) `
        -MinPasswordAge (New-TimeSpan -Days $MinPasswordAgeDays) `
        -MinPasswordLength $MinPasswordLength `
        -PasswordHistoryCount $PasswordHistoryCount `
        -ComplexityEnabled $ComplexityEnabled `
        -ReversibleEncryptionEnabled $false

    Write-Host ("Set domain default password policy (max age {0}d, min age {1}d, min len {2}, complexity {3}, history {4}, reversible encryption OFF)." -f `
        $MaxPasswordAgeDays, $MinPasswordAgeDays, $MinPasswordLength, $ComplexityEnabled, $PasswordHistoryCount) -ForegroundColor Green
}

# --- Configure password expiry warning in Default Domain Policy (computer-side registry policy) ---
# Security Options -> "Interactive logon: Prompt user to change password before expiration"
$gpoName = 'Default Domain Policy'
$winlogonKey = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$winlogonValueName = 'PasswordExpiryWarning'

# Ensure GPO exists before attempting to write to it
$null = Get-GPO -Name $gpoName -ErrorAction Stop

if ($PSCmdlet.ShouldProcess($gpoName, "Set $winlogonKey\$winlogonValueName = $PasswordExpiryWarningDays")) {
    Set-GPRegistryValue `
        -Name $gpoName `
        -Key $winlogonKey `
        -ValueName $winlogonValueName `
        -Type DWord `
        -Value $PasswordExpiryWarningDays

    Write-Host "Set $gpoName -> $winlogonKey\$winlogonValueName = $PasswordExpiryWarningDays (days warning)." -ForegroundColor Green
}

if (-not $NoVerify) {
    # --- Show resulting settings for quick verification ---
    Write-Host "`nVerification:" -ForegroundColor Cyan
    Get-ADDefaultDomainPasswordPolicy -Identity $domain.DNSRoot | Select-Object `
        MaxPasswordAge, MinPasswordAge, MinPasswordLength, PasswordHistoryCount, ComplexityEnabled, ReversibleEncryptionEnabled | Format-List

    Write-Host "GPO registry setting (PasswordExpiryWarning):" -ForegroundColor Cyan
    try {
        Get-GPRegistryValue -Name $gpoName -Key $winlogonKey -ValueName $winlogonValueName -ErrorAction Stop | Format-List
    }
    catch {
        if ($WhatIfPreference) {
            Write-Host "Not present (expected when running with -WhatIf because no changes were written)." -ForegroundColor Yellow
        }
        else {
            Write-Warning "PasswordExpiryWarning is not currently configured in '$gpoName' at $winlogonKey."
        }
    }
}
