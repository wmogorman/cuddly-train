<#
.SYNOPSIS
  Verify Windows 10 22H2 or Windows Server 2012 / 2012 R2 ESU readiness, remediate supported prerequisites, and optionally install and activate an ESU key.

.PARAMETER ProductKey
  Optional. If supplied and the machine is ESU-ready with no pending reboot, the script installs this key (slmgr /ipk) and activates online with the ESU activation ID.

.PARAMETER EsuYear
  Optional. ESU program year to target when deriving the activation ID automatically. Defaults to Year 1.

.PARAMETER ActivationId
  Optional. Override the activation ID passed to slmgr /ato. If omitted, the script derives the ID from the detected platform and -EsuYear.

.PARAMETER Json
  Optional. Emit a JSON summary without the normal host-formatted status output.

.PARAMETER RebootNow
  Optional. Reboot the computer after the script finishes. The script also honors env:RebootNow for Datto compatibility.

.PARAMETER SkipDattoUdf
  Optional. Skip writing ESU status fields to HKLM\SOFTWARE\CentraStage.

.PARAMETER SkipPrereqRemediation
  Optional. Verify ESU prerequisites without downloading and installing missing prerequisite updates.

.EXAMPLES
  # Verify ESU readiness and remediate missing prerequisites
  .\esu-script.ps1

  # Verify only, without downloading or installing prerequisite updates
  .\esu-script.ps1 -SkipPrereqRemediation

  # Verify and activate Windows 10 ESU Year 1 using the platform default activation ID
  .\esu-script.ps1 -ProductKey XXXXX-XXXXX-XXXXX-XXXXX-XXXXX -EsuYear 1

  # Verify, remediate, then install a key and emit JSON
  .\esu-script.ps1 -ProductKey XXXXX-XXXXX-XXXXX-XXXXX-XXXXX -Json
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [ValidatePattern('^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}$')]
  [string]$ProductKey,

  [ValidateSet(1, 2, 3)]
  [int]$EsuYear = 1,

  [ValidatePattern('^[{(]?[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}[)}]?$')]
  [string]$ActivationId,

  [switch]$Json,

  [switch]$RebootNow,

  [switch]$SkipDattoUdf,

  [switch]$SkipPrereqRemediation
)

$ErrorActionPreference = 'Stop'

if ($PSBoundParameters.ContainsKey('ProductKey')) {
  $ProductKey = $ProductKey.Trim().ToUpperInvariant()
}

if ($PSBoundParameters.ContainsKey('ActivationId')) {
  $ActivationId = ([guid]$ActivationId).Guid
}

$script:CbsPackageIndex = $null
$script:CbsPackagePropertyCache = @{}

# Windows 10 activation IDs were confirmed against Microsoft Learn on 2025-11-17.
$windows10ActivationIds = @{
  1 = 'f520e45e-7413-4a34-a497-d2765967d094'
  2 = '1043add5-23b1-4afb-9a0f-64343c8f3f8d'
  3 = '83d49986-add3-41d7-ba33-87c7bfb5c0fb'
}

# Windows Server 2012 / 2012 R2 activation IDs were confirmed against Microsoft's Windows IT Pro Blog guidance.
$server2012ActivationIds = @{
  1 = 'c0a2ea62-12ad-435b-ab4f-c9bfab48dbc4'
  2 = 'e3e2690b-931c-4c80-b1ff-dffba8a81988'
  3 = '55b1dd2d-2209-4ea0-a805-06298bad25b3'
}

# Server prerequisite mappings were confirmed against Microsoft support guidance current on 2026-04-03.
$serverPlatformCatalog = @{
  '6.3' = [pscustomobject]@{
    DisplayName   = 'Windows Server 2012 R2'
    PrepKb        = 'KB5017220'
    PrepTitle     = 'Extended Security Updates (ESU) Licensing Preparation Package'
    PrepUrl       = 'https://catalog.s.download.windowsupdate.com/c/msdownload/update/software/secu/2022/08/windows8.1-kb5017220-x64_d771111b22ec71560b207a6735d5ecebd47c4f38.msu'
    PrepFileName  = 'windows8.1-kb5017220-x64_d771111b22ec71560b207a6735d5ecebd47c4f38.msu'
    BaselineKb    = 'KB5079233'
    BaselineTitle = 'Servicing Stack Update'
    BaselineUrl   = 'https://catalog.s.download.windowsupdate.com/c/msdownload/update/software/secu/2026/03/windows8.1-kb5079233-x64_59c6da4865cb0cb99b38196a5ee966202c285dde.msu'
    BaselineFileName = 'windows8.1-kb5079233-x64_59c6da4865cb0cb99b38196a5ee966202c285dde.msu'
    ActivationIds = $server2012ActivationIds
  }
  '6.2' = [pscustomobject]@{
    DisplayName   = 'Windows Server 2012'
    PrepKb        = 'KB5017221'
    PrepTitle     = 'Extended Security Updates (ESU) Licensing Preparation Package'
    PrepUrl       = 'https://catalog.s.download.windowsupdate.com/c/msdownload/update/software/secu/2022/08/windows8-rt-kb5017221-x64_d01e9b9b910f5f1e374bc1b89a8d00c1a97e215f.msu'
    PrepFileName  = 'windows8-rt-kb5017221-x64_d01e9b9b910f5f1e374bc1b89a8d00c1a97e215f.msu'
    BaselineKb    = 'KB5079234'
    BaselineTitle = 'Servicing Stack Update'
    BaselineUrl   = 'https://catalog.s.download.windowsupdate.com/c/msdownload/update/software/secu/2026/03/windows8-rt-kb5079234-x64_2428f08cc4941bbd4b21be0a6a3ae1090678bd1b.msu'
    BaselineFileName = 'windows8-rt-kb5079234-x64_2428f08cc4941bbd4b21be0a6a3ae1090678bd1b.msu'
    ActivationIds = $server2012ActivationIds
  }
}

