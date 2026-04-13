#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetMode,

    [string[]]$ApprovedProductPatterns,

    [switch]$DryRun,

    [ValidateRange(1, 60)]
    [int]$UninstallTimeoutMinutes = 15,

    [string]$LogRoot = 'C:\ProgramData\DattoRMM\AVRemediation',

    [string[]]$SupportedTargetModes = @('DattoAV', 'WindowsDefender')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($TargetMode)) {
    throw 'TargetMode is required.'
}

$requestedTargetMode = $TargetMode.Trim()

switch -Regex ($requestedTargetMode) {
    '^Datto\s*AV$' {
        $TargetMode = 'DattoAV'
        break
    }
    '^DattoAV$' {
        $TargetMode = 'DattoAV'
        break
    }
    '^(Windows|Microsoft)\s*Defender$' {
        $TargetMode = 'WindowsDefender'
        break
    }
    '^(Windows|Microsoft)Defender$' {
        $TargetMode = 'WindowsDefender'
        break
    }
    default {
        throw "Unsupported TargetMode '$requestedTargetMode'. Supported values: DattoAV, Datto AV, WindowsDefender, Windows Defender, MicrosoftDefender, Microsoft Defender."
    }
}

# region Globals
$script:SuccessExitCodes = @(0, 1641, 3010)
$script:MinimumSupportedPowerShellVersion = [version]'5.1'
$script:InventoryQueryTimeoutSeconds = 45
$script:UninstallTimeoutMinutes = $UninstallTimeoutMinutes
$script:UninstallTimeoutMilliseconds = $UninstallTimeoutMinutes * 60 * 1000
$script:ServiceStopTimeoutSeconds = 5
$script:ProcessCleanupTimeoutSeconds = 5
$script:StartTimeUtc = [System.DateTime]::UtcNow
$script:InventoryDisplayNamePatterns = @(
    'Antivirus',
    'Internet Security',
    'Endpoint Security',
    'Endpoint Protection',
    '\bThreat\b',
    '\bMalware\b',
    '\bEDR\b',
    '\bXDR\b',
    '\bAVG\b',
    '\bAvast\b',
    '\bAvira\b',
    '\bBitdefender\b',
    '\bCrowdStrike\b',
    '\bCylance\b',
    '\bDatto\s+AV\b',
    '\bDatto\s+Antivirus\b',
    '\bDatto\s+EDR\b',
    '\bDefender\b',
    '\bESET\b',
    '\bKaspersky\b',
    '\bMalwarebytes\b',
    '\bMcAfee\b',
    'Microsoft Security Essentials',
    '\bNorton\b',
    '\bSentinelOne\b',
    '\bSophos\b',
    '\bTrend Micro\b',
    '\bWebroot\b'
)
$script:AlwaysAllowedNonTargetPatterns = @(
    '\bDatto\s+EDR\b',
    '\bDatto\s+EDR\s+Agent\b'
)
$script:DattoAvPlaceholderPatterns = @(
    '^Endpoint Protection SDK$'
)
$script:DefenderProductPatterns = @(
    'Microsoft Defender',
    'Windows Defender',
    'Defender for Endpoint'
)
$script:DattoAvProductPatterns = @(
    '\bDatto\s+AV\b',
    '\bDatto\s+Antivirus\b',
    '\bDatto\b.*\bAntivirus\b'
)
$script:VendorSilentSwitchProfiles = @(
    [pscustomobject]@{
        Name                     = 'AVG Consumer'
        DisplayNamePattern       = '(?i)^AVG (AntiVirus|Internet Security|Ultimate|Free|Driver Updater|Secure VPN|BreachGuard|TuneUp)'
        PreferredSilentSwitch    = '/silent'
        PreferredNoRestartSwitch = $null
    },
    [pscustomobject]@{
        Name                     = 'AVG Business'
        DisplayNamePattern       = '(?i)^AVG (Business|File Server|Email Server|CloudCare|Managed Workplace)'
        PreferredSilentSwitch    = '/silent'
        PreferredNoRestartSwitch = $null
    },
    [pscustomobject]@{
        Name                     = 'Bitdefender Consumer'
        DisplayNamePattern       = '(?i)^Bitdefender (Antivirus Plus|Internet Security|Total Security|Family Pack|Premium Security|VPN)'
        PreferredSilentSwitch    = '/silent'
        PreferredNoRestartSwitch = '/norestart'
    },
    [pscustomobject]@{
        Name                     = 'Bitdefender Endpoint'
        DisplayNamePattern       = '(?i)^Bitdefender (Endpoint Security Tools|Agent|GravityZone|BEST)'
        PreferredSilentSwitch    = '/quiet'
        PreferredNoRestartSwitch = '/norestart'
    },
    [pscustomobject]@{
        Name                     = 'AVG Generic'
        DisplayNamePattern       = '(?i)\bAVG\b'
        PreferredSilentSwitch    = '/silent'
        PreferredNoRestartSwitch = $null
    },
    [pscustomobject]@{
        Name                     = 'Bitdefender Generic'
        DisplayNamePattern       = '(?i)\bBitdefender\b'
        PreferredSilentSwitch    = '/quiet'
        PreferredNoRestartSwitch = '/norestart'
    }
)
# endregion Globals

# region GeneralHelpers
function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not [string]::IsNullOrWhiteSpace($Path) -and -not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $directory = Split-Path -Path $script:LogPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        Ensure-Directory -Path $directory
    }

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $script:LogPath -Value $line
}

function Get-ElapsedTimeSeconds {
    $elapsed = [System.DateTime]::UtcNow - $script:StartTimeUtc
    return [int]$elapsed.TotalSeconds
}

function Test-TimeoutExceeded {
    param(
        [int]$MaxSeconds
    )
    $elapsed = Get-ElapsedTimeSeconds
    return $elapsed -ge $MaxSeconds
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OptionalMemberValue {
    param(
        [psobject]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Get-OptionalPropertyValue {
    param(
        [psobject]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $value = Get-OptionalMemberValue -InputObject $InputObject -Name $Name
    if ($null -eq $value) {
        return $null
    }

    return [string]$value
}

function Test-PatternMatch {
    param(
        [string]$Value,
        [string[]]$Patterns
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $null -eq $Patterns) {
        return $false
    }

    foreach ($pattern in $Patterns) {
        if ($Value -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-DefaultApprovedProductPatterns {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mode
    )

    switch ($Mode) {
        'DattoAV' { return @($script:DattoAvProductPatterns) }
        'WindowsDefender' { return @($script:DefenderProductPatterns) }
        default { throw "Unsupported target mode: $Mode" }
    }
}

function Get-AllowedNonTargetPatterns {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mode
    )

    if ($Mode -eq 'DattoAV') {
        return @($script:DefenderProductPatterns + $script:AlwaysAllowedNonTargetPatterns + $script:DattoAvPlaceholderPatterns)
    }

    return @($script:AlwaysAllowedNonTargetPatterns)
}

function Join-DisplayValues {
    param(
        [AllowNull()]
        [object[]]$Values
    )

    $items = @(
        $Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )

    if ($items.Count -eq 0) {
        return '(none)'
    }

    return ($items | Sort-Object -Unique) -join '; '
}

function Assert-SupportedPowerShellVersion {
    $currentVersion = $PSVersionTable.PSVersion
    if ($currentVersion -lt $script:MinimumSupportedPowerShellVersion) {
        throw "PowerShell $($script:MinimumSupportedPowerShellVersion) or later is required. Current version: $currentVersion"
    }
}

function Assert-WindowsPlatform {
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw 'This script must run on Windows.'
    }
}

function Invoke-CommandWithTimeout {
    # Uses runspaces instead of Start-Job so this works correctly when running as SYSTEM
    # (Start-Job requires a user profile/temp environment that SYSTEM may not have in RMM contexts).
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 600)]
        [int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [object[]]$ArgumentList = @()
    )

    $runspace = $null
    $ps = $null

    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()

        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript($ScriptBlock)
        foreach ($arg in $ArgumentList) {
            [void]$ps.AddArgument($arg)
        }

        $asyncResult = $ps.BeginInvoke()

        if (-not $asyncResult.AsyncWaitHandle.WaitOne([timespan]::FromSeconds($TimeoutSeconds))) {
            try { $ps.Stop() } catch { }
            throw "$Description timed out after $TimeoutSeconds second(s)."
        }

        $results = $ps.EndInvoke($asyncResult)

        if ($ps.HadErrors -and $ps.Streams.Error.Count -gt 0) {
            $firstError = $ps.Streams.Error[0]
            if ($null -ne $firstError -and $null -ne $firstError.Exception) {
                throw $firstError.Exception
            }
        }

        return @($results)
    }
    finally {
        if ($null -ne $ps) {
            try { $ps.Dispose() } catch { }
        }
        if ($null -ne $runspace) {
            try { $runspace.Close() } catch { }
            try { $runspace.Dispose() } catch { }
        }
    }
}
# endregion GeneralHelpers

# region UninstallHelpers
function Get-MsiProductCodeFromUninstallEntry {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$InputObject
    )

    $guidPattern = '(?i)\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}'

    $windowsInstaller = Get-OptionalPropertyValue -InputObject $InputObject -Name 'WindowsInstaller'
    $psChildName = Get-OptionalPropertyValue -InputObject $InputObject -Name 'PSChildName'
    if ($windowsInstaller -eq '1' -and $psChildName -match "^$guidPattern$") {
        return $Matches[0]
    }

    $quietUninstall = Get-OptionalPropertyValue -InputObject $InputObject -Name 'QuietUninstallString'
    if (-not [string]::IsNullOrWhiteSpace($quietUninstall) -and $quietUninstall -match $guidPattern) {
        return $Matches[0]
    }

    $regularUninstall = Get-OptionalPropertyValue -InputObject $InputObject -Name 'UninstallString'
    if (-not [string]::IsNullOrWhiteSpace($regularUninstall) -and $regularUninstall -match $guidPattern) {
        return $Matches[0]
    }

    return $null
}

