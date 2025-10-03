<# 
Datto RMM: Largest Files & Root Folders (C:) — Safe-Exclude
- Lists largest files on C:\ (excludes unsafe-to-delete files/locations)
- Lists root-level folder sizes on C:\ in descending order
- Outputs CSVs and a concise console summary

Parameters you can edit up top:
  $TopFiles      — how many largest files to return
  $TopFolders    — how many root folders to return
  $MinFileSizeMB — skip files smaller than this (speeds scans)
#>

param(
    [int]$TopFiles = 100,
    [int]$TopFolders = 50,
    [int]$MinFileSizeMB = 50
)

# ---------- Config ----------
$Drive = 'C:'

# Paths we consider unsafe to delete; anything under these is excluded
$ProtectedRoots = @(
    'C:\Windows',
    'C:\Program Files',
    'C:\Program Files (x86)',
    'C:\ProgramData',
    'C:\Recovery',
    'C:\$WinREAgent',
    'C:\$WINDOWS.~BT',
    'C:\$GetCurrent',
    'C:\System Volume Information',
    'C:\PerfLogs',             # generally small; leave out of report
    'C:\$Recycle.Bin'          # system-managed
)

# Specific Windows subpaths that are notoriously dangerous to touch
$ProtectedCriticalSubpaths = @(
    'C:\Windows\Installer',
    'C:\Windows\WinSxS',
    'C:\Windows\System32',
    'C:\Windows\SysWOW64',
    'C:\Windows\Fonts',
    'C:\Windows\DriverStore',
    'C:\Windows\assembly',
    'C:\Windows\servicing'
)

# Specific files we never want to suggest (system-managed)
$ProtectedFiles = @(
    'C:\pagefile.sys',
    'C:\hiberfil.sys',
    'C:\swapfile.sys'
)

# Allowed exceptions (report even if under Windows). Add/remove as you wish.
$AllowedOverrides = @(
    'C:\Windows\Temp',
    'C:\Windows\SoftwareDistribution\Download'
)

# Output locations
$TimeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$HostName  = $env:COMPUTERNAME
$OutDir    = Join-Path 'C:\ProgramData\DattoRMM\DiskUsage' "$HostName\$TimeStamp"
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$FilesCsv      = Join-Path $OutDir 'LargestFiles.csv'
$RootFoldersCsv= Join-Path $OutDir 'RootFoldersBySize.csv'
$LogPath       = Join-Path $OutDir 'Scan.log'