$windows10PrepPackageCatalog = @{
  'x64' = [pscustomobject]@{
    PrepUrl      = 'https://catalog.s.download.windowsupdate.com/d/msdownload/update/software/secu/2025/11/windows10.0-kb5072653-x64_c2f56817f6ca39322bce94e7ea2c554cfa71abcd.msu'
    PrepFileName = 'windows10.0-kb5072653-x64_c2f56817f6ca39322bce94e7ea2c554cfa71abcd.msu'
  }
  'x86' = [pscustomobject]@{
    PrepUrl      = 'https://catalog.s.download.windowsupdate.com/d/msdownload/update/software/secu/2025/11/windows10.0-kb5072653-x86_8d3487fa93996facba9233443e461b32c02dab49.msu'
    PrepFileName = 'windows10.0-kb5072653-x86_8d3487fa93996facba9233443e461b32c02dab49.msu'
  }
}

$windows10BaselineMinVersion = [version]'10.0.19045.6456'

# -- Helpers -------------------------------------------------------

function Resolve-SysnativePath {
  param([Parameter(Mandatory = $true)][string]$PathUnderSystem32)

  if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysnative = Join-Path $env:WINDIR 'sysnative'
    $candidate = Join-Path $sysnative $PathUnderSystem32
    if (Test-Path $candidate) { return $candidate }
  }

  return Join-Path $env:WINDIR "System32\$PathUnderSystem32"
}

function Normalize-KbId {
  param([Parameter(Mandatory = $true)][string]$KbId)

  $trimmed = $KbId.Trim().ToUpperInvariant()
  if ($trimmed -notmatch '^KB\d{7}$') {
    throw "Invalid KB identifier '$KbId'. Expected format KB1234567."
  }

  return $trimmed
}

function Convert-ExitCodeToHex {
  param([Parameter(Mandatory = $true)][int]$ExitCode)

  return ('0x{0:X8}' -f ([uint32]$ExitCode))
}

function Convert-CbsFileTime {
  param(
    [Nullable[uint32]]$High,
    [Nullable[uint32]]$Low
  )

  if ($null -eq $High -or $null -eq $Low) {
    return $null
  }

  try {
    $fileTime = ([int64]$High -shl 32) -bor [uint32]$Low
    return [DateTime]::FromFileTimeUtc($fileTime)
  }
  catch {
    return $null
  }
}

function Convert-ToDateTime {
  param($Value)

  if ($null -eq $Value) {
    return $null
  }

  try {
    return [datetime]$Value
  }
  catch {
    return $null
  }
}

function Get-ProcessorArchitectureTag {
  $arch = @($env:PROCESSOR_ARCHITEW6432, $env:PROCESSOR_ARCHITECTURE) |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
          Select-Object -First 1

  if ([string]::IsNullOrWhiteSpace($arch)) {
    return $null
  }

  switch -Regex ($arch.ToUpperInvariant()) {
    '^AMD64$' { return 'x64' }
    '^X86$' { return 'x86' }
    '^ARM64$' { return 'ARM64' }
    default { return $null }
  }
}

