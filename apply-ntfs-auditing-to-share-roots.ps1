<# 
.SYNOPSIS
  Applies NTFS SACL auditing rules (file/folder access auditing) to share root folders.

.PREREQS
  1) "Audit File System" must be enabled via auditpol (GPO) or logs will not appear:
     auditpol /get /subcategory:"File System"
  2) Run as Administrator.

.NOTES
  Uses icacls because it's the most reliable way to set SACLs at scale.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  # Share root paths to audit. If omitted, the script discovers local file shares.
  [Parameter()][string[]]$Targets,
  # Principal to audit. "Everyone" is typical for file auditing (filter events later).
  [Parameter()][ValidateNotNullOrEmpty()][string]$Principal = "Everyone",
  # Audit flags:
  #   (OI)(CI) = objects + containers (files + folders)
  #   (IO)     = inherit-only (keeps root clean-ish; inherited rules apply below)
  [Parameter()][ValidateNotNullOrEmpty()][string]$Inheritance = "(OI)(CI)",  # or "(OI)(CI)(IO)"
  # Rights to audit:
  #   M  = Modify (create/write/append/read/execute/delete within permission bounds)
  #   D  = Delete
  #   DC = Delete child
  #   WDAC = Write DAC (change permissions)
  #   WO = Write Owner (take ownership)
  [Parameter()][ValidateNotNullOrEmpty()][string]$Rights = "M,D,DC,WDAC,WO",
  # Skip the audit policy check (useful when it is managed centrally).
  [Parameter()][switch]$SkipAuditPolicyCheck,
  # Do not propagate SACLs through subfolders.
  [Parameter()][switch]$NoPropagate,
  # Include hidden shares (names ending with $) when auto-discovering targets.
  [Parameter()][switch]$IncludeHiddenShares
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Success/Failure:
#   /success:enable /failure:enable are not icacls flags; for SACL we specify:
#   (S) success, (F) failure
# We'll create two ACEs so it's explicit.
$AuditSuccessAce = "${Inheritance}:${Principal}:(S):${Rights}"
$AuditFailureAce = "${Inheritance}:${Principal}:(F):${Rights}"

function Test-IsAdministrator {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IcaclsSetAuditSupported {
  $helpText = & icacls /? 2>&1
  return ($helpText | Select-String -SimpleMatch "/setaudit" -Quiet)
}

function Get-ShareRootPaths {
  [CmdletBinding()]
  param(
    [Parameter()][switch]$IncludeHiddenShares
  )

  $shares = @()
  $smbShareCmd = Get-Command -Name Get-SmbShare -ErrorAction SilentlyContinue
  if ($null -ne $smbShareCmd) {
    $shares = Get-SmbShare
    if (-not $IncludeHiddenShares) {
      $shares = $shares | Where-Object { -not $_.Special -and $_.Name -notlike "*$" }
    } else {
      $shares = $shares | Where-Object { $_.Name -ne "IPC$" }
    }
    $shares = $shares | Where-Object { $_.Path }
  } else {
    try {
      $shares = Get-CimInstance -ClassName Win32_Share -ErrorAction Stop
    } catch {
      $shares = Get-WmiObject -Class Win32_Share
    }
    $shares = $shares | Where-Object { $_.Type -eq 0 -and $_.Path }
    if (-not $IncludeHiddenShares) {
      $shares = $shares | Where-Object { $_.Name -notlike "*$" }
    } else {
      $shares = $shares | Where-Object { $_.Name -ne "IPC$" }
    }
  }

  return $shares | Select-Object -ExpandProperty Path -Unique
}

function Enable-Privilege {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Privilege
  )

  if (-not ("TokenPrivilege" -as [type])) {
    $definition = @"
using System;
using System.Runtime.InteropServices;
public class TokenPrivilege {
  [StructLayout(LayoutKind.Sequential, Pack=1)]
  public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential, Pack=1)]
  public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
  [StructLayout(LayoutKind.Sequential, Pack=1)]
  public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }
  [DllImport("advapi32.dll", SetLastError=true)]
  public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, ref LUID lpLuid);
  [DllImport("advapi32.dll", SetLastError=true)]
  public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);
  public const uint SE_PRIVILEGE_ENABLED = 0x00000002;
  public const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
  public const uint TOKEN_QUERY = 0x0008;
  public static void EnablePrivilege(string privilege) {
    IntPtr token;
    if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token)) {
      throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    LUID luid = new LUID();
    if (!LookupPrivilegeValue(null, privilege, ref luid)) {
      throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
    tp.PrivilegeCount = 1;
    tp.Privileges = new LUID_AND_ATTRIBUTES();
    tp.Privileges.Luid = luid;
    tp.Privileges.Attributes = SE_PRIVILEGE_ENABLED;
    if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) {
      throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
  }
}
"@
    Add-Type -TypeDefinition $definition -ErrorAction Stop
  }

  [TokenPrivilege]::EnablePrivilege($Privilege)
}

