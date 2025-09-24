# Remove-OldShares-And-Refresh.ps1
# Disconnect SMB mappings across all user profiles, update legacy server references, remove cached credentials, and run gpupdate /force.

$serverReplacements = [ordered]@{
    'BBM-FP01'  = 'BBM-DC01'
    '10.0.1.3'  = '10.0.1.6'
    'BBM-EVO01' = 'BBM-EVO02'
    '10.0.1.4'  = '10.0.1.11'
}

$servers = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
$activeShares = New-Object System.Collections.Generic.List[string]

function Add-ServerName {
    param([string]$Server)

    if ([string]::IsNullOrWhiteSpace($Server)) { return }

    $name = $Server.Trim().TrimStart('\\')
    if (-not $name) { return }

    $name = $name.Split('\')[0]
    if (-not $name) { return }

    [void]$servers.Add($name)

    if ($serverReplacements.Contains($name)) {
        [void]$servers.Add($serverReplacements[$name])
    }

    $reverseMatch = $serverReplacements.GetEnumerator() | Where-Object { $_.Value -eq $name }
    foreach ($item in $reverseMatch) {
        [void]$servers.Add($item.Key)
    }
}

function Get-ServersFromPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if ($Path -match '^\\\\([^\\\/]+)') {
        Add-ServerName $matches[1]
    }
}

