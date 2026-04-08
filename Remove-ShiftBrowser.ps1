[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$LogPath = 'C:\ProgramData\DattoRMM\Logs\Remove-ShiftBrowser.log',
    [int]$UninstallTimeoutSeconds = 120
)

<#
.SYNOPSIS
Quietly removes Shift Browser from a Windows endpoint.

.DESCRIPTION
Designed for Datto RMM components running as Local System. The script checks
machine-wide uninstall entries, loaded per-user uninstall entries, and common
per-user Shift install locations under each profile so it can remove Shift even
when the interactive user is not the one running the component.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Remove-ShiftBrowser.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SuccessExitCodes = @(0, 1641, 3010)
$script:RebootRequired = $false
$script:ShiftDisplayNamePattern = '(?i)^Shift(?: Browser)?(?:\s+[\w\.\- ].*)?$'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $directory = Split-Path -Path $LogPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogPath -Value $line
    Write-Host "[ShiftRemoval][$Level] $Message"
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OptionalPropertyValue {
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

function Convert-ToRegistryLiteralPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PSPath
    )

    if ($PSPath -match 'Registry::') {
        return 'Registry::' + ($PSPath -replace '^.*Registry::', '')
    }

    return $PSPath
}

function Test-IsShiftUninstallEntry {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Entry
    )

    $displayName = Get-OptionalPropertyValue -InputObject $Entry -Name 'DisplayName'
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        return $false
    }

    if ($displayName -match '(?i)^Shift Browser(?:\s+[\w\.\- ].*)?$') {
        return $true
    }

    $publisher = Get-OptionalPropertyValue -InputObject $Entry -Name 'Publisher'
    $installLocation = Get-OptionalPropertyValue -InputObject $Entry -Name 'InstallLocation'
    $displayIcon = Get-OptionalPropertyValue -InputObject $Entry -Name 'DisplayIcon'
    $quietUninstallString = Get-OptionalPropertyValue -InputObject $Entry -Name 'QuietUninstallString'
    $uninstallString = Get-OptionalPropertyValue -InputObject $Entry -Name 'UninstallString'

    if ($displayName -notmatch $script:ShiftDisplayNamePattern) {
        return $false
    }

    if ($publisher -match '(?i)\bShift\b') {
        return $true
    }

    $pathSignals = @($installLocation, $displayIcon, $quietUninstallString, $uninstallString) -join ' '

    if (
        $pathSignals -match '(?i)\\Shift(?: Browser)?(?:\\|\.exe|\s|")'
    ) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($publisher) -and $displayName -match '(?i)^Shift$') {
        return $true
    }

    return $false
}

function Get-MsiProductCodeFromUninstallEntry {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Entry
    )

    $guidPattern = '(?i)\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}'

    $windowsInstaller = Get-OptionalPropertyValue -InputObject $Entry -Name 'WindowsInstaller'
    $psChildName = Get-OptionalPropertyValue -InputObject $Entry -Name 'PSChildName'
    if ($windowsInstaller -eq '1' -and $psChildName -match "^$guidPattern$") {
        return $Matches[0]
    }

    foreach ($propertyName in @('QuietUninstallString', 'UninstallString')) {
        $commandLine = Get-OptionalPropertyValue -InputObject $Entry -Name $propertyName
        if (-not [string]::IsNullOrWhiteSpace($commandLine) -and $commandLine -match $guidPattern) {
            return $Matches[0]
        }
    }

    return $null
}

function Get-UserProfiles {
    $profileItems = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' -ErrorAction SilentlyContinue
    foreach ($profileItem in $profileItems) {
        $sid = [string]$profileItem.PSChildName
        if ($sid -match '_Classes$') {
            continue
        }

        if ($sid -notmatch '^S-1-5-21-(\d+-){3}\d+$' -and $sid -notmatch '^S-1-12-1-(\d+-){4}\d+$') {
            continue
        }

        $profilePath = [Environment]::ExpandEnvironmentVariables([string]$profileItem.ProfileImagePath)
        if ([string]::IsNullOrWhiteSpace($profilePath) -or -not (Test-Path -LiteralPath $profilePath)) {
            continue
        }

        if ($profilePath -like "$env:SystemRoot\*" -or $profilePath -like "$env:SystemDrive\Users\Public*") {
            continue
        }

        [pscustomobject]@{
            Sid            = $sid
            UserName       = Split-Path -Path $profilePath -Leaf
            ProfilePath    = $profilePath
            LocalAppData   = Join-Path -Path $profilePath -ChildPath 'AppData\Local'
            RoamingAppData = Join-Path -Path $profilePath -ChildPath 'AppData\Roaming'
            DesktopPath    = Join-Path -Path $profilePath -ChildPath 'Desktop'
        }
    }
}

