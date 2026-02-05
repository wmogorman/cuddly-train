<#
.SYNOPSIS
  Removes orphaned Bitdefender drivers/minifilters (BdSentry/BdNet/etc.)
  by deleting service registry keys and renaming driver SYS files (or scheduling rename on reboot).

.NOTES
  - Must be run in an elevated PowerShell unless -DryRun or -WhatIf are used.
  - Logs to $LogPath (default: C:\ProgramData\BD_Removal.log).
  - Safe approach: exports registry keys before removal and renames SYS files instead of deleting.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
  [string]$LogPath = 'C:\ProgramData\BD_Removal.log',
  [switch]$IncludeLegacyVBDADrivers,   # also handle bxvbda/evbda
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Message,
    [ValidateSet('INFO', 'WARN', 'ERROR')]
    [string]$Level = 'INFO'
  )

  $logDirectory = Split-Path -Path $LogPath -Parent
  if ($logDirectory -and -not (Test-Path -LiteralPath $logDirectory)) {
    New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
  }

  if ($WhatIfPreference -and -not $DryRun) {
    return
  }

  Add-Content -Path $LogPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
}

function Test-IsAdministrator {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = [Security.Principal.WindowsPrincipal]::new($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
  if ($DryRun -or $WhatIfPreference) {
    Write-Log -Message 'Not running elevated, but continuing because DryRun/WhatIf mode is active.' -Level WARN
  }
  else {
    Write-Log -Message 'Script must run elevated (administrator). Exiting.' -Level ERROR
    throw 'Administrator privileges are required.'
  }
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Targets
$svcNames = @("BdSentry","BdNet")
if ($IncludeLegacyVBDADrivers) { $svcNames += @("bxvbda","evbda") }

$driversDir = Join-Path $env:WINDIR "System32\drivers"
$driverFiles = @("BdSentry.sys","BdNet.sys")
$fltNames = @("BdSentry","BdNet")
if ($IncludeLegacyVBDADrivers) {
  $driverFiles += @("bxvbda.sys","evbda.sys")
  $fltNames += @("bxvbda","evbda")
}

$script:PendingRenameQueued = $false
$script:FailureCount = 0

# Helper: schedule rename on reboot via PendingFileRenameOperations
function Add-PendingRename {
  param(
    [Parameter(Mandatory)] [string] $ExistingPath,
    [Parameter(Mandatory)] [string] $NewPath
  )

  $sessMgr = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
  $name = "PendingFileRenameOperations"

  $existing = @()
  try {
    $existing = (Get-ItemProperty -Path $sessMgr -Name $name -ErrorAction Stop).$name
    if ($null -eq $existing) { $existing = @() }
  } catch {
    $existing = @()
  }

  # Each rename is stored as two entries:
  #  \??\C:\path\old.sys
  #  \??\C:\path\new.sys
  $pair = @("\??\$ExistingPath", "\??\$NewPath")
  $updated = @($existing) + $pair

  if ($PSCmdlet.ShouldProcess($sessMgr, "Queue rename on reboot: $ExistingPath -> $NewPath")) {
    Set-ItemProperty -Path $sessMgr -Name $name -Type MultiString -Value $updated
    return $true
  }

  return $false
}

Write-Log -Message '=== Starting Legacy Bitdefender Orphan Cleanup ==='
Write-Log -Message "Targets: $($svcNames -join ', ')"
Write-Log -Message "Driver files: $($driverFiles -join ', ')"
Write-Log -Message "Log path: $LogPath"
if ($DryRun) {
  Write-Log -Message 'DryRun mode active. No cleanup actions will be executed.' -Level WARN
}
elseif ($WhatIfPreference) {
  Write-Log -Message 'WhatIf mode active. No cleanup actions will be executed.' -Level WARN
}

# 1) Export and delete service registry keys
$backupDir = Join-Path $env:TEMP "BD_ServiceKeyBackup_$timestamp"

foreach ($svc in $svcNames) {
  $regPath = "HKLM\SYSTEM\CurrentControlSet\Services\$svc"
  $regFile = Join-Path $backupDir "$svc.reg"

  # Export if present
  $exists = & reg.exe query $regPath 2>$null
  if ($LASTEXITCODE -eq 0) {
    if ($DryRun) {
      Write-Log -Message "DryRun enabled; would export registry key: $regPath -> $regFile"
    }
    elseif ($PSCmdlet.ShouldProcess($regPath, "Export registry key to $regFile")) {
      if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
      }

      & reg.exe export $regPath $regFile /y | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Write-Log -Message "Failed to export registry key: $regPath (exit code $LASTEXITCODE)." -Level ERROR
        $script:FailureCount++
      }
    }
    else {
      Write-Log -Message "WhatIf: would export registry key: $regPath -> $regFile"
    }

    if ($DryRun) {
      Write-Log -Message "DryRun enabled; would delete registry key: $regPath"
    }
    elseif ($PSCmdlet.ShouldProcess($regPath, "Delete registry key")) {
      & reg.exe delete $regPath /f | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Write-Log -Message "Failed to delete registry key: $regPath (exit code $LASTEXITCODE)." -Level ERROR
        $script:FailureCount++
      }
      else {
        Write-Log -Message "Deleted: $regPath"
      }
    }
    else {
      Write-Log -Message "WhatIf: would delete registry key: $regPath"
    }
  }
  else {
    Write-Log -Message "Not found (ok): $regPath"
  }
}

