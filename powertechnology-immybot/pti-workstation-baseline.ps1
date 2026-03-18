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
$script:PTIRebootRequired = $false
$script:PTIRebootReasons = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:PTIRebootMarkerPath = 'C:\ProgramData\PTI\State\pti-workstation-baseline.reboot.json'

function Get-PTILastBootTimeUtc {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return ([datetime]$os.LastBootUpTime).ToUniversalTime()
    }
    catch {
        return (Get-Date).ToUniversalTime()
    }
}

function Set-PTIRebootRequired {
    param(
        [string]$Reason
    )

    $script:PTIRebootRequired = $true
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $isNewReason = $script:PTIRebootReasons.Add($Reason)
        if ($isNewReason) {
            Write-PTILog -Message "Marked PTI baseline reboot-required: $Reason" -Level 'WARN' -LogPath $LogPath
        }
    }
}

function Clear-PTIRebootMarker {
    if (Test-Path -LiteralPath $script:PTIRebootMarkerPath) {
        Remove-Item -LiteralPath $script:PTIRebootMarkerPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-PTIRebootMarker {
    $markerDirectory = Split-Path -Path $script:PTIRebootMarkerPath -Parent
    Ensure-PTIDirectory -Path $markerDirectory

    $marker = [pscustomobject]@{
        RequestedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
        BootTimeAtRequestUtc = (Get-PTILastBootTimeUtc).ToString('o')
        Reasons            = @($script:PTIRebootReasons | Sort-Object)
    }

    $marker | ConvertTo-Json -Depth 4 | Set-Content -Path $script:PTIRebootMarkerPath -Encoding ASCII -Force
    Write-PTILog -Message "Wrote PTI reboot marker: $script:PTIRebootMarkerPath" -Level 'WARN' -LogPath $LogPath
}

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
        $commandMatch = [regex]::Match(
            $trimmed,
            '^(?<FilePath>.+?\.(?:exe|com|cmd|bat|msi))(?<Arguments>\s.*)?$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if ($commandMatch.Success) {
            $filePath = $commandMatch.Groups['FilePath'].Value.Trim()
            $arguments = $commandMatch.Groups['Arguments'].Value.Trim()
        }
        else {
            $segments = $trimmed -split '\s+', 2
            $filePath = $segments[0]
            $arguments = if ($segments.Count -gt 1) { $segments[1] } else { '' }
        }
    }

    if ($filePath -match '(?i)\.msi$') {
        $arguments = ('/x "{0}" {1}' -f $filePath, $arguments).Trim()

        if ($arguments -notmatch '(?i)/qn') {
            $arguments = ($arguments + ' /qn').Trim()
        }

        if ($arguments -notmatch '(?i)/norestart') {
            $arguments = ($arguments + ' /norestart').Trim()
        }

        $filePath = 'msiexec.exe'
    }
    elseif ($filePath -match '^(?i)msiexec(?:\.exe)?$') {
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

function Get-ProgramPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return [string]$property.Value
    }

    return $null
}

function Get-MsiProductCodeFromProgram {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Program
    )

    $guidPattern = '(?i)\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}'

    $windowsInstaller = Get-ProgramPropertyValue -InputObject $Program -Name 'WindowsInstaller'
    $psChildName = Get-ProgramPropertyValue -InputObject $Program -Name 'PSChildName'
    if ($windowsInstaller -eq '1' -and $psChildName -match "^$guidPattern$") {
        return $Matches[0]
    }

    foreach ($propertyName in @('QuietUninstallString', 'UninstallString')) {
        $commandLine = Get-ProgramPropertyValue -InputObject $Program -Name $propertyName
        if (-not [string]::IsNullOrWhiteSpace($commandLine) -and $commandLine -match $guidPattern) {
            return $Matches[0]
        }
    }

    return $null
}

function Get-InstalledProgramMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$DisplayNamePatterns
    )

    return @(
        Get-PTIInstalledPrograms | Where-Object {
            $displayName = $_.DisplayName
            foreach ($pattern in $DisplayNamePatterns) {
                if ($displayName -match $pattern) {
                    return $true
                }
            }

            return $false
        }
    )
}