function Get-LoadedUserSids {
    return @(
        Get-ChildItem -Path 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PSChildName -notmatch '_Classes$' -and
            (
                $_.PSChildName -match '^S-1-5-21-(\d+-){3}\d+$' -or
                $_.PSChildName -match '^S-1-12-1-(\d+-){4}\d+$'
            )
        } |
        ForEach-Object { [string]$_.PSChildName }
    )
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
            $arguments = ($arguments + ' /norestart REBOOT=ReallySuppress').Trim()
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
            $arguments = ($arguments + ' /norestart REBOOT=ReallySuppress').Trim()
        }

        $filePath = 'msiexec.exe'
    }
    elseif ($filePath -match '(?i)\\setup\.exe$' -and $arguments -notmatch '(?i)(/quiet|/silent)') {
        $arguments = ($arguments + ' /quiet /norestart').Trim()
    }
    elseif ($filePath -match '(?i)\\unins[^\\]*\.exe$' -and $arguments -notmatch '(?i)(/verysilent|/silent)') {
        $arguments = ($arguments + ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-').Trim()
    }
    elseif ($filePath -match '(?i)\\Update\.exe$' -and $arguments -match '(?i)--uninstall' -and $arguments -notmatch '(?i)--silent') {
        $arguments = ($arguments + ' --silent').Trim()
    }

    return [pscustomobject]@{
        FilePath     = $filePath
        ArgumentList = $arguments
    }
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string]$ArgumentList,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    $parameters = @{
        FilePath    = $FilePath
        Wait        = $true
        PassThru    = $true
        ErrorAction = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($ArgumentList)) {
        $parameters['ArgumentList'] = $ArgumentList
    }

    $workingDirectory = $env:SystemRoot
    if ([System.IO.Path]::IsPathRooted($FilePath)) {
        if (-not (Test-Path -LiteralPath $FilePath)) {
            throw "Executable not found: $FilePath"
        }

        $workingDirectory = Split-Path -Path $FilePath -Parent
    }

    if (-not [string]::IsNullOrWhiteSpace($workingDirectory) -and (Test-Path -LiteralPath $workingDirectory)) {
        $parameters['WorkingDirectory'] = $workingDirectory
    }

    Write-Log -Message ("Starting uninstall for [{0}] using [{1}] {2}" -f $DisplayName, $FilePath, $ArgumentList)
    $process = Start-Process @parameters
    Write-Log -Message ("[{0}] exited with code {1}." -f $DisplayName, $process.ExitCode)

    if ($process.ExitCode -in @(1641, 3010)) {
        $script:RebootRequired = $true
    }

    if ($script:SuccessExitCodes -notcontains $process.ExitCode) {
        throw "Uninstall command exited with code $($process.ExitCode)."
    }
}

function Invoke-RawCommandLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLine,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    $escapedCommand = '/d /s /c ""{0}""' -f $CommandLine
    Invoke-ExternalCommand -FilePath 'cmd.exe' -ArgumentList $escapedCommand -DisplayName $DisplayName
}

function Wait-ForCondition {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Condition,

        [int]$TimeoutSeconds = 120,

        [int]$PollSeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) {
            return $true
        }

        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)

    return [bool](& $Condition)
}

function Get-ShiftProcesses {
    return @(Get-Process -Name 'Shift' -ErrorAction SilentlyContinue)
}

function Stop-ShiftProcesses {
    $processes = Get-ShiftProcesses
    foreach ($process in $processes) {
        if ($PSCmdlet.ShouldProcess("PID $($process.Id)", 'Stop Shift process')) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                Write-Log -Message "Stopped Shift process [$($process.ProcessName)] (PID $($process.Id))."
            }
            catch {
                Write-Log -Message "Failed to stop Shift process [$($process.ProcessName)] (PID $($process.Id)): $($_.Exception.Message)" -Level 'WARN'
            }
        }
    }
}

