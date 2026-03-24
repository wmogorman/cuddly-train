<#
.SYNOPSIS
Creates a dedicated strong-password GPO at the domain root and clears competing settings from Default Domain Policy.

.DESCRIPTION
Creates or updates a dedicated domain-root GPO for password policy settings and
the `PasswordExpiryWarning` security option, then removes those overlapping
settings from `Default Domain Policy` so the dedicated GPO is the single source
of truth.

This script writes the password policy settings into the GPO security template
(`GptTmpl.inf`) and updates the GPO version metadata so domain controllers can
process the change.

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

    [ValidateNotNullOrEmpty()]
    [string]$StrongPasswordGpoName = 'TechCare Strong Password Policy',

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

function Get-GpoAdPath {
    param(
        [Parameter(Mandatory)]
        [guid]$GpoId,

        [Parameter(Mandatory)]
        [string]$DomainDistinguishedName
    )

    return 'CN={0},CN=Policies,CN=System,{1}' -f $GpoId.ToString('B').ToUpperInvariant(), $DomainDistinguishedName
}

function Get-GpoAdObject {
    param(
        [Parameter(Mandatory)]
        [guid]$GpoId,

        [Parameter(Mandatory)]
        [string]$DomainDistinguishedName,

        [Parameter(Mandatory)]
        [string]$Server
    )

    $gpoAdPath = Get-GpoAdPath -GpoId $GpoId -DomainDistinguishedName $DomainDistinguishedName
    return Get-ADObject -Identity $gpoAdPath -Server $Server -Properties versionNumber, gPCMachineExtensionNames, gPCFileSysPath -ErrorAction Stop
}

function Get-InitialSecurityTemplateLines {
    return @(
        '[Unicode]'
        'Unicode=yes'
        ''
        '[Version]'
        'signature="$CHICAGO$"'
        'Revision=1'
        ''
        '[System Access]'
    )
}

function Update-InfSectionKeyValues {
    param(
        [Parameter(Mandatory)]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [string]$SectionName,

        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$KeyValueMap,

        [switch]$RemoveKeys
    )

    $mutableLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        $null = $mutableLines.Add([string]$line)
    }

    $sectionHeaderPattern = '^\s*\[{0}\]\s*$' -f [regex]::Escape($SectionName)
    $sectionStart = -1
    for ($i = 0; $i -lt $mutableLines.Count; $i++) {
        if ($mutableLines[$i] -imatch $sectionHeaderPattern) {
            $sectionStart = $i
            break
        }
    }

    if ($sectionStart -lt 0) {
        if ($RemoveKeys) {
            return @{
                Lines   = $mutableLines.ToArray()
                Changed = $false
            }
        }

        if ($mutableLines.Count -gt 0 -and $mutableLines[$mutableLines.Count - 1] -ne '') {
            $null = $mutableLines.Add('')
        }

        $sectionStart = $mutableLines.Count
        $null = $mutableLines.Add("[{0}]" -f $SectionName)

        foreach ($entry in $KeyValueMap.GetEnumerator()) {
            $null = $mutableLines.Add('{0} = {1}' -f $entry.Key, $entry.Value)
        }

        return @{
            Lines   = $mutableLines.ToArray()
            Changed = $true
        }
    }

    $sectionEnd = $mutableLines.Count
    for ($i = $sectionStart + 1; $i -lt $mutableLines.Count; $i++) {
        if ($mutableLines[$i] -match '^\s*\[.+\]\s*$') {
            $sectionEnd = $i
            break
        }
    }

    $changed = $false

    foreach ($entry in $KeyValueMap.GetEnumerator()) {
        $key = [string]$entry.Key
        $value = [string]$entry.Value
        $keyPattern = '^\s*{0}\s*=' -f [regex]::Escape($key)
        $matchingIndexes = [System.Collections.Generic.List[int]]::new()

        for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
            if ($mutableLines[$i] -imatch $keyPattern) {
                $null = $matchingIndexes.Add($i)
            }
        }

        if ($RemoveKeys) {
            for ($j = $matchingIndexes.Count - 1; $j -ge 0; $j--) {
                $mutableLines.RemoveAt($matchingIndexes[$j])
                $sectionEnd--
                $changed = $true
            }

            continue
        }

        $renderedLine = '{0} = {1}' -f $key, $value
        if ($matchingIndexes.Count -gt 0) {
            if ($mutableLines[$matchingIndexes[0]] -cne $renderedLine) {
                $mutableLines[$matchingIndexes[0]] = $renderedLine
                $changed = $true
            }

            for ($j = $matchingIndexes.Count - 1; $j -ge 1; $j--) {
                $mutableLines.RemoveAt($matchingIndexes[$j])
                $sectionEnd--
                $changed = $true
            }

            continue
        }

        $mutableLines.Insert($sectionEnd, $renderedLine)
        $sectionEnd++
        $changed = $true
    }

    return @{
        Lines   = $mutableLines.ToArray()
        Changed = $changed
    }
}