function Test-ProgramStillInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Program
    )

    $programKey = Get-ProgramPropertyValue -InputObject $Program -Name 'PSChildName'
    $programName = Get-ProgramPropertyValue -InputObject $Program -Name 'DisplayName'

    $matches = @(
        Get-PTIInstalledPrograms | Where-Object {
            $candidateKey = Get-ProgramPropertyValue -InputObject $_ -Name 'PSChildName'
            $candidateName = Get-ProgramPropertyValue -InputObject $_ -Name 'DisplayName'

            if (-not [string]::IsNullOrWhiteSpace($programKey) -and -not [string]::IsNullOrWhiteSpace($candidateKey)) {
                return $candidateKey -eq $programKey
            }

            return $candidateName -eq $programName
        }
    )

    return ($matches.Count -gt 0)
}

function Wait-ForProgramUnregister {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Program,

        [int]$TimeoutSeconds = 45,

        [int]$PollSeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (-not (Test-ProgramStillInstalled -Program $Program)) {
            return $true
        }

        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)

    return (-not (Test-ProgramStillInstalled -Program $Program))
}

function Invoke-RawUninstallCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLine,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    $argumentList = '/d /s /c ""{0}""' -f $CommandLine
    $exitCode = Invoke-PTIProcess -FilePath 'cmd.exe' -ArgumentList $argumentList -WorkingDirectory $env:SystemRoot -LogPath $LogPath
    if ($exitCode -in @(1641, 3010)) {
        Set-PTIRebootRequired -Reason "Application uninstall requested reboot: $DisplayName"
    }

    return $exitCode
}

function Invoke-UninstallByDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$DisplayNamePatterns
    )

    $matches = @(Get-InstalledProgramMatches -DisplayNamePatterns $DisplayNamePatterns)

    foreach ($program in $matches) {
        $quietUninstall = Get-ProgramPropertyValue -InputObject $program -Name 'QuietUninstallString'
        $regularUninstall = Get-ProgramPropertyValue -InputObject $program -Name 'UninstallString'
        $msiProductCode = Get-MsiProductCodeFromProgram -Program $program

        if ([string]::IsNullOrWhiteSpace($quietUninstall) -and [string]::IsNullOrWhiteSpace($regularUninstall) -and [string]::IsNullOrWhiteSpace($msiProductCode)) {
            Write-PTILog -Message "No uninstall string found for [$($program.DisplayName)]." -Level 'WARN' -LogPath $LogPath
            continue
        }

        if ($PSCmdlet.ShouldProcess($program.DisplayName, 'Uninstall application')) {
            $attemptSucceeded = $false

            if (-not [string]::IsNullOrWhiteSpace($quietUninstall)) {
                try {
                    Write-PTILog -Message "Trying raw quiet uninstall string for [$($program.DisplayName)]." -LogPath $LogPath
                    Invoke-RawUninstallCommand -CommandLine $quietUninstall -DisplayName $program.DisplayName | Out-Null
                    if (Wait-ForProgramUnregister -Program $program -TimeoutSeconds 45 -PollSeconds 5) {
                        $attemptSucceeded = $true
                    }
                }
                catch {
                    Write-PTILog -Message "Quiet uninstall failed for [$($program.DisplayName)]: $($_.Exception.Message)" -Level 'WARN' -LogPath $LogPath
                }
            }

            if (-not $attemptSucceeded -and -not [string]::IsNullOrWhiteSpace($regularUninstall)) {
                $command = Convert-UninstallStringToCommand -CommandLine $regularUninstall
                if ($command) {
                    try {
                        $workingDirectory = if ([System.IO.Path]::IsPathRooted($command.FilePath)) {
                            Split-Path -Path $command.FilePath -Parent
                        }
                        else {
                            $env:SystemRoot
                        }

                        Write-PTILog -Message "Trying parsed uninstall command for [$($program.DisplayName)]." -LogPath $LogPath
                        $exitCode = Invoke-PTIProcess -FilePath $command.FilePath -ArgumentList $command.ArgumentList -WorkingDirectory $workingDirectory -LogPath $LogPath
                        if ($exitCode -in @(1641, 3010)) {
                            Set-PTIRebootRequired -Reason "Application uninstall requested reboot: $($program.DisplayName)"
                        }

                        if (Wait-ForProgramUnregister -Program $program -TimeoutSeconds 45 -PollSeconds 5) {
                            $attemptSucceeded = $true
                        }
                    }
                    catch {
                        Write-PTILog -Message "Parsed uninstall failed for [$($program.DisplayName)]: $($_.Exception.Message)" -Level 'WARN' -LogPath $LogPath
                    }
                }
            }

            if (-not $attemptSucceeded -and -not [string]::IsNullOrWhiteSpace($msiProductCode)) {
                try {
                    Write-PTILog -Message "Trying MSI fallback uninstall for [$($program.DisplayName)] using product code [$msiProductCode]." -Level 'WARN' -LogPath $LogPath
                    $exitCode = Invoke-PTIProcess -FilePath 'msiexec.exe' -ArgumentList "/x $msiProductCode /qn /norestart REBOOT=ReallySuppress" -WorkingDirectory $env:SystemRoot -LogPath $LogPath
                    if ($exitCode -in @(1641, 3010)) {
                        Set-PTIRebootRequired -Reason "MSI fallback uninstall requested reboot: $($program.DisplayName)"
                    }

                    if (Wait-ForProgramUnregister -Program $program -TimeoutSeconds 45 -PollSeconds 5) {
                        $attemptSucceeded = $true
                    }
                }
                catch {
                    Write-PTILog -Message "MSI fallback uninstall failed for [$($program.DisplayName)]: $($_.Exception.Message)" -Level 'WARN' -LogPath $LogPath
                }
            }

            if (-not $attemptSucceeded -and (Test-ProgramStillInstalled -Program $program)) {
                Write-PTILog -Message "Application still appears installed after all uninstall attempts: [$($program.DisplayName)]." -Level 'WARN' -LogPath $LogPath
            }
        }
    }
}

