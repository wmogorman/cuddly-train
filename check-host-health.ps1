<# 
Hyper-V Host Health Quick Check
- Collects recent critical/errors/warnings from key event logs/providers
- Summarizes storage/volume status and free space
- Safe: read-only checks only
#>

param(
    [int]$HoursBack = 24,
    [string]$OutDir = "$env:ProgramData\HyperVHostHealth"
)

$ErrorActionPreference = "Stop"
$since = (Get-Date).AddHours(-1 * $HoursBack)

# Ensure output folder
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportTxt = Join-Path $OutDir "HostHealth_$env:COMPUTERNAME`_$stamp.txt"
$reportJson = Join-Path $OutDir "HostHealth_$env:COMPUTERNAME`_$stamp.json"

function Write-Section($title) {
    "`r`n==== $title ====`r`n" | Out-File -FilePath $reportTxt -Append -Encoding utf8
}

function Add-Lines($lines) {
    $lines | Out-File -FilePath $reportTxt -Append -Encoding utf8
}

# Collect objects for JSON too
$results = [ordered]@{
    ComputerName = $env:COMPUTERNAME
    Since        = $since
    Now          = (Get-Date)
    OS           = $null
    Hotfixes     = @()
    EventFindings= @()
    Storage      = [ordered]@{}
}

Write-Section "BASIC SYSTEM INFO"
$os = Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, LastBootUpTime
$results.OS = $os
Add-Lines ($os | Format-List | Out-String)

Write-Section "RECENT REBOOTS / UNEXPECTED SHUTDOWNS (System)"
# Common reboot/shutdown related event IDs
$rebootIds = 41, 1074, 6005, 6006, 6008, 109, 12, 13
try {
    $reboots = Get-WinEvent -FilterHashtable @{
        LogName   = "System"
        StartTime = $since
        Id        = $rebootIds
    } -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message

    $results.EventFindings += $reboots
    Add-Lines ($reboots | Format-Table -AutoSize | Out-String)
} catch {
    Add-Lines "Failed to query reboot events: $($_.Exception.Message)"
}

Write-Section "HYPER-V VMMS (Admin) - Errors/Warnings"
$vmmsLog = "Microsoft-Windows-Hyper-V-VMMS/Admin"
try {
    if (Get-WinEvent -ListLog $vmmsLog -ErrorAction SilentlyContinue) {
        $vmms = Get-WinEvent -FilterHashtable @{
            LogName   = $vmmsLog
            StartTime = $since
        } -ErrorAction SilentlyContinue |
        Where-Object { $_.LevelDisplayName -in @("Critical","Error","Warning") } |
        Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message

        $results.EventFindings += $vmms
        Add-Lines ($vmms | Format-Table -AutoSize | Out-String)
    } else {
        Add-Lines "Log not found: $vmmsLog"
    }
} catch {
    Add-Lines "Failed to query VMMS log: $($_.Exception.Message)"
}

Write-Section "HYPER-V WORKER (Admin) - Errors/Warnings"
$workerLog = "Microsoft-Windows-Hyper-V-Worker/Admin"
try {
    if (Get-WinEvent -ListLog $workerLog -ErrorAction SilentlyContinue) {
        $worker = Get-WinEvent -FilterHashtable @{
            LogName   = $workerLog
            StartTime = $since
        } -ErrorAction SilentlyContinue |
        Where-Object { $_.LevelDisplayName -in @("Critical","Error","Warning") } |
        Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message

        $results.EventFindings += $worker
        Add-Lines ($worker | Format-Table -AutoSize | Out-String)
    } else {
        Add-Lines "Log not found: $workerLog"
    }
} catch {
    Add-Lines "Failed to query Worker log: $($_.Exception.Message)"
}

Write-Section "STORAGE-RELATED SYSTEM EVENTS (Disk/Ntfs/ReFS/StorPort/iSCSI/MPIO)"
# Providers that commonly indicate storage trouble leading to Saved-Critical
$storageProviders = @(
    "disk", "ntfs", "refs", "storport", "partmgr", "volmgr", "volmgrx",
    "Microsoft-Windows-iScsiPrt", "mpio", "Microsoft-Windows-StorDiag", "Microsoft-Windows-StorageSpaces-Driver"
)

try {
    $storageEvents = Get-WinEvent -FilterHashtable @{
        LogName   = "System"
        StartTime = $since
    } -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.LevelDisplayName -in @("Critical","Error","Warning")) -and
        ($storageProviders -contains $_.ProviderName -or $storageProviders -contains ($_.ProviderName.ToLower()))
    } |
    Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message

    $results.EventFindings += $storageEvents
    Add-Lines ($storageEvents | Format-Table -AutoSize | Out-String)
} catch {
    Add-Lines "Failed to query storage-related events: $($_.Exception.Message)"
}

Write-Section "DISK / VOLUME STATUS"
try {
    $vols = Get-Volume | Sort-Object DriveLetter | Select-Object DriveLetter, FileSystemLabel, FileSystem, HealthStatus, OperationalStatus, SizeRemaining, Size
    $results.Storage.Volumes = $vols
    Add-Lines ($vols | Format-Table -AutoSize | Out-String)
} catch {
    Add-Lines "Get-Volume failed (may require newer OS / module): $($_.Exception.Message)"
}

try {
    $disks = Get-Disk | Sort-Object Number | Select-Object Number, FriendlyName, OperationalStatus, HealthStatus, Size, PartitionStyle
    $results.Storage.Disks = $disks
    Add-Lines ($disks | Format-Table -AutoSize | Out-String)
} catch {
    Add-Lines "Get-Disk failed: $($_.Exception.Message)"
}

Write-Section "PHYSICAL DISK / STORAGE POOL HEALTH (if Storage Spaces present)"
try {
    $pd = Get-PhysicalDisk -ErrorAction SilentlyContinue | Select-Object FriendlyName, MediaType, Size, HealthStatus, OperationalStatus
    if ($pd) {
        $results.Storage.PhysicalDisks = $pd
        Add-Lines ($pd | Format-Table -AutoSize | Out-String)
    } else {
        Add-Lines "No PhysicalDisk info available (Storage Spaces not present or not supported)."
    }
} catch {
    Add-Lines "Get-PhysicalDisk failed: $($_.Exception.Message)"
}

try {
    $pools = Get-StoragePool -ErrorAction SilentlyContinue | Select-Object FriendlyName, HealthStatus, OperationalStatus, IsPrimordial
    if ($pools) {
        $results.Storage.Pools = $pools
        Add-Lines ($pools | Format-Table -AutoSize | Out-String)
    } else {
        Add-Lines "No StoragePool info available."
    }
} catch {
    Add-Lines "Get-StoragePool failed: $($_.Exception.Message)"
}

Write-Section "HYPER-V SERVICE STATUS"
$svcNames = "vmms","vmcompute"
$svcs = foreach ($n in $svcNames) { Get-Service -Name $n -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType }
$results.Services = $svcs
Add-Lines ($svcs | Format-Table -AutoSize | Out-String)

Write-Section "DONE"
Add-Lines "Report saved to:"
Add-Lines " - $reportTxt"
# Save JSON (best effort: event objects can be large; we keep it anyway)
try {
    $results | ConvertTo-Json -Depth 6 | Out-File -FilePath $reportJson -Encoding utf8
    Add-Lines " - $reportJson"
} catch {
    Add-Lines "JSON export failed: $($_.Exception.Message)"
}

Write-Output "OK: Host health report written to $reportTxt"
exit 0
