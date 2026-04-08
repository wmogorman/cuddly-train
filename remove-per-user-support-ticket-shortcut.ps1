<# remove per-user support shortcut :: revision 1
   Removes per-user desktop copies of the Datto/ActaMSP support shortcut.
   Leaves the Public Desktop shortcut in place.
#>

Write-Host "Remove Per-User ActaMSP Support Shortcuts"
Write-Host "========================================="

$arrUserSID = @{}
$arrUserLoaded = @()
$desktopTargets = @{}
$shortcutShell = $null

function Add-DesktopTarget {
    param(
        [string]$Path,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    if (-not $desktopTargets.ContainsKey($Path)) {
        $desktopTargets[$Path] = $Label
    }
}

function Get-NormalizedPath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    try {
        return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\')
    } catch {
        return $Path.TrimEnd('\')
    }
}

function Test-IsSupportShortcut {
    param(
        [string]$ShortcutPath,
        [object]$Shell
    )

    try {
        $shortcut = $Shell.CreateShortcut($ShortcutPath)
    } catch {
        Write-Host "- Skipping unreadable shortcut: $ShortcutPath"
        return $false
    }

    $arguments = if ($null -ne $shortcut.Arguments) { $shortcut.Arguments.ToString().Trim() } else { '' }
    $targetPath = if ($null -ne $shortcut.TargetPath) { $shortcut.TargetPath.ToString().Trim().Trim('"') } else { '' }
    $iconLocation = if ($null -ne $shortcut.IconLocation) { $shortcut.IconLocation.ToString().Trim().Trim('"') } else { '' }

    $targetMatches = $targetPath -match '(?i)[\\/]CentraStage[\\/]gui\.exe$'
    $iconMatches = $iconLocation -match '(?i)[\\/]CentraStage[\\/]Brand[\\/]desktopshortcut\.ico(?:,\d+)?$'

    return ($arguments -ieq '/newticket' -and ($targetMatches -or $iconMatches))
}

try {
    $publicDesktopPath = $null
    try {
        $publicDesktopPath = [Environment]::GetFolderPath('CommonDesktopDirectory')
        if (-not [string]::IsNullOrWhiteSpace($publicDesktopPath)) {
            Write-Host "- Public Desktop path resolved as: $publicDesktopPath"
        } else {
            Write-Host "- Public Desktop path could not be resolved."
        }
    } catch {
        Write-Host "- Public Desktop path could not be resolved."
    }
    $normalizedPublicDesktopPath = Get-NormalizedPath -Path $publicDesktopPath

    # Enumerate user profiles that have a valid NTUSER.DAT
    Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" |
        ForEach-Object { Get-ItemProperty $_.PSPath } |
        Where-Object { $_.PSChildName -match '^S-1-5-21-' } |
        ForEach-Object {
            $varObject = New-Object PSObject
            $varObject | Add-Member -MemberType NoteProperty -Name "Username" -Value "$(Split-Path $_.ProfileImagePath -Leaf)"
            $varObject | Add-Member -MemberType NoteProperty -Name "ImagePath" -Value "$($_.ProfileImagePath)"

            if (Test-Path "$($_.ProfileImagePath)\NTUSER.DAT") {
                $arrUserSID += @{$($_.PSChildName) = $varObject}
            }
        }

    # Load hives for users who are not currently logged in
    $loadedUserSids = Get-ChildItem "Registry::HKEY_USERS" | ForEach-Object { Split-Path $_.Name -Leaf }
    $arrUserSID.Keys | Where-Object { $_ -notin $loadedUserSids } | ForEach-Object {
        $sid = $_
        Write-Host "- Loading hive for user $($arrUserSID[$sid].Username)..."
        & reg.exe load "HKU\$sid" "$($arrUserSID[$sid].ImagePath)\NTUSER.DAT" *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "! ERROR: Could not load Registry hive for user $($arrUserSID[$sid].Username)."
            & reg.exe load "HKU\$sid" "$($arrUserSID[$sid].ImagePath)\NTUSER.DAT"
            throw "Execution cannot continue."
        }
        $arrUserLoaded += $sid
    }

    # Enumerate user desktop locations from each loaded user hive
    Get-ChildItem "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'S-1-5-21' -and $_.Name -match '[0-9]$' } |
        ForEach-Object {
            $sid = Split-Path $_.Name -Leaf

            try {
                $desktopPath = (Get-ItemProperty "Registry::$($_.Name)\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" -Name Desktop -ErrorAction Stop).Desktop
                $username = if ($arrUserSID.ContainsKey($sid)) { $arrUserSID[$sid].Username } else { $sid }
                $normalizedDesktopPath = Get-NormalizedPath -Path $desktopPath

                if ($normalizedPublicDesktopPath -and $normalizedDesktopPath -ieq $normalizedPublicDesktopPath) {
                    Write-Host "- Skipping [$username] because Desktop resolves to Public Desktop."
                } else {
                    Add-DesktopTarget -Path $desktopPath -Label $username
                }
            } catch {
                Write-Host "- Skipping $sid (Desktop shell folder path not available)."
            }
        }

    Write-Host "- Checking $($desktopTargets.Count) per-user desktop location(s) for support shortcuts..."

    [int]$removedCount = 0
    $shortcutShell = New-Object -ComObject WScript.Shell

    $desktopTargets.GetEnumerator() |
        Sort-Object Key |
        ForEach-Object {
            $desktopPath = $_.Key
            $label = $_.Value

            if (-not (Test-Path -LiteralPath $desktopPath)) {
                Write-Host "- [$label] Desktop path not found: $desktopPath"
            } else {
                $removedHere = 0
                $shortcutFiles = @(Get-ChildItem -LiteralPath $desktopPath -Filter "*.lnk" -File -ErrorAction SilentlyContinue)

                foreach ($shortcutFile in $shortcutFiles) {
                    if (Test-IsSupportShortcut -ShortcutPath $shortcutFile.FullName -Shell $shortcutShell) {
                        try {
                            Remove-Item -LiteralPath $shortcutFile.FullName -Force -ErrorAction Stop
                            $removedCount++
                            $removedHere++
                            Write-Host "- Removed [$label]: $($shortcutFile.FullName)"
                        } catch {
                            Write-Host "! ERROR: Failed to remove $($shortcutFile.FullName)"
                        }
                    }
                }

                if ($removedHere -eq 0) {
                    Write-Host "- [$label] No per-user support shortcuts found."
                }
            }
        }

    Write-Host "- Complete. Removed $removedCount per-user support shortcut(s)."
}
finally {
    if ($null -ne $shortcutShell) {
        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcutShell)
        $shortcutShell = $null
    }

    foreach ($sid in $arrUserLoaded) {
        [GC]::Collect()
        Start-Sleep -Seconds 1
        & reg.exe unload "HKU\$sid" *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "! ERROR: Could not unload Registry hive for SID $sid."
            & reg.exe unload "HKU\$sid"
        }
    }
}
