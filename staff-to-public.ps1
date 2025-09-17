# ===========================
# Run as Administrator
# ===========================

$User          = 'staff'
$UserProfile   = "C:\Users\$User"
$Log           = "C:\Temp\Migrate-$User-to-Public-$(Get-Date -Format yyyyMMdd-HHmmss).log"
$SearchProgramFiles = $true   # set $false to skip deep EXE search (faster)

# ---- helpers ----
function Write-Log { param([string]$m)
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Write-Host $line
  Add-Content -Path $Log -Value $line
}
New-Item -ItemType Directory -Path (Split-Path $Log) -Force | Out-Null
Write-Log "Starting migration for $User"

if (-not (Test-Path $UserProfile)) { throw "Profile not found: $UserProfile" }

# Map of user known folders to Public equivalents
$Map = @{
  "Desktop"   = "$env:Public\Desktop"
  "Documents" = "$env:Public\Documents"
  "Pictures"  = "$env:Public\Pictures"
  "Music"     = "$env:Public\Music"
  "Videos"    = "$env:Public\Videos"
}

# 1) Move standard folders to Public
foreach ($k in $Map.Keys) {
  $src = Join-Path $UserProfile $k
  $dst = $Map[$k]
  if (Test-Path $src) {
    Write-Log "Moving $src -> $dst"
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    $p = Start-Process -FilePath robocopy.exe -ArgumentList @(
      $src, $dst, '*',
      '/E','/MOVE','/COPY:DAT','/DCOPY:DAT','/R:1','/W:1','/XJ'
    ) -NoNewWindow -PassThru -Wait
    Write-Log "Robocopy exit code for ${k}: $($p.ExitCode)"
  } else {
    Write-Log "No $k found at $src (skipping)"
  }
}

# 1b) If OneDrive exists, move its defaults to Public and archive remaining
$OneDrive = Join-Path $UserProfile 'OneDrive'
if (Test-Path $OneDrive) {
  Write-Log "OneDrive detected at $OneDrive"

  # Move OneDrive Desktop/Documents/Pictures/Music/Videos into Public (if present)
  foreach ($k in $Map.Keys) {
    $src = Join-Path $OneDrive $k
    $dst = $Map[$k]
    if (Test-Path $src) {
      Write-Log "Moving OneDrive\$k -> $dst"
      New-Item -ItemType Directory -Path $dst -Force | Out-Null
      $p = Start-Process -FilePath robocopy.exe -ArgumentList @(
        $src, $dst, '*',
        '/E','/MOVE','/COPY:DAT','/DCOPY:DAT','/R:1','/W:1','/XJ'
      ) -NoNewWindow -PassThru -Wait
      Write-Log "Robocopy exit code (OD $k): $($p.ExitCode)"
    }
  }

  # Archive anything else from OneDrive so nothing is lost
  $archive = "C:\Users\Public\${User}_OneDriveBackup"
  Write-Log "Archiving remaining OneDrive content -> $archive"
  New-Item -ItemType Directory -Path $archive -Force | Out-Null
  $p = Start-Process -FilePath robocopy.exe -ArgumentList @(
    $OneDrive, $archive, '*',
    '/E','/MOVE','/COPY:DAT','/DCOPY:DAT','/R:1','/W:1','/XJ'
  ) -NoNewWindow -PassThru -Wait
  Write-Log "Robocopy exit code (OD archive): $($p.ExitCode)"
}

# 2) Repair shortcuts in Public so they point to valid targets
#    Strategy:
#      - If shortcut target exists: leave it
#      - If target started under C:\Users\staff\KnownFolder -> rewrite to Public equivalent if that path now exists
#      - Else if EXE name only: search Program Files / Program Files (x86) for a matching executable and repoint
$PublicShortcutRoots = @(
  "$env:Public\Desktop",
  "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
)

# Precompute rewrite rules from staff paths to Public
$RewriteRules = @()
foreach ($k in $Map.Keys) {
  $RewriteRules += [PSCustomObject]@{
    From = (Join-Path $UserProfile $k)
    To   = $Map[$k]
  }
}
# Also handle direct OneDrive rewrites to the archive (as a fallback)
if (Test-Path $OneDrive) {
  $RewriteRules += [PSCustomObject]@{
    From = $OneDrive
    To   = "C:\Users\Public\${User}_OneDriveBackup"
  }
}

# Optional override map for known apps (fill in if you know exact new paths)
$AppOverrides = @{
  # "Free YouTube to MP3 Converter.lnk" = "C:\Program Files\DVDVideoSoft\Free YouTube to MP3 Converter\FreeYouTubeToMP3Converter.exe"
}

$shell = New-Object -ComObject WScript.Shell
$fixed = 0; $skipped = 0; $broken = 0

