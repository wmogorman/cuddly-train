<# 
.SYNOPSIS
  Check Windows and ESU activation, optionally install an ESU product key and activate online.

.PARAMETER ProductKey
  Optional. If supplied, the script installs this key (slmgr /ipk) and activates online with the ESU application ID.
  If omitted, the script also honors env:ESUKey for Datto RMM compatibility.

.PARAMETER Json
  Optional. Emit a JSON summary without the normal host-formatted status output.

.PARAMETER RebootNow
  Optional. Reboot the computer after the script finishes. The script also honors env:RebootNow for Datto compatibility.

.PARAMETER SkipDattoUdf
  Optional. Skip writing ESU status fields to HKLM\SOFTWARE\CentraStage.

.EXAMPLES
  # Just check status
  .\esu-script.ps1

  # Install a key, activate online, and emit JSON
  .\esu-script.ps1 -ProductKey XXXXX-XXXXX-XXXXX-XXXXX-XXXXX -Json

  # Check status without touching Datto RMM fields
  .\esu-script.ps1 -SkipDattoUdf
#>

[CmdletBinding()]
param(
[Parameter(Mandatory=$false)]
[string]$ProductKey,

[switch]$Json,

[switch]$RebootNow,

[switch]$SkipDattoUdf
)

$ErrorActionPreference = 'Stop'

function Resolve-ProductKeyInput {
  param(
    [string]$ExplicitProductKey,
    [bool]$ExplicitProductKeyProvided,
    [string]$EnvironmentProductKey
  )

  $candidate = $null

  if ($ExplicitProductKeyProvided) {
    if ([string]::IsNullOrWhiteSpace($ExplicitProductKey)) {
      throw "ProductKey cannot be empty when supplied."
    }
    $candidate = $ExplicitProductKey
  }
  elseif (-not [string]::IsNullOrWhiteSpace($EnvironmentProductKey)) {
    $candidate = $EnvironmentProductKey
  }
  else {
    return $null
  }

  $candidate = $candidate.Trim().ToUpperInvariant()
  if ($candidate -notmatch '^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}$') {
    throw "ProductKey must be in the format XXXXX-XXXXX-XXXXX-XXXXX-XXXXX."
  }

  return $candidate
}

$hasExplicitProductKey = $PSBoundParameters.ContainsKey('ProductKey')
$ProductKey = Resolve-ProductKeyInput -ExplicitProductKey $ProductKey -ExplicitProductKeyProvided $hasExplicitProductKey -EnvironmentProductKey $env:ESUKey
$hasProductKey = -not [string]::IsNullOrWhiteSpace($ProductKey)

# -- Helpers -------------------------------------------------------

