[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$LogPath = 'C:\ProgramData\AV_Removal.log',
    [string[]]$TargetPatterns = @('AVG', 'Bitdefender'),
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SuccessExitCodes = @(0, 1641, 3010)
$script:RebootRequired = $false
$script:VendorSilentSwitchProfiles = @(
    [pscustomobject]@{
        Name                    = 'AVG Consumer'
        DisplayNamePattern      = '(?i)^AVG (AntiVirus|Internet Security|Ultimate|Free|Driver Updater|Secure VPN|BreachGuard|TuneUp)'
        PreferredSilentSwitch   = '/silent'
        PreferredNoRestartSwitch = '/norestart'
    },
    [pscustomobject]@{
        Name                    = 'AVG Business'
        DisplayNamePattern      = '(?i)^AVG (Business|File Server|Email Server|CloudCare|Managed Workplace)'
        PreferredSilentSwitch   = '/silent'
        PreferredNoRestartSwitch = '/norestart'
    },
    [pscustomobject]@{
        Name                    = 'Bitdefender Consumer'
        DisplayNamePattern      = '(?i)^Bitdefender (Antivirus Plus|Internet Security|Total Security|Family Pack|Premium Security|VPN)'
        PreferredSilentSwitch   = '/silent'
        PreferredNoRestartSwitch = '/norestart'
    },
    [pscustomobject]@{
        Name                    = 'Bitdefender Endpoint'
        DisplayNamePattern      = '(?i)^Bitdefender (Endpoint Security Tools|Agent|GravityZone|BEST)'
        PreferredSilentSwitch   = '/quiet'
        PreferredNoRestartSwitch = '/norestart'
    },
    [pscustomobject]@{
        Name                    = 'AVG Generic'
        DisplayNamePattern      = '(?i)\bAVG\b'
        PreferredSilentSwitch   = '/silent'
        PreferredNoRestartSwitch = '/norestart'
    },
    [pscustomobject]@{
        Name                    = 'Bitdefender Generic'
        DisplayNamePattern      = '(?i)\bBitdefender\b'
        PreferredSilentSwitch   = '/quiet'
        PreferredNoRestartSwitch = '/norestart'
    }
)

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $logDirectory = Split-Path -Path $LogPath -Parent
    if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
    }

    if ($WhatIfPreference -and -not $DryRun) {
        return
    }

    Add-Content -Path $LogPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
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