function Set-GpoSystemAccessValues {
    param(
        [Parameter(Mandatory)]
        [string]$InfPath,

        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$KeyValueMap,

        [switch]$RemoveKeys
    )

    $existingLines = if (Test-Path -LiteralPath $InfPath) {
        Get-Content -Path $InfPath -ErrorAction Stop
    }
    else {
        Get-InitialSecurityTemplateLines
    }

    $result = Update-InfSectionKeyValues -Lines $existingLines -SectionName 'System Access' -KeyValueMap $KeyValueMap -RemoveKeys:$RemoveKeys

    if (-not $result.Changed) {
        return $false
    }

    $parentPath = Split-Path -Path $InfPath -Parent
    $null = New-Item -Path $parentPath -ItemType Directory -Force
    Set-Content -Path $InfPath -Value $result.Lines -Encoding Unicode
    return $true
}

function Set-GptIniVersion {
    param(
        [Parameter(Mandatory)]
        [string]$GptIniPath,

        [Parameter(Mandatory)]
        [int]$Version
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $GptIniPath) {
        foreach ($line in (Get-Content -Path $GptIniPath -ErrorAction Stop)) {
            $null = $lines.Add([string]$line)
        }
    }

    if ($lines.Count -eq 0) {
        $null = $lines.Add('[General]')
        $null = $lines.Add('Version={0}' -f $Version)
        Set-Content -Path $GptIniPath -Value $lines.ToArray() -Encoding ASCII
        return
    }

    $generalHeaderIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -imatch '^\s*\[General\]\s*$') {
            $generalHeaderIndex = $i
            break
        }
    }

    if ($generalHeaderIndex -lt 0) {
        $lines.Insert(0, '[General]')
        $generalHeaderIndex = 0
    }

    $insertIndex = $lines.Count
    for ($i = $generalHeaderIndex + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[.+\]\s*$') {
            $insertIndex = $i
            break
        }
    }

    $versionLineIndex = -1
    for ($i = $generalHeaderIndex + 1; $i -lt $insertIndex; $i++) {
        if ($lines[$i] -imatch '^\s*Version\s*=') {
            $versionLineIndex = $i
            break
        }
    }

    $renderedVersion = 'Version={0}' -f $Version
    if ($versionLineIndex -ge 0) {
        $lines[$versionLineIndex] = $renderedVersion
    }
    else {
        $lines.Insert($generalHeaderIndex + 1, $renderedVersion)
    }

    $parentPath = Split-Path -Path $GptIniPath -Parent
    $null = New-Item -Path $parentPath -ItemType Directory -Force
    Set-Content -Path $GptIniPath -Value $lines.ToArray() -Encoding ASCII
}

function Get-GptIniVersion {
    param(
        [Parameter(Mandatory)]
        [string]$GptIniPath
    )

    if (-not (Test-Path -LiteralPath $GptIniPath)) {
        return 0
    }

    foreach ($line in (Get-Content -Path $GptIniPath -ErrorAction Stop)) {
        if ($line -match '^\s*Version\s*=\s*(\d+)\s*$') {
            return [int]$matches[1]
        }
    }

    return 0
}

