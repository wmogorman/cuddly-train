[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PTIPayloadZip,

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

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-office2007-standard.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$payloadFolder = Resolve-PTIPayloadFolder -ZipPath $PTIPayloadZip
$entrypoint = Get-PTIPayloadEntrypoint -PayloadFolder $payloadFolder -ScriptName 'pti-install-office2007-standard.ps1'

& $entrypoint `
    -SourcePath $SourcePath `
    -InstallerRelativePath $InstallerRelativePath `
    -InstallArguments $InstallArguments `
    -InstallerType $InstallerType `
    -ShareUserName $ShareUserName `
    -SharePassword $SharePassword `
    -StageRoot $StageRoot `
    -LogPath $LogPath