function Set-ServerReplacements {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    $result = $Text
    foreach ($pair in $serverReplacements.GetEnumerator()) {
        $escaped = [System.Text.RegularExpressions.Regex]::Escape($pair.Key)
        $result = [System.Text.RegularExpressions.Regex]::Replace(
            $result,
            $escaped,
            [string]$pair.Value,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    return $result
}

function Get-UncFromMountPointName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    if (-not $Name.StartsWith('##')) { return $null }

    $converted = $Name.Substring(2).Replace('#', '\\')
    if (-not $converted) { return $null }

    return "\\\\$converted"
}

function Update-UserHive {
    param(
        [string]$HiveRoot,
        [string]$DisplayName
    )

    Write-Host "Processing profile hive: $DisplayName"

    $networkKey = Join-Path $HiveRoot 'Network'
    if (Test-Path $networkKey) {
        Write-Host "  Updating persisted drive mappings..."
        $networkItems = Get-ChildItem $networkKey -ErrorAction SilentlyContinue
        foreach ($item in $networkItems) {
            $props = $null
            try {
                $props = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction Stop
            }
            catch {
                Write-Warning "    Failed to read properties for $($item.PSChildName): $($_.Exception.Message)"
                continue
            }

            $remotePath = $props.RemotePath
            Get-ServersFromPath $remotePath

            $updatedPath = Set-ServerReplacements $remotePath
            if ($updatedPath -and $updatedPath -ne $remotePath) {
                try {
                    Set-ItemProperty -LiteralPath $item.PSPath -Name RemotePath -Value $updatedPath -ErrorAction Stop
                    Write-Host "    RemotePath updated: $remotePath -> $updatedPath"
                }
                catch {
                    Write-Warning "    Failed to update RemotePath for $($item.PSChildName): $($_.Exception.Message)"
                }
            }
        }
    }

    $mp2 = Join-Path $HiveRoot 'Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'
    if (Test-Path $mp2) {
        $mountEntries = Get-ChildItem $mp2 -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like '##*' }
        foreach ($entry in $mountEntries) {
            $unc = Get-UncFromMountPointName $entry.PSChildName
            if (-not $unc) { continue }

            Get-ServersFromPath $unc
            $updated = Set-ServerReplacements $unc

            if ($updated -ne $unc) {
                Write-Host "  Removing stale mount point: $($entry.PSChildName)"
                Remove-Item -LiteralPath $entry.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-PerUserCleanup {
    param([System.Collections.IEnumerable]$Profiles)

    foreach ($userProfile in $Profiles) {
        $sid = $userProfile.SID
        $localPath = $userProfile.LocalPath
        if (-not $sid -or -not $localPath) { continue }

        $hiveRoot = "Registry::HKEY_USERS\\$sid"
        $ntUser = Join-Path $localPath 'NTUSER.DAT'

        $mountName = $null
        $mountedHere = $false

        $hiveAvailable = $false
        try { $hiveAvailable = Test-Path -LiteralPath $hiveRoot } catch {}

        if (-not $hiveAvailable -and $userProfile.Loaded) {
            Write-Host "  Using live hive for $sid (profile is currently loaded)."
            $hiveAvailable = $true
        }

        if (-not $hiveAvailable) {
            if (-not (Test-Path -LiteralPath $ntUser)) { continue }

            $mountName = "TempHive_$([Guid]::NewGuid().ToString('N'))"
            Write-Host "Loading hive for $sid from $ntUser"
            & reg.exe load "HKU\\$mountName" "$ntUser" 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "  Failed to load hive for $sid"
                continue
            }
            $mountedHere = $true
            $hiveRoot = "Registry::HKEY_USERS\\$mountName"
        }

        try {
            Update-UserHive -HiveRoot $hiveRoot -DisplayName $localPath
        }
        finally {
            if ($mountedHere -and $mountName) {
                & reg.exe unload "HKU\\$mountName" 2>$null | Out-Null
            }
        }
    }
}

function Get-CmdKeyEntries {
    (cmd /c "cmdkey /list") 2>$null | Out-String
}

function Remove-CmdKeyTarget {
    param([string]$Target)

    try {
        cmd /c "cmdkey /delete:`"$Target`"" | Out-Null
        Write-Host "  Deleted stored credential: $Target"
    }
    catch {}
}

# Pre-seed with legacy hostnames to ensure they are purged even if no mappings remain.
foreach ($name in $serverReplacements.Keys) { Add-ServerName $name }
foreach ($name in $serverReplacements.Values) { Add-ServerName $name }

# Capture live connections under the current security context.
try {
    $netUse = (cmd /c "net use") 2>$null
    foreach ($line in $netUse) {
        if ($line -match '^\\\\[^\\\s]+\\[^\s]+') {
            $sharePath = $matches[0]
            $null = $activeShares.Add($sharePath)
            Get-ServersFromPath $sharePath
        }
    }
}
catch {}

Write-Host "Enumerating user profiles..."
$profiles = @()
try {
    $profiles = Get-CimInstance Win32_UserProfile -ErrorAction Stop |
        Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path $_.LocalPath) }
}
catch {
    Write-Warning "Unable to enumerate profiles via WMI: $($_.Exception.Message)"
}

if (-not $profiles) {
    Write-Warning 'No user profiles found to process.'
}
else {
    Invoke-PerUserCleanup -Profiles $profiles
}

if ($activeShares.Count -gt 0) {
    Write-Host "Disconnecting $($activeShares.Count) active SMB connection(s) for the current context..."
    cmd /c "net use * /delete /y" 2>$null | Out-Null
}
else {
    Write-Host "No active SMB connections detected for the current context."
}

Write-Host "Checking Credential Manager for stored credentials..."
$cmdKeyOutput = Get-CmdKeyEntries
if ($cmdKeyOutput) {
    $targets = @()
    foreach ($line in $cmdKeyOutput -split "`r?`n") {
        if ($line -match '^\s*Target:\s*(.+?)\s*$') { $targets += $matches[1] }
    }

    foreach ($target in $targets) {
        foreach ($server in $servers) {
            if ($target -match [System.Text.RegularExpressions.Regex]::Escape($server)) {
                Remove-CmdKeyTarget -Target $target
                break
            }
        }
    }
}

Write-Host 'Purging Kerberos tickets...'
try { klist purge -li 0x3e7 2>$null | Out-Null } catch {}
try { klist purge 2>$null | Out-Null } catch {}

Write-Host 'Running gpupdate /force...'
cmd /c "gpupdate /force" | Out-Null

Write-Host 'Done. Any updated drive maps will be applied on policy refresh or next logon.'