function Get-VendorSilentSwitchProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    foreach ($profile in $script:VendorSilentSwitchProfiles) {
        if ($DisplayName -match $profile.DisplayNamePattern) {
            return $profile
        }
    }

    return $null
}

function Test-AnyArgumentPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Arguments,
        [Parameter(Mandatory = $true)]
        [string[]]$Candidates
    )

    foreach ($candidate in $Candidates) {
        $escaped = [regex]::Escape($candidate)
        if ($Arguments -match "(?i)(^|\s)$escaped(\s|$)") {
            return $true
        }
    }

    return $false
}

function ConvertTo-ProcessInvocation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLine
    )

    $trimmed = $CommandLine.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $null
    }

    if ($trimmed -match '^(?i)msiexec(?:\.exe)?\s*(?<args>.*)$') {
        return [pscustomobject]@{
            FilePath  = 'msiexec.exe'
            Arguments = $Matches['args']
        }
    }

    if ($trimmed -match '^\s*"(?<file>[^"]+)"\s*(?<args>.*)$') {
        return [pscustomobject]@{
            FilePath  = $Matches['file']
            Arguments = $Matches['args']
        }
    }

    if ($trimmed -match '^\s*(?<file>\S+)\s*(?<args>.*)$') {
        return [pscustomobject]@{
            FilePath  = $Matches['file']
            Arguments = $Matches['args']
        }
    }

    return $null
}

function Add-SilentUninstallArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string]$Arguments
    )

    $updated = $Arguments.Trim()
    $isMsiExec = $FilePath -match '^(?i)msiexec(?:\.exe)?$'
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $isAvgInstup = ($DisplayName -match '(?i)\bAVG\b') -and ($fileName -match '^(?i)instup\.exe$')

    if ($isMsiExec) {
        $updated = [regex]::Replace($updated, '(?i)(^|\s)/I(?=\s*[{])', '$1/X')

        if ($updated -notmatch '(?i)(^|\s)/X(\s|$)') {
            Write-Log -Message "MSI command for [$DisplayName] did not include /X; leaving arguments unchanged." -Level WARN
        }

        if ($updated -notmatch '(?i)(^|\s)/(q|qn|qb|quiet)\b') {
            $updated = "$updated /qn"
        }
        if ($updated -notmatch '(?i)(^|\s)/norestart\b') {
            $updated = "$updated /norestart"
        }
        if ($updated -notmatch '(?i)(^|\s)REBOOT=ReallySuppress(\s|$)') {
            $updated = "$updated REBOOT=ReallySuppress"
        }

        return $updated.Trim()
    }

    $profile = Get-VendorSilentSwitchProfile -DisplayName $DisplayName
    if ($null -eq $profile) {
        return $updated
    }

    Write-Log -Message "Using validated silent-switch profile [$($profile.Name)] for [$DisplayName]."

    $acceptedSilentSwitches = @('/quiet', '/qn', '/s', '/silent', '/verysilent', '--quiet', '--silent', [string]$profile.PreferredSilentSwitch)

    if ($isAvgInstup -and $updated -match '(?i)(^|\s)/control_panel(\s|$)') {
        $updated = [regex]::Replace($updated, '(?i)(^|\s)/control_panel(\s|$)', ' ')
        $updated = [regex]::Replace($updated, '\s+', ' ').Trim()
        Write-Log -Message "Removed AVG Instup control-panel switch for [$DisplayName] in silent mode."
    }

    if ($isAvgInstup -and $updated -notmatch '(?i)(^|\s)(/instop:uninstall|/uninstall)(\s|$)') {
        $updated = "$updated /instop:uninstall"
        Write-Log -Message "Added AVG Instup uninstall action switch for [$DisplayName]."
    }

    if (-not (Test-AnyArgumentPresent -Arguments $updated -Candidates $acceptedSilentSwitches)) {
        $updated = "$updated $($profile.PreferredSilentSwitch)"
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$profile.PreferredNoRestartSwitch) -and -not (Test-AnyArgumentPresent -Arguments $updated -Candidates @('/norestart', '/nr'))) {
        $updated = "$updated $($profile.PreferredNoRestartSwitch)"
    }

    return $updated.Trim()
}

function Start-HiddenProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string]$ArgumentList
    )

    $parameters = @{
        FilePath     = $FilePath
        ArgumentList = $ArgumentList
        PassThru     = $true
        WindowStyle  = 'Hidden'
        ErrorAction  = 'Stop'
    }

    $workingDirectory = Split-Path -Path $FilePath -Parent
    if (-not [string]::IsNullOrWhiteSpace($workingDirectory) -and (Test-Path -LiteralPath $workingDirectory)) {
        $parameters['WorkingDirectory'] = $workingDirectory
    }

    return Start-Process @parameters
}

function Stop-ProcessTree {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId
    )

    try {
        $result = Invoke-CommandWithTimeout -TimeoutSeconds 10 -Description "Terminate process tree for PID $ProcessId" -ScriptBlock {
            param([int]$Pid)
            $taskKill = Start-Process -FilePath 'taskkill.exe' -ArgumentList "/PID $Pid /T /F" -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            return $taskKill.ExitCode
        } -ArgumentList $ProcessId

        return [pscustomobject]@{
            Succeeded = ($result -eq 0)
            ExitCode  = $result
            ErrorText = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Succeeded = $false
            ExitCode  = $null
            ErrorText = $_.Exception.Message
        }
    }
}

function Invoke-AvgPreUninstallCleanup {
    $attempted = $false

    try {
        $avgServices = Invoke-CommandWithTimeout -TimeoutSeconds $script:ServiceStopTimeoutSeconds -Description 'AVG service enumeration' -ScriptBlock {
            Get-Service -Name 'AVG*' -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running }
        }
    }
    catch {
        Write-Log -Message "AVG service enumeration timed out or failed: $($_.Exception.Message)" -Level WARN
        $avgServices = @()
    }

    foreach ($service in $avgServices) {
        try {
            Invoke-CommandWithTimeout -TimeoutSeconds $script:ServiceStopTimeoutSeconds -Description "Stop AVG service $($service.Name)" -ScriptBlock {
                param([string]$ServiceName)
                Stop-Service -Name $ServiceName -Force -ErrorAction Stop
            } -ArgumentList $service.Name | Out-Null
            Write-Log -Message "Stopped AVG service [$($service.Name)] before retry."
            $attempted = $true
        }
        catch {
            Write-Log -Message "Could not stop AVG service [$($service.Name)]: $($_.Exception.Message)" -Level WARN
        }
    }

    try {
        $avgProcesses = Invoke-CommandWithTimeout -TimeoutSeconds $script:ProcessCleanupTimeoutSeconds -Description 'AVG process enumeration' -ScriptBlock {
            Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(?i)avg' }
        }
    }
    catch {
        Write-Log -Message "AVG process enumeration timed out or failed: $($_.Exception.Message)" -Level WARN
        $avgProcesses = @()
    }

    foreach ($process in $avgProcesses) {
        try {
            Invoke-CommandWithTimeout -TimeoutSeconds $script:ProcessCleanupTimeoutSeconds -Description "Stop AVG process $($process.ProcessName)" -ScriptBlock {
                param([int]$ProcessId)
                Stop-Process -Id $ProcessId -Force -ErrorAction Stop
            } -ArgumentList $process.Id | Out-Null
            Write-Log -Message "Stopped AVG process [$($process.ProcessName)] (PID $($process.Id)) before retry."
            $attempted = $true
        }
        catch {
            Write-Log -Message "Could not stop AVG process [$($process.ProcessName)] (PID $($process.Id)): $($_.Exception.Message)" -Level WARN
        }
    }

    return $attempted
}

