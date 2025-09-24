# Remove-OldShares-And-Refresh.ps1
# Disconnect all SMB mappings, clear remembered entries, remove creds for those servers, then gpupdate /force.

# Region: Gather current/remembered mappings to learn server names
$servers = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

# 1) From active connections
try {
  $netUse = (cmd /c "net use") 2>$null
  foreach ($line in $netUse) {
    if ($line -match '^\\\\([^\\\s]+)\\') { [void]$servers.Add($matches[1]) }
  }
} catch {}

# 2) From remembered drive letters in HKCU:\Network
$networkKey = 'HKCU:\Network'
if (Test-Path $networkKey) {
  Get-ChildItem $networkKey -ErrorAction SilentlyContinue | ForEach-Object {
    $remotePath = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).RemotePath
    if ($remotePath -and $remotePath -match '^\\\\([^\\\s]+)\\') { [void]$servers.Add($matches[1]) }
  }
}

# Region: Disconnect everything currently mapped
Write-Host "Disconnecting active SMB connections..."
cmd /c "net use * /delete /y" | Out-Null

# Region: Clear remembered drive mappings (HKCU:\Network)
if (Test-Path $networkKey) {
  Write-Host "Removing remembered drive mappings under HKCU:\Network..."
  Get-ChildItem $networkKey -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# Region: Clear stale UNC mount points (Explorer cache)
$mp2 = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'
if (Test-Path $mp2) {
  Write-Host "Removing stale UNC MountPoints2 entries..."
  Get-ChildItem $mp2 -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like '##*' } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# Region: Remove saved credentials for those servers (only)
# We parse `cmdkey /list` and delete entries whose Target contains \\server or server name.
function Get-CmdKeyEntries {
  (cmd /c "cmdkey /list") 2>$null | Out-String
}
function Remove-CmdKeyTarget([string]$target) {
  try {
    cmd /c "cmdkey /delete:`"$target`"" | Out-Null
    Write-Host "  Deleted stored credential: $target"
  } catch {}
}

Write-Host "Checking Credential Manager for saved creds to those servers..."
$ck = Get-CmdKeyEntries
if ($ck) {
  # Targets appear like: "Target: LegacyGeneric:target=SERVER" or "Target: Domain:target=TERMSRV/SERVER" etc.
  $targets = @()
  foreach ($line in $ck -split "`r?`n") {
    if ($line -match '^\s*Target:\s*(.+?)\s*$') { $targets += $matches[1] }
  }
  foreach ($t in $targets) {
    foreach ($sv in $servers) {
      if ($t -match [Regex]::Escape($sv)) { Remove-CmdKeyTarget $t; break }
    }
  }
}

# Region: (Optional but helpful) Clear Kerberos tickets to avoid sticky auth
try { klist purge -li 0x3e7 2>$null | Out-Null } catch {}
try { klist purge 2>$null | Out-Null } catch {}

# Region: Force Group Policy to re-apply (including Drive Maps (GPP))
Write-Host "Running gpupdate /force..."
cmd /c "gpupdate /force" | Out-Null

Write-Host "Done. Any GPP drive maps will be re-applied on the next policy refresh/logon."
