#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true)]
param(
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

if ([string]::IsNullOrWhiteSpace($InstallArguments)) {
    throw 'Office 2007 Standard requires validated silent install arguments before deployment.'
}

$wrapper = Join-Path -Path $PSScriptRoot -ChildPath 'pti-stage-and-install-package.ps1'
& $wrapper -PackageName 'PTI Office 2007 Standard' -SourcePath $SourcePath -InstallerRelativePath $InstallerRelativePath -InstallArguments $InstallArguments -InstallerType $InstallerType -ShareUserName $ShareUserName -SharePassword $SharePassword -StageRoot $StageRoot -LogPath $LogPath -WhatIf:$WhatIfPreference
