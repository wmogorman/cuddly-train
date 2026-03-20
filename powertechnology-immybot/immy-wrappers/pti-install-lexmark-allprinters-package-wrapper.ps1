[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LexmarkPackageZip,

    [Parameter(DontShow = $true)]
    [string]$TenantName,

    [Parameter(DontShow = $true)]
    [string]$TenantSlug,

    [Parameter(DontShow = $true)]
    [string]$ComputerName,

    [Parameter(DontShow = $true)]
    [string]$ComputerSlug,

    [Parameter(DontShow = $true)]
    [string]$AzureTenantId,

    [Parameter(DontShow = $true)]
    [Guid]$PrimaryPersonAzurePrincipalId,

    [Parameter(DontShow = $true)]
    [string]$PrimaryPersonEmail,

    [Parameter(DontShow = $true)]
    [bool]$IsPortable,

    [string]$InstallerArguments = '',

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-lexmark-allprinters.log',

    [Parameter(DontShow = $true)]
    [ValidateRange(60, 3600)]
    [int]$InstallerWaitSeconds = 1200,

    [Parameter(DontShow = $true)]
    [ValidateRange(1, 3)]
    [int]$InstallerPassCount = 2,

    [Parameter(DontShow = $true, ValueFromRemainingArguments = $true)]
    [object[]]$ImmyRuntimeArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace([string](Get-Variable -Name 'Method' -ValueOnly -ErrorAction SilentlyContinue))) {
    $Method = 'Set'
}

function Write-PTILexmarkLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $logDirectory = Split-Path -Path $LogPath -Parent
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
    }

    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogPath -Value $line
}

function Resolve-LexmarkPackageRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackagePath
    )

    $stageRoot = 'C:\ProgramData\PTI\Packages\Lexmark-AllPrinters'
    $stageContentRoot = Join-Path -Path $stageRoot -ChildPath 'Content'

    if (Test-Path -LiteralPath $stageContentRoot) {
        Remove-Item -LiteralPath $stageContentRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    New-Item -Path $stageRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $stageContentRoot -ItemType Directory -Force | Out-Null

    $folderVariable = Get-Variable -Name 'LexmarkPackageZipFolder' -ValueOnly -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($folderVariable) -and (Test-Path -LiteralPath $folderVariable -PathType Container)) {
        Get-ChildItem -LiteralPath $folderVariable -Force | Copy-Item -Destination $stageContentRoot -Recurse -Force
        return $stageContentRoot
    }

    if (Test-Path -LiteralPath $PackagePath -PathType Container) {
        Get-ChildItem -LiteralPath $PackagePath -Force | Copy-Item -Destination $stageContentRoot -Recurse -Force
        return $stageContentRoot
    }

    if (Test-Path -LiteralPath $PackagePath -PathType Leaf) {
        Expand-Archive -LiteralPath $PackagePath -DestinationPath $stageContentRoot -Force
        return $stageContentRoot
    }

    throw "Unable to resolve package root from [$PackagePath]."
}

function Get-LexmarkPackageInstallerPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot
    )

    $installer = Get-ChildItem -Path $PackageRoot -Recurse -Filter 'LexmarkPkgInstaller.exe' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName

    if ([string]::IsNullOrWhiteSpace($installer)) {
        throw 'LexmarkPkgInstaller.exe was not found in the uploaded package.'
    }

    return $installer
}

function Get-ExpectedLexmarkQueueDefinitions {
    return @(
        [pscustomobject]@{ Name = 'Scheduling MS810dn'; IpAddress = '192.168.1.13' },
        [pscustomobject]@{ Name = 'Sales MS810dn'; IpAddress = '192.168.1.55' },
        [pscustomobject]@{ Name = 'Lexmark XS658de Front Copier'; IpAddress = '192.168.1.64' },
        [pscustomobject]@{ Name = 'Lexmark XS658de Copier #2'; IpAddress = '192.168.1.65' },
        [pscustomobject]@{ Name = 'Accounting MS810dn'; IpAddress = '192.168.1.66' }
    )
}

function Find-LexmarkQueueByIp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IpAddress
    )

    $printers = @(Get-Printer -ErrorAction SilentlyContinue)
    $ports = @(Get-PrinterPort -ErrorAction SilentlyContinue)
    return @(
        $printers | Where-Object {
            $port = @($ports | Where-Object Name -eq $_.PortName | Select-Object -First 1)
            $portHostAddress = $null

            if ($port.Count -gt 0) {
                $hostAddressProperty = $port[0].PSObject.Properties['PrinterHostAddress']
                if ($null -ne $hostAddressProperty -and -not [string]::IsNullOrWhiteSpace([string]$hostAddressProperty.Value)) {
                    $portHostAddress = [string]$hostAddressProperty.Value
                }
            }

            $_.DriverName -eq 'Lexmark Universal v2 XL' -and
            (
                $_.PortName -eq $IpAddress -or
                $_.PortName -eq ('IP_' + $IpAddress) -or
                $portHostAddress -eq $IpAddress
            )
        }
    )
}

