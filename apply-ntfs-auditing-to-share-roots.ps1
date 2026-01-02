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
  [Parameter()][ValidateNotNullOrEmpty()][string[]]$Targets = @(
    "D:\Shares",
    "D:\Departments"
    # "D:\Users"
  ),
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
  [Parameter()][switch]$NoPropagate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Success/Failure:
#   /success:enable /failure:enable are not icacls flags; for SACL we specify:
#   (S) success, (F) failure
# We'll create two ACEs so it's explicit.
$AuditSuccessAce = "$Inheritance:$Principal:(S):$Rights"
$AuditFailureAce = "$Inheritance:$Principal:(F):$Rights"

function Test-IsAdministrator {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

  Write-Host "Done: $Path" -ForegroundColor Green
}

if (-not (Test-IsAdministrator)) {
  throw "Run this script in an elevated session (Administrator)."
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