function Enable-AvgSilentUninstallInStatsIni {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UninstallerPath
    )

    try {
        $setupDirectory = Split-Path -Path $UninstallerPath -Parent
        if ([string]::IsNullOrWhiteSpace($setupDirectory) -or -not (Test-Path -LiteralPath $setupDirectory)) {
            return $false
        }

        $statsIniPath = Join-Path -Path $setupDirectory -ChildPath 'Stats.ini'
        if (-not (Test-Path -LiteralPath $statsIniPath)) {
            return $false
        }

        $content = [System.IO.File]::ReadAllText($statsIniPath)
        if ($content -match '(?im)^\s*SilentUninstallEnabled\s*=\s*1\s*$') {
            Write-Log -Message "AVG silent uninstall flag already enabled in [$statsIniPath]."
            return $true
        }

        [System.IO.File]::AppendAllText($statsIniPath, "`r`n[Common]`r`nSilentUninstallEnabled=1`r`n", [System.Text.Encoding]::ASCII)
        Write-Log -Message "Enabled AVG silent uninstall flag in [$statsIniPath]."
        return $true
    }
    catch {
        Write-Log -Message "Failed to adjust AVG Stats.ini for silent uninstall: $($_.Exception.Message)" -Level WARN
        return $false
    }
}

function New-MsiFallbackAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [Parameter(Mandatory = $true)]
        [string]$ProductCode,
        [Parameter(Mandatory = $true)]
        [string]$CommandSource,
        [string]$Reason
    )

    $arguments = "/x $ProductCode /qn /norestart REBOOT=ReallySuppress"

    return [pscustomobject]@{
        Supported      = $true
        FilePath       = 'msiexec.exe'
        Arguments      = $arguments
        DisplayCommand = "msiexec.exe $arguments"
        CommandSource  = $CommandSource
        Reason         = $Reason
    }
}