function Invoke-PTIDirectMsiUninstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [Parameter(Mandatory = $true)]
        [string]$ProductCode
    )

    Write-PTILog -Message "Trying direct MSI uninstall for [$DisplayName] using [$ProductCode]." -LogPath $LogPath
    $exitCode = Invoke-PTIProcess -FilePath 'msiexec.exe' -ArgumentList "/x $ProductCode /qn /norestart REBOOT=ReallySuppress" -WorkingDirectory $env:SystemRoot -LogPath $LogPath
    if ($exitCode -in @(1641, 3010)) {
        Set-PTIRebootRequired -Reason "Direct MSI uninstall requested reboot: $DisplayName"
    }

    return $exitCode
}

function Remove-PTIDellPackageTargets {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$DisplayNamePatterns,

        [string[]]$AppxPatterns = @()
    )

    $matches = @(Get-InstalledProgramMatches -DisplayNamePatterns $DisplayNamePatterns)
    foreach ($program in $matches) {
        $displayName = Get-ProgramPropertyValue -InputObject $program -Name 'DisplayName'
        $msiProductCode = Get-MsiProductCodeFromProgram -Program $program

        $removed = $false
        if (-not [string]::IsNullOrWhiteSpace($msiProductCode)) {
            try {
                Invoke-PTIDirectMsiUninstall -DisplayName $displayName -ProductCode $msiProductCode | Out-Null
                if (Wait-ForProgramUnregister -Program $program -TimeoutSeconds 90 -PollSeconds 5) {
                    $removed = $true
                }
            }
            catch {
                Write-PTILog -Message "Direct MSI uninstall failed for [$displayName]: $($_.Exception.Message)" -Level 'WARN' -LogPath $LogPath
            }
        }

        if (-not $removed -and (Test-ProgramStillInstalled -Program $program)) {
            Invoke-UninstallByDisplayName -DisplayNamePatterns @('(?i)^' + [regex]::Escape($displayName) + '$')
        }
    }

    if ($AppxPatterns.Count -gt 0) {
        Remove-AppxFamilies -PackagePatterns $AppxPatterns
    }
}

function Wait-PTIProgramRemoval {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$DisplayNamePatterns,

        [int]$TimeoutSeconds = 90,

        [int]$PollSeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $remaining = @(Get-InstalledProgramMatches -DisplayNamePatterns $DisplayNamePatterns | Select-Object -ExpandProperty DisplayName -Unique)
        if ($remaining.Count -eq 0) {
            return $true
        }

        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)

    return $false
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

