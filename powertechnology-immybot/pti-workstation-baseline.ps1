#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$ApprovedSecurityProducts = @(),

    [switch]$EnableUnauthorizedSecurityRemoval,

    [switch]$SkipUnauthorizedSecurityRemoval,

    [switch]$SkipDellCleanup,

    [switch]$SkipConsumerBloatwareRemoval,

    [switch]$SkipOneDriveRemoval,

    [switch]$SkipCortanaDisable,

    [switch]$SkipRemoteAssistance,

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-workstation-baseline.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'pti-common.ps1')
$script:PTICmdlet = $PSCmdlet

function Set-RegistryDwordValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [int]$Value
    )

    if ($script:PTICmdlet.ShouldProcess("$Path\$Name", "Set DWORD value to $Value")) {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }

        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
    }
}

function Convert-UninstallStringToCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLine
    )

    $trimmed = $CommandLine.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $null
    }

    if ($trimmed.StartsWith('"')) {
        $closingIndex = $trimmed.IndexOf('"', 1)
        if ($closingIndex -lt 1) {
            return $null
        }

        $filePath = $trimmed.Substring(1, $closingIndex - 1)
        $arguments = $trimmed.Substring($closingIndex + 1).Trim()
    }
    else {
        $segments = $trimmed -split '\s+', 2
        $filePath = $segments[0]
        $arguments = if ($segments.Count -gt 1) { $segments[1] } else { '' }
    }

    if ($filePath -match '^(?i)msiexec(?:\.exe)?$') {
        if ($arguments -notmatch '(?i)(^|\s)/x(\s|$)' -and $arguments -match '(?i)(^|\s)/i(\s|$)') {
            $arguments = [regex]::Replace($arguments, '(?i)(^|\s)/i(\s|$)', ' /x ')
        }

        if ($arguments -notmatch '(?i)/qn') {
            $arguments = ($arguments + ' /qn').Trim()
        }

        if ($arguments -notmatch '(?i)/norestart') {
            $arguments = ($arguments + ' /norestart').Trim()
        }

        $filePath = 'msiexec.exe'
    }
    elseif ($filePath -match '(?i)\\setup\.exe$' -and $arguments -notmatch '(?i)(/quiet|/silent|displaylevel=false)') {
        $arguments = ($arguments + ' /quiet /norestart').Trim()
    }
    elseif ($filePath -match '(?i)\\unins[^\\]*\.exe$' -and $arguments -notmatch '(?i)(/verysilent|/silent)') {
        $arguments = ($arguments + ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART').Trim()
    }

    return [pscustomobject]@{
        FilePath     = $filePath
        ArgumentList = $arguments
    }
}

function Invoke-UninstallByDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$DisplayNamePatterns
    )

    $matches = @(Get-PTIInstalledPrograms | Where-Object {
        $displayName = $_.DisplayName
        foreach ($pattern in $DisplayNamePatterns) {
            if ($displayName -match $pattern) {
                return $true
            }
        }

        return $false
    })

    foreach ($program in $matches) {
        $commandLine = if (-not [string]::IsNullOrWhiteSpace($program.QuietUninstallString)) {
            $program.QuietUninstallString
        }
        else {
            $program.UninstallString
        }

        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            Write-PTILog -Message "No uninstall string found for [$($program.DisplayName)]." -Level 'WARN' -LogPath $LogPath
            continue
        }

        $command = Convert-UninstallStringToCommand -CommandLine $commandLine
        if (-not $command) {
            Write-PTILog -Message "Could not parse uninstall command for [$($program.DisplayName)]." -Level 'WARN' -LogPath $LogPath
            continue
        }

        if ($PSCmdlet.ShouldProcess($program.DisplayName, 'Uninstall application')) {
            try {
                Invoke-PTIProcess -FilePath $command.FilePath -ArgumentList $command.ArgumentList -WorkingDirectory (Split-Path -Path $command.FilePath -Parent) -LogPath $LogPath | Out-Null
            }
            catch {
                Write-PTILog -Message "Uninstall failed for [$($program.DisplayName)]: $($_.Exception.Message)" -Level 'WARN' -LogPath $LogPath
            }
        }
    }
}