function Resolve-UninstallAction {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RegistryEntry
    )

    $displayName = Get-OptionalPropertyValue -InputObject $RegistryEntry -Name 'DisplayName'
    $quietUninstall = Get-OptionalPropertyValue -InputObject $RegistryEntry -Name 'QuietUninstallString'
    $regularUninstall = Get-OptionalPropertyValue -InputObject $RegistryEntry -Name 'UninstallString'
    $productCode = Get-OptionalPropertyValue -InputObject $RegistryEntry -Name 'ProductCode'

    if (-not [string]::IsNullOrWhiteSpace($quietUninstall)) {
        $quietInvocation = ConvertTo-ProcessInvocation -CommandLine $quietUninstall
        if ($quietInvocation) {
            $arguments = if ($quietInvocation.FilePath -match '^(?i)msiexec(?:\.exe)?$') {
                Add-SilentUninstallArguments -DisplayName $displayName -FilePath $quietInvocation.FilePath -Arguments ([string]$quietInvocation.Arguments)
            }
            else {
                ([string]$quietInvocation.Arguments).Trim()
            }

            $displayCommand = if ([string]::IsNullOrWhiteSpace($arguments)) {
                $quietInvocation.FilePath
            }
            else {
                "$($quietInvocation.FilePath) $arguments"
            }

            return [pscustomobject]@{
                Supported      = $true
                FilePath       = $quietInvocation.FilePath
                Arguments      = $arguments
                DisplayCommand = $displayCommand
                CommandSource  = 'QuietUninstallString'
                Reason         = 'Using QuietUninstallString.'
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($productCode)) {
            return New-MsiFallbackAction -DisplayName $displayName -ProductCode $productCode -CommandSource 'MSIProductCodeFallback' -Reason 'QuietUninstallString could not be parsed; using MSI product code fallback.'
        }

        return [pscustomobject]@{
            Supported      = $false
            FilePath       = $null
            Arguments      = $null
            DisplayCommand = $null
            CommandSource  = 'QuietUninstallString'
            Reason         = 'QuietUninstallString could not be parsed and no MSI product code fallback was available.'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($regularUninstall)) {
        $regularInvocation = ConvertTo-ProcessInvocation -CommandLine $regularUninstall
        if ($regularInvocation) {
            if ($regularInvocation.FilePath -match '^(?i)msiexec(?:\.exe)?$') {
                $arguments = Add-SilentUninstallArguments -DisplayName $displayName -FilePath $regularInvocation.FilePath -Arguments ([string]$regularInvocation.Arguments)
                $displayCommand = if ([string]::IsNullOrWhiteSpace($arguments)) {
                    $regularInvocation.FilePath
                }
                else {
                    "$($regularInvocation.FilePath) $arguments"
                }

                return [pscustomobject]@{
                    Supported      = $true
                    FilePath       = $regularInvocation.FilePath
                    Arguments      = $arguments
                    DisplayCommand = $displayCommand
                    CommandSource  = 'UninstallString'
                    Reason         = 'Converted MSI uninstall command to silent uninstall.'
                }
            }

            $profile = Get-VendorSilentSwitchProfile -DisplayName $displayName
            if ($null -ne $profile) {
                $arguments = Add-SilentUninstallArguments -DisplayName $displayName -FilePath $regularInvocation.FilePath -Arguments ([string]$regularInvocation.Arguments)
                $displayCommand = if ([string]::IsNullOrWhiteSpace($arguments)) {
                    $regularInvocation.FilePath
                }
                else {
                    "$($regularInvocation.FilePath) $arguments"
                }

                return [pscustomobject]@{
                    Supported      = $true
                    FilePath       = $regularInvocation.FilePath
                    Arguments      = $arguments
                    DisplayCommand = $displayCommand
                    CommandSource  = 'UninstallStringValidatedVendor'
                    Reason         = 'Applied validated vendor silent-switch profile.'
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($productCode)) {
                return New-MsiFallbackAction -DisplayName $displayName -ProductCode $productCode -CommandSource 'MSIProductCodeFallback' -Reason 'Regular uninstall is a non-MSI raw command; using MSI product code fallback instead.'
            }

            return [pscustomobject]@{
                Supported      = $false
                FilePath       = $null
                Arguments      = $null
                DisplayCommand = $null
                CommandSource  = 'UninstallString'
                Reason         = 'UninstallString is a non-MSI raw command and no validated silent-switch profile exists.'
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($productCode)) {
            return New-MsiFallbackAction -DisplayName $displayName -ProductCode $productCode -CommandSource 'MSIProductCodeFallback' -Reason 'UninstallString could not be parsed; using MSI product code fallback.'
        }

        return [pscustomobject]@{
            Supported      = $false
            FilePath       = $null
            Arguments      = $null
            DisplayCommand = $null
            CommandSource  = 'UninstallString'
            Reason         = 'UninstallString could not be parsed and no MSI product code fallback was available.'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($productCode)) {
        return New-MsiFallbackAction -DisplayName $displayName -ProductCode $productCode -CommandSource 'MSIProductCodeFallback' -Reason 'No uninstall command was present; using MSI product code fallback.'
    }

    return [pscustomobject]@{
        Supported      = $false
        FilePath       = $null
        Arguments      = $null
        DisplayCommand = $null
        CommandSource  = 'None'
        Reason         = 'No uninstall command or MSI product code was found.'
    }
}

function Invoke-UninstallProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string]$Arguments
    )

    try {
        $process = Start-HiddenProcess -FilePath $FilePath -ArgumentList $Arguments
        $completed = $process.WaitForExit($script:UninstallTimeoutMilliseconds)
        if (-not $completed) {
            $killResult = Stop-ProcessTree -ProcessId $process.Id
            $timeoutReason = "Process timed out after $($script:UninstallTimeoutMinutes) minute(s)."
            if ($killResult.Succeeded) {
                $timeoutReason += " Process tree was terminated."
            }
            else {
                $timeoutReason += " Failed to terminate process tree: $($killResult.ErrorText)"
            }

            return [pscustomobject]@{
                Started       = $true
                ExitCode      = $null
                ErrorText     = $timeoutReason
                TimedOut      = $true
                ProcessId     = $process.Id
                KillSucceeded = $killResult.Succeeded
                KillExitCode  = $killResult.ExitCode
            }
        }

        return [pscustomobject]@{
            Started       = $true
            ExitCode      = $process.ExitCode
            ErrorText     = $null
            TimedOut      = $false
            ProcessId     = $process.Id
            KillSucceeded = $null
            KillExitCode  = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Started       = $false
            ExitCode      = $null
            ErrorText     = $_.Exception.Message
            TimedOut      = $false
            ProcessId     = $null
            KillSucceeded = $null
            KillExitCode  = $null
        }
    }
}

function Invoke-UninstallEntry {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$RegistryEntry,
        [switch]$DryRun,
        [int]$MaxElapsedSeconds = 2400
    )

    $displayName = Get-OptionalPropertyValue -InputObject $RegistryEntry -Name 'DisplayName'
    $elapsedSeconds = Get-ElapsedTimeSeconds
    
    if ($elapsedSeconds -ge $MaxElapsedSeconds) {
        Write-Log -Message "Timeout budget exceeded ($elapsedSeconds/$MaxElapsedSeconds seconds); skipping uninstall for [$displayName]." -Level WARN
        return [pscustomobject]@{
            DisplayName      = $displayName
            Publisher        = Get-OptionalPropertyValue -InputObject $RegistryEntry -Name 'Publisher'
            DisplayVersion   = Get-OptionalPropertyValue -InputObject $RegistryEntry -Name 'DisplayVersion'
            ProductCode      = Get-OptionalPropertyValue -InputObject $RegistryEntry -Name 'ProductCode'
            CommandSource    = $null
            AttemptedCommand = $null
            Status           = 'TimeoutExceeded'
            ExitCode         = $null
            RebootRequired   = $false
            Reason           = "Global timeout budget exceeded after ${elapsedSeconds}s."
            RetryActions     = @()
        }
    }

    $resolved = Resolve-UninstallAction -RegistryEntry $RegistryEntry
    $retryActions = [System.Collections.Generic.List[object]]::new()

    $result = [ordered]@{
        DisplayName      = $displayName
        Publisher        = Get-OptionalPropertyValue -InputObject $RegistryEntry -Name 'Publisher'
        DisplayVersion   = Get-OptionalPropertyValue -InputObject $RegistryEntry -Name 'DisplayVersion'
        ProductCode      = Get-OptionalPropertyValue -InputObject $RegistryEntry -Name 'ProductCode'
        CommandSource    = $resolved.CommandSource
        AttemptedCommand = $resolved.DisplayCommand
        Status           = $null
        ExitCode         = $null
        RebootRequired   = $false
        Reason           = $resolved.Reason
        RetryActions     = @()
    }

    if (-not $resolved.Supported) {
        Write-Log -Message "Manual cleanup required for [$displayName]: $($resolved.Reason)" -Level WARN
        $result.Status = 'ManualCleanupRequired'
        return [pscustomobject]$result
    }

    if ($DryRun) {
        Write-Log -Message "DryRun: would uninstall [$displayName] with [$($resolved.DisplayCommand)]."
        $result.Status = 'DryRun'
        $result.Reason = "DryRun enabled. Would run: $($resolved.DisplayCommand)"
        return [pscustomobject]$result
    }

    if (-not $PSCmdlet.ShouldProcess($displayName, "Run uninstall command: $($resolved.DisplayCommand)")) {
        Write-Log -Message "WhatIf: would uninstall [$displayName] with [$($resolved.DisplayCommand)]."
        $result.Status = 'DryRun'
        $result.Reason = "WhatIf prevented execution. Would run: $($resolved.DisplayCommand)"
        return [pscustomobject]$result
    }

    Write-Log -Message "Starting uninstall for [$displayName] using [$($resolved.DisplayCommand)]."
    $primary = Invoke-UninstallProcess -FilePath $resolved.FilePath -Arguments ([string]$resolved.Arguments)
    if (-not $primary.Started) {
        Write-Log -Message "Failed to start uninstall for [$displayName]: $($primary.ErrorText)" -Level ERROR
        $result.Status = 'Failed'
        $result.Reason = "Failed to start uninstall command: $($primary.ErrorText)"
        return [pscustomobject]$result
    }

    if ($primary.TimedOut) {
        Write-Log -Message "Uninstall for [$displayName] timed out: $($primary.ErrorText)" -Level ERROR
        $result.Status = 'Failed'
        $result.Reason = $primary.ErrorText
        return [pscustomobject]$result
    }

    $result.ExitCode = $primary.ExitCode
    if ($script:SuccessExitCodes -contains $primary.ExitCode) {
        $result.RebootRequired = @(1641, 3010) -contains $primary.ExitCode
        $result.Status = if ($result.RebootRequired) { 'PendingReboot' } else { 'Removed' }
        $result.Reason = "Uninstall completed with exit code $($primary.ExitCode)."
        Write-Log -Message "Uninstall for [$displayName] completed with exit code $($primary.ExitCode)."
        return [pscustomobject]$result
    }

    Write-Log -Message "Primary uninstall for [$displayName] failed with exit code $($primary.ExitCode)." -Level ERROR

    if ($primary.ExitCode -eq 5 -and $displayName -match '(?i)\bAVG\b') {
        $statsUpdated = Enable-AvgSilentUninstallInStatsIni -UninstallerPath $resolved.FilePath
        if ($statsUpdated) {
            $statsRetry = Invoke-UninstallProcess -FilePath $resolved.FilePath -Arguments ([string]$resolved.Arguments)
            $retryActions.Add([pscustomobject]@{
                Step           = 'AvgStatsIniRetry'
                Command        = $resolved.DisplayCommand
                ExitCode       = $statsRetry.ExitCode
                Started        = $statsRetry.Started
                ErrorText      = $statsRetry.ErrorText
                RebootRequired = (@(1641, 3010) -contains $statsRetry.ExitCode)
            }) | Out-Null

            if ($statsRetry.TimedOut) {
                Write-Log -Message "AVG Stats.ini retry timed out for [$displayName]: $($statsRetry.ErrorText)" -Level ERROR
                $result.Status = 'Failed'
                $result.Reason = $statsRetry.ErrorText
                $result.RetryActions = @($retryActions)
                return [pscustomobject]$result
            }

            if ($statsRetry.Started -and $script:SuccessExitCodes -contains $statsRetry.ExitCode) {
                $result.ExitCode = $statsRetry.ExitCode
                $result.RebootRequired = @(1641, 3010) -contains $statsRetry.ExitCode
                $result.Status = if ($result.RebootRequired) { 'PendingReboot' } else { 'Removed' }
                $result.Reason = "Uninstall completed after AVG Stats.ini retry with exit code $($statsRetry.ExitCode)."
                $result.RetryActions = @($retryActions)
                Write-Log -Message "AVG Stats.ini retry succeeded for [$displayName] with exit code $($statsRetry.ExitCode)."
                return [pscustomobject]$result
            }
        }

        $cleanupAttempted = Invoke-AvgPreUninstallCleanup
        if ($cleanupAttempted) {
            $cleanupRetry = Invoke-UninstallProcess -FilePath $resolved.FilePath -Arguments ([string]$resolved.Arguments)
            $retryActions.Add([pscustomobject]@{
                Step           = 'AvgServiceCleanupRetry'
                Command        = $resolved.DisplayCommand
                ExitCode       = $cleanupRetry.ExitCode
                Started        = $cleanupRetry.Started
                ErrorText      = $cleanupRetry.ErrorText
                RebootRequired = (@(1641, 3010) -contains $cleanupRetry.ExitCode)
            }) | Out-Null

            if ($cleanupRetry.TimedOut) {
                Write-Log -Message "AVG cleanup retry timed out for [$displayName]: $($cleanupRetry.ErrorText)" -Level ERROR
                $result.Status = 'Failed'
                $result.Reason = $cleanupRetry.ErrorText
                $result.RetryActions = @($retryActions)
                return [pscustomobject]$result
            }

            if ($cleanupRetry.Started -and $script:SuccessExitCodes -contains $cleanupRetry.ExitCode) {
                $result.ExitCode = $cleanupRetry.ExitCode
                $result.RebootRequired = @(1641, 3010) -contains $cleanupRetry.ExitCode
                $result.Status = if ($result.RebootRequired) { 'PendingReboot' } else { 'Removed' }
                $result.Reason = "Uninstall completed after AVG cleanup retry with exit code $($cleanupRetry.ExitCode)."
                $result.RetryActions = @($retryActions)
                Write-Log -Message "AVG cleanup retry succeeded for [$displayName] with exit code $($cleanupRetry.ExitCode)."
                return [pscustomobject]$result
            }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$result.ProductCode) -and $resolved.FilePath -notmatch '^(?i)msiexec(?:\.exe)?$') {
            $fallback = New-MsiFallbackAction -DisplayName $displayName -ProductCode $result.ProductCode -CommandSource 'AvgMsiFallback' -Reason 'AVG retry using MSI product code fallback.'
            $fallbackRun = Invoke-UninstallProcess -FilePath $fallback.FilePath -Arguments ([string]$fallback.Arguments)
            $retryActions.Add([pscustomobject]@{
                Step           = 'AvgMsiFallback'
                Command        = $fallback.DisplayCommand
                ExitCode       = $fallbackRun.ExitCode
                Started        = $fallbackRun.Started
                ErrorText      = $fallbackRun.ErrorText
                RebootRequired = (@(1641, 3010) -contains $fallbackRun.ExitCode)
            }) | Out-Null

            if ($fallbackRun.TimedOut) {
                Write-Log -Message "AVG MSI fallback timed out for [$displayName]: $($fallbackRun.ErrorText)" -Level ERROR
                $result.Status = 'Failed'
                $result.Reason = $fallbackRun.ErrorText
                $result.RetryActions = @($retryActions)
                return [pscustomobject]$result
            }

            if ($fallbackRun.Started -and $script:SuccessExitCodes -contains $fallbackRun.ExitCode) {
                $result.AttemptedCommand = $fallback.DisplayCommand
                $result.CommandSource = $fallback.CommandSource
                $result.ExitCode = $fallbackRun.ExitCode
                $result.RebootRequired = @(1641, 3010) -contains $fallbackRun.ExitCode
                $result.Status = if ($result.RebootRequired) { 'PendingReboot' } else { 'Removed' }
                $result.Reason = "Uninstall completed after AVG MSI fallback with exit code $($fallbackRun.ExitCode)."
                $result.RetryActions = @($retryActions)
                Write-Log -Message "AVG MSI fallback succeeded for [$displayName] with exit code $($fallbackRun.ExitCode)."
                return [pscustomobject]$result
            }
        }

        Write-Log -Message "AVG uninstall for [$displayName] still failed after retry workflow." -Level WARN
    }

    $result.Status = 'Failed'
    $result.Reason = "Uninstall failed with exit code $($primary.ExitCode)."
    $result.RetryActions = @($retryActions)
    return [pscustomobject]$result
}
# endregion UninstallHelpers

