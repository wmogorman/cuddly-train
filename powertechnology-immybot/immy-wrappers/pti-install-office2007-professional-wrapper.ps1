[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PTIPayloadZipFolder,

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

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-office2007-professional.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$entrypoint = Get-PTIPayloadEntrypoint -PayloadFolder $PTIPayloadZipFolder -ScriptName 'pti-install-office2007-professional.ps1'

& $entrypoint `
    -SourcePath $SourcePath `
    -InstallerRelativePath $InstallerRelativePath `
    -InstallArguments $InstallArguments `
    -InstallerType $InstallerType `
    -ShareUserName $ShareUserName `
    -SharePassword $SharePassword `
    -StageRoot $StageRoot `
    -LogPath $LogPath