function Resolve-SysnativePath {
  param([Parameter(Mandatory=$true)][string]$PathUnderSystem32)
  if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
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
  $psi.CreateNoWindow = $true
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

function Assert-SlmgrResult {
  param(
    [Parameter(Mandatory=$true)]$Result,
    [Parameter(Mandatory=$true)][string]$Operation
  )

  $combinedOutput = (@($Result.StdOut, $Result.StdErr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
  if ($Result.ExitCode -ne 0 -or $combinedOutput -match '(?i)\berror:') {
    $detail = if ($combinedOutput) { $combinedOutput } else { 'No additional output was returned.' }
    throw "slmgr $Operation failed. $detail"
  }
}

function Get-LicenseStatusText {
  param([int]$Code)

  switch ($Code) {
    0 { 'Unlicensed' }
    1 { 'Licensed' }
    2 { 'OOB_Grace' }
    3 { 'OOT_Grace' }
    4 { 'NonGenuine_Grace' }
    5 { 'Notification' }
    default { 'Unknown' }
  }
}

function Get-WindowsActivation {
  # Filter only Windows OS products that actually have a key
  $filter = "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL"
  $win = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $filter -ErrorAction Stop |
         Select-Object -First 1 Name, Description, LicenseStatus, PartialProductKey, ApplicationID, ProductKeyID

  if (-not $win) {
    throw "Unable to locate Windows licensing details via SoftwareLicensingProduct."
  }

  $svc = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop

  [pscustomobject]@{
    Name              = $win.Name
    Description       = $win.Description
    LicenseStatus     = $win.LicenseStatus
    LicenseStatusText = Get-LicenseStatusText -Code $win.LicenseStatus
    PartialProductKey = $win.PartialProductKey
    RemainingGrace    = $svc.RemainingWindowsReArmCount
  }
}

function Get-ActivationByAppId {
  param(
    [Parameter(Mandatory=$true)][string]$ApplicationId
  )

  $filter = "ApplicationID='$ApplicationId' AND PartialProductKey IS NOT NULL"
  $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $filter -ErrorAction SilentlyContinue |
             Select-Object -First 1 Name, Description, LicenseStatus, PartialProductKey, ApplicationID, ProductKeyID

  if (-not $product) { return $null }

  [pscustomobject]@{
    Name              = $product.Name
    Description       = $product.Description
    LicenseStatus     = $product.LicenseStatus
    LicenseStatusText = Get-LicenseStatusText -Code $product.LicenseStatus
    PartialProductKey = $product.PartialProductKey
  }
}

function New-ActivationSummary {
  param($Activation)

  if ($Activation) {
    return [pscustomobject]@{
      StatusText = $Activation.LicenseStatusText
      StatusCode = $Activation.LicenseStatus
      KeyTail    = $Activation.PartialProductKey
    }
  }

  return [pscustomobject]@{
    StatusText = 'Not installed'
    StatusCode = -1
    KeyTail    = 'N/A'
  }
}

function Test-OverallActivationSuccess {
  param(
    [Parameter(Mandatory=$true)]$WindowsActivation,
    [Parameter(Mandatory=$true)]$EsuSummary,
    [Parameter(Mandatory=$true)][bool]$EsuRelevant
  )

  if ($WindowsActivation.LicenseStatus -ne 1) {
    return [pscustomobject]@{
      Success = $false
      Reason  = 'Windows is not licensed.'
    }
  }

  if ($EsuRelevant -and $EsuSummary.StatusCode -ne 1) {
    return [pscustomobject]@{
      Success = $false
      Reason  = 'ESU is not licensed.'
    }
  }

  return [pscustomobject]@{
    Success = $true
    Reason  = if ($EsuRelevant) { 'Windows and ESU are licensed.' } else { 'Windows is licensed.' }
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
    [string]$Value,
    [switch]$EmitOutput
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    $Value = 'N/A'
  }

  # Replace characters that could break Datto RMM parsing
  $sanitized = ($Value -replace '[\r\n|]', ' ').Trim()
  $propName = "CustomField{0}" -f $Id

  $baseKey = $null
  $subKey = $null

  try {
    $registryView = if ([Environment]::Is64BitOperatingSystem) {
      [Microsoft.Win32.RegistryView]::Registry64
    } else {
      [Microsoft.Win32.RegistryView]::Default
    }
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $registryView)
    $subKey = $baseKey.CreateSubKey('SOFTWARE\CentraStage')
    if ($null -eq $subKey) {
      throw "Unable to open or create HKLM\SOFTWARE\CentraStage"
    }
    $subKey.SetValue($propName, $sanitized, [Microsoft.Win32.RegistryValueKind]::String)
  }
  catch {
    Write-Warning "Failed to update $propName in CentraStage registry: $($_.Exception.Message)"
  }
  finally {
    if ($subKey) { $subKey.Dispose() }
    if ($baseKey) { $baseKey.Dispose() }
  }

  if ($EmitOutput) {
    Write-Host ("{0}|{1}" -f $propName, $sanitized)
  }
}

$shouldReboot = $RebootNow.IsPresent -or ($env:RebootNow -match '^(?i)(1|true|yes)$')

function Invoke-OptionalRestart {
  param(
    [bool]$ShouldReboot,
    [switch]$EmitOutput
  )

  if ($ShouldReboot) {
    if ($EmitOutput) {
      Write-Host "Reboot requested."
    }
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

  $esuApplicationId = 'f520e45e-7413-4a34-a497-d2765967d094'

  $initialWindows = Get-WindowsActivation
  $initialEsu = Get-ActivationByAppId -ApplicationId $esuApplicationId
  $initialEsuSummary = New-ActivationSummary -Activation $initialEsu

  $actions = @()

  if ($hasProductKey) {
    $actions += "Installing product key (slmgr /ipk)"
    $ipk = Invoke-Slmgr "/ipk $ProductKey"
    $actions += "  /ipk exit=$($ipk.ExitCode)"
    if ($ipk.StdOut) { $actions += "  /ipk: $($ipk.StdOut)" }
    if ($ipk.StdErr) { $actions += "  /ipk err: $($ipk.StdErr)" }
    Assert-SlmgrResult -Result $ipk -Operation '/ipk'

    $actions += "Activating online (slmgr /ato $esuApplicationId)"
    $ato = Invoke-Slmgr "/ato $esuApplicationId"
    $actions += "  /ato exit=$($ato.ExitCode)"
    if ($ato.StdOut) { $actions += "  /ato: $($ato.StdOut)" }
    if ($ato.StdErr) { $actions += "  /ato err: $($ato.StdErr)" }
    Assert-SlmgrResult -Result $ato -Operation '/ato'
  }

  $finalWindows = Get-WindowsActivation
  $finalEsu = Get-ActivationByAppId -ApplicationId $esuApplicationId
  $finalEsuSummary = New-ActivationSummary -Activation $finalEsu
  $esuRelevant = $hasProductKey -or $null -ne $initialEsu -or $null -ne $finalEsu
  $outcome = Test-OverallActivationSuccess -WindowsActivation $finalWindows -EsuSummary $finalEsuSummary -EsuRelevant $esuRelevant

  $result = [pscustomobject]@{
    ComputerName       = $env:COMPUTERNAME
    InitialStatus      = $initialWindows.LicenseStatusText
    InitialCode        = $initialWindows.LicenseStatus
    InitialKeyTail     = $initialWindows.PartialProductKey
    EsuInitialStatus   = $initialEsuSummary.StatusText
    EsuInitialCode     = $initialEsuSummary.StatusCode
    EsuInitialKeyTail  = $initialEsuSummary.KeyTail
    Actions            = $actions
    FinalStatus        = $finalWindows.LicenseStatusText
    FinalCode          = $finalWindows.LicenseStatus
    FinalKeyTail       = $finalWindows.PartialProductKey
    WindowsProductName = $finalWindows.Name
    WindowsDescription = $finalWindows.Description
    WindowsStatus      = $finalWindows.LicenseStatusText
    WindowsCode        = $finalWindows.LicenseStatus
    WindowsKeyTail     = $finalWindows.PartialProductKey
    EsuStatus          = $finalEsuSummary.StatusText
    EsuCode            = $finalEsuSummary.StatusCode
    EsuKeyTail         = $finalEsuSummary.KeyTail
    EsuRelevant        = $esuRelevant
    Success            = $outcome.Success
    ExitReason         = $outcome.Reason
  }

  if ($Json) {
    $result | ConvertTo-Json -Depth 5
  } else {
    Write-Host "=== Windows / ESU Activation Check ==="
    Write-Host " Computer     : $($result.ComputerName)"
    Write-Host " Product      : $($result.WindowsProductName)"
    Write-Host " Description  : $($result.WindowsDescription)"
    Write-Host " Initial      : $($result.InitialStatus) (code $($result.InitialCode)), key tail: $($result.InitialKeyTail)"
    Write-Host " ESU initial  : $($result.EsuInitialStatus) (code $($result.EsuInitialCode)), key tail: $($result.EsuInitialKeyTail)"
    if ($actions.Count) {
      Write-Host " Actions:"
      $actions | ForEach-Object { Write-Host "  - $_" }
    } else {
      Write-Host " Actions      : (none requested)"
    }
    Write-Host " Windows      : $($result.WindowsStatus) (code $($result.WindowsCode)), key tail: $($result.WindowsKeyTail)"
    if ($esuRelevant) {
      Write-Host " ESU          : $($result.EsuStatus) (code $($result.EsuCode)), key tail: $($result.EsuKeyTail)"
    } else {
      Write-Host " ESU          : Not installed (code -1), key tail: N/A"
    }
    Write-Host " Result       : $(if ($result.Success) { 'Success' } else { 'Failure' }) - $($result.ExitReason)"
  }

  if (-not $SkipDattoUdf) {
    Write-DattoUdf -Id 16 -Value $finalEsuSummary.StatusText -EmitOutput:(-not $Json)
    Write-DattoUdf -Id 17 -Value $finalEsuSummary.KeyTail -EmitOutput:(-not $Json)
  }
  Invoke-OptionalRestart -ShouldReboot $shouldReboot -EmitOutput:(-not $Json)

  if ($result.Success) { exit 0 } else { exit 1 }

}
catch {
  if (-not $SkipDattoUdf) {
    Write-DattoUdf -Id 16 -Value 'Error' -EmitOutput:(-not $Json)
    Write-DattoUdf -Id 17 -Value 'N/A' -EmitOutput:(-not $Json)
  }
  if ($Json) {
    [pscustomobject]@{
      ComputerName = $env:COMPUTERNAME
      Success      = $false
      Error        = $_.Exception.Message
    } | ConvertTo-Json -Depth 5
  } else {
    Write-Error $_.Exception.Message
  }
  Invoke-OptionalRestart -ShouldReboot $shouldReboot -EmitOutput:(-not $Json)
  exit 1
}