function Invoke-Slmgr {
  param([Parameter(Mandatory = $true)][string]$Argument)

  $cscript = Resolve-SysnativePath 'cscript.exe'
  $slmgr = Resolve-SysnativePath 'slmgr.vbs'

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $cscript
  $psi.Arguments = "//Nologo `"$slmgr`" $Argument"
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
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
    [Parameter(Mandatory = $true)]$Result,
    [Parameter(Mandatory = $true)][string]$Operation
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
  $filter = "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL"
  $win = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $filter -ErrorAction Stop |
         Select-Object -First 1 Name, Description, LicenseStatus, PartialProductKey, ApplicationID, ProductKeyID

  if (-not $win) {
    throw 'Unable to locate Windows licensing details via SoftwareLicensingProduct.'
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

function Get-ActivationById {
  param([Parameter(Mandatory = $true)][string]$ActivationId)

  $normalizedId = ([guid]$ActivationId).Guid
  $filter = "ID='$normalizedId'"
  $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $filter -ErrorAction SilentlyContinue |
             Where-Object { $_.PartialProductKey } |
             Select-Object -First 1 Name, Description, LicenseStatus, PartialProductKey, ApplicationID, ProductKeyID, ID

  if (-not $product) {
    $product = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction SilentlyContinue |
               Where-Object {
                 $_.PartialProductKey -and $_.ID -eq $normalizedId
               } |
               Select-Object -First 1 Name, Description, LicenseStatus, PartialProductKey, ApplicationID, ProductKeyID, ID
  }

  if (-not $product) { return $null }

  [pscustomobject]@{
    Name              = $product.Name
    Description       = $product.Description
    LicenseStatus     = $product.LicenseStatus
    LicenseStatusText = Get-LicenseStatusText -Code $product.LicenseStatus
    PartialProductKey = $product.PartialProductKey
    ActivationId      = $product.ID
  }
}

function New-ActivationSummary {
  param($Activation)

  if ($Activation) {
    return [pscustomobject]@{
      StatusText = $Activation.LicenseStatusText
      StatusCode = $Activation.LicenseStatus
      KeyTail    = $Activation.PartialProductKey
      ActivationId = $Activation.ActivationId
    }
  }

  return [pscustomobject]@{
    StatusText = 'Not installed'
    StatusCode = -1
    KeyTail    = 'N/A'
    ActivationId = 'N/A'
  }
}

function Require-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal $id
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must be run as Administrator.'
  }
}

function Write-DattoUdf {
  param(
    [Parameter(Mandatory = $true)][int]$Id,
    [string]$Value,
    [switch]$EmitOutput
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    $Value = 'N/A'
  }

  $sanitized = ($Value -replace '[\r\n|]', ' ').Trim()
  $propName = 'CustomField{0}' -f $Id

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
      throw 'Unable to open or create HKLM\SOFTWARE\CentraStage'
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
      Write-Host 'Reboot requested.'
    }

    try {
      Restart-Computer -Force -ErrorAction Stop
    }
    catch {
      Write-Warning "Failed to trigger reboot: $($_.Exception.Message)"
    }
  }
}

function Get-EsuPlatform {
  $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
  $currentVersion = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
  $version = [version]$os.Version
  $versionKey = '{0}.{1}' -f $version.Major, $version.Minor
  $buildNumber = [int]$os.BuildNumber
  $ubr = [int]$currentVersion.UBR
  $fullBuild = '{0}.{1}' -f $buildNumber, $ubr
  $fullVersion = [version]('{0}.{1}.{2}.{3}' -f $version.Major, $version.Minor, $buildNumber, $ubr)
  $displayVersion = if ($currentVersion.DisplayVersion) { [string]$currentVersion.DisplayVersion } elseif ($currentVersion.ReleaseId) { [string]$currentVersion.ReleaseId } else { $null }
  $productName = [string]$currentVersion.ProductName
  $editionId = [string]$currentVersion.EditionID
  $architectureTag = Get-ProcessorArchitectureTag

  if ($os.ProductType -eq 1 -and $version.Major -eq 10 -and $productName -match '^Windows 10') {
    $isLtsRelease = $productName -match 'LTSC|LTSB' -or $editionId -match 'LTSC|LTSB'
    $prepPackage = if ($architectureTag) { $windows10PrepPackageCatalog[$architectureTag] } else { $null }
    $supported = ($displayVersion -eq '22H2' -and -not $isLtsRelease)
    $supportReason = if ($supported) {
      $null
    } elseif ($isLtsRelease) {
      'Windows 10 LTSC/LTSB releases are not covered by the Windows 10 ESU commercial MAK flow.'
    } else {
      "Windows 10 ESU requires version 22H2. Detected display version: $displayVersion."
    }

    return [pscustomobject]@{
      Family            = 'Windows10'
      VersionKey        = $versionKey
      Caption           = $os.Caption
      Version           = $os.Version
      BuildNumber       = $os.BuildNumber
      BuildRevision     = $ubr
      FullBuild         = $fullBuild
      Architecture      = $os.OSArchitecture
      ArchitectureTag   = $architectureTag
      ProductType       = $os.ProductType
      ProductName       = $productName
      EditionId         = $editionId
      DisplayVersion    = $displayVersion
      Supported         = $supported
      SupportReason     = $supportReason
      DisplayName       = 'Windows 10, version 22H2'
      PrepKb            = 'KB5072653'
      PrepTitle         = 'Extended Security Updates (ESU) Licensing Preparation Package'
      PrepUrl           = if ($prepPackage) { $prepPackage.PrepUrl } else { $null }
      PrepFileName      = if ($prepPackage) { $prepPackage.PrepFileName } else { $null }
      BaselineKb        = 'KB5066791'
      BaselineTitle     = 'Windows 10, version 22H2 with KB5066791 or later installed'
      BaselineUrl       = $null
      BaselineFileName  = $null
      BaselineMinVersion = $windows10BaselineMinVersion
      BaselineSatisfied = ($fullVersion -ge $windows10BaselineMinVersion)
      ActivationIds     = $windows10ActivationIds
    }
  }

  $mapping = if ($os.ProductType -eq 3) { $serverPlatformCatalog[$versionKey] } else { $null }

  [pscustomobject]@{
    Family            = 'Server2012'
    VersionKey        = $versionKey
    Caption           = $os.Caption
    Version           = $os.Version
    BuildNumber       = $os.BuildNumber
    BuildRevision     = $ubr
    FullBuild         = $fullBuild
    Architecture      = $os.OSArchitecture
    ArchitectureTag   = $architectureTag
    ProductType       = $os.ProductType
    ProductName       = $productName
    EditionId         = $editionId
    DisplayVersion    = $displayVersion
    Supported         = ($null -ne $mapping -and $os.ProductType -eq 3)
    SupportReason     = if ($mapping) { $null } else { "This script only supports Windows 10 22H2 and Windows Server 2012 / 2012 R2. Detected: $($os.Caption) ($($os.Version))." }
    DisplayName       = if ($mapping) { $mapping.DisplayName } else { $os.Caption }
    PrepKb            = if ($mapping) { $mapping.PrepKb } else { $null }
    PrepTitle         = if ($mapping) { $mapping.PrepTitle } else { $null }
    PrepUrl           = if ($mapping) { $mapping.PrepUrl } else { $null }
    PrepFileName      = if ($mapping) { $mapping.PrepFileName } else { $null }
    BaselineKb        = if ($mapping) { $mapping.BaselineKb } else { $null }
    BaselineTitle     = if ($mapping) { $mapping.BaselineTitle } else { $null }
    BaselineUrl       = if ($mapping) { $mapping.BaselineUrl } else { $null }
    BaselineFileName  = if ($mapping) { $mapping.BaselineFileName } else { $null }
    BaselineMinVersion = $null
    BaselineSatisfied = $false
    ActivationIds     = if ($mapping) { $mapping.ActivationIds } else { @{} }
  }
}

function Get-CbsPackageIndex {
  if ($null -ne $script:CbsPackageIndex) {
    return $script:CbsPackageIndex
  }

  $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'
  $script:CbsPackageIndex = Get-ChildItem -Path $root -ErrorAction Stop | Select-Object PSChildName, PSPath
  return $script:CbsPackageIndex
}

function Get-CbsPackageProperties {
  param([Parameter(Mandatory = $true)][string]$PackagePath)

  if (-not $script:CbsPackagePropertyCache.ContainsKey($PackagePath)) {
    $script:CbsPackagePropertyCache[$PackagePath] = Get-ItemProperty -Path $PackagePath -ErrorAction SilentlyContinue
  }

  return $script:CbsPackagePropertyCache[$PackagePath]
}

function Get-KbState {
  param([Parameter(Mandatory = $true)][string]$KbId)

  $normalizedKb = Normalize-KbId -KbId $KbId
  $kbDigits = $normalizedKb.Substring(2)
  $evidence = @()
  $installedDates = @()

  try {
    $qfe = Get-CimInstance -ClassName Win32_QuickFixEngineering -Filter "HotFixID='$normalizedKb'" -ErrorAction SilentlyContinue
    foreach ($item in @($qfe)) {
      if ($item) {
        $evidence += 'Win32_QuickFixEngineering'
        $date = Convert-ToDateTime -Value $item.InstalledOn
        if ($date) { $installedDates += $date }
      }
    }
  }
  catch {
  }

  foreach ($entry in Get-CbsPackageIndex | Where-Object { $_.PSChildName -match "(?i)KB$kbDigits\b" }) {
    $props = Get-CbsPackageProperties -PackagePath $entry.PSPath
    if ($null -ne $props -and $props.CurrentState -eq 112) {
      $evidence += "CBS:$($entry.PSChildName)"
      $date = Convert-CbsFileTime -High $props.InstallTimeHigh -Low $props.InstallTimeLow
      if ($date) { $installedDates += $date }
    }
  }

  [pscustomobject]@{
    KbId        = $normalizedKb
    Installed   = ($evidence.Count -gt 0)
    InstalledOn = if ($installedDates.Count -gt 0) { $installedDates | Sort-Object -Descending | Select-Object -First 1 } else { $null }
    Evidence    = @($evidence | Sort-Object -Unique)
  }
}

function Test-PendingReboot {
  $paths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
  )

  foreach ($path in $paths) {
    if (Test-Path $path) {
      return $true
    }
  }

  try {
    $sessionManager = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($null -ne $sessionManager.PendingFileRenameOperations) {
      return $true
    }
  }
  catch {
  }

  return $false
}

function Get-ActivationTarget {
  param(
    [Parameter(Mandatory = $true)]$Platform,
    [Parameter(Mandatory = $true)][int]$Year,
    [string]$ActivationIdOverride
  )

  if ($ActivationIdOverride) {
    return [pscustomobject]@{
      ActivationId = ([guid]$ActivationIdOverride).Guid
      Label        = 'Custom activation target'
      Source       = 'Parameter override'
    }
  }

  if ($Platform.ActivationIds -and $Platform.ActivationIds.ContainsKey($Year)) {
    $labelPrefix = if ($Platform.Family -eq 'Windows10') { 'Windows 10 ESU' } else { 'Windows Server 2012 / 2012 R2 ESU' }
    return [pscustomobject]@{
      ActivationId = $Platform.ActivationIds[$Year]
      Label        = "$labelPrefix Year $Year"
      Source       = 'Platform default'
    }
  }

  return [pscustomobject]@{
    ActivationId = $null
    Label        = "ESU Year $Year"
    Source       = 'Unavailable'
  }
}

function Enable-Tls12IfSupported {
  try {
    if ([enum]::IsDefined([Net.SecurityProtocolType], 'Tls12')) {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
  }
  catch {
  }
}

function Get-DownloadCacheRoot {
  $candidate = Join-Path $env:ProgramData 'ESUPrereqs'
  if (-not (Test-Path $candidate)) {
    New-Item -Path $candidate -ItemType Directory -Force | Out-Null
  }

  return $candidate
}

function Download-File {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$FileName
  )

  Enable-Tls12IfSupported

  $downloadRoot = Get-DownloadCacheRoot
  $destination = Join-Path $downloadRoot $FileName

  if (-not (Test-Path $destination) -or (Get-Item $destination).Length -lt 1024) {
    Invoke-WebRequest -Uri $Url -OutFile $destination -UseBasicParsing -ErrorAction Stop
  }

  return $destination
}

function Invoke-WusaInstall {
  param([Parameter(Mandatory = $true)][string]$PackagePath)

  $wusa = Resolve-SysnativePath 'wusa.exe'
  $process = Start-Process -FilePath $wusa -ArgumentList "`"$PackagePath`" /quiet /norestart" -Wait -PassThru -WindowStyle Hidden

  [pscustomobject]@{
    ExitCode    = $process.ExitCode
    ExitCodeHex = Convert-ExitCodeToHex -ExitCode $process.ExitCode
  }
}

