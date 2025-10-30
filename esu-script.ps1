<# 
.SYNOPSIS
  Check Windows activation, optionally install product key (/ipk) and activate online (/ato).

.PARAMETER ProductKey
  Optional. If supplied, the script installs this key (slmgr /ipk).

.PARAMETER Ato
  Optional. If set, the script runs slmgr /ato to activate online.

.PARAMETER Json
  Optional. Emit a JSON summary (useful for RMM ingestion).

.EXAMPLES
  # Just check status
  .\Check-Activation.ps1

  # Install a key and activate online
  .\Check-Activation.ps1 -ProductKey XXXXX-XXXXX-XXXXX-XXXXX-XXXXX -Ato -Json
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$false)]
  [ValidatePattern('^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$')]
  [string]$ProductKey,

  [switch]$Ato,
  [switch]$Json
)

# -- Helpers -------------------------------------------------------

function Resolve-SysnativePath {
  param([Parameter(Mandatory=$true)][string]$PathUnderSystem32)
  if ($env:PROCESSOR_ARCHITEW6432 -or $env:PROCESSOR_ARCHITECTURE -eq 'AMD64') {
    $sysnative = Join-Path $env:WINDIR 'sysnative'
    $candidate = Join-Path $sysnative $PathUnderSystem32
    if (Test-Path $candidate) { return $candidate }
  }
  return Join-Path $env:WINDIR "System32\$PathUnderSystem32"
}

function Invoke-Slmgr {
  param([Parameter(Mandatory=$true)][string]$Argument)

  $cscript = Resolve-SysnativePath 'cscript.exe'
  $slmgr = Resolve-SysnativePath 'slmgr.vbs'

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $cscript
  $psi.Arguments = "//Nologo `"$slmgr`" $Argument"
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi | Out-Null
  [void]$proc.Start()
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  [pscustomobject]@{
    Argument = $Argument
    ExitCode = $proc.ExitCode
    StdOut   = $stdout.Trim()
    StdErr   = $stderr.Trim()
  }
}

function Get-WindowsActivation {
  # Filter only Windows OS products that actually have a key
  $win = Get-CimInstance -ClassName SoftwareLicensingProduct `
         | Where-Object { $_.PartialProductKey -and $_.Name -match '^Windows' } `
         | Select-Object -First 1 Name, Description, LicenseStatus, PartialProductKey, ApplicationID, ProductKeyID

  $svc = Get-CimInstance -ClassName SoftwareLicensingService

  # Map LicenseStatus to text
  $map = @{
    0 = 'Unlicensed'
    1 = 'Licensed'
    2 = 'OOB_Grace'
    3 = 'OOT_Grace'
    4 = 'NonGenuine_Grace'
    5 = 'Notification'
  }

  [pscustomobject]@{
    Name              = $win.Name
    Description       = $win.Description
    LicenseStatus     = $win.LicenseStatus
    LicenseStatusText = $map[[int]$win.LicenseStatus]
    PartialProductKey = $win.PartialProductKey
    RemainingGrace    = $svc.RemainingWindowsReArmCount
  }
}

function Require-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal $id
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must be run as Administrator."
  }
}

# -- Main ----------------------------------------------------------

try {
  Require-Admin

  $initial = Get-WindowsActivation

  $actions = @()

  if ($PSBoundParameters.ContainsKey('ProductKey')) {
    $actions += "Installing product key (slmgr /ipk)"
    $ipk = Invoke-Slmgr "/ipk $ProductKey"
    $actions += "  /ipk exit=$($ipk.ExitCode)"
    if ($ipk.StdOut) { $actions += "  /ipk: $($ipk.StdOut)" }
    if ($ipk.StdErr) { $actions += "  /ipk err: $($ipk.StdErr)" }
  }

  if ($Ato) {
    $actions += "Activating online (slmgr /ato)"
    $ato = Invoke-Slmgr "/ato"
    $actions += "  /ato exit=$($ato.ExitCode)"
    if ($ato.StdOut) { $actions += "  /ato: $($ato.StdOut)" }
    if ($ato.StdErr) { $actions += "  /ato err: $($ato.StdErr)" }
  }

  $final = Get-WindowsActivation

  $result = [pscustomobject]@{
    ComputerName       = $env:COMPUTERNAME
    InitialStatus      = $initial.LicenseStatusText
    InitialCode        = $initial.LicenseStatus
    InitialKeyTail     = $initial.PartialProductKey
    Actions            = $actions
    FinalStatus        = $final.LicenseStatusText
    FinalCode          = $final.LicenseStatus
    FinalKeyTail       = $final.PartialProductKey
    WindowsProductName = $final.Name
    WindowsDescription = $final.Description
  }

  if ($Json) {
    $result | ConvertTo-Json -Depth 5
  } else {
    Write-Host "=== Windows Activation Check ==="
    Write-Host " Computer     : $($result.ComputerName)"
    Write-Host " Product      : $($result.WindowsProductName)"
    Write-Host " Description  : $($result.WindowsDescription)"
    Write-Host " Initial      : $($result.InitialStatus) (code $($result.InitialCode)), key tail: $($result.InitialKeyTail)"
    if ($actions.Count) {
      Write-Host " Actions:"
      $actions | ForEach-Object { Write-Host "  - $_" }
    } else {
      Write-Host " Actions      : (none requested)"
    end
    Write-Host " Final        : $($result.FinalStatus) (code $($result.FinalCode)), key tail: $($result.FinalKeyTail)"
  }

  # Exit 0 if activated, 1 otherwise (handy for RMM success/failure)
  if ($final.LicenseStatus -eq 1) { exit 0 } else { exit 1 }

}
catch {
  Write-Error $_.Exception.Message
  if ($Json) {
    @{ error = $_.Exception.Message } | ConvertTo-Json
  }
  exit 1
}
