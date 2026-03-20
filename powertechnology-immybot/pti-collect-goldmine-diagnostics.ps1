#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$OutputDirectory = 'C:\ProgramData\PTI\Diagnostics\GoldMine',

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-goldmine-diagnostics.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'pti-common.ps1')

function Get-ObjectPropertyValue {
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

function Add-UniqueString {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$Set,

        [string]$Value
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        [void]$Set.Add($Value)
    }
}

function Get-LocalUserProfileDirectories {
    $excludedNames = @(
        'All Users',
        'Default',
        'Default User',
        'defaultuser0',
        'Public'
    )

    return @(
        Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $excludedNames -notcontains $_.Name
            } |
            Sort-Object FullName |
            Select-Object @{ Name = 'UserName'; Expression = { $_.Name } }, FullName
    )
}

function Get-LoadedUserSoftwareRegistryRoots {
    $results = New-Object System.Collections.Generic.List[object]
    $usersHiveRoot = 'Registry::HKEY_USERS'

    if (-not (Test-Path -LiteralPath $usersHiveRoot)) {
        return @()
    }

    foreach ($key in @(Get-ChildItem -LiteralPath $usersHiveRoot -ErrorAction SilentlyContinue)) {
        if ($key.PSChildName -notmatch '^S-\d-\d+-.+') {
            continue
        }

        $softwarePath = Join-Path -Path $key.PSPath -ChildPath 'Software'
        if (Test-Path -LiteralPath $softwarePath) {
            $results.Add([pscustomobject]@{
                    Sid          = $key.PSChildName
                    SoftwarePath = $softwarePath
                    OdbcIniPath  = Join-Path -Path $softwarePath -ChildPath 'ODBC\ODBC.INI'
                }) | Out-Null
        }
    }

    return @($results | Sort-Object Sid -Unique)
}