# ---------- Helpers ----------
function Test-IsUnderPath {
    param(
        [Parameter(Mandatory=$true)][string]$Child,
        [Parameter(Mandatory=$true)][string]$Parent
    )
    try {
        $c = [System.IO.Path]::GetFullPath($Child)
        $p = [System.IO.Path]::GetFullPath($Parent.TrimEnd('\') + '\')
        return $c.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Is-ProtectedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }

    # Specific protected files
    if ($ProtectedFiles -contains $Path) { return $true }

    # Allowed overrides take precedence
    foreach ($a in $AllowedOverrides) {
        if (Test-IsUnderPath -Child $Path -Parent $a) { return $false }
    }

    # Protected critical subpaths
    foreach ($pp in $ProtectedCriticalSubpaths) {
        if (Test-IsUnderPath -Child $Path -Parent $pp) { return $true }
    }

    # Protected root areas
    foreach ($root in $ProtectedRoots) {
        if (Test-IsUnderPath -Child $Path -Parent $root) { return $true }
    }

    return $false
}

function Try-GetChildItems {
    param(
        [string]$Path,
        [switch]$FilesOnly,
        [switch]$DirsOnly
    )
    try {
        if ($FilesOnly) {
            Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction Stop
        } elseif ($DirsOnly) {
            Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction Stop
        } else {
            Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop
        }
    } catch {
        @() # swallow access errors
    }
}

# ---------- Largest Files ----------
Write-Host "Scanning largest files on $Drive (>= $MinFileSizeMB MB)..." 

$minBytes = [int64]$MinFileSizeMB * 1MB
$largestFiles = @()

# We enumerate by top-level first to avoid expensive recursing into protected roots.
$topLevelDirs = Try-GetChildItems -Path $Drive -DirsOnly | Where-Object {
    # skip reparse points and protected roots
    $_.Attributes -notmatch 'ReparsePoint' -and -not (Is-ProtectedPath -Path $_.FullName)
}

# Include root-level files (that aren’t protected)
$rootLevelFiles = Try-GetChildItems -Path $Drive -FilesOnly | Where-Object {
    -not (Is-ProtectedPath -Path $_.FullName) -and $_.Length -ge $minBytes
}

$largestFiles += $rootLevelFiles | Select-Object FullName, Length, @{n='SizeMB';e={[math]::Round($_.Length/1MB,2)}}, LastWriteTime

# Go through each allowed top-level directory and recurse
foreach ($dir in $topLevelDirs) {
    # Enumerate files under each allowed root, skipping reparse points along the way
    try {
        Get-ChildItem -LiteralPath $dir.FullName -File -Recurse -Force -ErrorAction Stop |
            Where-Object {
                $_.Length -ge $minBytes -and -not (Is-ProtectedPath -Path $_.FullName)
            } |
            ForEach-Object {
                [pscustomobject]@{
                    FullName     = $_.FullName
                    Length       = $_.Length
                    SizeMB       = [math]::Round($_.Length/1MB, 2)
                    LastWriteTime= $_.LastWriteTime
                }
            } | ForEach-Object { $largestFiles += $_ }
    } catch {
        "`n[Files] Access denied or error: $($dir.FullName) - $($_.Exception.Message)" | Out-File -FilePath $LogPath -Append -Encoding UTF8
    }
}

$largestFiles = $largestFiles | Sort-Object Length -Descending | Select-Object -First $TopFiles
$largestFiles | Export-Csv -Path $FilesCsv -NoTypeInformation -Encoding UTF8

# ---------- Root-Level Folders by Size ----------
Write-Host "Calculating root-level folder sizes on $Drive ... (excluding protected roots)"

$folderSizes = @()

$rootDirsForSizing = Try-GetChildItems -Path $Drive -DirsOnly | Where-Object {
    $_.Attributes -notmatch 'ReparsePoint'
} | Sort-Object Name

foreach ($rd in $rootDirsForSizing) {
    if (Is-ProtectedPath -Path $rd.FullName) {
        # skip protected roots entirely
        continue
    }

    $total = 0L
    try {
        # Enumerate all files under this root dir, excluding protected subpaths
        Get-ChildItem -LiteralPath $rd.FullName -File -Recurse -Force -ErrorAction Stop |
            Where-Object { -not (Is-ProtectedPath -Path $_.FullName) } |
            ForEach-Object { $total += $_.Length }
    } catch {
        "`n[Folders] Access denied or error: $($rd.FullName) - $($_.Exception.Message)" | Out-File -FilePath $LogPath -Append -Encoding UTF8
        continue
    }

    $folderSizes += [pscustomobject]@{
        RootFolder = $rd.FullName
        Bytes      = $total
        SizeGB     = [math]::Round($total/1GB, 2)
        SizeMB     = [math]::Round($total/1MB, 2)
    }
}

$folderSizes = $folderSizes | Sort-Object Bytes -Descending | Select-Object -First $TopFolders
$folderSizes | Export-Csv -Path $RootFoldersCsv -NoTypeInformation -Encoding UTF8

# ---------- Console Summary ----------
Write-Host ""
Write-Host "=== Output Files ==="
Write-Host "Largest files:        $FilesCsv"
Write-Host "Root folders by size: $RootFoldersCsv"
if (Test-Path $LogPath) {
    Write-Host "Scan log (errors):    $LogPath"
}

Write-Host ""
Write-Host "Top $TopFiles files (preview):"
$largestFiles | Select-Object @{n='SizeMB';e={$_.SizeMB}}, @{n='Modified';e={$_.LastWriteTime}}, FullName | Format-Table -AutoSize

Write-Host ""
Write-Host "Top $TopFolders root folders (preview):"
$folderSizes | Select-Object @{n='SizeGB';e={$_.SizeGB}}, RootFolder | Format-Table -AutoSize

exit 0