function Get-LegacyAVUninstallEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    $registryPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
        Where-Object {
            $displayName = Get-OptionalPropertyValue -InputObject $_ -Name 'DisplayName'
            return -not [string]::IsNullOrWhiteSpace($displayName)
        } |
        Sort-Object -Property @{
            Expression = { Get-OptionalPropertyValue -InputObject $_ -Name 'DisplayName' }
        }, @{
            Expression = { Get-OptionalPropertyValue -InputObject $_ -Name 'UninstallString' }
        } -Unique |
        Where-Object {
            $displayName = Get-OptionalPropertyValue -InputObject $_ -Name 'DisplayName'
            foreach ($pattern in $Patterns) {
                if ($displayName -match $pattern) {
                    return $true
                }
            }

            return $false
        }
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

    if ($isMsiExec) {
        $updated = [regex]::Replace($updated, '(?i)(^|\s)/I(?=\s*[{])', '$1/X')

        if ($updated -notmatch '(?i)(^|\s)/X(\s|$)') {
            Write-Log -Message 'MSI command did not include /X; leaving arguments unchanged.' -Level WARN
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
    if ($null -ne $profile) {
        Write-Log -Message "Using silent-switch profile [$($profile.Name)] for [$DisplayName]"
    }

    $preferredSilentSwitch = if ($null -ne $profile) { $profile.PreferredSilentSwitch } else { '/quiet' }
    $preferredNoRestartSwitch = if ($null -ne $profile) { $profile.PreferredNoRestartSwitch } else { '/norestart' }

    $acceptedSilentSwitches = @('/quiet', '/qn', '/s', '/silent', '/verysilent', '--quiet', '--silent')
    if ($acceptedSilentSwitches -notcontains $preferredSilentSwitch) {
        $acceptedSilentSwitches += $preferredSilentSwitch
    }

    if (-not (Test-AnyArgumentPresent -Arguments $updated -Candidates $acceptedSilentSwitches)) {
        $updated = "$updated $preferredSilentSwitch"
    }
    if (-not (Test-AnyArgumentPresent -Arguments $updated -Candidates @('/norestart', '/nr'))) {
        $updated = "$updated $preferredNoRestartSwitch"
    }

    return $updated.Trim()
}

function Invoke-LegacyAVUninstall {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [Parameter(Mandatory = $true)]
        [string]$CommandLine,
        [switch]$DryRun
    )

    $invocation = ConvertTo-ProcessInvocation -CommandLine $CommandLine
    if (-not $invocation) {
        Write-Log -Message "Unable to parse uninstall command for [$DisplayName]: $CommandLine" -Level ERROR
        return $false
    }

    $arguments = Add-SilentUninstallArguments -DisplayName $DisplayName -FilePath $invocation.FilePath -Arguments ([string]$invocation.Arguments)
    $displayCommand = if ([string]::IsNullOrWhiteSpace($arguments)) { $invocation.FilePath } else { "$($invocation.FilePath) $arguments" }
    Write-Log -Message "Prepared uninstall command for [$DisplayName]: $displayCommand"

    if ($DryRun) {
        Write-Log -Message "DryRun enabled; would uninstall [$DisplayName] with: $displayCommand"
        return $true
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayName, "Run uninstall command: $displayCommand")) {
        Write-Log -Message "WhatIf: would uninstall [$DisplayName] with: $displayCommand"
        return $true
    }

    try {
        $process = Start-Process -FilePath $invocation.FilePath -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        $exitCode = $process.ExitCode

        if ($script:SuccessExitCodes -contains $exitCode) {
            if ($exitCode -in @(1641, 3010)) {
                $script:RebootRequired = $true
                Write-Log -Message "[$DisplayName] removed. Reboot required (exit code $exitCode)." -Level WARN
            }
            else {
                Write-Log -Message "[$DisplayName] removed successfully (exit code $exitCode)."
            }

            return $true
        }

        Write-Log -Message "[$DisplayName] uninstall failed with exit code $exitCode." -Level ERROR
        return $false
    }
    catch {
        Write-Log -Message "Failed to execute uninstall for [$DisplayName]: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

if (-not (Test-IsAdministrator)) {
    if ($DryRun -or $WhatIfPreference) {
        Write-Log -Message 'Not running elevated, but continuing because DryRun/WhatIf mode is active.' -Level WARN
    }
    else {
        Write-Log -Message 'Script must run elevated (administrator). Exiting.' -Level ERROR
        throw 'Administrator privileges are required.'
    }
}

Write-Log -Message '=== Starting Legacy AV Removal ==='
Write-Log -Message "Target patterns: $($TargetPatterns -join ', ')"
if ($DryRun) {
    Write-Log -Message 'DryRun mode active. No uninstall commands will be executed.' -Level WARN
}
elseif ($WhatIfPreference) {
    Write-Log -Message 'WhatIf mode active. No uninstall commands will be executed.' -Level WARN
}

$apps = Get-LegacyAVUninstallEntries -Patterns $TargetPatterns

if (-not $apps) {
    Write-Log -Message 'No targeted AV products detected via uninstall registry keys.'
    Write-Log -Message '=== AV Removal Script Complete ==='
    return
}

$failedCount = 0

foreach ($app in $apps) {
    $displayName = Get-OptionalPropertyValue -InputObject $app -Name 'DisplayName'
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        $displayName = '<Unknown Product>'
    }

    Write-Log -Message "Detected uninstall candidate: $displayName"

    $quietUninstall = Get-OptionalPropertyValue -InputObject $app -Name 'QuietUninstallString'
    $regularUninstall = Get-OptionalPropertyValue -InputObject $app -Name 'UninstallString'

    $commandLine = if (-not [string]::IsNullOrWhiteSpace($quietUninstall)) {
        $quietUninstall
    }
    else {
        $regularUninstall
    }

    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        Write-Log -Message "No uninstall command found for [$displayName]. Skipping." -Level WARN
        $failedCount++
        continue
    }

    $success = Invoke-LegacyAVUninstall -DisplayName $displayName -CommandLine $commandLine -DryRun:$DryRun -WhatIf:$WhatIfPreference
    if (-not $success) {
        $failedCount++
    }
}

Write-Log -Message "Registry uninstall phase complete. Failures: $failedCount."

if ($script:RebootRequired) {
    Write-Log -Message 'Reboot required to fully unload remaining AV drivers/services.' -Level WARN
}
else {
    Write-Log -Message 'No reboot signal detected from uninstall commands.'
}

Write-Log -Message '=== AV Removal Script Complete ==='

if ($failedCount -gt 0) {
    throw "Legacy AV removal completed with $failedCount failure(s). Review log at $LogPath."
}