function Get-SearchableFilesFromRoots {
    param(
        [string[]]$RootPaths,

        [string[]]$Extensions = @('.ini', '.cfg', '.xml', '.config', '.dsn', '.udl', '.txt'),

        [string[]]$ExcludedDirectoryPatterns = @()
    )

    $results = New-Object System.Collections.Generic.List[object]
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($rootPath in @($RootPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
            continue
        }

        $rootDirectory = Get-Item -LiteralPath $rootPath -ErrorAction SilentlyContinue
        if ($null -eq $rootDirectory) {
            continue
        }

        $pendingDirectories = [System.Collections.Generic.Queue[object]]::new()
        $pendingDirectories.Enqueue($rootDirectory)

        while ($pendingDirectories.Count -gt 0) {
            $directory = $pendingDirectories.Dequeue()
            if (Test-AnyPatternMatch -Value $directory.FullName -Patterns $ExcludedDirectoryPatterns) {
                continue
            }

            foreach ($file in @(Get-ChildItem -LiteralPath $directory.FullName -File -Force -ErrorAction SilentlyContinue)) {
                if ($Extensions -contains $file.Extension.ToLowerInvariant()) {
                    if ($seenPaths.Add($file.FullName)) {
                        $results.Add($file) | Out-Null
                    }
                }
            }

            foreach ($subDirectory in @(Get-ChildItem -LiteralPath $directory.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                if (-not (Test-AnyPatternMatch -Value $subDirectory.FullName -Patterns $ExcludedDirectoryPatterns)) {
                    $pendingDirectories.Enqueue($subDirectory)
                }
            }
        }
    }

    return @($results | Sort-Object FullName -Unique)
}

function Get-GoldMinePatternMatchesInFiles {
    param(
        [Parameter(Mandatory = $true)]
        [psobject[]]$Files,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($file in $Files) {
        $matches = @(Select-String -Path $file.FullName -Pattern $Pattern -ErrorAction SilentlyContinue)
        foreach ($match in $matches) {
            $results.Add([pscustomobject]@{
                    Source     = $Source
                    Path       = $file.FullName
                    LineNumber = $match.LineNumber
                    Line       = $match.Line.Trim()
                }) | Out-Null
        }
    }

    return @($results | Sort-Object Path, LineNumber -Unique)
}

function Get-GoldMineInstalledPrograms {
    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    return @(
        Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
            ForEach-Object {
                $displayName = Get-ObjectPropertyValue -InputObject $_ -Name 'DisplayName'
                $publisher = Get-ObjectPropertyValue -InputObject $_ -Name 'Publisher'

                if (
                    (Test-AnyPatternMatch -Value $displayName -Patterns @('(?i)\bGoldMine\b')) -or
                    (Test-AnyPatternMatch -Value $publisher -Patterns @('(?i)\bGoldMine\b', '(?i)\bIvanti\b', '(?i)\bFrontRange\b'))
                ) {
                    [pscustomobject]@{
                        DisplayName          = $displayName
                        Publisher            = $publisher
                        DisplayVersion       = Get-ObjectPropertyValue -InputObject $_ -Name 'DisplayVersion'
                        InstallLocation      = Get-ObjectPropertyValue -InputObject $_ -Name 'InstallLocation'
                        UninstallString      = Get-ObjectPropertyValue -InputObject $_ -Name 'UninstallString'
                        QuietUninstallString = Get-ObjectPropertyValue -InputObject $_ -Name 'QuietUninstallString'
                        PSChildName          = Get-ObjectPropertyValue -InputObject $_ -Name 'PSChildName'
                        WindowsInstaller     = Get-ObjectPropertyValue -InputObject $_ -Name 'WindowsInstaller'
                    }
                }
            } |
            Sort-Object DisplayName, DisplayVersion
    )
}

function Get-GoldMineCandidateDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [psobject[]]$InstalledPrograms
    )

    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($defaultPath in @(
        'C:\Program Files (x86)\GoldMine',
        'C:\Program Files\GoldMine',
        'C:\ProgramData\GoldMine',
        (Join-Path -Path $env:APPDATA -ChildPath 'GoldMine'),
        (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'GoldMine')
    )) {
        if (-not [string]::IsNullOrWhiteSpace($defaultPath) -and (Test-Path -LiteralPath $defaultPath)) {
            [void]$paths.Add($defaultPath)
        }
    }

    foreach ($program in $InstalledPrograms) {
        Add-UniqueString -Set $paths -Value (Get-ObjectPropertyValue -InputObject $program -Name 'InstallLocation')
    }

    foreach ($profile in @(Get-LocalUserProfileDirectories)) {
        foreach ($userPath in @(
            (Join-Path -Path $profile.FullName -ChildPath 'AppData\Roaming\GoldMine'),
            (Join-Path -Path $profile.FullName -ChildPath 'AppData\Local\GoldMine')
        )) {
            if (Test-Path -LiteralPath $userPath) {
                [void]$paths.Add($userPath)
            }
        }
    }

    return @(
        $paths |
            Sort-Object |
            ForEach-Object {
                [pscustomobject]@{
                    Path   = $_
                    Exists = (Test-Path -LiteralPath $_)
                }
            }
    )
}

function Get-GoldMineUserProfileSearchRoots {
    param(
        [Parameter(Mandatory = $true)]
        [psobject[]]$UserProfiles
    )

    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($profile in $UserProfiles) {
        foreach ($userPath in @(
            (Join-Path -Path $profile.FullName -ChildPath 'AppData\Roaming'),
            (Join-Path -Path $profile.FullName -ChildPath 'AppData\Local')
        )) {
            if (Test-Path -LiteralPath $userPath -PathType Container) {
                [void]$paths.Add($userPath)
            }
        }
    }

    return @(
        $paths |
            Sort-Object |
            ForEach-Object {
                [pscustomobject]@{
                    Path   = $_
                    Exists = (Test-Path -LiteralPath $_ -PathType Container)
                }
            }
    )
}

