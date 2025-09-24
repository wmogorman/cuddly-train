# Remove-OldShares-And-Refresh-CurrentUser.ps1
# Reset SMB drive mappings for the current interactive user, update legacy server references, clear cached credentials, and run gpupdate /force.

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

function Refresh-CurrentUserHive {
    Write-Host 'Updating persisted drive mappings for the current user...'

    $networkKey = 'HKCU:\Network'
    if (Test-Path $networkKey) {
        Get-ChildItem $networkKey -ErrorAction SilentlyContinue | ForEach-Object {
            $props = $null
            try {
                $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
            }
            catch {
                Write-Warning "  Failed to read properties for $($_.PSChildName): $($_.Exception.Message)"
                return
            }

            $remotePath = $props.RemotePath
            Get-ServersFromPath $remotePath

            $updatedPath = Set-ServerReplacements $remotePath
            if ($updatedPath -and $updatedPath -ne $remotePath) {
                try {
                    Set-ItemProperty -LiteralPath $_.PSPath -Name RemotePath -Value $updatedPath -ErrorAction Stop
                    Write-Host "  RemotePath updated: $remotePath -> $updatedPath"
                }
                catch {
                    Write-Warning "  Failed to update RemotePath for $($_.PSChildName): $($_.Exception.Message)"
                }
            }
        }
    }

    $mp2 = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'
    if (Test-Path $mp2) {
        Get-ChildItem $mp2 -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like '##*' } | ForEach-Object {
            $name = $_.PSChildName.Substring(2).Replace('#', '\\')
            if (-not $name) { return }

            $unc = "\\\\$name"
            Get-ServersFromPath $unc
            $updated = Set-ServerReplacements $unc

            if ($updated -ne $unc) {
                Write-Host "  Removing stale mount point: $($_.PSChildName)"
                Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
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

# Pre-seed with legacy names so credential purge still runs even without live mappings.
foreach ($name in $serverReplacements.Keys) { Add-ServerName $name }
foreach ($name in $serverReplacements.Values) { Add-ServerName $name }

try {
    $netUse = (cmd /c "net use") 2>$null
    foreach ($line in $netUse) {
        if ($line -match '^\\\\[^\\\s]+\\[^\s]+') {
            $path = $matches[0]
            $null = $activeShares.Add($path)
            Get-ServersFromPath $path
        }
    }
}
catch {}

Refresh-CurrentUserHive

if ($activeShares.Count -gt 0) {
    Write-Host "Disconnecting $($activeShares.Count) active SMB connection(s) for the current user..."
    cmd /c "net use * /delete /y" 2>$null | Out-Null
}
else {
    Write-Host 'No active SMB connections detected for the current user.'
}

Write-Host 'Checking Credential Manager for stored credentials...'
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
try { klist purge 2>$null | Out-Null } catch {}

Write-Host 'Running gpupdate /force...'
cmd /c "gpupdate /force" | Out-Null

Write-Host 'Done. Any updated drive maps will be applied on policy refresh or next logon.'