function Ensure-PlatformBaseline {
  param(
    [Parameter(Mandatory = $true)]$Platform,
    [Parameter(Mandatory = $true)][bool]$AllowRemediation
  )

  if ($Platform.Family -eq 'Windows10') {
    $evidence = @("Build:$($Platform.FullBuild)")
    if ($Platform.BaselineSatisfied) {
      return [pscustomobject]@{
        KbId                 = $Platform.BaselineKb
        Title                = $Platform.BaselineTitle
        InstalledBefore      = $true
        InstalledAfter       = $true
        RemediationAttempted = $false
        RebootRequired       = $false
        Evidence             = $evidence
        InstalledOn          = $null
        Actions              = @()
      }
    }

    $actions = @()
    if ($AllowRemediation) {
      $actions += "Automatic remediation for $($Platform.BaselineKb) or later is not implemented. Install the latest Windows 10 22H2 cumulative update so the build is at least $($Platform.BaselineMinVersion)."
    }

    return [pscustomobject]@{
      KbId                 = $Platform.BaselineKb
      Title                = $Platform.BaselineTitle
      InstalledBefore      = $false
      InstalledAfter       = $false
      RemediationAttempted = $false
      RebootRequired       = $false
      Evidence             = $evidence
      InstalledOn          = $null
      Actions              = $actions
    }
  }

  return Ensure-UpdateInstalled -KbId $Platform.BaselineKb -Title $Platform.BaselineTitle -Url $Platform.BaselineUrl -FileName $Platform.BaselineFileName -AllowRemediation:$AllowRemediation
}