function Get-GoldMineFileMatches {
    param(
        [Parameter(Mandatory = $true)]
        [psobject[]]$CandidateDirectories
    )

    $pattern = '(?i)Data Source=|Server=|Initial Catalog=|Database=|Trusted_Connection=|Integrated Security=|UID=|User ID=|DSN=|GoldMine|SQLSERVER|PTILT001'
    $excludedPathPatterns = @(
        '(?i)\\OnlineHelp\\',
        '(?i)\\Predefined Dashboards\\'
    )

    $files = @(Get-SearchableFilesFromRoots -RootPaths @($CandidateDirectories | Where-Object Exists | ForEach-Object Path) -ExcludedDirectoryPatterns $excludedPathPatterns)
    return @(Get-GoldMinePatternMatchesInFiles -Files $files -Pattern $pattern -Source 'CandidateDirectories')
}

function Get-GoldMineBroaderUserProfileFileMatches {
    param(
        [Parameter(Mandatory = $true)]
        [psobject[]]$UserProfileSearchRoots
    )

    $pattern = '(?i)Data Source=|Server=|Initial Catalog=|Database=|Trusted_Connection=|Integrated Security=|UID=|User ID=|DSN=|PTILT001|GoldMine|FrontRange|Ivanti'
    $excludedPathPatterns = @(
        '(?i)\\AppData\\Local\\Temp\\',
        '(?i)\\AppData\\Local\\Packages\\',
        '(?i)\\AppData\\Local\\Google\\Chrome\\User Data\\',
        '(?i)\\AppData\\Local\\Microsoft\\Edge\\User Data\\',
        '(?i)\\AppData\\Local\\Microsoft\\Windows\\INetCache\\',
        '(?i)\\AppData\\Roaming\\Mozilla\\Firefox\\Profiles\\',
        '(?i)\\AppData\\Roaming\\Microsoft\\Teams\\',
        '(?i)\\AppData\\Roaming\\Microsoft\\Windows\\',
        '(?i)\\AppData\\Roaming\\Code\\',
        '(?i)\\OnlineHelp\\',
        '(?i)\\Predefined Dashboards\\'
    )

    $files = @(Get-SearchableFilesFromRoots -RootPaths @($UserProfileSearchRoots | Where-Object Exists | ForEach-Object Path) -ExcludedDirectoryPatterns $excludedPathPatterns)
    return @(Get-GoldMinePatternMatchesInFiles -Files $files -Pattern $pattern -Source 'BroaderUserProfileScan')
}

function Get-GoldMineRegistryMatches {
    $searchRoots = New-Object System.Collections.Generic.List[string]

    foreach ($defaultRoot in @(
        'HKLM:\SOFTWARE',
        'HKLM:\SOFTWARE\WOW6432Node',
        'HKCU:\Software'
    )) {
        $searchRoots.Add($defaultRoot) | Out-Null
    }

    foreach ($loadedUserRoot in @(Get-LoadedUserSoftwareRegistryRoots)) {
        $searchRoots.Add($loadedUserRoot.SoftwarePath) | Out-Null
    }

    $candidateRoots = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($searchRoot in $searchRoots) {
        if (-not (Test-Path -LiteralPath $searchRoot)) {
            continue
        }

        $topLevelKeys = @(Get-ChildItem -LiteralPath $searchRoot -ErrorAction SilentlyContinue)
        foreach ($key in $topLevelKeys) {
            if ($key.PSChildName -match '(?i)GoldMine|FrontRange|Ivanti') {
                [void]$candidateRoots.Add($key.PSPath)
            }
        }
    }

    $namePatterns = @('(?i)Server', '(?i)Database', '(?i)Catalog', '(?i)DSN', '(?i)User', '(?i)UID', '(?i)Trusted', '(?i)Integrated', '(?i)GoldMine', '(?i)SQL')
    $valuePatterns = @('(?i)GoldMine', '(?i)PTILT001', '(?i)SQL', '(?i)Data Source=', '(?i)Server=', '(?i)Database=', '(?i)Trusted_Connection=', '(?i)Integrated Security=', '(?i)UID=')

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($candidateRoot in $candidateRoots) {
        $keys = @((Get-Item -LiteralPath $candidateRoot -ErrorAction SilentlyContinue)) + @(Get-ChildItem -LiteralPath $candidateRoot -Recurse -ErrorAction SilentlyContinue)
        foreach ($key in $keys) {
            $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $item) {
                continue
            }

            foreach ($property in $item.PSObject.Properties) {
                if ($property.Name -like 'PS*') {
                    continue
                }

                $value = [string]$property.Value
                if (
                    (Test-AnyPatternMatch -Value $property.Name -Patterns $namePatterns) -or
                    (Test-AnyPatternMatch -Value $value -Patterns $valuePatterns)
                ) {
                    $results.Add([pscustomobject]@{
                            KeyPath       = ($key.Name -replace '^HKEY_', 'HK')
                            PropertyName  = $property.Name
                            PropertyValue = $value
                        }) | Out-Null
                }
            }
        }
    }

    return @($results | Sort-Object KeyPath, PropertyName -Unique)
}