function Get-LexmarkAllPrintersState {
    $queueStates = @(
        Get-ExpectedLexmarkQueueDefinitions | ForEach-Object {
            $matches = @(Find-LexmarkQueueByIp -IpAddress $_.IpAddress)
            [pscustomobject]@{
                ExpectedName = $_.Name
                IpAddress    = $_.IpAddress
                Installed    = ($matches.Count -gt 0)
                QueueNames   = @($matches | Select-Object -ExpandProperty Name)
                DriverNames  = @($matches | Select-Object -ExpandProperty DriverName -Unique)
                PortNames    = @($matches | Select-Object -ExpandProperty PortName -Unique)
            }
        }
    )

    return [pscustomobject]@{
        Compliant = (@($queueStates | Where-Object { -not $_.Installed }).Count -eq 0)
        Queues    = $queueStates
        LogPath   = $LogPath
    }
}

function Test-LexmarkPackageInstalled {
    param(
        [switch]$Quiet
    )

    $state = Get-LexmarkAllPrintersState
    $missing = @($state.Queues | Where-Object { -not $_.Installed })

    if ($missing.Count -gt 0) {
        $message = 'Missing expected Lexmark queues: ' + (($missing | ForEach-Object { '{0} ({1})' -f $_.ExpectedName, $_.IpAddress }) -join ' | ')
        if (-not $Quiet) {
            Write-PTILexmarkLog -Message $message
            Write-Warning $message
        }
        return $false
    }

    if (-not $Quiet) {
        Write-PTILexmarkLog -Message 'All expected Lexmark queues are present.'
        Write-Host 'All expected Lexmark queues are present.'
    }
    return $true
}

function Get-MissingLexmarkQueueSummary {
    $state = Get-LexmarkAllPrintersState
    $missing = @($state.Queues | Where-Object { -not $_.Installed })
    if ($missing.Count -eq 0) {
        return ''
    }

    return (($missing | ForEach-Object { '{0} ({1})' -f $_.ExpectedName, $_.IpAddress }) -join ' | ')
}

function Start-LexmarkInstallerPass {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [int]$PassNumber
    )

    Write-PTILexmarkLog -Message ("Starting Lexmark installer pass [{0}] using [{1}] with args [{2}]." -f $PassNumber, $InstallerPath, $InstallerArguments)

    if ([string]::IsNullOrWhiteSpace($InstallerArguments)) {
        $process = Start-Process -FilePath $InstallerPath -WorkingDirectory $WorkingDirectory -PassThru -WindowStyle Hidden
    }
    else {
        $process = Start-Process -FilePath $InstallerPath -ArgumentList $InstallerArguments -WorkingDirectory $WorkingDirectory -PassThru -WindowStyle Hidden
    }

    Write-PTILexmarkLog -Message ("Lexmark installer pass [{0}] started process id [{1}]." -f $PassNumber, $process.Id)
    return $process
}

function Install-LexmarkPackage {
    $packageRoot = Resolve-LexmarkPackageRoot -PackagePath $LexmarkPackageZip
    $installer = Get-LexmarkPackageInstallerPath -PackageRoot $packageRoot
    $installerDirectory = Split-Path -Path $installer -Parent

    $attemptCount = [Math]::Max([int][Math]::Ceiling($InstallerWaitSeconds / 10), 1)

    for ($pass = 1; $pass -le $InstallerPassCount; $pass++) {
        $process = Start-LexmarkInstallerPass -InstallerPath $installer -WorkingDirectory $installerDirectory -PassNumber $pass

        for ($attempt = 1; $attempt -le $attemptCount; $attempt++) {
            if (Test-LexmarkPackageInstalled -Quiet) {
                Write-PTILexmarkLog -Message ("Lexmark queues verified after pass [{0}] and {1} second(s)." -f $pass, (($attempt - 1) * 10))
                return $true
            }

            if ($process.HasExited) {
                Write-PTILexmarkLog -Message ("Lexmark installer pass [{0}] exited with code [{1}] before all queues were present." -f $pass, $process.ExitCode)
                if ($process.ExitCode -ne 0) {
                    throw "Lexmark package installer exited with code $($process.ExitCode)."
                }

                break
            }

            if ($attempt -lt $attemptCount) {
                Write-PTILexmarkLog -Message ("Lexmark verification retry {0}/{1} during pass [{2}] after waiting for queue registration." -f $attempt, $attemptCount, $pass)
                Start-Sleep -Seconds 10
            }
        }

        if ($pass -lt $InstallerPassCount) {
            $missingSummary = Get-MissingLexmarkQueueSummary
            if (-not [string]::IsNullOrWhiteSpace($missingSummary)) {
                Write-PTILexmarkLog -Message ("Lexmark installer pass [{0}] completed with queues still missing: {1}. Starting another pass." -f $pass, $missingSummary)
                Start-Sleep -Seconds 5
            }
        }
    }

    return (Test-LexmarkPackageInstalled)
}

switch -Regex ($Method) {
    '^(?i)Get$' {
        Get-LexmarkAllPrintersState
    }
    '^(?i)Test$' {
        Test-LexmarkPackageInstalled
    }
    '^(?i)Set$' {
        Install-LexmarkPackage
    }
    default {
        throw "Unsupported method: $Method"
    }
}
