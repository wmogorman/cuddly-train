<# 
.SYNOPSIS
  Deep cleanup for common Windows disk hogs (caches, dumps, installers, stale update content).
  PowerShell port of the provided batch script.

.NOTES
  Run As Admin. Safe to use on Windows 10/11 and Server variants.
#>

# --- Safety: must be admin
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).
  IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
  Write-Error "[!] Please run this script as Administrator."
  exit 1
}

Write-Host "=== Starting cleanup on $env:COMPUTERNAME at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

# --- Helpers
function Remove-ItemQuiet {
  param([Parameter(Mandatory)][string]$Path)
  try {
    if (Test-Path -LiteralPath $Path) {
      Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
  } catch { }
}

function Remove-PatternFromRoot {
  param([Parameter(Mandatory)][string]$Pattern)
  try {
    Get-ChildItem -LiteralPath $env:SystemDrive\ -Filter $Pattern -File -Force -ErrorAction SilentlyContinue |
      Remove-Item -Force -ErrorAction SilentlyContinue
  } catch { }
}

function New-DirIfMissing {
  param([Parameter(Mandatory)][string]$Path)
  try {
    if (-not (Test-Path -LiteralPath $Path)) {
      New-Item -ItemType Directory -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null
    }
  } catch { }
}

# --- Stop update/DO services so caches unlock
Write-Host "[*] Stopping Windows Update + Delivery Optimization..."
$servicesToStop = @('wuauserv','dosvc')
foreach ($svc in $servicesToStop) { 
  try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch { }
}

# --- YOUR ORIGINAL TARGETS
$targets = @(
  'C:\$GetCurrent\*',
  'C:\Windows.old\*',
  'C:\Dell\*',
  'C:\Drivers\*',
  'C:\e-logo\*',
  'C:\OneDriveTemp\*',
  'C:\Recovery\*',
  'C:\System repair\*',
  'C:\Windows\Temp\*',
  'C:\Windows\minidump\*',
  'C:\Windows\Logs\*',
  'C:\Windows\Prefetch\*',
  'C:\ProgramData\Microsoft\Windows\WER\*',
  'C:\Windows\Temp\*'
)

foreach ($t in $targets) {
  try { Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# Single file: memory.dmp
try { Remove-Item 'C:\Windows\memory.dmp' -Force -ErrorAction SilentlyContinue } catch { }

# Root garbage by extension
Remove-PatternFromRoot '*.tmp'
Remove-PatternFromRoot '*._mp'
Remove-PatternFromRoot '*.log'
Remove-PatternFromRoot '*.gid'
Remove-PatternFromRoot '*.chk'
Remove-PatternFromRoot '*.old'

# Windows Update cache refresh
$sd = 'C:\Windows\SoftwareDistribution\Download'
try { Remove-ItemQuiet -Path $sd } catch { }
New-DirIfMissing -Path $sd

# --- MAJOR SPACE SAVERS

# Delivery Optimization cache
Write-Host "[*] Clearing Delivery Optimization cache (DoSvc)..."
$doCache = 'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
Remove-ItemQuiet -Path $doCache
New-DirIfMissing -Path $doCache

# Live Kernel + crash dumps
Write-Host "[*] Clearing Live Kernel + crash dumps..."
foreach ($p in @(
  'C:\Windows\LiveKernelReports\*.dmp',
  'C:\Windows\LiveKernelReports\*.etl',
  'C:\Windows\System32\config\systemprofile\AppData\Local\CrashDumps\*'
)) { try { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } catch { } }

# CBS / Panther logs
Write-Host "[*] Clearing CBS/Panther/log noise (safe)..."
foreach ($p in @(
  'C:\Windows\Logs\CBS\CBS*.log',
  'C:\Windows\Logs\CBS\*.cab',
  'C:\Windows\Panther\*.log',
  'C:\Windows\Panther\UnattendGC\*'
)) { try { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } catch { } }

# SystemTemp (chromium unpacker junk often here)
Write-Host "[*] Clearing SystemTemp (huge chrome_Unpacker files live here)..."
foreach ($p in @(
  'C:\Windows\SystemTemp\*',
  'C:\Windows\SystemTemp\chrome_Unpacker_BeginUnzipping*'
)) { try { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } catch { } }

# Browser updater/installer caches
Write-Host "[*] Clearing browser updater/installer caches (Chrome/Google Updater)..."
$pf   = $env:ProgramFiles
$pf86 = ${env:ProgramFiles(x86)}   # <-- fixed: env var with () needs braces

foreach ($d in @(
  (Join-Path $pf   'Google\Chrome\Application\*\Installer'),
  (Join-Path $pf86 'Google\GoogleUpdater\crx_cache'),
  (Join-Path $pf   'Google\Update\Download')
)) { if ($d) { Remove-ItemQuiet -Path $d } }

# Teams classic installer cache
Write-Host "[*] Clearing Teams classic installer cache..."
if ($pf86) { Remove-ItemQuiet -Path (Join-Path $pf86 'Teams Installer') }

# Common InstallShield heavyweight caches (GUIDs from field reports)
Write-Host "[*] Clearing common InstallShield installer caches..."
if ($pf86) {
  Remove-ItemQuiet -Path (Join-Path $pf86 'InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}')
  Remove-ItemQuiet -Path (Join-Path $pf86 'InstallShield Installation Information\{CC40119D-6ADF-4832-8025-4808195E41D5}')
}

# Acrobat setup leftovers (optional)
Write-Host "[*] Optional Acrobat setup leftovers..."
if ($pf)   { Remove-ItemQuiet -Path (Join-Path $pf   'Common Files\Adobe\Acrobat\Setup') }
if ($pf86) { Remove-ItemQuiet -Path (Join-Path $pf86 'Adobe\Acrobat DC\Setup Files') }

# --- PER-USER JUNK (browser caches, temp, crashdumps)
Write-Host "[*] Clearing per-user caches (Temp, CrashDumps, Chrome/Edge Cache_Data)..."
Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
  $U = $_.FullName
  $cacheRelPaths = @(
    'AppData\Local\Temp\*'
    'AppData\Local\CrashDumps\*'
    'AppData\Local\Google\Chrome\User Data\Default\Cache\Cache_Data'
    'AppData\Local\Microsoft\Edge\User Data\Default\Cache\Cache_Data'
  )

  foreach ($rel in $cacheRelPaths) {
    $p = Join-Path -Path $U -ChildPath $rel
    try {
      if ($p.EndsWith('Cache_Data')) {
        Remove-ItemQuiet -Path $p
      } else {
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
      }
    } catch { }
  }

  # "*updater*\pending*" payloads
  try {
    $local = Join-Path $U 'AppData\Local'
    if (Test-Path $local) {
      Get-ChildItem $local -Directory -Filter '*updater*' -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ChildItem $_.FullName -Directory -Filter 'pending*' -ErrorAction SilentlyContinue |
          ForEach-Object { Remove-ItemQuiet -Path $_.FullName }
      }
    }
  } catch { }
}

# --- TAKE OWNERSHIP & REMOVE STUB FOLDERS (Windows.old, $GetCurrent)
Write-Host "[*] Finalizing Windows.old / $GetCurrent removal (ownership)..."
foreach ($z in @('C:\Windows.old','C:\$GetCurrent')) {
  if (Test-Path -LiteralPath $z) {
    try {
      & takeown.exe /f $z /r /d y   *> $null
      & icacls.exe  $z /grant *S-1-5-32-544:F /t   *> $null  # Administrators SID
      Remove-ItemQuiet -Path $z
    } catch { }
  }
}

# --- OPTIONAL: Component Store cleanup
# Write-Host "[*] Optional: DISM component store cleanup (commented out by default)..."
# Start-Process -FilePath dism.exe -ArgumentList "/Online","/Cleanup-Image","/StartComponentCleanup" -Wait

# --- Restart services
Write-Host "[*] Restarting services..."
foreach ($svc in $servicesToStop) { 
  try { Start-Service -Name $svc -ErrorAction SilentlyContinue } catch { }
}

Write-Host "=== Cleanup complete on $env:COMPUTERNAME ==="