function Add-UniqueItem {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, psobject]]$Dictionary,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [psobject]$Value
    )

    if (-not $Dictionary.ContainsKey($Key)) {
        $Dictionary.Add($Key, $Value)
    }
}

function Get-ShiftRegistryTargets {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, psobject]]$ProfileIndex
    )

    $targets = [System.Collections.Generic.Dictionary[string, psobject]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $machinePaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($entry in @(Get-ItemProperty -Path $machinePaths -ErrorAction SilentlyContinue)) {
        if (-not (Test-IsShiftUninstallEntry -Entry $entry)) {
            continue
        }

        $registryKeyPath = Convert-ToRegistryLiteralPath -PSPath $entry.PSPath
        Add-UniqueItem -Dictionary $targets -Key $registryKeyPath -Value ([pscustomobject]@{
                TargetType           = 'Registry'
                Identity             = $registryKeyPath
                Scope                = 'Machine'
                Sid                  = $null
                ProfilePath          = $null
                DisplayName          = (Get-OptionalPropertyValue -InputObject $entry -Name 'DisplayName')
                RegistryKeyPath      = $registryKeyPath
                QuietUninstallString = (Get-OptionalPropertyValue -InputObject $entry -Name 'QuietUninstallString')
                UninstallString      = (Get-OptionalPropertyValue -InputObject $entry -Name 'UninstallString')
                MsiProductCode       = (Get-MsiProductCodeFromUninstallEntry -Entry $entry)
            })
    }

    foreach ($sid in Get-LoadedUserSids) {
        $profile = $null
        if ($ProfileIndex.ContainsKey($sid)) {
            $profile = $ProfileIndex[$sid]
        }

        $registryPaths = @(
            "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "Registry::HKEY_USERS\$sid\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )

        foreach ($entry in @(Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue)) {
            if (-not (Test-IsShiftUninstallEntry -Entry $entry)) {
                continue
            }

            $registryKeyPath = Convert-ToRegistryLiteralPath -PSPath $entry.PSPath
            Add-UniqueItem -Dictionary $targets -Key $registryKeyPath -Value ([pscustomobject]@{
                    TargetType           = 'Registry'
                    Identity             = $registryKeyPath
                    Scope                = 'PerUserRegistry'
                    Sid                  = $sid
                    ProfilePath          = if ($profile) { $profile.ProfilePath } else { $null }
                    DisplayName          = (Get-OptionalPropertyValue -InputObject $entry -Name 'DisplayName')
                    RegistryKeyPath      = $registryKeyPath
                    QuietUninstallString = (Get-OptionalPropertyValue -InputObject $entry -Name 'QuietUninstallString')
                    UninstallString      = (Get-OptionalPropertyValue -InputObject $entry -Name 'UninstallString')
                    MsiProductCode       = (Get-MsiProductCodeFromUninstallEntry -Entry $entry)
                })
        }
    }

    return @($targets.Values)
}