function Ensure-UpdateInstalled {
  param(
    [Parameter(Mandatory = $true)][string]$KbId,
    [Parameter(Mandatory = $true)][string]$Title,
    [string]$Url,
    [string]$FileName,
    [Parameter(Mandatory = $true)][bool]$AllowRemediation
  )

  $stateBefore = Get-KbState -KbId $KbId
  $actions = @()
  $rebootRequired = $false
  $remediationAttempted = $false

  if ($stateBefore.Installed) {
    return [pscustomobject]@{
      KbId                 = $stateBefore.KbId
      Title                = $Title
      InstalledBefore      = $true
      InstalledAfter       = $true
      RemediationAttempted = $false
      RebootRequired       = $false
      Evidence             = $stateBefore.Evidence
      InstalledOn          = $stateBefore.InstalledOn
      Actions              = @()
    }
  }

  if (-not $AllowRemediation -or [string]::IsNullOrWhiteSpace($Url) -or [string]::IsNullOrWhiteSpace($FileName)) {
    $actionsIfUnavailable = @()
    if ($AllowRemediation -and ([string]::IsNullOrWhiteSpace($Url) -or [string]::IsNullOrWhiteSpace($FileName))) {
      $actionsIfUnavailable += "Automatic remediation for $($stateBefore.KbId) is not configured on this platform."
    }

    return [pscustomobject]@{
      KbId                 = $stateBefore.KbId
      Title                = $Title
      InstalledBefore      = $false
      InstalledAfter       = $false
      RemediationAttempted = $false
      RebootRequired       = $false
      Evidence             = $stateBefore.Evidence
      InstalledOn          = $stateBefore.InstalledOn
      Actions              = $actionsIfUnavailable
    }
  }

  $remediationAttempted = $true
  $packagePath = Download-File -Url $Url -FileName $FileName
  $actions += "Downloaded $($stateBefore.KbId) to $packagePath"

  $install = Invoke-WusaInstall -PackagePath $packagePath
  $actions += "Installed $($stateBefore.KbId) via wusa (exit $($install.ExitCode) / $($install.ExitCodeHex))"

  switch ($install.ExitCodeHex) {
    '0x00000000' {
    }
    '0x00000BC2' {
      $rebootRequired = $true
    }
    '0x00240006' {
    }
    default {
      throw "$($stateBefore.KbId) installation failed with exit code $($install.ExitCode) ($($install.ExitCodeHex))."
    }
  }

  $stateAfter = Get-KbState -KbId $KbId
  $installedAfter = $stateAfter.Installed
  $evidenceAfter = @($stateAfter.Evidence)

  if ($install.ExitCodeHex -eq '0x00240006' -and -not $installedAfter) {
    $installedAfter = $true
    $evidenceAfter += 'WUSA:AlreadyInstalled'
  }

  if (-not $installedAfter -and $install.ExitCodeHex -ne '0x00240006') {
    throw "$($stateBefore.KbId) still does not appear to be installed after remediation."
  }

  return [pscustomobject]@{
    KbId                 = $stateAfter.KbId
    Title                = $Title
    InstalledBefore      = $false
    InstalledAfter       = $installedAfter
    RemediationAttempted = $true
    RebootRequired       = $rebootRequired
    Evidence             = @($evidenceAfter | Sort-Object -Unique)
    InstalledOn          = $stateAfter.InstalledOn
    Actions              = $actions
  }
}