# region InventoryHelpers
function Get-SecurityCenterProducts {
    $items = [System.Collections.Generic.List[object]]::new()
    $errorText = $null

    try {
        Write-Log -Message "Inventory step started: SecurityCenter2 query (timeout ${script:InventoryQueryTimeoutSeconds}s)."
        $products = Invoke-CommandWithTimeout -TimeoutSeconds $script:InventoryQueryTimeoutSeconds -Description 'SecurityCenter2 query' -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName 'AntivirusProduct' -ErrorAction Stop |
                ForEach-Object {
                    [pscustomobject]@{
                        DisplayName              = [string]$_.displayName
                        InstanceGuid             = [string]$_.instanceGuid
                        ProductState             = [string]$_.productState
                        PathToSignedProductExe   = [string]$_.pathToSignedProductExe
                        PathToSignedReportingExe = [string]$_.pathToSignedReportingExe
                    }
                }
        }

        foreach ($product in $products) {
            if (-not [string]::IsNullOrWhiteSpace([string]$product.displayName)) {
                $items.Add([pscustomobject]@{
                    DisplayName              = [string]$product.displayName
                    InstanceGuid             = [string]$product.instanceGuid
                    ProductState             = [string]$product.productState
                    PathToSignedProductExe   = [string]$product.pathToSignedProductExe
                    PathToSignedReportingExe = [string]$product.pathToSignedReportingExe
                }) | Out-Null
            }
        }

        Write-Log -Message "Inventory step completed: SecurityCenter2 query returned $($items.Count) item(s)."
    }
    catch {
        $errorText = $_.Exception.Message
        Write-Log -Message "SecurityCenter2 inventory unavailable: $errorText" -Level WARN
    }

    return [pscustomobject]@{
        Items = @($items)
        Error = $errorText
    }
}

function Get-InstalledSecurityPrograms {
    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $errorText = $null

    try {
        Write-Log -Message 'Inventory step started: uninstall registry scan.'
        $programs = Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
            Where-Object {
                $displayName = Get-OptionalPropertyValue -InputObject $_ -Name 'DisplayName'
                if ([string]::IsNullOrWhiteSpace($displayName)) {
                    $false
                }
                else {
                    Test-PatternMatch -Value $displayName -Patterns $script:InventoryDisplayNamePatterns
                }
            } |
            Select-Object DisplayName, Publisher, DisplayVersion, UninstallString, QuietUninstallString, PSChildName, WindowsInstaller |
            Sort-Object DisplayName, UninstallString, QuietUninstallString -Unique

        foreach ($program in $programs) {
            $items.Add([pscustomobject]@{
                DisplayName          = Get-OptionalPropertyValue -InputObject $program -Name 'DisplayName'
                Publisher            = Get-OptionalPropertyValue -InputObject $program -Name 'Publisher'
                DisplayVersion       = Get-OptionalPropertyValue -InputObject $program -Name 'DisplayVersion'
                UninstallString      = Get-OptionalPropertyValue -InputObject $program -Name 'UninstallString'
                QuietUninstallString = Get-OptionalPropertyValue -InputObject $program -Name 'QuietUninstallString'
                PSChildName          = Get-OptionalPropertyValue -InputObject $program -Name 'PSChildName'
                WindowsInstaller     = Get-OptionalPropertyValue -InputObject $program -Name 'WindowsInstaller'
                ProductCode          = Get-MsiProductCodeFromUninstallEntry -InputObject $program
            }) | Out-Null
        }

        Write-Log -Message "Inventory step completed: uninstall registry scan returned $($items.Count) item(s)."
    }
    catch {
        $errorText = $_.Exception.Message
        Write-Log -Message "Registry AV inventory failed: $errorText" -Level WARN
    }

    return [pscustomobject]@{
        Items = @($items)
        Error = $errorText
    }
}

function Get-DefenderStatus {
    $command = Get-Command -Name 'Get-MpComputerStatus' -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return [pscustomobject]@{
            Available                 = $false
            Error                     = 'Get-MpComputerStatus is unavailable.'
            AMServiceEnabled          = $false
            AntivirusEnabled          = $false
            AntispywareEnabled        = $false
            RealTimeProtectionEnabled = $false
            ProductStatus             = $null
            SignatureVersion          = $null
        }
    }

    try {
        Write-Log -Message "Inventory step started: Get-MpComputerStatus (timeout ${script:InventoryQueryTimeoutSeconds}s)."
        $status = Invoke-CommandWithTimeout -TimeoutSeconds $script:InventoryQueryTimeoutSeconds -Description 'Get-MpComputerStatus' -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $status = Get-MpComputerStatus -ErrorAction Stop
            [pscustomobject]@{
                Available                 = $true
                Error                     = $null
                AMServiceEnabled          = [bool]$status.AMServiceEnabled
                AntivirusEnabled          = [bool]$status.AntivirusEnabled
                AntispywareEnabled        = [bool]$status.AntispywareEnabled
                RealTimeProtectionEnabled = [bool]$status.RealTimeProtectionEnabled
                ProductStatus             = [string]$status.ProductStatus
                SignatureVersion          = [string]$status.AntivirusSignatureVersion
            }
        } | Select-Object -First 1

        Write-Log -Message 'Inventory step completed: Get-MpComputerStatus succeeded.'
        return $status
    }
    catch {
        Write-Log -Message "Get-MpComputerStatus failed: $($_.Exception.Message)" -Level WARN
        return [pscustomobject]@{
            Available                 = $false
            Error                     = $_.Exception.Message
            AMServiceEnabled          = $false
            AntivirusEnabled          = $false
            AntispywareEnabled        = $false
            RealTimeProtectionEnabled = $false
            ProductStatus             = $null
            SignatureVersion          = $null
        }
    }
}

function Get-PendingRebootState {
    $sources = [System.Collections.Generic.List[string]]::new()

    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $sources.Add('Component Based Servicing') | Out-Null
    }

    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $sources.Add('Windows Update') | Out-Null
    }

    try {
        $sessionManager = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction Stop
        $pendingFileRenames = Get-OptionalMemberValue -InputObject $sessionManager -Name 'PendingFileRenameOperations'
        if ($null -ne $pendingFileRenames -and @($pendingFileRenames).Count -gt 0) {
            $sources.Add('PendingFileRenameOperations') | Out-Null
        }
    }
    catch {
    }

    return [pscustomobject]@{
        IsPending = ($sources.Count -gt 0)
        Sources   = @($sources | Sort-Object -Unique)
    }
}

