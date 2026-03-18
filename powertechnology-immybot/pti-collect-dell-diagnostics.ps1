#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$OutputDirectory = 'C:\ProgramData\PTI\Diagnostics\Dell',

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-dell-diagnostics.log',

    [string]$BaselineLogPath = 'C:\ProgramData\PTI\Logs\pti-workstation-baseline.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'pti-common.ps1')

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

function Test-AnyPatternMatch {
    param(
        [string]$Value,
        [string[]]$Patterns
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    foreach ($pattern in $Patterns) {
        if ($Value -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-LastBootTimeUtc {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return ([datetime]$os.LastBootUpTime).ToUniversalTime()
    }
    catch {
        return (Get-Date).ToUniversalTime()
    }
}

Ensure-PTIDirectory -Path $OutputDirectory
Write-PTILog -Message 'Collecting PTI Dell diagnostics.' -LogPath $LogPath

$programPatterns = @(
    '(?i)\bDell\b',
    '(?i)\bSupportAssist\b',
    '(?i)\bDigital Delivery\b',
    '(?i)\bTechHub\b',
    '(?i)\bData Vault\b'
)

$servicePatterns = @(
    '(?i)^Dell',
    '(?i)^SupportAssist',
    '(?i)^DellDataVault',
    '(?i)^ServiceShell',
    '(?i)^TechHub'
)

$processPatterns = @(
    '(?i)^Dell',
    '(?i)^SupportAssist',
    '(?i)^ServiceShell',
    '(?i)^AgentAssist',
    '(?i)^DDV'
)

$matchingPrograms = @(
    Get-PTIInstalledPrograms | Where-Object {
        Test-AnyPatternMatch -Value $_.DisplayName -Patterns $programPatterns -or
        Test-AnyPatternMatch -Value $_.Publisher -Patterns @('(?i)\bDell\b')
    } | Sort-Object DisplayName, DisplayVersion -Unique
)

$programDiagnostics = @(
    $matchingPrograms | ForEach-Object {
        [pscustomobject]@{
            DisplayName          = $_.DisplayName
            DisplayVersion       = Get-ProgramPropertyValue -InputObject $_ -Name 'DisplayVersion'
            Publisher            = $_.Publisher
            WindowsInstaller     = Get-ProgramPropertyValue -InputObject $_ -Name 'WindowsInstaller'
            PSChildName          = Get-ProgramPropertyValue -InputObject $_ -Name 'PSChildName'
            MsiProductCode       = Get-MsiProductCodeFromProgram -Program $_
            QuietUninstallString = Get-ProgramPropertyValue -InputObject $_ -Name 'QuietUninstallString'
            UninstallString      = Get-ProgramPropertyValue -InputObject $_ -Name 'UninstallString'
            InstallLocation      = Get-ProgramPropertyValue -InputObject $_ -Name 'InstallLocation'
        }
    }
)

$serviceDiagnostics = @(
    Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue |
        Where-Object {
            Test-AnyPatternMatch -Value $_.Name -Patterns $servicePatterns -or
            Test-AnyPatternMatch -Value $_.DisplayName -Patterns $servicePatterns
        } |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Name          = $_.Name
                DisplayName   = $_.DisplayName
                State         = $_.State
                StartMode     = $_.StartMode
                PathName      = $_.PathName
                ProcessId     = $_.ProcessId
            }
        }
)

$processDiagnostics = @(
    Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            Test-AnyPatternMatch -Value $_.Name -Patterns $processPatterns -or
            Test-AnyPatternMatch -Value $_.ExecutablePath -Patterns @('(?i)\\Dell\\', '(?i)SupportAssist', '(?i)Digital Delivery')
        } |
        Sort-Object Name, ProcessId |
        ForEach-Object {
            [pscustomobject]@{
                Name           = $_.Name
                ProcessId      = $_.ProcessId
                ExecutablePath = $_.ExecutablePath
                CommandLine    = $_.CommandLine
            }
        }
)