function Get-ShiftFileTargets {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Profiles
    )

    $targets = [System.Collections.Generic.Dictionary[string, psobject]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $filePatterns = New-Object System.Collections.Generic.List[string]

    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        $filePatterns.Add((Join-Path -Path $root -ChildPath 'Shift\unins*.exe')) | Out-Null
        $filePatterns.Add((Join-Path -Path $root -ChildPath 'Shift\Update.exe')) | Out-Null
        $filePatterns.Add((Join-Path -Path $root -ChildPath 'Shift Browser\unins*.exe')) | Out-Null
        $filePatterns.Add((Join-Path -Path $root -ChildPath 'Shift Browser\Update.exe')) | Out-Null
    }

    foreach ($profile in $Profiles) {
        $filePatterns.Add((Join-Path -Path $profile.LocalAppData -ChildPath 'Shift\unins*.exe')) | Out-Null
        $filePatterns.Add((Join-Path -Path $profile.LocalAppData -ChildPath 'Shift\Update.exe')) | Out-Null
        $filePatterns.Add((Join-Path -Path $profile.LocalAppData -ChildPath 'Shift Browser\unins*.exe')) | Out-Null
        $filePatterns.Add((Join-Path -Path $profile.LocalAppData -ChildPath 'Shift Browser\Update.exe')) | Out-Null
        $filePatterns.Add((Join-Path -Path $profile.LocalAppData -ChildPath 'Programs\Shift\unins*.exe')) | Out-Null
        $filePatterns.Add((Join-Path -Path $profile.LocalAppData -ChildPath 'Programs\Shift\Update.exe')) | Out-Null
        $filePatterns.Add((Join-Path -Path $profile.LocalAppData -ChildPath 'Programs\Shift Browser\unins*.exe')) | Out-Null
        $filePatterns.Add((Join-Path -Path $profile.LocalAppData -ChildPath 'Programs\Shift Browser\Update.exe')) | Out-Null
    }

    foreach ($pattern in $filePatterns) {
        foreach ($file in @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)) {
            $profileMatch = $Profiles | Where-Object { $file.FullName -like "$($_.ProfilePath)\*" } | Select-Object -First 1
            $argumentList = if ($file.Name -ieq 'Update.exe') {
                '--uninstall --silent'
            }
            else {
                '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
            }

            Add-UniqueItem -Dictionary $targets -Key $file.FullName -Value ([pscustomobject]@{
                    TargetType      = 'File'
                    Identity        = $file.FullName
                    Scope           = if ($profileMatch) { 'PerUserPath' } else { 'MachinePath' }
                    Sid             = if ($profileMatch) { $profileMatch.Sid } else { $null }
                    ProfilePath     = if ($profileMatch) { $profileMatch.ProfilePath } else { $null }
                    DisplayName     = 'Shift'
                    FilePath        = $file.FullName
                    ArgumentList    = $argumentList
                })
        }
    }

    return @($targets.Values)
}

function Get-ShiftFileIndicators {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Profiles
    )

    $indicators = [System.Collections.Generic.Dictionary[string, psobject]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $candidatePaths = New-Object System.Collections.Generic.List[string]

    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        foreach ($relativePath in @(
                'Shift\Shift.exe',
                'Shift\Update.exe',
                'Shift\unins000.exe',
                'Shift Browser\Shift.exe',
                'Shift Browser\Update.exe',
                'Shift Browser\unins000.exe'
            )) {
            $candidatePaths.Add((Join-Path -Path $root -ChildPath $relativePath)) | Out-Null
        }
    }

    foreach ($profile in $Profiles) {
        foreach ($relativePath in @(
                'Shift\Shift.exe',
                'Shift\Update.exe',
                'Shift\unins000.exe',
                'Shift Browser\Shift.exe',
                'Shift Browser\Update.exe',
                'Shift Browser\unins000.exe',
                'Programs\Shift\Shift.exe',
                'Programs\Shift\Update.exe',
                'Programs\Shift\unins000.exe',
                'Programs\Shift Browser\Shift.exe',
                'Programs\Shift Browser\Update.exe',
                'Programs\Shift Browser\unins000.exe'
            )) {
            $candidatePaths.Add((Join-Path -Path $profile.LocalAppData -ChildPath $relativePath)) | Out-Null
        }
    }

    foreach ($candidatePath in $candidatePaths) {
        if (-not (Test-Path -LiteralPath $candidatePath)) {
            continue
        }

        $profileMatch = $Profiles | Where-Object { $candidatePath -like "$($_.ProfilePath)\*" } | Select-Object -First 1
        Add-UniqueItem -Dictionary $indicators -Key $candidatePath -Value ([pscustomobject]@{
                Path        = $candidatePath
                Scope       = if ($profileMatch) { 'PerUserPath' } else { 'MachinePath' }
                Sid         = if ($profileMatch) { $profileMatch.Sid } else { $null }
                ProfilePath = if ($profileMatch) { $profileMatch.ProfilePath } else { $null }
            })
    }

    return @($indicators.Values)
}

function Get-ShiftState {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Profiles,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, psobject]]$ProfileIndex
    )

    [pscustomobject]@{
        RegistryTargets = @(Get-ShiftRegistryTargets -ProfileIndex $ProfileIndex)
        FileTargets     = @(Get-ShiftFileTargets -Profiles $Profiles)
        FileIndicators  = @(Get-ShiftFileIndicators -Profiles $Profiles)
        Processes       = @(Get-ShiftProcesses)
    }
}