function Get-GoldMineOdbcDiagnostics {
    $roots = New-Object System.Collections.Generic.List[object]

    foreach ($defaultRoot in @(
        'HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI',
        'HKLM:\SOFTWARE\ODBC\ODBC.INI',
        'HKCU:\Software\ODBC\ODBC.INI'
    )) {
        $roots.Add([pscustomobject]@{ Label = $defaultRoot; Path = $defaultRoot }) | Out-Null
    }

    foreach ($loadedUserRoot in @(Get-LoadedUserSoftwareRegistryRoots)) {
        $roots.Add([pscustomobject]@{
                Label = "HKEY_USERS\\$($loadedUserRoot.Sid)\\Software\\ODBC\\ODBC.INI"
                Path  = $loadedUserRoot.OdbcIniPath
            }) | Out-Null
    }

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root.Path)) {
            continue
        }

        foreach ($key in @(Get-ChildItem -LiteralPath $root.Path -ErrorAction SilentlyContinue)) {
            if ($key.PSChildName -eq 'ODBC Data Sources') {
                continue
            }

            $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $item) {
                continue
            }

            $server = @(
                Get-ObjectPropertyValue -InputObject $item -Name 'Server'
                Get-ObjectPropertyValue -InputObject $item -Name 'Data Source'
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1

            $database = @(
                Get-ObjectPropertyValue -InputObject $item -Name 'Database'
                Get-ObjectPropertyValue -InputObject $item -Name 'Initial Catalog'
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1

            $trustedConnection = @(
                Get-ObjectPropertyValue -InputObject $item -Name 'Trusted_Connection'
                Get-ObjectPropertyValue -InputObject $item -Name 'Integrated Security'
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1

            $userId = @(
                Get-ObjectPropertyValue -InputObject $item -Name 'UID'
                Get-ObjectPropertyValue -InputObject $item -Name 'User ID'
                Get-ObjectPropertyValue -InputObject $item -Name 'LastUser'
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1

            $text = @(
                $key.PSChildName
                (Get-ObjectPropertyValue -InputObject $item -Name 'Driver')
                $server
                $database
                $trustedConnection
                $userId
                (Get-ObjectPropertyValue -InputObject $item -Name 'Description')
            ) -join ' '

            if (-not (Test-AnyPatternMatch -Value $text -Patterns @('(?i)\bGoldMine\b', '(?i)\bSQL\b', '(?i)\bODBC\b', '(?i)PTILT001'))) {
                continue
            }

            $results.Add([pscustomobject]@{
                    Hive               = $root.Label
                    DSN                = $key.PSChildName
                    Driver             = Get-ObjectPropertyValue -InputObject $item -Name 'Driver'
                    Server             = $server
                    Database           = $database
                    TrustedConnection  = $trustedConnection
                    UserId             = $userId
                    Description        = Get-ObjectPropertyValue -InputObject $item -Name 'Description'
                }) | Out-Null
        }
    }

    return @($results | Sort-Object Hive, DSN -Unique)
}

Ensure-PTIDirectory -Path $OutputDirectory
Write-PTILog -Message 'Collecting PTI GoldMine diagnostics.' -LogPath $LogPath

$installedPrograms = @(Get-GoldMineInstalledPrograms)
$loadedUserRegistryRoots = @(Get-LoadedUserSoftwareRegistryRoots)
$localUserProfiles = @(Get-LocalUserProfileDirectories)
$candidateDirectories = @(Get-GoldMineCandidateDirectories -InstalledPrograms $installedPrograms)
$userProfileSearchRoots = @(Get-GoldMineUserProfileSearchRoots -UserProfiles $localUserProfiles)
$candidateDirectoryFileMatches = @(Get-GoldMineFileMatches -CandidateDirectories $candidateDirectories)
$broaderUserProfileFileMatches = @(Get-GoldMineBroaderUserProfileFileMatches -UserProfileSearchRoots $userProfileSearchRoots)
$fileMatches = @($candidateDirectoryFileMatches + $broaderUserProfileFileMatches | Sort-Object Source, Path, LineNumber -Unique)
$registryMatches = @(Get-GoldMineRegistryMatches)
$odbcDiagnostics = @(Get-GoldMineOdbcDiagnostics)

$diagnostics = [pscustomobject]@{
    CapturedAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
    ComputerName        = $env:COMPUTERNAME
    UserName            = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    LocalUserProfiles   = $localUserProfiles
    LoadedUserRegistryRoots = $loadedUserRegistryRoots
    InstalledPrograms   = $installedPrograms
    CandidateDirectories = $candidateDirectories
    UserProfileSearchRoots = $userProfileSearchRoots
    OdbcDiagnostics     = $odbcDiagnostics
    RegistryMatches     = $registryMatches
    CandidateDirectoryFileMatches = $candidateDirectoryFileMatches
    BroaderUserProfileFileMatches = $broaderUserProfileFileMatches
    FileMatches         = $fileMatches
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-goldmine-diagnostics-{0}.json" -f $timestamp)
$odbcCsvPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-goldmine-odbc-{0}.csv" -f $timestamp)
$registryCsvPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-goldmine-registry-{0}.csv" -f $timestamp)
$fileMatchesCsvPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-goldmine-files-{0}.csv" -f $timestamp)
$summaryPath = Join-Path -Path $OutputDirectory -ChildPath ("pti-goldmine-summary-{0}.txt" -f $timestamp)

$diagnostics | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8
$odbcDiagnostics | Export-Csv -Path $odbcCsvPath -NoTypeInformation -Encoding UTF8
$registryMatches | Export-Csv -Path $registryCsvPath -NoTypeInformation -Encoding UTF8
$fileMatches | Export-Csv -Path $fileMatchesCsvPath -NoTypeInformation -Encoding UTF8

@(
    "CapturedAtUtc: $($diagnostics.CapturedAtUtc)"
    "ComputerName: $($diagnostics.ComputerName)"
    "UserName: $($diagnostics.UserName)"
    ''
    'Local User Profiles:'
    ($localUserProfiles | Format-Table -AutoSize | Out-String).TrimEnd()
    ''
    'Loaded User Registry Roots:'
    ($loadedUserRegistryRoots | Format-Table -AutoSize | Out-String).TrimEnd()
    ''
    'Installed Programs:'
    ($installedPrograms | Format-Table -AutoSize | Out-String).TrimEnd()
    ''
    'Candidate Directories:'
    ($candidateDirectories | Format-Table -AutoSize | Out-String).TrimEnd()
    ''
    'User Profile Search Roots:'
    ($userProfileSearchRoots | Format-Table -AutoSize | Out-String).TrimEnd()
    ''
    'ODBC Diagnostics:'
    ($odbcDiagnostics | Format-Table -AutoSize | Out-String).TrimEnd()
    ''
    'Registry Matches:'
    ($registryMatches | Select-Object -First 100 | Format-Table -AutoSize | Out-String).TrimEnd()
    ''
    'File Matches:'
    ($fileMatches | Select-Object -First 100 | Format-Table -AutoSize | Out-String).TrimEnd()
) | Set-Content -Path $summaryPath -Encoding UTF8

Write-PTILog -Message ("GoldMine diagnostics written to [{0}]." -f $OutputDirectory) -LogPath $LogPath

[pscustomobject]@{
    OutputDirectory   = $OutputDirectory
    JsonPath          = $jsonPath
    OdbcCsvPath       = $odbcCsvPath
    RegistryCsvPath   = $registryCsvPath
    FileMatchesCsvPath = $fileMatchesCsvPath
    SummaryPath       = $summaryPath
}
