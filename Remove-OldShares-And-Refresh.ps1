# Force-Remap-Drives.ps1
# Run in USER context (logon script or RMM as logged-on user)
# Purpose: Nuke stale mappings, remove cached entries, re-map drives to new UNC paths

# --- SETTINGS ---
$Mappings = @{
  'M' = '\\bbm-dc01\data'
  'R' = '\\bbm-evo02\dbamfg'
  'S' = '\\bbm-dc01\Customer Supplied Data'
  'Z' = '\\bbm-dc01\QMS'
  'I' = '\\bbm-dc01\Inventory'
}

# Any legacy targets we should yank if found
$LegacyTargets = @(
  '\\bbm-fp01\', '\\bbm-fs1\', '\\bbm-evo01\'
)

# Log file in user profile (change if desired)
$LogPath = Join-Path $env:LOCALAPPDATA 'DriveRemap\remap.log'
New-Item -Path (Split-Path $LogPath) -ItemType Directory -Force | Out-Null

function Write-Log {
  param([string]$Message)
  $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  "$timestamp  $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

function Remove-DriveMapping {
  param([Parameter(Mandatory)] [ValidatePattern('^[A-Za-z]$')] [string]$Letter)

  $lp = "${Letter}:"
  Write-Log "Removing mapping for $lp (any method available)."

  try { Remove-SmbMapping -LocalPath $lp -Force -ErrorAction SilentlyContinue } catch {}
  try { net use $lp /delete /y | Out-Null } catch {}
  try { Remove-PSDrive -Name $Letter -Force -ErrorAction SilentlyContinue } catch {}

  # Remove cached per-user mapping key so Windows doesn’t “reconnect at logon”
  $regKey = "HKCU:\Network\$Letter"
  try {
    if (Test-Path $regKey) {
      Remove-Item $regKey -Recurse -Force -ErrorAction SilentlyContinue
      Write-Log "Deleted $regKey."
    }
  } catch {
    Write-Log ("WARN: Could not delete ${regKey}: {0}" -f $_.Exception.Message)
  }
}

function Map-Drive {
  param(
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z]$')] [string]$Letter,
    [Parameter(Mandatory)] [string]$Path
  )
  $lp = "${Letter}:"
  Write-Log "Mapping $lp -> $Path"

  # Primary method
  try {
    # New-PSDrive with -Persist writes HKCU:\Network\<Letter>
    New-PSDrive -Name $Letter -PSProvider FileSystem -Root $Path -Persist -Scope Global -ErrorAction Stop | Out-Null
  } catch {
    Write-Log "New-PSDrive failed for ${lp}: $($_.Exception.Message) - trying New-SmbMapping..."
    try {
      New-SmbMapping -LocalPath $lp -RemotePath $Path -Persistent $true -ErrorAction Stop | Out-Null
    } catch {
      Write-Log "ERROR: New-SmbMapping failed for ${lp}: $($_.Exception.Message)"
      return $false
    }
  }

  Start-Sleep -Milliseconds 400
  if (Test-Path "$lp\") {
    Write-Log "OK: $lp is accessible."
    return $true
  } else {
    Write-Log "ERROR: $lp is not accessible after mapping."
    return $false
  }
}

# --- EXECUTION ---

Write-Log "===== Starting drive remap for user $env:USERNAME on $env:COMPUTERNAME ====="

# 1) Remove any mapped drives pointing at legacy servers (surgical cleanup)
try {
  $current = Get-SmbMapping -ErrorAction SilentlyContinue
  foreach ($map in ($current | Where-Object { $_.RemotePath })) {
    foreach ($legacy in $LegacyTargets) {
      if ($map.RemotePath.ToLower().StartsWith($legacy.ToLower())) {
        Write-Log "Found legacy mapping $($map.LocalPath) -> $($map.RemotePath). Removing…"
        try { Remove-SmbMapping -LocalPath $map.LocalPath -Force -ErrorAction SilentlyContinue } catch {}
      }
    }
  }
} catch {
  # If Get-SmbMapping isn’t available, ignore and continue
}

# 2) Remove our target drive letters unconditionally
foreach ($letter in $Mappings.Keys) {
  Remove-DriveMapping -Letter $letter
}

# 3) Extra: also clear any old “net use” reconnections for our letters
foreach ($letter in $Mappings.Keys) {
  try { cmd /c "net use $($letter): /delete /y" | Out-Null } catch {}
}

# 4) Re-map to new locations
$results = @()
foreach ($kv in $Mappings.GetEnumerator()) {
  $ok = Map-Drive -Letter $kv.Key -Path $kv.Value
  $results += [pscustomobject]@{
    Drive = "$($kv.Key):"
    Path  = $kv.Value
    Status = if ($ok) { 'Mapped' } else { 'FAILED' }
  }
}

# 5) Optional: Nudge Explorer to pick up new mappings immediately (non-fatal if it fails)
try {
  # Send a lightweight broadcast that often refreshes Explorer drive list
  (New-Object -ComObject WScript.Shell).AppActivate('Explorer') | Out-Null
} catch {}

Write-Log "Summary:`n$($results | Format-Table -AutoSize | Out-String)"
Write-Log "===== Completed drive remap ====="

# Exit code: 0 if all mapped, 1 if any failed
if ($results.Status -contains 'FAILED') { exit 1 } else { exit 0 }
