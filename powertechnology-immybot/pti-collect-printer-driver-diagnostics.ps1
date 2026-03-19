#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$SourceRootPath = '\\pti-dcfs01\Applications\Public\! DRIVERS\Workstation Files\Printers',

    [string]$ShareUserName,

    [string]$SharePassword,

    [string]$OutputDirectory = 'C:\ProgramData\PTI\Diagnostics\Printers',

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-printer-driver-diagnostics.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'pti-common.ps1')

function Get-PTIDiagnosticRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FullPath,

        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $normalizedFullPath = $FullPath -replace '^Microsoft\.PowerShell\.Core\\FileSystem::', ''
    $normalizedRootPath = $RootPath -replace '^Microsoft\.PowerShell\.Core\\FileSystem::', ''

    if ($normalizedFullPath.StartsWith($normalizedRootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $normalizedFullPath.Substring($normalizedRootPath.Length).TrimStart('\')
    }

    if ($normalizedFullPath -match '^[^:]+:(?<remainder>\\.*)$') {
        return ([string]$Matches['remainder']).TrimStart('\')
    }

    return $normalizedFullPath
}

function Get-PTIInfPropertyValue {
    param(
        [string[]]$Content,
        [string]$Name
    )

    if (-not $Content -or [string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $match = $Content | Select-String -Pattern ("(?i)^\s*{0}\s*=\s*(.+)$" -f [regex]::Escape($Name)) | Select-Object -First 1
    if ($match) {
        return $match.Matches[0].Groups[1].Value.Trim()
    }

    return $null
}

function Test-PTITextMatch {
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

function Get-PTICandidateScore {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('LexmarkCopier', 'LexmarkMono', 'HP5000')]
        [string]$Target,

        [Parameter(Mandatory = $true)]
        [psobject]$Entry
    )

    $score = 0
    $text = @(
        $Entry.RelativePath
        $Entry.Provider
        $Entry.Manufacturer
        ($Entry.MatchLines -join ' ')
    ) -join ' '

    $isLegacy = Test-PTITextMatch -Value $text -Patterns @('(?i)Win_2kXP', '(?i)\bXP\b', '(?i)\b2000\b', '(?i)\b32BIT\b')
    $isFaxOrScan = Test-PTITextMatch -Value $text -Patterns @('(?i)\bFax\b', '(?i)\bScan\b')

    switch ($Target) {
        'LexmarkCopier' {
            if (Test-PTITextMatch -Value $text -Patterns @('(?i)\bLexmark\b')) { $score += 2 }
            if (Test-PTITextMatch -Value $text -Patterns @('(?i)\bX658\b', '(?i)\bXS658\b', '(?i)\bCopier\b')) { $score += 5 }
            if (Test-PTITextMatch -Value $text -Patterns @('(?i)\bMS810\b')) { $score -= 1 }
        }
        'LexmarkMono' {
            if (Test-PTITextMatch -Value $text -Patterns @('(?i)\bLexmark\b')) { $score += 2 }
            if (Test-PTITextMatch -Value $text -Patterns @('(?i)\bMS810\b')) { $score += 5 }
            if (Test-PTITextMatch -Value $text -Patterns @('(?i)\bUniversal\b')) { $score += 2 }
        }
        'HP5000' {
            if (Test-PTITextMatch -Value $text -Patterns @('(?i)\bHP\b', '(?i)\bHewlett\b')) { $score += 2 }
            if (Test-PTITextMatch -Value $text -Patterns @('(?i)\bLaserJet\b', '(?i)\b5000\b')) { $score += 5 }
        }
    }

    if ($isLegacy) {
        $score -= 4
    }

    if ($isFaxOrScan) {
        $score -= 5
    }

    return $score
}

function Get-PTIInstalledPrinterDiagnostics {
    $printers = @(Get-Printer -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object Name, DriverName, PortName, Shared, Published)
    $drivers = @(
        Get-PrinterDriver -ErrorAction SilentlyContinue |
            Sort-Object Name |
            Select-Object Name, InfPath, Manufacturer, MajorVersion
    )

    return [pscustomobject]@{
        Printers = $printers
        Drivers  = $drivers
    }
}

Ensure-PTIDirectory -Path $OutputDirectory
Write-PTILog -Message "Collecting PTI printer-driver diagnostics from [$SourceRootPath]." -LogPath $LogPath

$credential = New-PTICredential -UserName $ShareUserName -Password $SharePassword
$mounted = Mount-PTISharePath -Path $SourceRootPath -Credential $credential

try {
    if (-not (Test-Path -LiteralPath $mounted.ResolvedPath)) {
        throw "Printer source path not found: $SourceRootPath"
    }

    $sourceRootItem = Get-Item -LiteralPath $mounted.ResolvedPath -ErrorAction Stop
    $sourceRootResolved = $sourceRootItem.FullName

    $infFiles = @(Get-ChildItem -LiteralPath $mounted.ResolvedPath -Recurse -File -Filter '*.inf' -ErrorAction SilentlyContinue | Sort-Object FullName)
    $packageFiles = @(
        Get-ChildItem -LiteralPath $mounted.ResolvedPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.exe', '.zip', '.msi', '.cab') } |
            Sort-Object FullName
    )

    $infDiagnostics = @(
        $infFiles | ForEach-Object {
            $content = @(Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue)
            $matchLines = @(
                $content |
                    Select-String -Pattern '(?i)Lexmark|HP|Hewlett|LaserJet|5000|MS810|X658|XS658|Universal|Provider|Manufacturer|DriverVer|Class' |
                    Select-Object -First 25 |
                    ForEach-Object { $_.Line.Trim() }
            )

            [pscustomobject]@{
                Name               = $_.Name
                FullName           = $_.FullName
                RelativePath       = Get-PTIDiagnosticRelativePath -FullPath $_.FullName -RootPath $sourceRootResolved
                DirectoryName      = $_.DirectoryName
                Length             = $_.Length
                LastWriteTime      = $_.LastWriteTime
                Provider           = Get-PTIInfPropertyValue -Content $content -Name 'Provider'
                Manufacturer       = Get-PTIInfPropertyValue -Content $content -Name 'Manufacturer'
                DriverVer          = Get-PTIInfPropertyValue -Content $content -Name 'DriverVer'
                Class              = Get-PTIInfPropertyValue -Content $content -Name 'Class'
                MatchLines         = $matchLines
                LexmarkCopierScore = 0
                LexmarkMonoScore   = 0
                HP5000Score        = 0
            }
        }
    )

    foreach ($entry in $infDiagnostics) {
        $entry.LexmarkCopierScore = Get-PTICandidateScore -Target 'LexmarkCopier' -Entry $entry
        $entry.LexmarkMonoScore = Get-PTICandidateScore -Target 'LexmarkMono' -Entry $entry
        $entry.HP5000Score = Get-PTICandidateScore -Target 'HP5000' -Entry $entry
    }

    $packageDiagnostics = @(
        $packageFiles | ForEach-Object {
            [pscustomobject]@{
                Name         = $_.Name
                FullName     = $_.FullName
                RelativePath = Get-PTIDiagnosticRelativePath -FullPath $_.FullName -RootPath $sourceRootResolved
                Extension    = $_.Extension
                Length       = $_.Length
                LastWriteTime = $_.LastWriteTime
            }
        }
    )

    $installedPrinterState = Get-PTIInstalledPrinterDiagnostics

    $diagnostics = [pscustomobject]@{
        CapturedAtUtc              = (Get-Date).ToUniversalTime().ToString('o')
        ComputerName               = $env:COMPUTERNAME
        SourceRootPath             = $SourceRootPath
        MountedResolvedPath        = $mounted.ResolvedPath
        InstalledPrinters          = $installedPrinterState.Printers
        InstalledPrinterDrivers    = $installedPrinterState.Drivers
        InfDiagnostics             = $infDiagnostics
        PackageDiagnostics         = $packageDiagnostics
        RecommendedLexmarkCopier   = @($infDiagnostics | Sort-Object -Property @{ Expression = 'LexmarkCopierScore'; Descending = $true }, RelativePath | Select-Object -First 10)
        RecommendedLexmarkMono     = @($infDiagnostics | Sort-Object -Property @{ Expression = 'LexmarkMonoScore'; Descending = $true }, RelativePath | Select-Object -First 10)
        RecommendedHP5000          = @($infDiagnostics | Sort-Object -Property @{ Expression = 'HP5000Score'; Descending = $true }, RelativePath | Select-Object -First 10)
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $jsonPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-printer-driver-diagnostics-{0}.json" -f $timestamp)
    $infCsvPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-printer-driver-inf-{0}.csv" -f $timestamp)
    $packageCsvPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-printer-driver-packages-{0}.csv" -f $timestamp)
    $installedDriversCsvPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-installed-printer-drivers-{0}.csv" -f $timestamp)
    $summaryPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-printer-driver-summary-{0}.txt" -f $timestamp)

    $diagnostics | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8
    $infDiagnostics | Export-Csv -Path $infCsvPath -NoTypeInformation -Encoding UTF8
    $packageDiagnostics | Export-Csv -Path $packageCsvPath -NoTypeInformation -Encoding UTF8
    $installedPrinterState.Drivers | Export-Csv -Path $installedDriversCsvPath -NoTypeInformation -Encoding UTF8

    @(
        "CapturedAtUtc: $($diagnostics.CapturedAtUtc)"
        "ComputerName: $($diagnostics.ComputerName)"
        "SourceRootPath: $($diagnostics.SourceRootPath)"
        ''
        'Installed Printers:'
        ($diagnostics.InstalledPrinters | Format-Table -AutoSize | Out-String).TrimEnd()
        ''
        'Installed Printer Drivers:'
        ($diagnostics.InstalledPrinterDrivers | Format-Table -AutoSize | Out-String).TrimEnd()
        ''
        'Top Lexmark Copier INF Candidates:'
        ($diagnostics.RecommendedLexmarkCopier | Select-Object RelativePath, LexmarkCopierScore, Provider, Manufacturer, DriverVer | Format-Table -AutoSize | Out-String).TrimEnd()
        ''
        'Top Lexmark Mono INF Candidates:'
        ($diagnostics.RecommendedLexmarkMono | Select-Object RelativePath, LexmarkMonoScore, Provider, Manufacturer, DriverVer | Format-Table -AutoSize | Out-String).TrimEnd()
        ''
        'Top HP5000 INF Candidates:'
        ($diagnostics.RecommendedHP5000 | Select-Object RelativePath, HP5000Score, Provider, Manufacturer, DriverVer | Format-Table -AutoSize | Out-String).TrimEnd()
        ''
        'Package Files:'
        ($packageDiagnostics | Select-Object RelativePath, Extension, Length | Format-Table -AutoSize | Out-String).TrimEnd()
    ) | Set-Content -Path $summaryPath -Encoding UTF8

    Write-PTILog -Message "PTI printer-driver diagnostics written to [$OutputDirectory]." -LogPath $LogPath

    [pscustomobject]@{
        OutputDirectory         = $OutputDirectory
        JsonPath                = $jsonPath
        InfCsvPath              = $infCsvPath
        PackageCsvPath          = $packageCsvPath
        InstalledDriversCsvPath = $installedDriversCsvPath
        SummaryPath             = $summaryPath
        LogPath                 = $LogPath
    }
}
finally {
    Dismount-PTISharePath -DriveName $mounted.DriveName
}