function Get-ExecutionOutcome {
  param(
    [Parameter(Mandatory = $true)]$Platform,
    [Parameter(Mandatory = $true)]$WindowsActivation,
    [Parameter(Mandatory = $true)]$BaselineState,
    [Parameter(Mandatory = $true)]$PrepState,
    [Parameter(Mandatory = $true)][bool]$PendingReboot,
    [Parameter(Mandatory = $true)]$EsuSummary,
    [Parameter(Mandatory = $true)][bool]$ProductKeyProvided,
    [Parameter(Mandatory = $true)]$ActivationTarget
  )

  if (-not $Platform.Supported) {
    return [pscustomobject]@{
      Success = $false
      Reason  = $Platform.SupportReason
    }
  }

  if ($WindowsActivation.LicenseStatus -ne 1) {
    return [pscustomobject]@{
      Success = $false
      Reason  = 'Windows is not licensed.'
    }
  }

  if (-not $BaselineState.InstalledAfter) {
    return [pscustomobject]@{
      Success = $false
      Reason  = "$($BaselineState.Title) is missing."
    }
  }

  if (-not $PrepState.InstalledAfter) {
    return [pscustomobject]@{
      Success = $false
      Reason  = "$($PrepState.KbId) is missing."
    }
  }

  if ($PendingReboot) {
    return [pscustomobject]@{
      Success = $false
      Reason  = 'A reboot is required before the machine is ready for ESU activation.'
    }
  }

  if ($ProductKeyProvided) {
    if (-not $ActivationTarget.ActivationId) {
      return [pscustomobject]@{
        Success = $false
        Reason  = 'No activation ID is available for this platform/year. Supply -ActivationId explicitly.'
      }
    }

    if ($EsuSummary.StatusCode -ne 1) {
      return [pscustomobject]@{
        Success = $false
        Reason  = 'The ESU key is not licensed.'
      }
    }

    return [pscustomobject]@{
      Success = $true
      Reason  = 'Machine is ESU-ready and the ESU key is licensed.'
    }
  }

  if ($EsuSummary.StatusCode -eq 1) {
    return [pscustomobject]@{
      Success = $true
      Reason  = 'Machine is ESU-ready and an ESU key is already licensed.'
    }
  }

  return [pscustomobject]@{
    Success = $true
    Reason  = 'Machine is ESU-ready and can accept an ESU key.'
  }
}

