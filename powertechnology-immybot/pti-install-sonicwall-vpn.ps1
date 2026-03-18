#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$InstallerRelativePath,

    [Parameter(Mandatory = $true)]
    [string]$InstallArguments,

    [ValidateSet('Executable', 'Msi')]
    [string]$InstallerType = 'Executable',

    [string]$ShareUserName,

    [string]$SharePassword,

    [string]$StageRoot = 'C:\ProgramData\PTI\StagedInstallers',

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-sonicwall-vpn.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InstallArguments)) {
    throw 'SonicWall VPN requires validated silent install arguments before deployment.'
}

$wrapper = Join-Path -Path $PSScriptRoot -ChildPath 'pti-stage-and-install-package.ps1'
& $wrapper -PackageName 'PTI SonicWall VPN' -SourcePath $SourcePath -InstallerRelativePath $InstallerRelativePath -InstallArguments $InstallArguments -InstallerType $InstallerType -ShareUserName $ShareUserName -SharePassword $SharePassword -StageRoot $StageRoot -LogPath $LogPath -WhatIf:$WhatIfPreference