function Remove-AppxFamilies {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$PackagePatterns
    )

    foreach ($pattern in $PackagePatterns) {
        $installedPackages = @(Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue)
        foreach ($package in $installedPackages) {
            if ($PSCmdlet.ShouldProcess($package.Name, 'Remove AppX package for all users')) {
                try {
                    Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
                    Write-PTILog -Message "Removed AppX package [$($package.Name)] for all users." -LogPath $LogPath
                }
                catch {
                    Write-PTILog -Message "Failed to remove AppX package [$($package.Name)]: $($_.Exception.Message)" -Level 'WARN' -LogPath $LogPath
                }
            }
        }

        $provisionedPackages = @(Get-AppxProvisionedPackage -Online | Where-Object {
            $_.DisplayName -like $pattern
        })
        foreach ($package in $provisionedPackages) {
            if ($PSCmdlet.ShouldProcess($package.DisplayName, 'Remove provisioned AppX package')) {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null
                    Write-PTILog -Message "Removed provisioned AppX package [$($package.DisplayName)]." -LogPath $LogPath
                }
                catch {
                    Write-PTILog -Message "Failed to remove provisioned AppX package [$($package.DisplayName)]: $($_.Exception.Message)" -Level 'WARN' -LogPath $LogPath
                }
            }
        }
    }
}

function Install-PTIPerUserOneDriveCleanup {
    $scriptDirectory = 'C:\ProgramData\PTI\Scripts'
    $scriptPath = Join-Path -Path $scriptDirectory -ChildPath 'pti-onedrive-per-user.ps1'

    $scriptContent = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Test-Path -LiteralPath $runKey) {
    Remove-ItemProperty -Path $runKey -Name 'OneDrive' -ErrorAction SilentlyContinue
}

$oneDriveKey = 'HKCU:\Software\Microsoft\OneDrive'
New-Item -Path $oneDriveKey -Force | Out-Null
New-ItemProperty -Path $oneDriveKey -Name 'DisableTutorial' -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $oneDriveKey -Name 'PreventNetworkTrafficPreUserSignIn' -Value 1 -PropertyType DWord -Force | Out-Null
Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
'@

    if ($script:PTICmdlet.ShouldProcess($scriptPath, 'Install per-user OneDrive cleanup script and Active Setup entry')) {
        Ensure-PTIDirectory -Path $scriptDirectory
        Set-Content -Path $scriptPath -Value $scriptContent -Encoding ASCII -Force

        $activeSetupPath = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\PTI-OneDriveCleanup'
        New-Item -Path $activeSetupPath -Force | Out-Null
        New-ItemProperty -Path $activeSetupPath -Name 'Version' -Value '1,0,0,0' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $activeSetupPath -Name 'StubPath' -Value ("powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $scriptPath) -PropertyType String -Force | Out-Null
    }
}