function ConvertTo-FileSystemRights {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Rights
  )

  $map = @{
    "F"    = "FullControl"
    "M"    = "Modify"
    "RX"   = "ReadAndExecute"
    "R"    = "Read"
    "W"    = "Write"
    "D"    = "Delete"
    "DC"   = "DeleteSubdirectoriesAndFiles"
    "WDAC" = "WritePermissions"
    "WO"   = "TakeOwnership"
    "RC"   = "ReadPermissions"
    "RD"   = "ReadData"
    "WD"   = "WriteData"
    "AD"   = "AppendData"
    "REA"  = "ReadExtendedAttributes"
    "WEA"  = "WriteExtendedAttributes"
    "X"    = "ExecuteFile"
    "RA"   = "ReadAttributes"
    "WA"   = "WriteAttributes"
    "S"    = "Synchronize"
  }

  $flags = [System.Security.AccessControl.FileSystemRights]0
  foreach ($token in ($Rights -split ",")) {
    $trimmed = $token.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
    $name = if ($map.ContainsKey($trimmed)) { $map[$trimmed] } else { $trimmed }
    try {
      $parsed = [System.Enum]::Parse([System.Security.AccessControl.FileSystemRights], $name, $true)
    } catch {
      throw "Unsupported rights token '$trimmed'. Use FileSystemRights names or icacls abbreviations."
    }
    $flags = $flags -bor $parsed
  }

  return $flags
}

function ConvertTo-InheritanceAndPropagationFlags {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Inheritance
  )

  $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::None
  $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None

  $tokens = [regex]::Matches($Inheritance, "\(([^)]+)\)") | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() }
  foreach ($token in $tokens) {
    switch ($token) {
      "OI" { $inheritanceFlags = $inheritanceFlags -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit }
      "CI" { $inheritanceFlags = $inheritanceFlags -bor [System.Security.AccessControl.InheritanceFlags]::ContainerInherit }
      "IO" { $propagationFlags = $propagationFlags -bor [System.Security.AccessControl.PropagationFlags]::InheritOnly }
      "NP" { $propagationFlags = $propagationFlags -bor [System.Security.AccessControl.PropagationFlags]::NoPropagateInherit }
      "I"  { }
      default { Write-Verbose "Ignoring unsupported inheritance token '$token'." }
    }
  }

  return @($inheritanceFlags, $propagationFlags)
}

function Invoke-Icacls {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string[]]$Arguments,
    [Parameter(Mandatory=$true)][string]$Action,
    [Parameter()][switch]$ContinueOnError
  )

  if ($PSCmdlet.ShouldProcess($Path, $Action)) {
    & icacls $Path @Arguments | Out-Host
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      $message = "icacls failed for $Path (exit $exitCode): $Action"
      if ($ContinueOnError) {
        Write-Warning $message
      } else {
        throw $message
      }
    }
  }
}

function Set-AuditRulesOnPath {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Action,
    [Parameter()][switch]$ContinueOnError
  )

  if ($PSCmdlet.ShouldProcess($Path, $Action)) {
    try {
      $acl = Get-Acl -LiteralPath $Path -Audit
      $null = $acl.SetAuditRule($AuditSuccessRule)
      $null = $acl.SetAuditRule($AuditFailureRule)
      Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
      if ($ContinueOnError) {
        Write-Warning ("Set-Acl failed for {0}: {1}" -f $Path, $_.Exception.Message)
      } else {
        throw
      }
    }
  }
}