function Get-NextMachineVersionNumber {
    param(
        [Parameter(Mandatory)]
        [int]$CurrentVersion
    )

    $machineVersion = ($CurrentVersion -shr 16) -band 0xFFFF
    $userVersion = $CurrentVersion -band 0xFFFF
    $machineVersion++

    if ($machineVersion -gt 0xFFFF) {
        $machineVersion = 1
    }

    return (($machineVersion -shl 16) -bor $userVersion)
}

function Update-GpoMachineVersion {
    param(
        [Parameter(Mandatory)]
        [guid]$GpoId,

        [Parameter(Mandatory)]
        [string]$DomainDistinguishedName,

        [Parameter(Mandatory)]
        [string]$Server
    )

    $gpoAdObject = Get-GpoAdObject -GpoId $GpoId -DomainDistinguishedName $DomainDistinguishedName -Server $Server
    $gptIniPath = Join-Path -Path $gpoAdObject.gPCFileSysPath -ChildPath 'GPT.INI'
    $currentFileVersion = Get-GptIniVersion -GptIniPath $gptIniPath
    $currentAdVersion = if ($null -ne $gpoAdObject.versionNumber) { [int]$gpoAdObject.versionNumber } else { 0 }
    $newVersion = Get-NextMachineVersionNumber -CurrentVersion ([Math]::Max($currentFileVersion, $currentAdVersion))

    Set-GptIniVersion -GptIniPath $gptIniPath -Version $newVersion
    Set-ADObject -Identity $gpoAdObject.DistinguishedName -Server $Server -Replace @{ versionNumber = $newVersion } -ErrorAction Stop
}

function Get-SecurityExtensionPair {
    param(
        [string]$ExtensionNames
    )

    if ([string]::IsNullOrWhiteSpace($ExtensionNames)) {
        return $null
    }

    foreach ($match in [regex]::Matches($ExtensionNames, '\[(\{[0-9A-F\-]+\})(\{[0-9A-F\-]+\})\]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        if ($match.Groups[1].Value -ieq '{827D319E-6EAC-11D2-A4EA-00C04F79F83A}') {
            return $match.Value.ToUpperInvariant()
        }
    }

    return $null
}

function Ensure-GpoSecurityExtensionRegistration {
    param(
        [Parameter(Mandatory)]
        [guid]$TargetGpoId,

        [Parameter(Mandatory)]
        [guid]$SourceGpoId,

        [Parameter(Mandatory)]
        [string]$DomainDistinguishedName,

        [Parameter(Mandatory)]
        [string]$Server
    )

    $targetAdObject = Get-GpoAdObject -GpoId $TargetGpoId -DomainDistinguishedName $DomainDistinguishedName -Server $Server
    $targetExtensionNames = [string]$targetAdObject.gPCMachineExtensionNames
    if (Get-SecurityExtensionPair -ExtensionNames $targetExtensionNames) {
        return $false
    }

    $sourceAdObject = Get-GpoAdObject -GpoId $SourceGpoId -DomainDistinguishedName $DomainDistinguishedName -Server $Server
    $securityPair = Get-SecurityExtensionPair -ExtensionNames ([string]$sourceAdObject.gPCMachineExtensionNames)
    if (-not $securityPair) {
        $securityPair = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
    }

    $newExtensionNames = if ([string]::IsNullOrWhiteSpace($targetExtensionNames)) {
        $securityPair
    }
    else {
        '{0}{1}' -f $targetExtensionNames, $securityPair
    }

    Set-ADObject -Identity $targetAdObject.DistinguishedName -Server $Server -Replace @{ gPCMachineExtensionNames = $newExtensionNames } -ErrorAction Stop
    return $true
}

