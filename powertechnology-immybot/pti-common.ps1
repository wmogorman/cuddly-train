Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-PTIDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Write-PTILog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Level = 'INFO',

        [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti.log'
    )

    $directory = Split-Path -Path $LogPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        Ensure-PTIDirectory -Path $directory
    }

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    Add-Content -Path $LogPath -Value $line
    Write-Host "[PTI][$($Level.ToUpperInvariant())] $Message"
}

function New-PTICredential {
    param(
        [string]$UserName,
        [string]$Password
    )

    if ([string]::IsNullOrWhiteSpace($UserName) -and [string]::IsNullOrWhiteSpace($Password)) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($UserName) -or [string]::IsNullOrWhiteSpace($Password)) {
        throw 'Both UserName and Password must be provided when using secured share access.'
    }

    $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
    return [pscredential]::new($UserName, $securePassword)
}

function Mount-PTISharePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [pscredential]$Credential
    )

    if (-not $Credential -or $Path -notmatch '^(\\\\[^\\]+\\[^\\]+)(?<remainder>\\.*)?$') {
        return [pscustomobject]@{
            ResolvedPath = $Path
            DriveName    = $null
        }
    }

    $shareRoot = $Matches[1]
    $remainder = [string]$Matches['remainder']
    $driveName = 'PTI' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    New-PSDrive -Name $driveName -PSProvider FileSystem -Root $shareRoot -Credential $Credential -Scope Global | Out-Null

    $resolvedPath = if ([string]::IsNullOrWhiteSpace($remainder)) {
        '{0}:\' -f $driveName
    }
    else {
        '{0}:{1}' -f $driveName, $remainder
    }

    return [pscustomobject]@{
        ResolvedPath = $resolvedPath
        DriveName    = $driveName
    }
}

function Dismount-PTISharePath {
    param(
        [string]$DriveName
    )

    if (-not [string]::IsNullOrWhiteSpace($DriveName) -and (Get-PSDrive -Name $DriveName -ErrorAction SilentlyContinue)) {
        Remove-PSDrive -Name $DriveName -Force -ErrorAction SilentlyContinue
    }
}

function Copy-PTISourceToCache {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,

        [pscredential]$Credential,

        [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti.log'
    )

    Ensure-PTIDirectory -Path $DestinationRoot

    $mounted = Mount-PTISharePath -Path $SourcePath -Credential $Credential
    try {
        if (-not (Test-Path -LiteralPath $mounted.ResolvedPath)) {
            throw "Source path not found: $SourcePath"
        }

        $sourceItem = Get-Item -LiteralPath $mounted.ResolvedPath -ErrorAction Stop
        $leafName = if ([string]::IsNullOrWhiteSpace($sourceItem.Name)) { 'Source' } else { $sourceItem.Name }
        $destinationPath = Join-Path -Path $DestinationRoot -ChildPath $leafName

        if (Test-Path -LiteralPath $destinationPath) {
            Remove-Item -LiteralPath $destinationPath -Recurse -Force
        }

        Write-PTILog -Message "Copying source [$SourcePath] to [$destinationPath]." -LogPath $LogPath
        Copy-Item -LiteralPath $sourceItem.FullName -Destination $destinationPath -Recurse -Force
        return $destinationPath
    }
    finally {
        Dismount-PTISharePath -DriveName $mounted.DriveName
    }
}

function Resolve-PTIRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return $BasePath
    }

    return Join-Path -Path $BasePath -ChildPath $RelativePath
}

function Invoke-PTIProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string]$ArgumentList,

        [string]$WorkingDirectory,

        [int[]]$SuccessExitCodes = @(0, 1641, 3010),

        [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti.log'
    )

    $parameters = @{
        FilePath    = $FilePath
        Wait        = $true
        PassThru    = $true
        ErrorAction = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($ArgumentList)) {
        $parameters.ArgumentList = $ArgumentList
    }

    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $parameters.WorkingDirectory = $WorkingDirectory
    }

    Write-PTILog -Message ("Starting process [{0}] {1}" -f $FilePath, $ArgumentList) -LogPath $LogPath
    $process = Start-Process @parameters
    Write-PTILog -Message ("Process [{0}] exited with code {1}." -f $FilePath, $process.ExitCode) -LogPath $LogPath

    if ($SuccessExitCodes -notcontains $process.ExitCode) {
        throw "Process [$FilePath] exited with code $($process.ExitCode)."
    }

    return $process.ExitCode
}

function Get-PTIInstalledPrograms {
    [CmdletBinding()]
    param()

    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    return Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.DisplayName) } |
        Select-Object DisplayName, Publisher, DisplayVersion, UninstallString, QuietUninstallString, PSChildName, WindowsInstaller
}