function Get-KbSummaryText {
  param(
    [Parameter(Mandatory = $true)]$State
  )

  if ($State.InstalledAfter) {
    $suffix = if ($State.RemediationAttempted) { ' (remediated)' } else { '' }
    return "Installed$suffix"
  }

  return 'Missing'
}

# -- Main ----------------------------------------------------------

try {
  Require-Admin

  $platform = Get-EsuPlatform
  $activationTarget = Get-ActivationTarget -Platform $platform -Year $EsuYear -ActivationIdOverride $ActivationId

  $initialWindows = Get-WindowsActivation
  $initialEsu = if ($activationTarget.ActivationId) {
    Get-ActivationById -ActivationId $activationTarget.ActivationId
  } else {
    $null
  }
  $initialEsuSummary = New-ActivationSummary -Activation $initialEsu

  $actions = @()

  $baselineState = if ($platform.Supported) {
    Ensure-PlatformBaseline -Platform $platform -AllowRemediation:(-not $SkipPrereqRemediation)
  } else {
    [pscustomobject]@{
      KbId                 = 'N/A'
      Title                = 'N/A'
      InstalledBefore      = $false
      InstalledAfter       = $false
      RemediationAttempted = $false
      RebootRequired       = $false
      Evidence             = @()
      InstalledOn          = $null
      Actions              = @()
    }
  }
  $actions += $baselineState.Actions

  $prepState = if ($platform.Supported) {
    Ensure-UpdateInstalled -KbId $platform.PrepKb -Title $platform.PrepTitle -Url $platform.PrepUrl -FileName $platform.PrepFileName -AllowRemediation:(-not $SkipPrereqRemediation)
  } else {
    [pscustomobject]@{
      KbId                 = 'N/A'
      Title                = 'N/A'
      InstalledBefore      = $false
      InstalledAfter       = $false
      RemediationAttempted = $false
      RebootRequired       = $false
      Evidence             = @()
      InstalledOn          = $null
      Actions              = @()
    }
  }
  $actions += $prepState.Actions

  $pendingReboot = Test-PendingReboot
  $prereqChangesNeedReboot = $baselineState.RebootRequired -or $prepState.RebootRequired
  $canAttemptActivation = $PSBoundParameters.ContainsKey('ProductKey') -and $platform.Supported -and $initialWindows.LicenseStatus -eq 1 -and $baselineState.InstalledAfter -and $prepState.InstalledAfter -and -not $pendingReboot -and -not [string]::IsNullOrWhiteSpace($activationTarget.ActivationId)

  if ($PSBoundParameters.ContainsKey('ProductKey') -and -not $canAttemptActivation) {
    if ($pendingReboot) {
      $actions += 'Skipped ESU key installation because a reboot is pending.'
    } elseif (-not $platform.Supported) {
      $actions += "Skipped ESU key installation because this platform is not supported. $($platform.SupportReason)"
    } elseif ($initialWindows.LicenseStatus -ne 1) {
      $actions += 'Skipped ESU key installation because Windows is not licensed.'
    } elseif (-not $activationTarget.ActivationId) {
      $actions += 'Skipped ESU key installation because no activation ID is available for the selected platform/year.'
    } else {
      $actions += 'Skipped ESU key installation because prerequisite updates are still missing.'
    }
  }

  if ($canAttemptActivation) {
    $actions += 'Installing ESU product key (slmgr /ipk)'
    $ipk = Invoke-Slmgr "/ipk $ProductKey"
    $actions += "  /ipk exit=$($ipk.ExitCode)"
    if ($ipk.StdOut) { $actions += "  /ipk: $($ipk.StdOut)" }
    if ($ipk.StdErr) { $actions += "  /ipk err: $($ipk.StdErr)" }
    Assert-SlmgrResult -Result $ipk -Operation '/ipk'

    $actions += "Activating ESU online (slmgr /ato $($activationTarget.ActivationId))"
    $ato = Invoke-Slmgr "/ato $($activationTarget.ActivationId)"
    $actions += "  /ato exit=$($ato.ExitCode)"
    if ($ato.StdOut) { $actions += "  /ato: $($ato.StdOut)" }
    if ($ato.StdErr) { $actions += "  /ato err: $($ato.StdErr)" }
    Assert-SlmgrResult -Result $ato -Operation '/ato'
  }

  $finalWindows = Get-WindowsActivation
  $finalEsu = if ($activationTarget.ActivationId) {
    Get-ActivationById -ActivationId $activationTarget.ActivationId
  } else {
    $null
  }
  $finalEsuSummary = New-ActivationSummary -Activation $finalEsu
  $outcome = Get-ExecutionOutcome -Platform $platform -WindowsActivation $finalWindows -BaselineState $baselineState -PrepState $prepState -PendingReboot $pendingReboot -EsuSummary $finalEsuSummary -ProductKeyProvided:$PSBoundParameters.ContainsKey('ProductKey') -ActivationTarget $activationTarget

  $result = [pscustomobject]@{
    ComputerName         = $env:COMPUTERNAME
    PlatformSupported    = $platform.Supported
    Platform             = $platform.DisplayName
    PlatformSupportReason = $platform.SupportReason
    PlatformCaption      = $platform.Caption
    PlatformVersion      = $platform.Version
    PlatformBuild        = $platform.BuildNumber
    PlatformBuildRevision = $platform.BuildRevision
    PlatformFullBuild    = $platform.FullBuild
    PlatformArchitecture = $platform.Architecture
    EsuYear              = $EsuYear
    ActivationTarget     = $activationTarget.Label
    ActivationIdUsed     = if ($activationTarget.ActivationId) { $activationTarget.ActivationId } else { 'N/A' }
    ActivationIdSource   = $activationTarget.Source
    InitialStatus        = $initialWindows.LicenseStatusText
    InitialCode          = $initialWindows.LicenseStatus
    InitialKeyTail       = $initialWindows.PartialProductKey
    EsuInitialStatus     = $initialEsuSummary.StatusText
    EsuInitialCode       = $initialEsuSummary.StatusCode
    EsuInitialKeyTail    = $initialEsuSummary.KeyTail
    RequiredBaselineKb   = $baselineState.KbId
    BaselineTitle        = $baselineState.Title
    BaselineInstalled    = $baselineState.InstalledAfter
    BaselineInstalledOn  = $baselineState.InstalledOn
    BaselineEvidence     = $baselineState.Evidence
    RequiredPrepKb       = $prepState.KbId
    PrepKbInstalled      = $prepState.InstalledAfter
    PrepKbInstalledOn    = $prepState.InstalledOn
    PrepKbEvidence       = $prepState.Evidence
    PendingReboot        = $pendingReboot
    RebootRequired       = $prereqChangesNeedReboot
    PrerequisitesMet     = ($platform.Supported -and $baselineState.InstalledAfter -and $prepState.InstalledAfter)
    Actions              = $actions
    FinalStatus          = $finalWindows.LicenseStatusText
    FinalCode            = $finalWindows.LicenseStatus
    FinalKeyTail         = $finalWindows.PartialProductKey
    WindowsProductName   = $finalWindows.Name
    WindowsDescription   = $finalWindows.Description
    WindowsStatus        = $finalWindows.LicenseStatusText
    WindowsCode          = $finalWindows.LicenseStatus
    WindowsKeyTail       = $finalWindows.PartialProductKey
    EsuStatus            = $finalEsuSummary.StatusText
    EsuCode              = $finalEsuSummary.StatusCode
    EsuKeyTail           = $finalEsuSummary.KeyTail
    Success              = $outcome.Success
    ExitReason           = $outcome.Reason
  }

  if ($Json) {
    $result | ConvertTo-Json -Depth 6
  } else {
    Write-Host '=== Windows ESU Readiness Check ==='
    Write-Host " Computer       : $($result.ComputerName)"
    Write-Host " Platform       : $($result.PlatformCaption) ($($result.PlatformVersion), build $($result.PlatformBuild), $($result.PlatformArchitecture))"
    Write-Host " Full build     : $($result.PlatformFullBuild)"
    Write-Host " Product        : $($result.WindowsProductName)"
    Write-Host " Description    : $($result.WindowsDescription)"
    Write-Host " Windows        : $($result.WindowsStatus) (code $($result.WindowsCode)), key tail: $($result.WindowsKeyTail)"
    Write-Host " ESU target     : $($result.ActivationTarget) [$($result.ActivationIdUsed)]"
    if ($platform.Supported) {
      Write-Host " Baseline       : $($result.RequiredBaselineKb) - $($result.BaselineTitle) - $(Get-KbSummaryText -State $baselineState)"
      Write-Host " Prep package   : $($result.RequiredPrepKb) - $(Get-KbSummaryText -State $prepState)"
      Write-Host " Pending reboot : $(if ($result.PendingReboot) { 'Yes' } else { 'No' })"
    } else {
      Write-Host ' Baseline       : N/A'
      Write-Host ' Prep package   : N/A'
      Write-Host ' Pending reboot : N/A'
    }
    Write-Host " ESU initial    : $($result.EsuInitialStatus) (code $($result.EsuInitialCode)), key tail: $($result.EsuInitialKeyTail)"
    if ($actions.Count) {
      Write-Host ' Actions:'
      $actions | ForEach-Object { Write-Host "  - $_" }
    } else {
      Write-Host ' Actions        : (none required)'
    }
    Write-Host " ESU final      : $($result.EsuStatus) (code $($result.EsuCode)), key tail: $($result.EsuKeyTail)"
    Write-Host " Result         : $(if ($result.Success) { 'Success' } else { 'Failure' }) - $($result.ExitReason)"
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