function Add-ObservedProduct {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Map,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    if (-not $Map.ContainsKey($Name)) {
        $Map[$Name] = [System.Collections.Generic.List[string]]::new()
    }

    $Map[$Name].Add($Source) | Out-Null
}

function Get-ObservedProducts {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$SecurityCenterProducts,
        [Parameter(Mandatory = $true)]
        [object[]]$RegistryPrograms,
        [Parameter(Mandatory = $true)]
        [psobject]$DefenderStatus
    )

    $map = @{}

    foreach ($product in $SecurityCenterProducts) {
        Add-ObservedProduct -Map $map -Name ([string]$product.DisplayName) -Source 'SecurityCenter2'
    }

    foreach ($program in $RegistryPrograms) {
        Add-ObservedProduct -Map $map -Name ([string]$program.DisplayName) -Source 'Registry'
    }

    $defenderSeen = @($map.Keys | Where-Object { Test-PatternMatch -Value $_ -Patterns $script:DefenderProductPatterns }).Count -gt 0
    $defenderFromStatus = $DefenderStatus.AMServiceEnabled -or $DefenderStatus.AntivirusEnabled -or $DefenderStatus.RealTimeProtectionEnabled -or $DefenderStatus.AntispywareEnabled
    if (-not $defenderSeen -and $defenderFromStatus) {
        Add-ObservedProduct -Map $map -Name 'Windows Defender Antivirus' -Source 'DefenderStatus'
    }

    return @(
        $map.GetEnumerator() |
            Sort-Object Name |
            ForEach-Object {
                [pscustomobject]@{
                    Name    = $_.Key
                    Sources = @($_.Value | Sort-Object -Unique)
                }
            }
    )
}

function Get-SecurityInventory {
    $securityCenter = Get-SecurityCenterProducts
    $registry = Get-InstalledSecurityPrograms
    $defender = Get-DefenderStatus
    $pendingReboot = Get-PendingRebootState
    $products = Get-ObservedProducts -SecurityCenterProducts $securityCenter.Items -RegistryPrograms $registry.Items -DefenderStatus $defender

    return [pscustomobject]@{
        Products             = $products
        SecurityCenter2      = @($securityCenter.Items)
        SecurityCenter2Error = $securityCenter.Error
        RegistryPrograms     = @($registry.Items)
        RegistryError        = $registry.Error
        DefenderStatus       = $defender
        PendingReboot        = $pendingReboot
    }
}
# endregion InventoryHelpers

# region ReportingValidationHelpers
function Get-ReportingDiscrepancies {
    <#
    .SYNOPSIS
    Detects discrepancies between registry/installed programs and WMI SecurityCenter2 reporting.
    
    .DESCRIPTION
    Some endpoints have AV installed and active (visible in WMI SecurityCenter2) but it may not 
    appear in registry uninstall entries, or vice versa. This function identifies these discrepancies
    to help diagnose Datto RMM reporting issues vs. actual compliance problems.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Inventory,
        [Parameter(Mandatory = $true)]
        [string[]]$ApprovedPatterns,
        [Parameter(Mandatory = $true)]
        [string]$Mode
    )
    
    $discrepancies = @()
    
    # Get what's reported in SecurityCenter2 (WMI - the "truth" from Windows)
    $wmiProducts = @($Inventory.SecurityCenter2 | Select-Object -ExpandProperty DisplayName)
    
    # Get what's in the registry (installed programs)
    $registryProducts = @($Inventory.RegistryPrograms | Select-Object -ExpandProperty DisplayName)
    
    # Check for products in WMI but not in registry (ghost installs or reporting issues)
    foreach ($wmiProduct in $wmiProducts) {
        $foundInRegistry = $false
        foreach ($regProduct in $registryProducts) {
            if ($wmiProduct -eq $regProduct -or $wmiProduct -like "*$regProduct*" -or $regProduct -like "*$wmiProduct*") {
                $foundInRegistry = $true
                break
            }
        }
        
        if (-not $foundInRegistry) {
            $isApproved = Test-PatternMatch -Value $wmiProduct -Patterns $ApprovedPatterns
            $discrepancies += [pscustomobject]@{
                Type           = 'WMI-Only'
                Product        = $wmiProduct
                Source         = 'SecurityCenter2 (WMI)'
                RegistryStatus = 'Not Found'
                IsApproved     = $isApproved
                Interpretation = if ($isApproved) { 
                    'Target AV is ACTIVE in Windows Security Center but missing from registry (possible reporting lag or clean uninstall remnant)'
                } else { 
                    'Non-target AV reported in Windows Security Center but not in registry (ghost entry or reporting issue)'
                }
            }
        }
    }
    
    # Check for products in registry but not in WMI (uninstalled but registry entry remains)
    foreach ($regProduct in $registryProducts) {
        $foundInWmi = $false
        foreach ($wmiProduct in $wmiProducts) {
            if ($regProduct -eq $wmiProduct -or $regProduct -like "*$wmiProduct*" -or $wmiProduct -like "*$regProduct*") {
                $foundInWmi = $true
                break
            }
        }
        
        if (-not $foundInWmi) {
            $isApproved = Test-PatternMatch -Value $regProduct -Patterns $ApprovedPatterns
            $discrepancies += [pscustomobject]@{
                Type           = 'Registry-Only'
                Product        = $regProduct
                Source         = 'Uninstall Registry'
                WmiStatus      = 'Not Detected'
                IsApproved     = $isApproved
                Interpretation = if ($isApproved) { 
                    'Target AV is registered but NOT active in Windows Security Center (likely already uninstalled or needs activation check)'
                } else { 
                    'Non-target AV registry entry remains but not detected by WMI (successful uninstall but registry cleanup needed)'
                }
            }
        }
    }
    
    return @($discrepancies)
}

function Test-TargetComplianceByWmi {
    <#
    .SYNOPSIS
    Directly tests if the target AV is present and active in WMI, independent of installation attempts.
    
    .DESCRIPTION
    This provides a definitive check: is the target actually installed and active according to
    Windows Security Center? This helps distinguish between "we need to install" vs "it's installed
    but Datto RMM doesn't see it."
    #>
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Inventory,
        [Parameter(Mandatory = $true)]
        [string]$Mode,
        [Parameter(Mandatory = $true)]
        [string[]]$ApprovedPatterns
    )
    
    $targetProducts = @($Inventory.SecurityCenter2 | 
        Where-Object { Test-PatternMatch -Value $_.DisplayName -Patterns $ApprovedPatterns } |
        Select-Object -ExpandProperty DisplayName)
    
    $wmiStatus = @{
        TargetDetected      = ($targetProducts.Count -gt 0)
        TargetProducts      = @($targetProducts)
        ProductCount        = $targetProducts.Count
        ComplianceByWmi     = ($targetProducts.Count -gt 0)
        TotalWmiProducts    = @($Inventory.SecurityCenter2).Count
    }
    
    return [pscustomobject]$wmiStatus
}
# endregion ReportingValidationHelpers
function Get-BlockingProductNames {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Inventory,
        [Parameter(Mandatory = $true)]
        [string[]]$ApprovedPatterns,
        [Parameter(Mandatory = $true)]
        [string[]]$AllowedNonTargetPatterns
    )

    return @(
        $Inventory.Products |
            Where-Object {
                -not (Test-PatternMatch -Value $_.Name -Patterns $ApprovedPatterns) -and
                -not (Test-PatternMatch -Value $_.Name -Patterns $AllowedNonTargetPatterns)
            } |
            Select-Object -ExpandProperty Name
    )
}

function Get-RemovalCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Inventory,
        [Parameter(Mandatory = $true)]
        [string[]]$ApprovedPatterns,
        [Parameter(Mandatory = $true)]
        [string[]]$AllowedNonTargetPatterns
    )

    return @(
        $Inventory.RegistryPrograms |
            Where-Object {
                -not (Test-PatternMatch -Value $_.DisplayName -Patterns $ApprovedPatterns) -and
                -not (Test-PatternMatch -Value $_.DisplayName -Patterns $AllowedNonTargetPatterns)
            }
    )
}