function Get-GpoSystemAccessSummary {
    param(
        [Parameter(Mandatory)]
        [string]$InfPath,

        [Parameter(Mandatory)]
        [string[]]$Keys
    )

    $summary = [ordered]@{}
    foreach ($key in $Keys) {
        $summary[$key] = 'Not defined'
    }

    if (-not (Test-Path -LiteralPath $InfPath)) {
        return [pscustomobject]$summary
    }

    $currentSection = $null
    foreach ($line in (Get-Content -Path $InfPath -ErrorAction Stop)) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $currentSection = $matches[1]
            continue
        }

        if ($currentSection -ine 'System Access') {
            continue
        }

        if ($line -match '^\s*([^=]+?)\s*=\s*(.+?)\s*$') {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim()
            if ($summary.Contains($name)) {
                $summary[$name] = $value
            }
        }
    }

    return [pscustomobject]$summary
}

# --- Resolve domain and preferred DC target ---
$domain = Get-ADDomain -ErrorAction Stop
$localDc = $null
try {
    $localDc = Get-ADDomainController -Identity $env:COMPUTERNAME -ErrorAction Stop
}
catch {
    $localDc = $null
}

$pdcHost = $domain.PDCEmulator
$policyServer = $pdcHost

if (-not $SkipPdcCheck) {
    if (-not $localDc) {
        throw "This machine is not a domain controller. PDC is: $pdcHost. Run this script there or use -SkipPdcCheck intentionally."
    }

    $isPdc = $localDc.OperationMasterRoles -contains 'PDCEmulator'
    if (-not $isPdc) {
        throw "This machine is not the PDC Emulator. PDC is: $pdcHost. Run this script there (or use -SkipPdcCheck intentionally)."
    }

    $policyServer = $localDc.HostName
    Write-Host "Running on PDC Emulator: $($localDc.HostName)" -ForegroundColor Green
}
else {
    if ($localDc) {
        Write-Host "Skipping PDC Emulator check by request. Targeting PDC: $pdcHost" -ForegroundColor Yellow
    }
    else {
        Write-Host "This machine is not a domain controller. Skipping PDC Emulator check by request and targeting PDC: $pdcHost" -ForegroundColor Yellow
    }
}

$defaultDomainPolicyName = 'Default Domain Policy'
$winlogonKey = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$winlogonValueName = 'PasswordExpiryWarning'

$systemAccessValues = [ordered]@{
    MaximumPasswordAge   = $MaxPasswordAgeDays
    MinimumPasswordAge   = $MinPasswordAgeDays
    MinimumPasswordLength = $MinPasswordLength
    PasswordHistorySize  = $PasswordHistoryCount
    PasswordComplexity   = if ($ComplexityEnabled) { 1 } else { 0 }
    ClearTextPassword    = 0
}

$systemAccessKeys = @($systemAccessValues.Keys)

# --- Ensure GPOs exist and dedicated GPO is linked at highest precedence ---
$defaultDomainPolicy = Get-GPO -Name $defaultDomainPolicyName -Domain $domain.DNSRoot -Server $policyServer -ErrorAction Stop
$strongPasswordGpo = Get-GPO -Name $StrongPasswordGpoName -Domain $domain.DNSRoot -Server $policyServer -ErrorAction SilentlyContinue

if (-not $strongPasswordGpo) {
    if ($PSCmdlet.ShouldProcess($StrongPasswordGpoName, 'Create dedicated strong-password GPO')) {
        $strongPasswordGpo = New-GPO `
            -Name $StrongPasswordGpoName `
            -Comment 'Dedicated domain-root password policy GPO managed by strong-password-techcare.ps1' `
            -Domain $domain.DNSRoot `
            -Server $policyServer

        Write-Host "Created GPO '$StrongPasswordGpoName'." -ForegroundColor Green
    }
    else {
        throw "Dedicated GPO '$StrongPasswordGpoName' does not exist and creation was skipped."
    }
}

$domainTarget = $domain.DistinguishedName
$inheritance = Get-GPInheritance -Target $domainTarget -Domain $domain.DNSRoot -Server $policyServer -ErrorAction Stop
$existingStrongLink = $inheritance.GpoLinks | Where-Object { $_.DisplayName -eq $StrongPasswordGpoName } | Select-Object -First 1