# 2) Attempt to unload filters (best-effort)
foreach ($flt in $fltNames) {
  try {
    if ($DryRun) {
      Write-Log -Message "DryRun enabled; would run: fltmc unload $flt"
    }
    elseif ($PSCmdlet.ShouldProcess($flt, "fltmc unload")) {
      & fltmc.exe unload $flt | Out-Null
      Write-Log -Message "Attempted to unload filter: $flt"
    }
    else {
      Write-Log -Message "WhatIf: would run: fltmc unload $flt"
    }
  }
  catch {
    Write-Log -Message "fltmc unload $flt failed (continuing): $($_.Exception.Message)" -Level WARN
  }
}

# 3) Rename driver SYS files (or schedule on reboot if locked)
foreach ($file in $driverFiles) {
  $full = Join-Path $driversDir $file
  if (-not (Test-Path $full)) {
    Write-Log -Message "Missing (ok): $full"
    continue
  }

  $new = "$full.old"
  if (Test-Path $new) {
    $new = "$full.old.$timestamp"
  }

  try {
    if ($DryRun) {
      Write-Log -Message "DryRun enabled; would rename: $full -> $new"
    }
    elseif ($PSCmdlet.ShouldProcess($full, "Rename to $new")) {
      Rename-Item -Path $full -NewName ([IO.Path]::GetFileName($new)) -Force
      Write-Log -Message "Renamed: $full -> $new"
    }
    else {
      Write-Log -Message "WhatIf: would rename: $full -> $new"
    }
  }
  catch {
    Write-Log -Message "Rename failed (likely in use): $full" -Level WARN
    Write-Log -Message "Queueing rename on reboot instead..."

    if ($DryRun) {
      Write-Log -Message "DryRun enabled; would queue rename on reboot: $full -> $new"
      continue
    }

    try {
      $queued = Add-PendingRename -ExistingPath $full -NewPath $new
      if ($queued) {
        $script:PendingRenameQueued = $true
        Write-Log -Message "Queued rename on reboot: $full -> $new"
      }
      else {
        Write-Log -Message "Pending rename operation not queued for: $full" -Level WARN
      }
    }
    catch {
      Write-Log -Message "Failed to queue rename on reboot for [$full]: $($_.Exception.Message)" -Level ERROR
      $script:FailureCount++
    }
  }
}

Write-Log -Message 'Registry/service cleanup complete.'

if ($script:PendingRenameQueued) {
  Write-Log -Message 'Reboot required to complete pending driver rename(s).' -Level WARN
}
else {
  Write-Log -Message 'No pending renames detected.'
}

Write-Log -Message "Backup of deleted service keys (if present): $backupDir"
Write-Log -Message '=== Bitdefender Orphan Cleanup Complete ==='

if ($script:FailureCount -gt 0) {
  throw "Legacy Bitdefender cleanup completed with $($script:FailureCount) failure(s). Review log at $LogPath."
}
