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

$Targets = @(
  "D:\Shares",
  "D:\Departments"
  # "D:\Users"
)

# Principal to audit. "Everyone" is typical for file auditing (filter events later).
$Principal = "Everyone"

# Audit flags:
#   (OI)(CI) = objects + containers (files + folders)
#   (IO)     = inherit-only (keeps root clean-ish; inherited rules apply below)
# Choose to include (IO) or not:
$Inheritance = "(OI)(CI)"   # or "(OI)(CI)(IO)"

# Rights to audit:
#   M  = Modify (create/write/append/read/execute/delete within permission bounds)
#   D  = Delete
#   DC = Delete child
#   WDAC = Write DAC (change permissions)
#   WO = Write Owner (take ownership)
$Rights = "M,D,DC,WDAC,WO"

# Success/Failure:
#   /success:enable /failure:enable are not icacls flags; for SACL we specify:
#   (S) success, (F) failure
# We'll create two ACEs so it's explicit.
$AuditSuccessAce = "$Inheritance:$Principal:(S):$Rights"
$AuditFailureAce = "$Inheritance:$Principal:(F):$Rights"

function Add-Auditing {
  param(
    [Parameter(Mandatory=$true)][string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    Write-Warning "Target not found: $Path"
    return
  }

  Write-Host "`n=== Applying auditing to: $Path ===" -ForegroundColor Cyan

  # Add Success auditing
  & icacls $Path /setaudit "$AuditSuccessAce" | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "icacls /setaudit (Success) failed for $Path (exit $LASTEXITCODE)" }

  # Add Failure auditing
  & icacls $Path /setaudit "$AuditFailureAce" | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "icacls /setaudit (Failure) failed for $Path (exit $LASTEXITCODE)" }

  # Propagate auditing down the tree (this is the time-consuming part on big shares)
  # /T = traverse all subfolders
  # /C = continue on errors (locked files etc.)
  & icacls $Path /setaudit "$AuditSuccessAce" /T /C | Out-Host
  if ($LASTEXITCODE -ne 0) { Write-Warning "Propagation (Success) returned exit $LASTEXITCODE for $Path" }

  & icacls $Path /setaudit "$AuditFailureAce" /T /C | Out-Host
  if ($LASTEXITCODE -ne 0) { Write-Warning "Propagation (Failure) returned exit $LASTEXITCODE for $Path" }

  Write-Host "Done: $Path" -ForegroundColor Green
}

# Safety: confirm audit policy is enabled first
Write-Host "Checking audit policy for File System..." -ForegroundColor Yellow
& auditpol /get /subcategory:"File System" | Out-Host

foreach ($t in $Targets) {
  Add-Auditing -Path $t
}

Write-Host "`nAll targets processed." -ForegroundColor Green
Write-Host "Now test: create/modify/delete a file, then check Event Viewer > Security (4663/4660/4670)." -ForegroundColor Yellow
