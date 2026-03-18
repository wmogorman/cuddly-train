#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$ApprovedProductPatterns,

    [string[]]$IgnoreProductPatterns = @(
        'Microsoft Defender',
        'Windows Defender',
        'Defender for Endpoint'
    ),

    [string[]]$SecurityDisplayNamePatterns = @(
        'Antivirus',
        'Internet Security',
        'Endpoint Security',
        'Threat',
        'Malware',
        'EDR',
        'XDR',
        'AVG',
        'Avast',
        'Bitdefender',
        'CrowdStrike',
        'Cylance',
        'ESET',
        'Kaspersky',
        'McAfee',
        'Norton',
        'SentinelOne',
        'Sophos',
        'Trend Micro',
        'Webroot'
    ),

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-security-removal.log',

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'pti-common.ps1')

function Test-PatternMatch {
    param(
        [string]$Value,
        [string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        if ($Value -match $pattern) {
            return $true
        }
    }

    return $false
}

$legacyAvScript = Join-Path -Path $PSScriptRoot -ChildPath '..\Remove-LegacyAV.ps1'
if (-not (Test-Path -LiteralPath $legacyAvScript)) {
    throw "Required helper script not found: $legacyAvScript"
}

Write-PTILog -Message 'Enumerating installed security software.' -LogPath $LogPath

$inventory = [System.Collections.Generic.List[string]]::new()

try {
    $securityCenterProducts = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName 'AntivirusProduct' -ErrorAction Stop
    foreach ($product in $securityCenterProducts) {
        if (-not [string]::IsNullOrWhiteSpace($product.displayName)) {
            $inventory.Add($product.displayName) | Out-Null
        }
    }
}
catch {
    Write-PTILog -Message "SecurityCenter2 inventory unavailable: $($_.Exception.Message)" -Level 'WARN' -LogPath $LogPath
}

foreach ($program in Get-PTIInstalledPrograms) {
    if (Test-PatternMatch -Value $program.DisplayName -Patterns $SecurityDisplayNamePatterns) {
        $inventory.Add($program.DisplayName) | Out-Null
    }
}

$uniqueInventory = @($inventory | Sort-Object -Unique)
if ($uniqueInventory.Count -eq 0) {
    Write-PTILog -Message 'No security products matched the current inventory rules.' -LogPath $LogPath
    return
}

Write-PTILog -Message ("Security inventory: {0}" -f ($uniqueInventory -join '; ')) -LogPath $LogPath

$approvedPatterns = @($ApprovedProductPatterns + $IgnoreProductPatterns)
$unapproved = @(
    $uniqueInventory | Where-Object {
        -not (Test-PatternMatch -Value $_ -Patterns $approvedPatterns)
    }
)

if ($unapproved.Count -eq 0) {
    Write-PTILog -Message 'All detected security products match the approved allowlist.' -LogPath $LogPath
    return
}

Write-PTILog -Message ("Unapproved security products detected: {0}" -f ($unapproved -join '; ')) -Level 'WARN' -LogPath $LogPath

if ($PSCmdlet.ShouldProcess('Security software inventory', 'Remove unapproved security products')) {
    & $legacyAvScript -TargetPatterns $unapproved -LogPath $LogPath -DryRun:$DryRun -WhatIf:$WhatIfPreference
}