if ($existingStrongLink) {
    if ($PSCmdlet.ShouldProcess($StrongPasswordGpoName, 'Recreate domain-root link at precedence order 1')) {
        Remove-GPLink -Guid $strongPasswordGpo.Id -Target $domainTarget -Domain $domain.DNSRoot -Server $policyServer
        New-GPLink -Guid $strongPasswordGpo.Id -Target $domainTarget -Domain $domain.DNSRoot -Server $policyServer -LinkEnabled Yes -Order 1 | Out-Null
        Write-Host "Moved '$StrongPasswordGpoName' to domain link order 1." -ForegroundColor Green
    }
}
else {
    if ($PSCmdlet.ShouldProcess($StrongPasswordGpoName, 'Link dedicated GPO to the domain root at precedence order 1')) {
        New-GPLink -Guid $strongPasswordGpo.Id -Target $domainTarget -Domain $domain.DNSRoot -Server $policyServer -LinkEnabled Yes -Order 1 | Out-Null
        Write-Host "Linked '$StrongPasswordGpoName' to the domain root at order 1." -ForegroundColor Green
    }
}

# --- Ensure the dedicated GPO is registered for security settings processing ---
if ($PSCmdlet.ShouldProcess($StrongPasswordGpoName, 'Ensure security settings extension registration')) {
    $extensionUpdated = Ensure-GpoSecurityExtensionRegistration `
        -TargetGpoId $strongPasswordGpo.Id `
        -SourceGpoId $defaultDomainPolicy.Id `
        -DomainDistinguishedName $domain.DistinguishedName `
        -Server $policyServer

    if ($extensionUpdated) {
        Write-Host "Registered the security settings client-side extension on '$StrongPasswordGpoName'." -ForegroundColor Green
    }
}

# --- Apply password policy settings to the dedicated GPO security template ---
$strongGpoAdObject = Get-GpoAdObject -GpoId $strongPasswordGpo.Id -DomainDistinguishedName $domain.DistinguishedName -Server $policyServer
$strongGpoInfPath = Join-Path -Path $strongGpoAdObject.gPCFileSysPath -ChildPath 'MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf'

if ($PSCmdlet.ShouldProcess($StrongPasswordGpoName, 'Write password policy settings to GptTmpl.inf')) {
    $strongGpoChanged = Set-GpoSystemAccessValues -InfPath $strongGpoInfPath -KeyValueMap $systemAccessValues
    if ($strongGpoChanged) {
        Update-GpoMachineVersion -GpoId $strongPasswordGpo.Id -DomainDistinguishedName $domain.DistinguishedName -Server $policyServer
        Write-Host ("Configured {0} password settings in '{1}'." -f $systemAccessKeys.Count, $StrongPasswordGpoName) -ForegroundColor Green
    }
    else {
        Write-Host "Password settings in '$StrongPasswordGpoName' were already in the desired state." -ForegroundColor Yellow
    }
}

