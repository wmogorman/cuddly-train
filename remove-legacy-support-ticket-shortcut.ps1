<# remove legacy support shortcut :: revision 1
   Removes the old English shortcut created by the Datto support shortcut component:
   "Create new Support Ticket.lnk"
#>

write-host "Remove Legacy 'Create new Support Ticket' Shortcuts for All Users"
write-host "================================================================="

$legacyShortcutName = "Create new Support Ticket.lnk"
$arrUserSID = @{}
$arrUserLoaded = @()
$desktopTargets = @{}

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

# Enumerate user profiles that have a valid NTUSER.DAT
gci "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" | % {Get-ItemProperty $_.PSPath} | ? {$_.PSChildName -match '^S-1-5-21-'} | % {
    $varObject = New-Object PSObject
    $varObject | Add-Member -MemberType NoteProperty -Name "Username" -Value "$(split-path $_.ProfileImagePath -Leaf)"
    $varObject | Add-Member -MemberType NoteProperty -Name "ImagePath" -Value "$($_.ProfileImagePath)"

    if (Test-Path "$($_.ProfileImagePath)\NTUser.dat") {
        $arrUserSID += @{$($_.PSChildName) = $varObject}
    }
}

# Load hives for users who are not currently logged in
$loadedUserSids = gci "Registry::HKEY_USERS" | % {$_.Name} | % {split-path $_ -leaf}
$arrUserSID.Keys | ? {$_ -notin $loadedUserSids} | % {
    write-host "- Loading hive for user $($arrUserSID[$_].Username)..."
    cmd /c "reg load `"HKU\$($_)`" `"$($arrUserSID[$_].ImagePath)\NTUSER.DAT`"" 2>&1>$null
    if (!$?) {
        write-host "! ERROR: Could not load Registry hive for user $($arrUserSID[$_].Username)."
        cmd /c "reg load `"HKU\$($_)`" `"$($arrUserSID[$_].ImagePath)\NTUSER.DAT`""
        write-host "  Execution cannot continue."
        exit 1
    }
    $arrUserLoaded += $_
}

# Add Public Desktop target (if present)
try {
    $publicProfile = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -Name Public -ErrorAction Stop).Public
    Add-DesktopTarget -Path "$publicProfile\Desktop" -Label "Public"
} catch {
    write-host "- Public Desktop path could not be resolved."
}

# Enumerate user desktop locations from each loaded user hive
gci "Registry::HKEY_USERS" -ea 0 | ? {$_.Name -match 'S-1-5-21' -and $_.Name -match '[0-9]$'} | % {
    $sid = split-path $_.Name -leaf
    try {
        $desktopPath = (Get-ItemProperty "Registry::$($_.Name)\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" -Name Desktop -ErrorAction Stop).Desktop
        $username = if ($arrUserSID.ContainsKey($sid)) { $arrUserSID[$sid].Username } else { $sid }
        Add-DesktopTarget -Path $desktopPath -Label $username
    } catch {
        write-host "- Skipping $sid (Desktop shell folder path not available)."
    }
}

write-host "- Checking $($desktopTargets.Count) desktop location(s) for '$legacyShortcutName'..."

[int]$removedCount = 0

$desktopTargets.GetEnumerator() | sort-object Key | % {
    $desktopPath = $_.Key
    $label = $_.Value

    if (-not (Test-Path -LiteralPath $desktopPath)) {
        write-host "- [$label] Desktop path not found: $desktopPath"
    } else {
        $shortcutPath = Join-Path $desktopPath $legacyShortcutName
        if (Test-Path -LiteralPath $shortcutPath) {
            try {
                Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction Stop
                $removedCount++
                write-host "- Removed: $shortcutPath"
            } catch {
                write-host "! ERROR: Failed to remove $shortcutPath"
            }
        } else {
            write-host "- Not present: $shortcutPath"
        }
    }
}

# Unload any hives we loaded
$arrUserLoaded | % {
    [gc]::Collect()
    start-sleep -seconds 3
    cmd /c "reg unload `"HKU\$($_)`"" 2>&1>$null
    if (!$?) {
        write-host "! ERROR: Could not unload Registry hive for SID $($_)."
        cmd /c "reg unload `"HKU\$($_)`""
    }
}

write-host "- Complete. Removed $removedCount legacy shortcut(s)."
