# Run as Administrator

# ======= Settings =======
$SourceProfile = 'Philip Smith'                       # local account name
$DoMove        = $false                        # set $true to MOVE instead of COPY
$LogPath       = "C:\Temp\Promote-PhilipSmithToPublic-$(Get-Date -Format yyyyMMdd-HHmmss).log"

# Exclusions (filenames/patterns)
$Exclude = @('*.tmp','~$*','Thumbs.db','desktop.ini')

# ======= Paths =======
$UserRoot          = Join-Path 'C:\Users' $SourceProfile
$PublicRoot        = $env:Public
$ProgramDataRoot   = $env:ProgramData

$Paths = [ordered]@{
  # Desktop shortcuts & files -> Public Desktop
  'DesktopShortcuts' = @{
      Source = Join-Path $UserRoot 'Desktop'
      Target = Join-Path $PublicRoot 'Desktop'
      Filters = @('*.lnk','*.url','*.bat','*.cmd','*.ps1')   # only typical shortcut/script types
      WholeFolder = $false
  }

  # Start Menu (per-user) -> All Users Start Menu
  'StartMenu' = @{
      Source = Join-Path $UserRoot 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs'
      Target = Join-Path $ProgramDataRoot 'Microsoft\Windows\Start Menu\Programs'
      Filters = @('*')   # copy all shortcuts/folders here
      WholeFolder = $true
  }

  # Documents -> Public\Documents\From-PhilipSmith
  'Documents' = @{
      Source = Join-Path $UserRoot 'Documents'
      Target = Join-Path $PublicRoot 'Documents\From-PhilipSmith'
      Filters = @('*')
      WholeFolder = $true
  }

  # Pictures -> Public\Pictures\From-PhilipSmith
  'Pictures' = @{
      Source = Join-Path $UserRoot 'Pictures'
      Target = Join-Path $PublicRoot 'Pictures\From-PhilipSmith'
      Filters = @('*')
      WholeFolder = $true
  }

  # Music -> Public\Music\From-PhilipSmith
  'Music' = @{
      Source = Join-Path $UserRoot 'Music'
      Target = Join-Path $PublicRoot 'Music\From-PhilipSmith'
      Filters = @('*')
      WholeFolder = $true
  }

  # Videos -> Public\Videos\From-PhilipSmith
  'Videos' = @{
      Source = Join-Path $UserRoot 'Videos'
      Target = Join-Path $PublicRoot 'Videos\From-PhilipSmith'
      Filters = @('*')
      WholeFolder = $true
  }
}

# ======= Helpers =======
function Write-Log {
  param([string]$Message)
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  Add-Content -Path $LogPath -Value $line
}

function Test-Elevation {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Elevation)) {
  Write-Host "Please run in an elevated PowerShell session." -ForegroundColor Yellow
  return
}

# Prepare log folder
New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
Write-Log "Starting promotion from '$SourceProfile' at $UserRoot"
Write-Log "Mode: $([string]::Format('{0}', $(if($DoMove){'MOVE'}else{'COPY'})))"

# Build base robocopy switches
# /E  = copy subdirs incl. empty
# /COPY:DATSO = copy Data, Attributes, Timestamps, Security (ACLs), Owner
# /R:1 /W:1 = quick retry
# /NFL /NDL /NP = quieter logging
# /XO = skip older
# /XJ = skip junctions (helps avoid weird profile links)
$baseSwitches = @('/E','/COPY:DATSO','/R:1','/W:1','/XO','/XJ','/NFL','/NDL','/NP')

if ($DoMove) {
  # /MOVE moves files and directories (be careful!)
  $baseSwitches += '/MOVE'
}

# Do work
foreach ($key in $Paths.Keys) {
  $job = $Paths[$key]
  $src = $job.Source
  $dst = $job.Target
  $filters = $job.Filters
  $whole = $job.WholeFolder

  if (-not (Test-Path $src)) {
    Write-Log "SKIP [$key]: source missing -> $src"
    continue
  }

  # Ensure target exists
  New-Item -ItemType Directory -Path $dst -Force | Out-Null

  Write-Log "PROCESS [$key]: $src  ->  $dst"

  # Compose robocopy command
  $arguments = @("$src", "$dst")
  if ($whole -and $filters -and $filters -notcontains '*.lnk') {
    # When copying whole folders, use a generic * filter to bring everything (we’ll still exclude temp/junk)
    $arguments += '*'
  } else {
    # When copying selected patterns (e.g., desktop shortcuts)
    foreach ($f in $filters) { $arguments += $f }
  }

  # Add excludes
  foreach ($ex in $Exclude) {
    $arguments += ("/XF", $ex)
  }
  # Exclude common cache folders inside Start Menu or libraries if present
  $arguments += '/XD' 
  $arguments += @('Cache','Temp','Temporary Internet Files','$RECYCLE.BIN','System Volume Information')

  $arguments += $baseSwitches

  # Run
  $cmd = 'robocopy.exe ' + ($arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } } | ForEach-Object { $_ }) -join ' '
  Write-Log "CMD: $cmd"
  $result = Start-Process -FilePath robocopy.exe -ArgumentList $arguments -NoNewWindow -PassThru -Wait
  $exit = $result.ExitCode

  # Robocopy exit codes 0–7 are success-ish
  if ($exit -le 7) {
    Write-Log "SUCCESS [$key] robocopy exit code: $exit"
  } else {
    Write-Log "ERROR   [$key] robocopy exit code: $exit"
  }
}

Write-Log "Completed. Log: $LogPath"
Write-Host "`nDone. Review the log for details:`n$LogPath"