function Get-TargetPresenceState {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Inventory,
        [Parameter(Mandatory = $true)]
        [string]$Mode,
        [Parameter(Mandatory = $true)]
        [string[]]$ApprovedPatterns
    )

    $productNames = @($Inventory.Products | Select-Object -ExpandProperty Name)
    $defenderRegistered = @($productNames | Where-Object { Test-PatternMatch -Value $_ -Patterns $script:DefenderProductPatterns }).Count -gt 0
    $defenderActive = $Inventory.DefenderStatus.AMServiceEnabled -or $Inventory.DefenderStatus.AntivirusEnabled -or $Inventory.DefenderStatus.RealTimeProtectionEnabled -or $Inventory.DefenderStatus.AntispywareEnabled
    $dattoPresent = @($productNames | Where-Object { Test-PatternMatch -Value $_ -Patterns $ApprovedPatterns }).Count -gt 0

    return [pscustomobject]@{
        DefenderRegistered = $defenderRegistered
        DefenderActive     = $defenderActive
        DefenderSatisfied  = ($defenderRegistered -and ($defenderActive -or -not $Inventory.DefenderStatus.Available))
        DattoPresent       = $dattoPresent
    }
}

function Resolve-Outcome {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$BeforeInventory,
        [Parameter(Mandatory = $true)]
        [psobject]$AfterInventory,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Attempts,
        [Parameter(Mandatory = $true)]
        [string]$Mode,
        [Parameter(Mandatory = $true)]
        [string[]]$ApprovedPatterns,
        [Parameter(Mandatory = $true)]
        [string[]]$AllowedNonTargetPatterns,
        [switch]$DryRun
    )

    $afterBlocking = @(Get-BlockingProductNames -Inventory $AfterInventory -ApprovedPatterns $ApprovedPatterns -AllowedNonTargetPatterns $AllowedNonTargetPatterns)
    $targetPresence = Get-TargetPresenceState -Inventory $AfterInventory -Mode $Mode -ApprovedPatterns $ApprovedPatterns
    $attemptStatuses = @($Attempts | Select-Object -ExpandProperty Status)
    $successfulRemoval = @($attemptStatuses | Where-Object { @('Removed', 'PendingReboot') -contains $_ }).Count -gt 0
    $rebootRequired = @($Attempts | Where-Object { $_.RebootRequired }).Count -gt 0 -or $AfterInventory.PendingReboot.IsPending
    $manualCleanupNeeded = @($attemptStatuses | Where-Object { $_ -eq 'ManualCleanupRequired' }).Count -gt 0
    $failedAttempts = @($attemptStatuses | Where-Object { $_ -eq 'Failed' }).Count -gt 0
    $dryRunOnly = @($attemptStatuses | Where-Object { $_ -eq 'DryRun' }).Count -gt 0 -and -not $successfulRemoval -and -not $failedAttempts
    $beforeBlocking = @(Get-BlockingProductNames -Inventory $BeforeInventory -ApprovedPatterns $ApprovedPatterns -AllowedNonTargetPatterns $AllowedNonTargetPatterns)
    $beforeTargetPresence = Get-TargetPresenceState -Inventory $BeforeInventory -Mode $Mode -ApprovedPatterns $ApprovedPatterns
    $alreadySatisfied = ($beforeBlocking.Count -eq 0) -and (
        ($Mode -eq 'DattoAV' -and $beforeTargetPresence.DattoPresent) -or
        ($Mode -eq 'WindowsDefender' -and $beforeTargetPresence.DefenderSatisfied)
    )

    if ($afterBlocking.Count -eq 0) {
        if ($Mode -eq 'DattoAV' -and -not $targetPresence.DattoPresent) {
            return [pscustomobject]@{
                Outcome        = 'NeedsDattoPolicy'
                RebootRequired = $rebootRequired
                NextAction     = 'Check Datto AV policy/install.'
            }
        }

        if ($Mode -eq 'WindowsDefender' -and -not $targetPresence.DefenderSatisfied) {
            return [pscustomobject]@{
                Outcome        = 'Failed'
                RebootRequired = $rebootRequired
                NextAction     = 'Repair or enable Microsoft Defender, then rerun.'
            }
        }

        if ($alreadySatisfied -and -not $successfulRemoval) {
            return [pscustomobject]@{
                Outcome        = 'NoActionNeeded'
                RebootRequired = $rebootRequired
                NextAction     = 'No further action.'
            }
        }

        if ($successfulRemoval -and $rebootRequired) {
            return [pscustomobject]@{
                Outcome        = 'RemediatedPendingReboot'
                RebootRequired = $rebootRequired
                NextAction     = 'Reboot and rerun.'
            }
        }

        return [pscustomobject]@{
            Outcome        = if ($successfulRemoval) { 'Remediated' } else { 'NoActionNeeded' }
            RebootRequired = $rebootRequired
            NextAction     = 'No further action.'
        }
    }

    if ($failedAttempts) {
        return [pscustomobject]@{
            Outcome        = 'Failed'
            RebootRequired = $rebootRequired
            NextAction     = if ($DryRun -or $dryRunOnly) { 'Run again without -DryRun after validating the uninstall plan.' } else { 'Review failed uninstall attempts and log output.' }
        }
    }

    if (($DryRun -or $dryRunOnly) -and -not $manualCleanupNeeded) {
        return [pscustomobject]@{
            Outcome        = 'Failed'
            RebootRequired = $rebootRequired
            NextAction     = 'Run again without -DryRun after validating the uninstall plan.'
        }
    }

    if ($manualCleanupNeeded -or $afterBlocking.Count -gt 0) {
        return [pscustomobject]@{
            Outcome        = 'NeedsManualCleanup'
            RebootRequired = $rebootRequired
            NextAction     = 'Manual vendor cleanup tool required or investigate stale Windows Security Center registration.'
        }
    }

    return [pscustomobject]@{
        Outcome        = 'Failed'
        RebootRequired = $rebootRequired
        NextAction     = 'Review the summary JSON and log output.'
    }
}