foreach ($root in $PublicShortcutRoots) {
  if (-not (Test-Path $root)) { continue }
  Get-ChildItem $root -Recurse -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
    $lnkPath = $_.FullName
    $sc = $shell.CreateShortcut($lnkPath)
    $target = $sc.TargetPath

    if ([string]::IsNullOrWhiteSpace($target)) { $skipped++; return }

    # If target exists, all good
    if (Test-Path $target) { $skipped++; return }

    # Override by display name if provided
    if ($AppOverrides.ContainsKey($_.Name)) {
      $new = $AppOverrides[$_.Name]
      if (Test-Path $new) {
        $sc.TargetPath = $new
        $sc.Save(); $fixed++
        Write-Log "Updated via override: $($_.Name) -> $new"
        return
      }
    }

    # Try rewrite rules (staff -> Public paths)
    $rewritten = $null
    foreach ($rule in $RewriteRules) {
      if ($target.StartsWith($rule.From, [System.StringComparison]::InvariantCultureIgnoreCase)) {
        $candidate = $target -replace [regex]::Escape($rule.From), $rule.To
        if (Test-Path $candidate) { $rewritten = $candidate; break }
      }
    }
    if ($rewritten) {
      $sc.TargetPath = $rewritten
      $sc.Save(); $fixed++
      Write-Log "Rewrote: $($_.Name) -> $rewritten"
      return
    }

    # If EXE, try to find by file name
    if ($SearchProgramFiles -and ([System.IO.Path]::GetExtension($target) -match '^\.exe$')) {
      $exeName = [System.IO.Path]::GetFileName($target)
      $searchRoots = @("C:\Program Files","C:\Program Files (x86)")
      foreach ($sr in $searchRoots) {
        try {
          $match = Get-ChildItem -Path $sr -Recurse -Filter $exeName -ErrorAction SilentlyContinue | Select-Object -First 1
          if ($match) {
            $sc.TargetPath = $match.FullName
            $sc.Save(); $fixed++
            Write-Log "Found by name: $($_.Name) -> $($match.FullName)"
            break
          }
        } catch {}
      }
      if ($sc.TargetPath -and (Test-Path $sc.TargetPath)) { return }
    }

    # Could not fix
    $broken++
    Write-Log "Could not resolve target for shortcut: $lnkPath (orig: $target)"
  }
}

Write-Log "Shortcut repair summary: fixed=$fixed, ok/unchanged=$skipped, broken=$broken"

# 3) Sign out and disable 'staff'

# 3a) Log off any interactive sessions for 'staff'
try {
  $quser = (quser) 2>$null
  if ($quser) {
    # Parse 'query user' output to find session IDs for 'staff'
    $lines = $quser -split "`r?`n" | Where-Object { $_ -match '^\s*STAFF\s' -or $_ -match '^\s*staff\s' }
    foreach ($line in $lines) {
      # Columns: USERNAME SESSIONNAME ID STATE IDLE LOGON TIME (varies). Extract the ID (integer).
      if ($line -match '\s(\d+)\s+(\w+)\s+\d{1,2}/\d{1,2}/\d{2,4}') {
        $sid = $Matches[1]
        Write-Log "Logging off session ID $sid for user $User"
        logoff $sid /V
      } elseif ($line -match '\s(\d+)\s') {
        $sid = $Matches[1]
        Write-Log "Logging off session ID $sid for user $User"
        logoff $sid /V
      }
    }
  }
} catch {
  Write-Log "Warning: could not parse/logoff staff sessions via 'query user' ($_)."
}

# 3b) Remove from local Administrators (if present)
try {
  if (Get-Command Remove-LocalGroupMember -ErrorAction SilentlyContinue) {
    Remove-LocalGroupMember -Group 'Administrators' -Member $User -ErrorAction SilentlyContinue
  } else {
    cmd /c "net localgroup Administrators $User /delete" | Out-Null
  }
  Write-Log "Removed $User from local Administrators (if present)."
} catch { Write-Log "Warning removing from Administrators: $_" }

# 3c) Disable the local account
try {
  if (Get-Command Disable-LocalUser -ErrorAction SilentlyContinue) {
    Disable-LocalUser -Name $User -ErrorAction Stop
  } else {
    cmd /c "net user $User /active:no" | Out-Null
  }
  Write-Log "Disabled local account: $User"
} catch { Write-Log "ERROR disabling ${User}: $_" }

# 3d) Clear potential autologon for that user
try {
  $w = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  $defaultUser = (Get-ItemProperty -Path $w -Name 'DefaultUserName' -ErrorAction SilentlyContinue).DefaultUserName
  if ($defaultUser -and $defaultUser -ieq $User) {
    Set-ItemProperty -Path $w -Name 'AutoAdminLogon' -Value '0' -Force
    foreach ($n in 'DefaultUserName','DefaultPassword','DefaultDomainName') {
      Remove-ItemProperty -Path $w -Name $n -ErrorAction SilentlyContinue
    }
    Write-Log "Cleared AutoAdminLogon for $User"
  }
} catch { Write-Log "Warning clearing autologon: $_" }

Write-Log "Completed. Log at $Log"
Write-Host "`nDone. See log: $Log"