function Remove-PTIDellBloatware {
    $dellPatterns = @(
        '(?i)^Dell Optimizer(?: Service)?\b',
        '(?i)^Dell SupportAssist\b',
        '(?i)^Dell SupportAssist OS Recovery\b',
        '(?i)^Dell SupportAssist OS Recovery Plugin\b',
        '(?i)^Dell SupportAssist Remediation\b',
        '(?i)^Dell Digital Delivery\b',
        '(?i)^Dell Customer Connect\b',
        '(?i)^Dell Update(?: for Windows)?\b',
        '(?i)^Dell Command \| Update\b',
        '(?i)^Dell Core Services\b',
        '(?i)^My Dell\b',
        '(?i)^Dell TechHub\b',
        '(?i)^Dell Power Manager\b'
    )

    $serviceNamePatterns = @(
        '(?i)^DellClientManagementService$',
        '(?i)^DellDigitalDelivery$',
        '(?i)^SupportAssistAgent$',
        '(?i)^Dell\.?TechHub',
        '(?i)^DellDataVault',
        '(?i)^Dell SupportAssist(?: Remediation)?$'
    )

    $serviceDisplayNamePatterns = @(
        '(?i)^Dell Client Management Service$',
        '(?i)^Dell Data Vault Collector$',
        '(?i)^Dell Data Vault Processor$',
        '(?i)^Dell Data Vault Service API$',
        '(?i)^Dell Digital Delivery Service$',
        '(?i)^Dell SupportAssist$',
        '(?i)^Dell SupportAssist Remediation$',
        '(?i)^Dell TechHub$'
    )

    foreach ($service in @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        foreach ($pattern in $serviceNamePatterns) {
            if ($_.Name -match $pattern) {
                return $true
            }
        }

        foreach ($pattern in $serviceDisplayNamePatterns) {
            if ($_.DisplayName -match $pattern) {
                return $true
            }
        }

        return $false
    })) {
        try {
            if ($service.State -eq 'Running') {
                Write-PTILog -Message "Stopping Dell service [$($service.Name)] prior to uninstall." -LogPath $LogPath
                Stop-Service -Name $service.Name -Force -ErrorAction Stop
            }
        }
        catch {
            Write-PTILog -Message "Failed to stop Dell service [$($service.Name)]: $($_.Exception.Message)" -Level 'WARN' -LogPath $LogPath
        }

        try {
            Set-Service -Name $service.Name -StartupType Disabled -ErrorAction SilentlyContinue
        }
        catch {
        }
    }

    foreach ($processName in @(
        'SupportAssist',
        'SupportAssistAgent',
        'SupportAssistRemediationService',
        'DellSupportAssistRemediationService',
        'DellSupportAssistRemediation',
        'DeliveryService',
        'DellTechHub',
        'ServiceShell',
        'DellDataVault',
        'DellDataVaultWiz',
        'DellDataVaultSvcApi'
    )) {
        Get-Process -Name $processName -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Write-PTILog -Message "Stopping Dell process [$($_.ProcessName)] (PID $($_.Id)) prior to uninstall." -LogPath $LogPath
                Stop-Process -Id $_.Id -Force -ErrorAction Stop
            }
            catch {
                Write-PTILog -Message "Failed to stop Dell process [$($_.ProcessName)] (PID $($_.Id)): $($_.Exception.Message)" -Level 'WARN' -LogPath $LogPath
            }
        }
    }

    $dellRemovalPlan = @(
        @{
            Name = 'Dell SupportAssist'
            DisplayNamePatterns = @('(?i)^Dell SupportAssist$')
            AppxPatterns = @('Dell.SupportAssistforPCs')
        },
        @{
            Name = 'Dell SupportAssist Remediation'
            DisplayNamePatterns = @('(?i)^Dell SupportAssist Remediation$')
        },
        @{
            Name = 'Dell SupportAssist OS Recovery Plugin for Dell Update'
            DisplayNamePatterns = @('(?i)^Dell SupportAssist OS Recovery Plugin for Dell Update$')
        },
        @{
            Name = 'Dell Digital Delivery'
            DisplayNamePatterns = @('(?i)^Dell Digital Delivery$')
        },
        @{
            Name = 'Dell Core Services'
            DisplayNamePatterns = @('(?i)^Dell Core Services$')
        },
        @{
            Name = 'Dell Command | Update'
            DisplayNamePatterns = @('(?i)^Dell Command \| Update$')
            AppxPatterns = @('DellInc.DellCommandUpdate')
        },
        @{
            Name = 'Other Dell bloatware'
            DisplayNamePatterns = @(
                '(?i)^Dell Optimizer(?: Service)?\b',
                '(?i)^Dell SupportAssist OS Recovery\b',
                '(?i)^Dell Customer Connect\b',
                '(?i)^Dell Update(?: for Windows)?\b',
                '(?i)^My Dell\b',
                '(?i)^Dell TechHub\b',
                '(?i)^Dell Power Manager\b'
            )
        }
    )

    Write-PTILog -Message 'Running PTI Dell application removal pass.' -LogPath $LogPath
    foreach ($packageGroup in $dellRemovalPlan) {
        Write-PTILog -Message "Processing Dell removal group [$($packageGroup.Name)]." -LogPath $LogPath
        Remove-PTIDellPackageTargets -DisplayNamePatterns $packageGroup.DisplayNamePatterns -AppxPatterns $packageGroup.AppxPatterns
    }

    if (-not (Wait-PTIProgramRemoval -DisplayNamePatterns $dellPatterns -TimeoutSeconds 60 -PollSeconds 5)) {
        $remainingDellApps = @(Get-InstalledProgramMatches -DisplayNamePatterns $dellPatterns | Select-Object -ExpandProperty DisplayName -Unique)
        if ($remainingDellApps.Count -gt 0) {
            Write-PTILog -Message ("Dell applications still detected after first pass: {0}" -f ($remainingDellApps -join '; ')) -Level 'WARN' -LogPath $LogPath
            Write-PTILog -Message 'Retrying PTI Dell application removal pass.' -Level 'WARN' -LogPath $LogPath
            Invoke-UninstallByDisplayName -DisplayNamePatterns $dellPatterns
            $null = Wait-PTIProgramRemoval -DisplayNamePatterns $dellPatterns -TimeoutSeconds 60 -PollSeconds 5
        }
    }

    $finalRemainingDellApps = @(Get-InstalledProgramMatches -DisplayNamePatterns $dellPatterns | Select-Object -ExpandProperty DisplayName -Unique)
    if ($finalRemainingDellApps.Count -gt 0) {
        Set-PTIRebootRequired -Reason ("Dell applications still registered after cleanup and may clear after reboot: {0}" -f ($finalRemainingDellApps -join '; '))
        Write-PTILog -Message ("Dell applications remain registered after cleanup: {0}" -f ($finalRemainingDellApps -join '; ')) -Level 'WARN' -LogPath $LogPath
    }
    else {
        Write-PTILog -Message 'No Dell applications remain after PTI cleanup.' -LogPath $LogPath
    }
}

