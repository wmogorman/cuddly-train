<# 
.SYNOPSIS
  Check Windows activation, optionally install product key (/ipk) and activate online (/ato).

.PARAMETER ProductKey
  Optional. If supplied, the script installs this key (slmgr /ipk) and activates online with the ESU application ID.

.PARAMETER Json
  Optional. Emit a JSON summary (useful for RMM ingestion).

.EXAMPLES
  # Just check status
  .\Check-Activation.ps1

  # Install a key and activate online
  .\Check-Activation.ps1 -ProductKey XXXXX-XXXXX-XXXXX-XXXXX-XXXXX -Json
#>

[CmdletBinding()]
param(
[Parameter(Mandatory=$false)]
[ValidatePattern('^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$')]
[string]$ProductKey,

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
  $proc.StartInfo = $psi
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

function Write-DattoUdf {
  param(
    [Parameter(Mandatory=$true)][int]$Id,
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    $Value = 'N/A'
  }

  # Replace characters that could break Datto RMM parsing
  $sanitized = ($Value -replace '[\r\n|]', ' ').Trim()
  Write-Host ("UDF|{0}|{1}" -f $Id, $sanitized)
}

$shouldReboot = $false
if ($env:RebootNow) {
  if ($env:RebootNow -match '^(?i)(1|true|yes)$') {
    $shouldReboot = $true
  }
}

function Invoke-OptionalRestart {
  param([bool]$ShouldReboot)

  if ($ShouldReboot) {
    Write-Host "Reboot requested via env:RebootNow"
    try {
      Restart-Computer -Force -ErrorAction Stop
    }
    catch {
      Write-Warning "Failed to trigger reboot: $($_.Exception.Message)"
    }
  }
}

# -- Main ----------------------------------------------------------

try {
  Require-Admin

  $initial = Get-WindowsActivation

  $actions = @()

  $esuApplicationId = 'f520e45e-7413-4a34-a497-d2765967d094'

  if ($PSBoundParameters.ContainsKey('ProductKey')) {
    $actions += "Installing product key (slmgr /ipk)"
    $ipk = Invoke-Slmgr "/ipk $ProductKey"
    $actions += "  /ipk exit=$($ipk.ExitCode)"
    if ($ipk.StdOut) { $actions += "  /ipk: $($ipk.StdOut)" }
    if ($ipk.StdErr) { $actions += "  /ipk err: $($ipk.StdErr)" }
    $actions += "Activating online (slmgr /ato $esuApplicationId)"
    $ato = Invoke-Slmgr "/ato $esuApplicationId"
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
    }
    Write-Host " Final        : $($result.FinalStatus) (code $($result.FinalCode)), key tail: $($result.FinalKeyTail)"
  }

  Write-DattoUdf -Id 16 -Value $result.FinalStatus
  Write-DattoUdf -Id 17 -Value $result.FinalKeyTail
  Invoke-OptionalRestart -ShouldReboot $shouldReboot

  # Exit 0 if activated, 1 otherwise (handy for RMM success/failure)
  if ($final.LicenseStatus -eq 1) { exit 0 } else { exit 1 }

}
catch {
  Write-DattoUdf -Id 16 -Value 'Error'
  Write-DattoUdf -Id 17 -Value 'N/A'
  Write-Error $_.Exception.Message
  if ($Json) {
    @{ error = $_.Exception.Message } | ConvertTo-Json
  }
  Invoke-OptionalRestart -ShouldReboot $shouldReboot
  exit 1
}
