[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PTIPayloadZip,

    [Parameter(DontShow = $true)]
    [string]$TenantName,

    [Parameter(DontShow = $true)]
    [string]$TenantSlug,

    [Parameter(DontShow = $true)]
    [string]$ComputerName,

    [Parameter(DontShow = $true)]
    [string]$ComputerSlug,

    [Parameter(DontShow = $true)]
    [string]$AzureTenantId,

    [Parameter(DontShow = $true)]
    [Guid]$PrimaryPersonAzurePrincipalId,

    [Parameter(DontShow = $true)]
    [string]$PrimaryPersonEmail,

    [Parameter(DontShow = $true)]
    [bool]$IsPortable,

    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [string]$InstallerRelativePath = 'setup.exe',

    [Parameter(Mandatory = $true)]
    [string]$InstallArguments,

    [ValidateSet('Executable', 'Msi')]
    [string]$InstallerType = 'Executable',

    [string]$ShareUserName,

    [string]$SharePassword,

    [string]$StageRoot = 'C:\ProgramData\PTI\StagedInstallers',

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-office2007-standard.log',

    [Parameter(DontShow = $true, ValueFromRemainingArguments = $true)]
    [object[]]$ImmyRuntimeArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace([string](Get-Variable -Name 'Method' -ValueOnly -ErrorAction SilentlyContinue))) {
    $Method = 'Set'
}

function Resolve-PTIPayloadFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath
    )

    $folderVariable = Get-Variable -Name 'PTIPayloadZipFolder' -ValueOnly -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($folderVariable)) {
        return $folderVariable
    }

    if (Test-Path -LiteralPath $ZipPath -PathType Container) {
        return $ZipPath
    }

    if (Test-Path -LiteralPath $ZipPath -PathType Leaf) {
        $zipItem = Get-Item -LiteralPath $ZipPath -ErrorAction Stop
        $extractRoot = Join-Path -Path $env:TEMP -ChildPath ('pti-immy-payload-' + $zipItem.BaseName + '-' + $zipItem.LastWriteTimeUtc.Ticks)
        if (-not (Test-Path -LiteralPath $extractRoot)) {
            Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractRoot -Force
        }

        return $extractRoot
    }

    throw 'PTIPayloadZipFolder was not available at runtime. Ensure PTIPayloadZip is a File parameter that points to the PTI payload zip.'
}

function Get-PTIPayloadEntrypoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PayloadFolder,

        [Parameter(Mandatory = $true)]
        [string]$ScriptName
    )

    $payloadRoot = Join-Path -Path $PayloadFolder -ChildPath 'payload'
    $scriptPath = Join-Path -Path $payloadRoot -ChildPath $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "PTI payload entrypoint not found: $scriptPath. Rebuild and re-upload the PTI payload zip."
    }

    return $scriptPath
}

function Get-Office12InstallRoot {
    $candidates = @(
        (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'Microsoft Office\Office12'),
        (Join-Path -Path $env:ProgramFiles -ChildPath 'Microsoft Office\Office12')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return $candidate
        }
    }

    return $null
}

function Test-OfficeExecutablePresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutableName
    )

    $installRoot = Get-Office12InstallRoot
    if ([string]::IsNullOrWhiteSpace($installRoot)) {
        return $false
    }

    return (Test-Path -LiteralPath (Join-Path -Path $installRoot -ChildPath $ExecutableName) -PathType Leaf)
}

function Get-OfficeStandardState {
    $installRoot = Get-Office12InstallRoot
    $word = Test-OfficeExecutablePresent -ExecutableName 'WINWORD.EXE'
    $excel = Test-OfficeExecutablePresent -ExecutableName 'EXCEL.EXE'
    $powerPoint = Test-OfficeExecutablePresent -ExecutableName 'POWERPNT.EXE'
    $outlook = Test-OfficeExecutablePresent -ExecutableName 'OUTLOOK.EXE'
    $access = Test-OfficeExecutablePresent -ExecutableName 'MSACCESS.EXE'

    return [pscustomobject]@{
        Compliant   = ($word -and $excel -and $powerPoint -and $outlook -and -not $access)
        InstallRoot = $installRoot
        Word        = $word
        Excel       = $excel
        PowerPoint  = $powerPoint
        Outlook     = $outlook
        Access      = $access
        LogPath     = $LogPath
    }
}

function Test-OfficeStandardInstalled {
    $state = Get-OfficeStandardState
    if (-not $state.Compliant) {
        $issues = [System.Collections.Generic.List[string]]::new()
        if (-not $state.Word) { $issues.Add('WINWORD.EXE missing') | Out-Null }
        if (-not $state.Excel) { $issues.Add('EXCEL.EXE missing') | Out-Null }
        if (-not $state.PowerPoint) { $issues.Add('POWERPNT.EXE missing') | Out-Null }
        if (-not $state.Outlook) { $issues.Add('OUTLOOK.EXE missing') | Out-Null }
        if ($state.Access) { $issues.Add('MSACCESS.EXE present') | Out-Null }
        Write-Warning ('Office 2007 Standard is not compliant: ' + ($issues -join ' | '))
        return $false
    }

    Write-Host 'Office 2007 Standard is compliant.'
    return $true
}

$payloadFolder = Resolve-PTIPayloadFolder -ZipPath $PTIPayloadZip
$entrypoint = Get-PTIPayloadEntrypoint -PayloadFolder $payloadFolder -ScriptName 'pti-install-office2007-standard.ps1'

switch -Regex ($Method) {
    '^(?i)Get$' {
        Get-OfficeStandardState
    }
    '^(?i)Test$' {
        Test-OfficeStandardInstalled
    }
    '^(?i)Set$' {
        & $entrypoint `
            -SourcePath $SourcePath `
            -InstallerRelativePath $InstallerRelativePath `
            -InstallArguments $InstallArguments `
            -InstallerType $InstallerType `
            -ShareUserName $ShareUserName `
            -SharePassword $SharePassword `
            -StageRoot $StageRoot `
            -LogPath $LogPath
        return $true
    }
    default {
        throw "Unsupported Immy combined-script method: $Method"
    }
}
