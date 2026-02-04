[CmdletBinding()]
param(
    [string]$LogPath = 'C:\ProgramData\AV_Removal.log',
    [string[]]$TargetPatterns = @('AVG', 'Bitdefender')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SuccessExitCodes = @(0, 1641, 3010)
$script:RebootRequired = $false

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

    Add-Content -Path $LogPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.DisplayName) } |
        Sort-Object DisplayName, UninstallString -Unique |
        Where-Object {
            foreach ($pattern in $Patterns) {
                if ($_.DisplayName -match $pattern) {
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

    if ($updated -notmatch '(?i)(^|\s)(/quiet|/qn|/s|/silent|/verysilent|--quiet|--silent)(\s|$)') {
        $updated = "$updated /quiet"
    }
    if ($updated -notmatch '(?i)(^|\s)(/norestart|/nr)(\s|$)') {
        $updated = "$updated /norestart"
    }

    return $updated.Trim()
}

function Invoke-LegacyAVUninstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [Parameter(Mandatory = $true)]
        [string]$CommandLine
    )

    $invocation = ConvertTo-ProcessInvocation -CommandLine $CommandLine
    if (-not $invocation) {
        Write-Log -Message "Unable to parse uninstall command for [$DisplayName]: $CommandLine" -Level ERROR
        return $false
    }

    $arguments = Add-SilentUninstallArguments -FilePath $invocation.FilePath -Arguments ([string]$invocation.Arguments)
    $displayCommand = if ([string]::IsNullOrWhiteSpace($arguments)) { $invocation.FilePath } else { "$($invocation.FilePath) $arguments" }
    Write-Log -Message "Executing uninstall for [$DisplayName]: $displayCommand"

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
    Write-Log -Message 'Script must run elevated (administrator). Exiting.' -Level ERROR
    throw 'Administrator privileges are required.'
}

Write-Log -Message '=== Starting Legacy AV Removal ==='
Write-Log -Message "Target patterns: $($TargetPatterns -join ', ')"

$apps = Get-LegacyAVUninstallEntries -Patterns $TargetPatterns

if (-not $apps) {
    Write-Log -Message 'No targeted AV products detected via uninstall registry keys.'
    Write-Log -Message '=== AV Removal Script Complete ==='
    return
}

$failedCount = 0

foreach ($app in $apps) {
    Write-Log -Message "Detected uninstall candidate: $($app.DisplayName)"

    $commandLine = if (-not [string]::IsNullOrWhiteSpace($app.QuietUninstallString)) {
        [string]$app.QuietUninstallString
    }
    else {
        [string]$app.UninstallString
    }

    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        Write-Log -Message "No uninstall command found for [$($app.DisplayName)]. Skipping." -Level WARN
        $failedCount++
        continue
    }

    $success = Invoke-LegacyAVUninstall -DisplayName $app.DisplayName -CommandLine $commandLine
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