function Disable-PTIOneDrive {
    $oneDrivePolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
    Set-RegistryDwordValue -Path $oneDrivePolicyPath -Name 'DisableFileSyncNGSC' -Value 1
    Set-RegistryDwordValue -Path $oneDrivePolicyPath -Name 'DisableLibrariesDefaultSaveToOneDrive' -Value 1
    Set-RegistryDwordValue -Path $oneDrivePolicyPath -Name 'DisablePersonalSync' -Value 1
    Set-RegistryDwordValue -Path $oneDrivePolicyPath -Name 'PreventNetworkTrafficPreUserSignIn' -Value 1

    if ($script:PTICmdlet.ShouldProcess('OneDrive.exe', 'Stop OneDrive processes')) {
        Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    foreach ($task in @(Get-ScheduledTask -TaskName 'OneDrive*' -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($task.TaskName, 'Disable OneDrive scheduled task')) {
            Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Out-Null
        }
    }

    foreach ($oneDriveSetup in @(
        (Join-Path -Path $env:SystemRoot -ChildPath 'System32\OneDriveSetup.exe'),
        (Join-Path -Path $env:SystemRoot -ChildPath 'SysWOW64\OneDriveSetup.exe')
    )) {
        if ((Test-Path -LiteralPath $oneDriveSetup) -and $PSCmdlet.ShouldProcess($oneDriveSetup, 'Uninstall OneDrive')) {
            try {
                Invoke-PTIProcess -FilePath $oneDriveSetup -ArgumentList '/uninstall' -WorkingDirectory (Split-Path -Path $oneDriveSetup -Parent) -LogPath $LogPath | Out-Null
            }
            catch {
                Write-PTILog -Message "OneDrive uninstall attempt failed from [$oneDriveSetup]: $($_.Exception.Message)" -Level 'WARN' -LogPath $LogPath
            }
        }
    }

    Install-PTIPerUserOneDriveCleanup
}

function Disable-PTICortana {
    Set-RegistryDwordValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'AllowCortana' -Value 0
    Set-RegistryDwordValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'DisableWebSearch' -Value 1
    Remove-AppxFamilies -PackagePatterns @('Microsoft.549981C3F5F10')
}

function Enable-PTIRemoteAssistance {
    Set-RegistryDwordValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' -Name 'fAllowToGetHelp' -Value 1
    Set-RegistryDwordValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fAllowToGetHelp' -Value 1
    if ($script:PTICmdlet.ShouldProcess('Remote Assistance firewall group', 'Enable firewall rules')) {
        Enable-NetFirewallRule -DisplayGroup 'Remote Assistance' -ErrorAction SilentlyContinue | Out-Null
    }
}

Write-PTILog -Message 'Starting PTI workstation baseline.' -LogPath $LogPath

if (-not $SkipConsumerBloatwareRemoval) {
    Invoke-UninstallByDisplayName -DisplayNamePatterns @(
        '(?i)\bMicrosoft 365\b',
        '(?i)\bMicrosoft 365 Apps\b',
        '(?i)\bOffice 365\b',
        '(?i)^Microsoft Office Desktop Apps\b'
    )

    Remove-AppxFamilies -PackagePatterns @(
        'Microsoft.BingNews',
        'Microsoft.News',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.OutlookForWindows',
        'Microsoft.GamingApp',
        'Microsoft.Xbox.TCUI',
        'Microsoft.XboxApp',
        'Microsoft.XboxGameOverlay',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.MicrosoftOfficeHub'
    )
}

if (-not $SkipCortanaDisable) {
    Disable-PTICortana
}

if (-not $SkipOneDriveRemoval) {
    Disable-PTIOneDrive
}

if (-not $SkipDellCleanup) {
    $dellCleanupScript = Join-Path -Path $PSScriptRoot -ChildPath '..\dell-cleanup.ps1'
    if (Test-Path -LiteralPath $dellCleanupScript) {
        if ($PSCmdlet.ShouldProcess('Dell applications', 'Run Dell cleanup helper')) {
            & $dellCleanupScript
        }
    }
    else {
        Write-PTILog -Message "Dell cleanup helper not found: $dellCleanupScript" -Level 'WARN' -LogPath $LogPath
    }
}

if (-not $SkipUnauthorizedSecurityRemoval) {
    if ($EnableUnauthorizedSecurityRemoval -and $ApprovedSecurityProducts.Count -gt 0) {
        $securityScript = Join-Path -Path $PSScriptRoot -ChildPath 'pti-remove-unapproved-security.ps1'
        if (Test-Path -LiteralPath $securityScript) {
            & $securityScript -ApprovedProductPatterns $ApprovedSecurityProducts -LogPath $LogPath -WhatIf:$WhatIfPreference
        }
        else {
            Write-PTILog -Message "Security removal helper not found: $securityScript" -Level 'WARN' -LogPath $LogPath
        }
    }
    else {
        Write-PTILog -Message 'Skipping unauthorized security removal because the approved allowlist was not supplied.' -Level 'WARN' -LogPath $LogPath
    }
}

if (-not $SkipRemoteAssistance) {
    Enable-PTIRemoteAssistance
}

Write-PTILog -Message 'PTI workstation baseline completed.' -LogPath $LogPath

[pscustomobject]@{
    ConsumerBloatwareRemoved = (-not $SkipConsumerBloatwareRemoval)
    CortanaDisabled          = (-not $SkipCortanaDisable)
    OneDriveDisabled         = (-not $SkipOneDriveRemoval)
    DellCleanupAttempted     = (-not $SkipDellCleanup)
    RemoteAssistanceEnabled  = (-not $SkipRemoteAssistance)
    SecurityRemovalEnabled   = ($EnableUnauthorizedSecurityRemoval -and $ApprovedSecurityProducts.Count -gt 0 -and -not $SkipUnauthorizedSecurityRemoval)
    LogPath                  = $LogPath
}
