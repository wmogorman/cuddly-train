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
  [switch]$DryRun,
  [switch]$FixPermissions
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

function Enable-Privilege {
  param(
    [Parameter(Mandatory)]
    [string]$Privilege
  )

  if (-not ("NativeMethods" -as [type])) {
    $definition = @'
using System;
using System.Runtime.InteropServices;
public static class NativeMethods {
  [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
  public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
  [DllImport("advapi32.dll", SetLastError=true)]
  public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);
  [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
  public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);
  public const uint TOKEN_ADJUST_PRIVILEGES = 0x20;
  public const uint TOKEN_QUERY = 0x8;
  public const uint SE_PRIVILEGE_ENABLED = 0x2;
  [StructLayout(LayoutKind.Sequential)]
  public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)]
  public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID Luid; public uint Attributes; }
}
'@
    Add-Type -TypeDefinition $definition -ErrorAction Stop
  }

  $token = [IntPtr]::Zero
  $desired = [NativeMethods]::TOKEN_ADJUST_PRIVILEGES -bor [NativeMethods]::TOKEN_QUERY
  if (-not [NativeMethods]::OpenProcessToken([System.Diagnostics.Process]::GetCurrentProcess().Handle, $desired, [ref]$token)) {
    return $false
  }

  $luid = New-Object NativeMethods+LUID
  if (-not [NativeMethods]::LookupPrivilegeValue($null, $Privilege, [ref]$luid)) {
    return $false
  }

  $tp = New-Object NativeMethods+TOKEN_PRIVILEGES
  $tp.PrivilegeCount = 1
  $tp.Luid = $luid
  $tp.Attributes = [NativeMethods]::SE_PRIVILEGE_ENABLED
  return [NativeMethods]::AdjustTokenPrivileges($token, $false, [ref]$tp, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Convert-ToRegistryProviderPath {
  param(
    [Parameter(Mandatory)]
    [string]$RegistryPath
  )

  if ($RegistryPath -match '^(?i)HKLM\\') {
    return "HKLM:\$($RegistryPath.Substring(5))"
  }

  if ($RegistryPath -match '^(?i)HKCU\\') {
    return "HKCU:\$($RegistryPath.Substring(5))"
  }

  return $RegistryPath
}

function Invoke-RegCommand {
  param(
    [Parameter(Mandatory)]
    [string[]]$Arguments
  )

  $stdout = [IO.Path]::GetTempFileName()
  $stderr = [IO.Path]::GetTempFileName()

  try {
    $process = Start-Process -FilePath 'reg.exe' -ArgumentList $Arguments -Wait -PassThru -NoNewWindow `
      -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop

    $output = @()
    if (Test-Path -LiteralPath $stdout) {
      $output += Get-Content -LiteralPath $stdout -Raw
    }
    if (Test-Path -LiteralPath $stderr) {
      $output += Get-Content -LiteralPath $stderr -Raw
    }

    $text = ($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"

    [pscustomobject]@{
      ExitCode = $process.ExitCode
      Output   = $text.Trim()
    }
  }
  finally {
    if (Test-Path -LiteralPath $stdout) { Remove-Item -LiteralPath $stdout -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $stderr) { Remove-Item -LiteralPath $stderr -Force -ErrorAction SilentlyContinue }
  }
}

function Test-RegAccessDenied {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Result
  )

  if ($Result.ExitCode -eq 5) {
    return $true
  }

  if (-not [string]::IsNullOrWhiteSpace($Result.Output) -and $Result.Output -match '(?i)access is denied') {
    return $true
  }

  return $false
}

function Grant-RegistryKeyFullControl {
  param(
    [Parameter(Mandatory)]
    [string]$RegistryPath
  )

  Enable-Privilege -Privilege 'SeTakeOwnershipPrivilege' | Out-Null
  Enable-Privilege -Privilege 'SeRestorePrivilege' | Out-Null

  $providerPath = Convert-ToRegistryProviderPath -RegistryPath $RegistryPath
  $adminSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
  $acl = Get-Acl -Path $providerPath -ErrorAction Stop
  $acl.SetOwner($adminSid)
  $rule = New-Object Security.AccessControl.RegistryAccessRule($adminSid, 'FullControl', 'ContainerInherit', 'None', 'Allow')
  $acl.SetAccessRule($rule)
  Set-Acl -Path $providerPath -AclObject $acl -ErrorAction Stop
}

function Try-RepairRegistryPermissions {
  param(
    [Parameter(Mandatory)]
    [string]$RegistryPath,
    [Parameter(Mandatory)]
    [string]$Reason
  )

  if (-not $FixPermissions) {
    return $false
  }

  if ($DryRun -or $WhatIfPreference) {
    Write-Log -Message "DryRun/WhatIf enabled; would repair registry permissions for: $RegistryPath ($Reason)" -Level WARN
    return $false
  }

  if (-not $PSCmdlet.ShouldProcess($RegistryPath, "Repair registry permissions ($Reason)")) {
    Write-Log -Message "WhatIf: would repair registry permissions for: $RegistryPath ($Reason)"
    return $false
  }

  try {
    Grant-RegistryKeyFullControl -RegistryPath $RegistryPath
    Write-Log -Message "Repaired registry permissions for: $RegistryPath ($Reason)"
    return $true
  }
  catch {
    Write-Log -Message "Failed to repair registry permissions for [$RegistryPath]: $($_.Exception.Message)" -Level WARN
    return $false
  }
}

function Grant-FileFullControl {
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  Enable-Privilege -Privilege 'SeTakeOwnershipPrivilege' | Out-Null
  Enable-Privilege -Privilege 'SeRestorePrivilege' | Out-Null

  $adminSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
  $acl = Get-Acl -Path $Path -ErrorAction Stop
  $acl.SetOwner($adminSid)
  $rule = New-Object Security.AccessControl.FileSystemAccessRule($adminSid, 'FullControl', 'Allow')
  $acl.SetAccessRule($rule)
  Set-Acl -Path $Path -AclObject $acl -ErrorAction Stop
}

function Take-OwnershipAndGrantAdminFileFullControl {
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  $takeown = & takeown.exe /F $Path /A /D Y 2>&1
  $takeownExit = $LASTEXITCODE
  $icacls = & icacls.exe $Path /grant "*S-1-5-32-544:(F)" /C 2>&1
  $icaclsExit = $LASTEXITCODE

  if ($takeownExit -ne 0) {
    Write-Log -Message "takeown.exe failed for [$Path] (exit code $takeownExit)." -Level WARN
  }
  if ($icaclsExit -ne 0) {
    Write-Log -Message "icacls.exe failed for [$Path] (exit code $icaclsExit)." -Level WARN
  }

  return ($takeownExit -eq 0 -and $icaclsExit -eq 0)
}

function Try-RepairFilePermissions {
  param(
    [Parameter(Mandatory)]
    [string]$Path,
    [Parameter(Mandatory)]
    [string]$Reason
  )

  if (-not $FixPermissions) {
    return $false
  }

  if ($DryRun -or $WhatIfPreference) {
    Write-Log -Message "DryRun/WhatIf enabled; would repair file permissions for: $Path ($Reason)" -Level WARN
    return $false
  }

  if (-not $PSCmdlet.ShouldProcess($Path, "Repair file permissions ($Reason)")) {
    Write-Log -Message "WhatIf: would repair file permissions for: $Path ($Reason)"
    return $false
  }

  try {
    Grant-FileFullControl -Path $Path
    Write-Log -Message "Repaired file permissions for: $Path ($Reason)"
    return $true
  }
  catch {
    Write-Log -Message "Failed to repair file permissions via Set-Acl for [$Path]: $($_.Exception.Message)" -Level WARN
  }

  try {
    if (Take-OwnershipAndGrantAdminFileFullControl -Path $Path) {
      Write-Log -Message "Repaired file permissions via takeown/icacls for: $Path ($Reason)"
      return $true
    }
  }
  catch {
    Write-Log -Message "Failed to repair file permissions via takeown/icacls for [$Path]: $($_.Exception.Message)" -Level WARN
  }

  return $false
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
if ($FixPermissions) {
  Write-Log -Message 'FixPermissions mode active. The script will attempt to take ownership and grant Administrators full control when access is denied.' -Level WARN
}

# 1) Export and delete service registry keys
$backupDir = Join-Path $env:TEMP "BD_ServiceKeyBackup_$timestamp"

foreach ($svc in $svcNames) {
  $regPath = "HKLM\SYSTEM\CurrentControlSet\Services\$svc"
  $regFile = Join-Path $backupDir "$svc.reg"

  # Export if present
  $query = Invoke-RegCommand -Arguments @('query', $regPath)
  if (Test-RegAccessDenied -Result $query) {
    if (Try-RepairRegistryPermissions -RegistryPath $regPath -Reason 'query access denied') {
      $query = Invoke-RegCommand -Arguments @('query', $regPath)
    }
  }

  if ($query.ExitCode -eq 0) {
    if ($DryRun) {
      Write-Log -Message "DryRun enabled; would export registry key: $regPath -> $regFile"
    }
    elseif ($PSCmdlet.ShouldProcess($regPath, "Export registry key to $regFile")) {
      if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
      }

      $export = Invoke-RegCommand -Arguments @('export', $regPath, $regFile, '/y')
      if (Test-RegAccessDenied -Result $export) {
        if (Try-RepairRegistryPermissions -RegistryPath $regPath -Reason 'export access denied') {
          $export = Invoke-RegCommand -Arguments @('export', $regPath, $regFile, '/y')
        }
      }

      if ($export.ExitCode -ne 0) {
        $detail = if ([string]::IsNullOrWhiteSpace($export.Output)) { '' } else { " Output: $($export.Output)" }
        Write-Log -Message "Failed to export registry key: $regPath (exit code $($export.ExitCode)).$detail" -Level ERROR
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
      $delete = Invoke-RegCommand -Arguments @('delete', $regPath, '/f')
      if (Test-RegAccessDenied -Result $delete) {
        if (Try-RepairRegistryPermissions -RegistryPath $regPath -Reason 'delete access denied') {
          $delete = Invoke-RegCommand -Arguments @('delete', $regPath, '/f')
        }
      }

      if ($delete.ExitCode -ne 0) {
        $detail = if ([string]::IsNullOrWhiteSpace($delete.Output)) { '' } else { " Output: $($delete.Output)" }
        Write-Log -Message "Failed to delete registry key: $regPath (exit code $($delete.ExitCode)).$detail" -Level ERROR
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
  elseif ($query.ExitCode -eq 2 -or ($query.Output -match '(?i)unable to find|not found')) {
    Write-Log -Message "Not found (ok): $regPath"
  }
  else {
    $detail = if ([string]::IsNullOrWhiteSpace($query.Output)) { '' } else { " Output: $($query.Output)" }
    Write-Log -Message "Failed to query registry key: $regPath (exit code $($query.ExitCode)).$detail" -Level WARN
    $script:FailureCount++
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
    $isAccessDenied = $_.Exception -is [System.UnauthorizedAccessException] -or $_.Exception.Message -match '(?i)access is denied'
    if ($isAccessDenied -and (Try-RepairFilePermissions -Path $full -Reason 'rename access denied')) {
      try {
        Rename-Item -Path $full -NewName ([IO.Path]::GetFileName($new)) -Force
        Write-Log -Message "Renamed after permission repair: $full -> $new"
        continue
      }
      catch {
        Write-Log -Message "Rename still failed after permission repair: $full" -Level WARN
      }
    }

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