function Add-Auditing {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param(
    [Parameter(Mandatory=$true)][string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    Write-Warning "Target not found: $Path"
    return
  }

  Write-Host "`n=== Applying auditing to: $Path ===" -ForegroundColor Cyan

  if ($UseIcacls) {
    # Add Success auditing
    Invoke-Icacls -Path $Path -Arguments @("/setaudit", $AuditSuccessAce) -Action "Add Success auditing"

    # Add Failure auditing
    Invoke-Icacls -Path $Path -Arguments @("/setaudit", $AuditFailureAce) -Action "Add Failure auditing"

    if (-not $NoPropagate) {
      # Propagate auditing down the tree (this is the time-consuming part on big shares)
      # /T = traverse all subfolders
      # /C = continue on errors (locked files etc.)
      Invoke-Icacls -Path $Path -Arguments @("/setaudit", $AuditSuccessAce, "/T", "/C") -Action "Propagate Success auditing" -ContinueOnError
      Invoke-Icacls -Path $Path -Arguments @("/setaudit", $AuditFailureAce, "/T", "/C") -Action "Propagate Failure auditing" -ContinueOnError
    } else {
      Write-Verbose "Skipping propagation for $Path"
    }
  } else {
    Set-AuditRulesOnPath -Path $Path -Action "Add auditing via Set-Acl"
    if (-not $NoPropagate) {
      try {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -Attributes !ReparsePoint -ErrorAction Stop | ForEach-Object {
          Set-AuditRulesOnPath -Path $_.FullName -Action "Propagate auditing via Set-Acl" -ContinueOnError
        }
      } catch {
        Write-Warning ("Failed to enumerate {0}: {1}" -f $Path, $_.Exception.Message)
      }
    } else {
      Write-Verbose "Skipping propagation for $Path"
    }
  }

  Write-Host "Done: $Path" -ForegroundColor Green
}

if (-not (Test-IsAdministrator)) {
  throw "Run this script in an elevated session (Administrator)."
}

# Determine whether icacls supports /setaudit; fall back to Set-Acl if not.
$UseIcacls = Test-IcaclsSetAuditSupported
if (-not $UseIcacls) {
  Write-Warning "icacls does not support /setaudit on this OS. Falling back to Set-Acl."
  try {
    Enable-Privilege -Privilege "SeSecurityPrivilege"
  } catch {
    Write-Warning ("Failed to enable SeSecurityPrivilege: {0}" -f $_.Exception.Message)
  }

  $parsedFlags = ConvertTo-InheritanceAndPropagationFlags -Inheritance $Inheritance
  $InheritanceFlags = $parsedFlags[0]
  $PropagationFlags = $parsedFlags[1]
  $AuditRights = ConvertTo-FileSystemRights -Rights $Rights
  $AuditSuccessRule = New-Object System.Security.AccessControl.FileSystemAuditRule(
    $Principal,
    $AuditRights,
    $InheritanceFlags,
    $PropagationFlags,
    [System.Security.AccessControl.AuditFlags]::Success
  )
  $AuditFailureRule = New-Object System.Security.AccessControl.FileSystemAuditRule(
    $Principal,
    $AuditRights,
    $InheritanceFlags,
    $PropagationFlags,
    [System.Security.AccessControl.AuditFlags]::Failure
  )
}

# Auto-discover targets when none are provided.
if (-not $Targets -or $Targets.Count -eq 0) {
  Write-Host "Discovering local file shares..." -ForegroundColor Yellow
  $Targets = Get-ShareRootPaths -IncludeHiddenShares:$IncludeHiddenShares
  if (-not $Targets -or $Targets.Count -eq 0) {
    throw "No local file share paths were discovered."
  }
  Write-Verbose ("Discovered targets: {0}" -f ($Targets -join ", "))
}

# Safety: confirm audit policy is enabled first (output is localized by OS language).
if (-not $SkipAuditPolicyCheck) {
  Write-Host "Checking audit policy for File System..." -ForegroundColor Yellow
  & auditpol /get /subcategory:"File System" | Out-Host
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "auditpol returned exit $LASTEXITCODE. Auditing may be disabled or unavailable."
  }
}

foreach ($t in $Targets) {
  Add-Auditing -Path $t
}

Write-Host "`nAll targets processed." -ForegroundColor Green
Write-Host "Now test: create/modify/delete a file, then check Event Viewer > Security (4663/4660/4670)." -ForegroundColor Yellow