$installedAppxDiagnostics = @(
    Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object {
            Test-AnyPatternMatch -Value $_.Name -Patterns @('(?i)dell', '(?i)supportassist') -or
            Test-AnyPatternMatch -Value $_.PackageFamilyName -Patterns @('(?i)dell', '(?i)supportassist')
        } |
        Sort-Object Name |
        Select-Object Name, PackageFullName, PackageFamilyName, Version
)

$provisionedAppxDiagnostics = @(
    Get-AppxProvisionedPackage -Online |
        Where-Object {
            Test-AnyPatternMatch -Value $_.DisplayName -Patterns @('(?i)dell', '(?i)supportassist')
        } |
        Sort-Object DisplayName |
        Select-Object DisplayName, PackageName, Version
)

$directoryDiagnostics = @(
    'C:\Program Files\Dell',
    'C:\Program Files (x86)\Dell',
    'C:\ProgramData\Dell',
    'C:\Program Files\SupportAssistAgent'
) | ForEach-Object {
    [pscustomobject]@{
        Path   = $_
        Exists = Test-Path -LiteralPath $_
    }
}

$baselineLogExcerpt = @()
if (Test-Path -LiteralPath $BaselineLogPath) {
    $baselineLogExcerpt = @(
        Get-Content -Path $BaselineLogPath -ErrorAction SilentlyContinue |
            Select-String -Pattern 'Dell|SupportAssist|Digital Delivery|MSI fallback|quiet uninstall|parsed uninstall|still appears installed' |
            Select-Object -Last 200 |
            ForEach-Object { $_.Line }
    )
}

$diagnostics = [pscustomobject]@{
    CapturedAtUtc         = (Get-Date).ToUniversalTime().ToString('o')
    ComputerName          = $env:COMPUTERNAME
    UserName              = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    LastBootTimeUtc       = (Get-LastBootTimeUtc).ToString('o')
    InstalledPrograms     = $programDiagnostics
    Services              = $serviceDiagnostics
    Processes             = $processDiagnostics
    InstalledAppxPackages = $installedAppxDiagnostics
    ProvisionedAppx       = $provisionedAppxDiagnostics
    Directories           = $directoryDiagnostics
    BaselineLogExcerpt    = $baselineLogExcerpt
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-dell-diagnostics-{0}.json" -f $timestamp)
$programsCsvPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-dell-programs-{0}.csv" -f $timestamp)
$servicesCsvPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-dell-services-{0}.csv" -f $timestamp)
$processesCsvPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-dell-processes-{0}.csv" -f $timestamp)
$summaryPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-dell-summary-{0}.txt" -f $timestamp)

$diagnostics | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8
$programDiagnostics | Export-Csv -Path $programsCsvPath -NoTypeInformation -Encoding UTF8
$serviceDiagnostics | Export-Csv -Path $servicesCsvPath -NoTypeInformation -Encoding UTF8
$processDiagnostics | Export-Csv -Path $processesCsvPath -NoTypeInformation -Encoding UTF8

@(
    "CapturedAtUtc: $($diagnostics.CapturedAtUtc)"
    "ComputerName: $($diagnostics.ComputerName)"
    "LastBootTimeUtc: $($diagnostics.LastBootTimeUtc)"
    ''
    'Installed Programs:'
    ($programDiagnostics | Format-Table -AutoSize | Out-String).TrimEnd()
    ''
    'Services:'
    ($serviceDiagnostics | Format-Table -AutoSize | Out-String).TrimEnd()
    ''
    'Processes:'
    ($processDiagnostics | Format-Table -AutoSize | Out-String).TrimEnd()
    ''
    'Relevant baseline log lines:'
    ($baselineLogExcerpt -join [Environment]::NewLine)
) | Set-Content -Path $summaryPath -Encoding UTF8

Write-PTILog -Message "PTI Dell diagnostics written to [$OutputDirectory]." -LogPath $LogPath

[pscustomobject]@{
    OutputDirectory = $OutputDirectory
    JsonPath        = $jsonPath
    ProgramsCsvPath = $programsCsvPath
    ServicesCsvPath = $servicesCsvPath
    ProcessesCsvPath = $processesCsvPath
    SummaryPath     = $summaryPath
    LogPath         = $LogPath
}