function Test-TargetStillPresent {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Target
    )

    if ($Target.TargetType -eq 'Registry') {
        return Test-Path -LiteralPath $Target.RegistryKeyPath
    }

    if ($Target.TargetType -eq 'File') {
        return Test-Path -LiteralPath $Target.FilePath
    }

    return $false
}

function Wait-ForTargetRemoval {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Target,

        [int]$TimeoutSeconds = 120
    )

    return Wait-ForCondition -TimeoutSeconds $TimeoutSeconds -PollSeconds 5 -Condition {
        -not (Test-TargetStillPresent -Target $Target)
    }
}

function Invoke-ShiftTargetUninstall {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Target,

        [int]$TimeoutSeconds = 120
    )

    $displayName = if ([string]::IsNullOrWhiteSpace($Target.DisplayName)) { 'Shift' } else { $Target.DisplayName }
    if (-not (Test-TargetStillPresent -Target $Target)) {
        Write-Log -Message "Skipping [$displayName] because its uninstall target no longer exists."
        return $false
    }

    if ($Target.TargetType -eq 'Registry') {
        if (-not [string]::IsNullOrWhiteSpace($Target.QuietUninstallString)) {
            Invoke-RawCommandLine -CommandLine $Target.QuietUninstallString -DisplayName $displayName
        }
        elseif (-not [string]::IsNullOrWhiteSpace($Target.UninstallString)) {
            $command = Convert-UninstallStringToCommand -CommandLine $Target.UninstallString
            if (-not $command) {
                throw "Unable to parse uninstall string for [$displayName]."
            }

            Invoke-ExternalCommand -FilePath $command.FilePath -ArgumentList $command.ArgumentList -DisplayName $displayName
        }
        elseif (-not [string]::IsNullOrWhiteSpace($Target.MsiProductCode)) {
            Invoke-ExternalCommand -FilePath 'msiexec.exe' -ArgumentList "/x $($Target.MsiProductCode) /qn /norestart REBOOT=ReallySuppress" -DisplayName $displayName
        }
        else {
            throw "No uninstall command was available for [$displayName]."
        }
    }
    elseif ($Target.TargetType -eq 'File') {
        Invoke-ExternalCommand -FilePath $Target.FilePath -ArgumentList $Target.ArgumentList -DisplayName $displayName
    }
    else {
        throw "Unsupported target type [$($Target.TargetType)]."
    }

    if (Wait-ForTargetRemoval -Target $Target -TimeoutSeconds $TimeoutSeconds) {
        Write-Log -Message "Confirmed removal of [$displayName] from target [$($Target.Identity)]."
        return $true
    }

    Write-Log -Message "Uninstall command ran for [$displayName], but the target still appears present: [$($Target.Identity)]." -Level 'WARN'
    return $false
}

function Remove-ShiftShortcuts {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Profiles
    )

    $shortcutPatterns = New-Object System.Collections.Generic.List[string]
    $shortcutPatterns.Add('C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Shift*.lnk') | Out-Null

    foreach ($profile in $Profiles) {
        $shortcutPatterns.Add((Join-Path -Path $profile.DesktopPath -ChildPath 'Shift*.lnk')) | Out-Null
        $shortcutPatterns.Add((Join-Path -Path $profile.RoamingAppData -ChildPath 'Microsoft\Windows\Start Menu\Programs\Shift*.lnk')) | Out-Null
    }

    foreach ($pattern in $shortcutPatterns) {
        foreach ($shortcut in @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)) {
            if ($PSCmdlet.ShouldProcess($shortcut.FullName, 'Remove stale Shift shortcut')) {
                try {
                    Remove-Item -LiteralPath $shortcut.FullName -Force -ErrorAction Stop
                    Write-Log -Message "Removed stale Shift shortcut [$($shortcut.FullName)]."
                }
                catch {
                    Write-Log -Message "Failed to remove Shift shortcut [$($shortcut.FullName)]: $($_.Exception.Message)" -Level 'WARN'
                }
            }
        }
    }
}

if (-not (Test-IsAdministrator)) {
    throw 'Remove-ShiftBrowser.ps1 must run from an elevated PowerShell session.'
}

Write-Log -Message 'Starting Shift Browser removal.'