function Update-PTIRebootState {
    if ($script:PTIRebootRequired) {
        Set-PTIRebootMarker
    }
    else {
        Clear-PTIRebootMarker
        Write-PTILog -Message 'No reboot required marker remains for PTI baseline.' -LogPath $LogPath
    }
}

function Invoke-PTIOneDriveUninstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath
    )

    $exitCode = Invoke-PTIProcess -FilePath $InstallerPath -ArgumentList '/uninstall' -WorkingDirectory (Split-Path -Path $InstallerPath -Parent) -LogPath $LogPath
    if ($exitCode -in @(1641, 3010)) {
        Set-PTIRebootRequired -Reason "OneDrive uninstall requested reboot: $InstallerPath"
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
                Invoke-PTIOneDriveUninstall -InstallerPath $oneDriveSetup
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
            try {
                & $dellCleanupScript
            }
            catch {
                Write-PTILog -Message "Dell cleanup helper failed but PTI targeted cleanup will continue: $($_.Exception.Message)" -Level 'WARN' -LogPath $LogPath
            }
        }
    }
    else {
        Write-PTILog -Message "Dell cleanup helper not found: $dellCleanupScript" -Level 'WARN' -LogPath $LogPath
    }

    Remove-PTIDellBloatware
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

Update-PTIRebootState
Write-PTILog -Message 'PTI workstation baseline completed.' -LogPath $LogPath

[pscustomobject]@{
    ConsumerBloatwareRemoved = (-not $SkipConsumerBloatwareRemoval)
    CortanaDisabled          = (-not $SkipCortanaDisable)
    OneDriveDisabled         = (-not $SkipOneDriveRemoval)
    DellCleanupAttempted     = (-not $SkipDellCleanup)
    RemoteAssistanceEnabled  = (-not $SkipRemoteAssistance)
    SecurityRemovalEnabled   = ($EnableUnauthorizedSecurityRemoval -and $ApprovedSecurityProducts.Count -gt 0 -and -not $SkipUnauthorizedSecurityRemoval)
    RebootRequired           = $script:PTIRebootRequired
    RebootMarkerPath         = $script:PTIRebootMarkerPath
    LogPath                  = $LogPath
}