# --- Set password expiry warning in the dedicated GPO ---
if ($PSCmdlet.ShouldProcess($StrongPasswordGpoName, "Set $winlogonKey\$winlogonValueName = $PasswordExpiryWarningDays")) {
    Set-GPRegistryValue `
        -Name $StrongPasswordGpoName `
        -Domain $domain.DNSRoot `
        -Server $policyServer `
        -Key $winlogonKey `
        -ValueName $winlogonValueName `
        -Type DWord `
        -Value $PasswordExpiryWarningDays

    Write-Host "Set $StrongPasswordGpoName -> $winlogonKey\$winlogonValueName = $PasswordExpiryWarningDays." -ForegroundColor Green
}

# --- Clear competing settings from Default Domain Policy ---
$defaultGpoAdObject = Get-GpoAdObject -GpoId $defaultDomainPolicy.Id -DomainDistinguishedName $domain.DistinguishedName -Server $policyServer
$defaultGpoInfPath = Join-Path -Path $defaultGpoAdObject.gPCFileSysPath -ChildPath 'MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf'

if ($PSCmdlet.ShouldProcess($defaultDomainPolicyName, 'Remove overlapping password policy settings from GptTmpl.inf')) {
    $defaultGpoChanged = Set-GpoSystemAccessValues -InfPath $defaultGpoInfPath -KeyValueMap $systemAccessValues -RemoveKeys
    if ($defaultGpoChanged) {
        Update-GpoMachineVersion -GpoId $defaultDomainPolicy.Id -DomainDistinguishedName $domain.DistinguishedName -Server $policyServer
        Write-Host "Removed overlapping password settings from '$defaultDomainPolicyName'." -ForegroundColor Green
    }
    else {
        Write-Host "No overlapping password settings were defined in '$defaultDomainPolicyName'." -ForegroundColor Yellow
    }
}

if ($PSCmdlet.ShouldProcess($defaultDomainPolicyName, "Remove $winlogonKey\$winlogonValueName")) {
    try {
        $null = Get-GPRegistryValue `
            -Name $defaultDomainPolicyName `
            -Domain $domain.DNSRoot `
            -Server $policyServer `
            -Key $winlogonKey `
            -ValueName $winlogonValueName `
            -ErrorAction Stop

        Remove-GPRegistryValue `
            -Name $defaultDomainPolicyName `
            -Domain $domain.DNSRoot `
            -Server $policyServer `
            -Key $winlogonKey `
            -ValueName $winlogonValueName

        Write-Host "Removed $winlogonKey\$winlogonValueName from '$defaultDomainPolicyName'." -ForegroundColor Green
    }
    catch {
        Write-Host "$winlogonKey\$winlogonValueName is already not defined in '$defaultDomainPolicyName'." -ForegroundColor Yellow
    }
}

if (-not $NoVerify) {
    Write-Host "`nVerification:" -ForegroundColor Cyan

    $verificationInheritance = Get-GPInheritance -Target $domainTarget -Domain $domain.DNSRoot -Server $policyServer -ErrorAction Stop
    Write-Host "Domain-root GPO links:" -ForegroundColor Cyan
    $verificationInheritance.GpoLinks |
        Select-Object Order, DisplayName, Enabled, Enforced |
        Format-Table -AutoSize

    Write-Host "`nDedicated GPO password settings:" -ForegroundColor Cyan
    $strongGpoVerificationAdObject = Get-GpoAdObject -GpoId $strongPasswordGpo.Id -DomainDistinguishedName $domain.DistinguishedName -Server $policyServer
    $strongVerificationInfPath = Join-Path -Path $strongGpoVerificationAdObject.gPCFileSysPath -ChildPath 'MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf'
    Get-GpoSystemAccessSummary -InfPath $strongVerificationInfPath -Keys $systemAccessKeys | Format-List

    Write-Host "Dedicated GPO registry setting:" -ForegroundColor Cyan
    Get-GPRegistryValue `
        -Name $StrongPasswordGpoName `
        -Domain $domain.DNSRoot `
        -Server $policyServer `
        -Key $winlogonKey `
        -ValueName $winlogonValueName | Format-List

    Write-Host "Default Domain Policy competing password settings:" -ForegroundColor Cyan
    $defaultGpoVerificationAdObject = Get-GpoAdObject -GpoId $defaultDomainPolicy.Id -DomainDistinguishedName $domain.DistinguishedName -Server $policyServer
    $defaultVerificationInfPath = Join-Path -Path $defaultGpoVerificationAdObject.gPCFileSysPath -ChildPath 'MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf'
    Get-GpoSystemAccessSummary -InfPath $defaultVerificationInfPath -Keys $systemAccessKeys | Format-List

    Write-Host "Default Domain Policy registry setting:" -ForegroundColor Cyan
    try {
        Get-GPRegistryValue `
            -Name $defaultDomainPolicyName `
            -Domain $domain.DNSRoot `
            -Server $policyServer `
            -Key $winlogonKey `
            -ValueName $winlogonValueName `
            -ErrorAction Stop | Format-List
    }
    catch {
        if ($WhatIfPreference) {
            Write-Host "Not present (expected when running with -WhatIf because no changes were written)." -ForegroundColor Yellow
        }
        else {
            Write-Host 'Not defined.' -ForegroundColor Green
        }
    }
}