$profiles = @(Get-UserProfiles)
$profileIndex = [System.Collections.Generic.Dictionary[string, psobject]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($profile in $profiles) {
    if (-not $profileIndex.ContainsKey($profile.Sid)) {
        $profileIndex.Add($profile.Sid, $profile)
    }
}

Write-Log -Message "Discovered $($profiles.Count) local user profile(s) to inspect."

$initialState = Get-ShiftState -Profiles $profiles -ProfileIndex $profileIndex
$initialTargetCount = $initialState.RegistryTargets.Count + $initialState.FileTargets.Count

Write-Log -Message ("Initial detection found {0} uninstall target(s), {1} file indicator(s), and {2} running Shift process(es)." -f $initialTargetCount, $initialState.FileIndicators.Count, $initialState.Processes.Count)

if ($initialTargetCount -eq 0 -and $initialState.FileIndicators.Count -eq 0 -and $initialState.Processes.Count -eq 0) {
    $summary = [pscustomobject]@{
        Removed                = $true
        AlreadyAbsent          = $true
        RebootRequired         = $false
        ProfilesScanned        = $profiles.Count
        UninstallTargetsFound  = 0
        RemainingTargets       = 0
        RemainingFileIndicators = 0
    }

    Write-Output $summary
    Write-Log -Message 'Shift Browser does not appear to be installed.'
    return
}

Stop-ShiftProcesses

$attemptedTargets = 0
$confirmedTargets = 0
$failureMessages = New-Object System.Collections.Generic.List[string]
$targets = @($initialState.RegistryTargets + $initialState.FileTargets)

foreach ($target in $targets) {
    $displayName = if ([string]::IsNullOrWhiteSpace($target.DisplayName)) { 'Shift' } else { $target.DisplayName }
    if (-not $PSCmdlet.ShouldProcess($displayName, "Remove Shift Browser target [$($target.Scope)]")) {
        continue
    }

    try {
        $attemptedTargets++
        if (Invoke-ShiftTargetUninstall -Target $target -TimeoutSeconds $UninstallTimeoutSeconds) {
            $confirmedTargets++
        }
    }
    catch {
        $message = "Failed to remove [$displayName] from [$($target.Identity)]: $($_.Exception.Message)"
        $failureMessages.Add($message) | Out-Null
        Write-Log -Message $message -Level 'WARN'
    }
}

Stop-ShiftProcesses
Remove-ShiftShortcuts -Profiles $profiles

$finalState = Get-ShiftState -Profiles $profiles -ProfileIndex $profileIndex
$remainingTargets = $finalState.RegistryTargets.Count + $finalState.FileTargets.Count
$remainingProcesses = $finalState.Processes.Count

$summary = [pscustomobject]@{
    Removed                 = ($remainingTargets -eq 0 -and $finalState.FileIndicators.Count -eq 0 -and $remainingProcesses -eq 0)
    AlreadyAbsent           = $false
    RebootRequired          = $script:RebootRequired
    ProfilesScanned         = $profiles.Count
    UninstallTargetsFound   = $initialTargetCount
    UninstallTargetsTried   = $attemptedTargets
    UninstallTargetsCleared = $confirmedTargets
    RemainingTargets        = $remainingTargets
    RemainingFileIndicators = $finalState.FileIndicators.Count
    RemainingProcesses      = $remainingProcesses
}

Write-Output $summary

foreach ($failureMessage in $failureMessages) {
    Write-Log -Message $failureMessage -Level 'WARN'
}

if ($script:RebootRequired) {
    Write-Log -Message 'One or more uninstall commands requested a reboot.'
}

if (-not $summary.Removed) {
    $remainingEvidence = @()

    foreach ($target in $finalState.RegistryTargets) {
        $remainingEvidence += "Registry target: $($target.Identity)"
    }

    foreach ($target in $finalState.FileTargets) {
        $remainingEvidence += "File target: $($target.FilePath)"
    }

    foreach ($indicator in $finalState.FileIndicators) {
        $remainingEvidence += "File indicator: $($indicator.Path)"
    }

    foreach ($process in $finalState.Processes) {
        $remainingEvidence += "Process: $($process.ProcessName) (PID $($process.Id))"
    }

    $detail = ($remainingEvidence -join '; ')
    Write-Log -Message "Shift Browser still appears to be installed. $detail" -Level 'ERROR'
    throw "Shift Browser removal did not fully complete. $detail"
}

Write-Log -Message 'Shift Browser removal completed successfully.'