function Write-ConsoleSummary {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Summary
    )

    $beforeProducts = Join-DisplayValues -Values @($Summary.BeforeInventory.Products | Select-Object -ExpandProperty Name)
    $afterProducts = Join-DisplayValues -Values @($Summary.AfterInventory.Products | Select-Object -ExpandProperty Name)
    $defenderSummary = 'Available={0}; Registered={1}; Active={2}' -f `
        $Summary.TargetPresence.DefenderCmdletAvailable, `
        $Summary.TargetPresence.DefenderRegistered, `
        $Summary.TargetPresence.DefenderActive

    Write-Output "Resolve RMM Antivirus State - $($Summary.ComputerName)"
    Write-Output "Target Mode: $($Summary.TargetMode)"
    Write-Output "Approved Patterns: $(Join-DisplayValues -Values $Summary.ApprovedProductPatterns)"
    Write-Output "Products Before: $beforeProducts"
    Write-Output "Products After: $afterProducts"
    Write-Output "Defender Status: $defenderSummary"

    if (@($Summary.UninstallAttempts).Count -gt 0) {
        Write-Output 'Uninstall Attempts:'
        foreach ($attempt in $Summary.UninstallAttempts) {
            $line = '- {0}: {1}' -f $attempt.DisplayName, $attempt.Status
            if ($attempt.ExitCode -ne $null) {
                $line += " (exit $($attempt.ExitCode))"
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$attempt.Reason)) {
                $line += " - $($attempt.Reason)"
            }
            Write-Output $line

            foreach ($retry in @($attempt.RetryActions)) {
                $retryLine = '  retry {0}: {1}' -f $retry.Step, $(if ($retry.Started) { "exit $($retry.ExitCode)" } else { "start failed: $($retry.ErrorText)" })
                Write-Output $retryLine
            }
        }
    }
    else {
        Write-Output 'Uninstall Attempts: (none)'
    }

    Write-Output "Outcome: $($Summary.Outcome)"
    Write-Output "Reboot Required: $(if ($Summary.RebootRequired) { 'Yes' } else { 'No' })"
    Write-Output "Next Action: $($Summary.NextAction)"
    
    if ($null -ne $Summary.WmiComplianceCheck) {
        Write-Output ""
        Write-Output "WMI Compliance Check (Target Detection via Windows Security Center):"
        Write-Output "  Target Detected: $($Summary.WmiComplianceCheck.TargetDetected)"
        Write-Output "  Compliant by WMI: $($Summary.WmiComplianceCheck.ComplianceByWmi)"
        if ($Summary.WmiComplianceCheck.TargetProducts.Count -gt 0) {
            Write-Output "  Target Products in WMI: $(($Summary.WmiComplianceCheck.TargetProducts -join '; '))"
        }
    }
    
    if ($null -ne $Summary.ReportingDiscrepancies -and @($Summary.ReportingDiscrepancies).Count -gt 0) {
        Write-Output ""
        Write-Output "Reporting Discrepancies (Registry vs WMI Mismatch - Possible Datto RMM Reporting Issue):"
        foreach ($disc in $Summary.ReportingDiscrepancies) {
            Write-Output "  [$($disc.Type)] $($disc.Product)"
            Write-Output "    Interpretation: $($disc.Interpretation)"
        }
    }
    
    Write-Output ""
    Write-Output "Log Path: $($Summary.LogPath)"
    Write-Output "Summary JSON: $($Summary.SummaryPath)"
}
# endregion EvaluationHelpers

# region Main
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$script:LogPath = Join-Path -Path $LogRoot -ChildPath ("{0}-{1}.log" -f $env:COMPUTERNAME, $runStamp)
$summaryPath = Join-Path -Path $LogRoot -ChildPath ("{0}-{1}.json" -f $env:COMPUTERNAME, $runStamp)
Ensure-Directory -Path $LogRoot

$approvedPatternsToUse = if ($ApprovedProductPatterns -and $ApprovedProductPatterns.Count -gt 0) {
    @($ApprovedProductPatterns)
}
else {
    Get-DefaultApprovedProductPatterns -Mode $TargetMode
}

$allowedNonTargetPatterns = Get-AllowedNonTargetPatterns -Mode $TargetMode
$beforeInventory = $null
$afterInventory = $null
$attempts = @()
$summary = $null

try {
    Assert-SupportedPowerShellVersion
    Assert-WindowsPlatform
    Write-Log -Message "=== Starting RMM antivirus remediation. TargetMode=$TargetMode DryRun=$($DryRun.IsPresent) ==="

    if (-not (Test-IsAdministrator)) {
        if ($DryRun -or $WhatIfPreference) {
            Write-Log -Message 'Not running elevated, but continuing because DryRun/WhatIf mode is active.' -Level WARN
        }
        else {
            throw 'Administrator privileges are required.'
        }
    }

    Write-Log -Message 'Collecting pre-remediation inventory.'
    $beforeInventory = Get-SecurityInventory
    Write-Log -Message ("Products before remediation: {0}" -f (Join-DisplayValues -Values @($beforeInventory.Products | Select-Object -ExpandProperty Name)))

    $candidates = Get-RemovalCandidates -Inventory $beforeInventory -ApprovedPatterns $approvedPatternsToUse -AllowedNonTargetPatterns $allowedNonTargetPatterns
    Write-Log -Message "Found $(@($candidates).Count) removal candidate(s)."
    foreach ($candidate in $candidates) {
        $attempts += Invoke-UninstallEntry -RegistryEntry $candidate -DryRun:$DryRun -WhatIf:$WhatIfPreference -MaxElapsedSeconds 2400
    }

    Write-Log -Message 'Collecting post-remediation inventory.'
    if (Test-TimeoutExceeded -MaxSeconds 2700) {
        Write-Log -Message "Approaching timeout budget; skipping post-remediation inventory collection." -Level WARN
        $afterInventory = $beforeInventory
    }
    else {
        $afterInventory = Get-SecurityInventory
    }
    Write-Log -Message ("Products after remediation: {0}" -f (Join-DisplayValues -Values @($afterInventory.Products | Select-Object -ExpandProperty Name)))

    $outcome = Resolve-Outcome -BeforeInventory $beforeInventory -AfterInventory $afterInventory -Attempts $attempts -Mode $TargetMode -ApprovedPatterns $approvedPatternsToUse -AllowedNonTargetPatterns $allowedNonTargetPatterns -DryRun:$DryRun
    $targetPresence = Get-TargetPresenceState -Inventory $afterInventory -Mode $TargetMode -ApprovedPatterns $approvedPatternsToUse
    $reportingDiscrepancies = Get-ReportingDiscrepancies -Inventory $afterInventory -ApprovedPatterns $approvedPatternsToUse -Mode $TargetMode
    $wmiComplianceCheck = Test-TargetComplianceByWmi -Inventory $afterInventory -Mode $TargetMode -ApprovedPatterns $approvedPatternsToUse

    $summary = [pscustomobject]@{
        ComputerName             = $env:COMPUTERNAME
        Timestamp                = (Get-Date).ToString('o')
        TargetMode               = $TargetMode
        PowerShellVersion        = $PSVersionTable.PSVersion.ToString()
        UninstallTimeoutMinutes  = $script:UninstallTimeoutMinutes
        ApprovedProductPatterns  = @($approvedPatternsToUse)
        AllowedNonTargetPatterns = @($allowedNonTargetPatterns)
        DryRun                   = $DryRun.IsPresent
        BeforeInventory          = $beforeInventory
        UninstallAttempts        = @($attempts)
        AfterInventory           = $afterInventory
        TargetPresence           = [pscustomobject]@{
            DefenderCmdletAvailable = $afterInventory.DefenderStatus.Available
            DefenderRegistered      = $targetPresence.DefenderRegistered
            DefenderActive          = $targetPresence.DefenderActive
            DefenderSatisfied       = $targetPresence.DefenderSatisfied
            DattoPresent            = $targetPresence.DattoPresent
        }
        WmiComplianceCheck       = $wmiComplianceCheck
        ReportingDiscrepancies   = @($reportingDiscrepancies)
        Outcome                  = $outcome.Outcome
        RebootRequired           = $outcome.RebootRequired
        NextAction               = $outcome.NextAction
        LogPath                  = $script:LogPath
        SummaryPath              = $summaryPath
        FatalError               = $null
    }

    Write-Log -Message "Final outcome: $($summary.Outcome). NextAction=$($summary.NextAction)"
}
catch {
    Write-Log -Message "Fatal error: $($_.Exception.Message)" -Level ERROR

    if ($null -eq $beforeInventory) {
        $beforeInventory = [pscustomobject]@{
            Products             = @()
            SecurityCenter2      = @()
            SecurityCenter2Error = $null
            RegistryPrograms     = @()
            RegistryError        = $null
            DefenderStatus       = Get-DefenderStatus
            PendingReboot        = Get-PendingRebootState
        }
    }

    if ($null -eq $afterInventory) {
        $afterInventory = $beforeInventory
    }

    $targetPresence = Get-TargetPresenceState -Inventory $afterInventory -Mode $TargetMode -ApprovedPatterns $approvedPatternsToUse
    $reportingDiscrepancies = Get-ReportingDiscrepancies -Inventory $afterInventory -ApprovedPatterns $approvedPatternsToUse -Mode $TargetMode
    $wmiComplianceCheck = Test-TargetComplianceByWmi -Inventory $afterInventory -Mode $TargetMode -ApprovedPatterns $approvedPatternsToUse
    
    $summary = [pscustomobject]@{
        ComputerName             = $env:COMPUTERNAME
        Timestamp                = (Get-Date).ToString('o')
        TargetMode               = $TargetMode
        PowerShellVersion        = $PSVersionTable.PSVersion.ToString()
        UninstallTimeoutMinutes  = $script:UninstallTimeoutMinutes
        ApprovedProductPatterns  = @($approvedPatternsToUse)
        AllowedNonTargetPatterns = @($allowedNonTargetPatterns)
        DryRun                   = $DryRun.IsPresent
        BeforeInventory          = $beforeInventory
        UninstallAttempts        = @($attempts)
        AfterInventory           = $afterInventory
        TargetPresence           = [pscustomobject]@{
            DefenderCmdletAvailable = $afterInventory.DefenderStatus.Available
            DefenderRegistered      = $targetPresence.DefenderRegistered
            DefenderActive          = $targetPresence.DefenderActive
            DefenderSatisfied       = $targetPresence.DefenderSatisfied
            DattoPresent            = $targetPresence.DattoPresent
        }
        WmiComplianceCheck       = $wmiComplianceCheck
        ReportingDiscrepancies   = @($reportingDiscrepancies)
        Outcome                  = 'Failed'
        RebootRequired           = $afterInventory.PendingReboot.IsPending
        NextAction               = 'Review the log and summary JSON.'
        LogPath                  = $script:LogPath
        SummaryPath              = $summaryPath
        FatalError               = $_.Exception.Message
    }
}
finally {
    if ($null -ne $summary) {
        $summary | ConvertTo-Json -Depth 8 | Out-File -FilePath $summaryPath -Encoding UTF8
        Write-ConsoleSummary -Summary $summary
    }
}

if (@('NeedsDattoPolicy', 'NeedsManualCleanup', 'Failed') -contains $summary.Outcome) {
    throw "Resolve-RmmAntivirusState completed with outcome [$($summary.Outcome)]. Review $summaryPath and $($summary.LogPath)."
}
# endregion Main
