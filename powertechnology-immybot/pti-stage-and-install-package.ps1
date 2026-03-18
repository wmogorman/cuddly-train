#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageName,

    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [string]$InstallerRelativePath,

    [string]$InstallArguments,

    [ValidateSet('Executable', 'Msi')]
    [string]$InstallerType = 'Executable',

    [string]$ShareUserName,

    [string]$SharePassword,

    [string]$StageRoot = 'C:\ProgramData\PTI\StagedInstallers',

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-package-install.log',

    [int[]]$SuccessExitCodes = @(0, 1641, 3010)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'pti-common.ps1')

$credential = New-PTICredential -UserName $ShareUserName -Password $SharePassword
$safePackageName = ($PackageName -replace '[^A-Za-z0-9\-_]', '_')
$packageStageRoot = Join-Path -Path $StageRoot -ChildPath $safePackageName
$stagedSource = $null
$installerPath = $null

if ($PSCmdlet.ShouldProcess($PackageName, "Stage and install from [$SourcePath]")) {
    Ensure-PTIDirectory -Path $packageStageRoot
    $stagedSource = Copy-PTISourceToCache -SourcePath $SourcePath -DestinationRoot $packageStageRoot -Credential $credential -LogPath $LogPath
    $installerPath = Resolve-PTIRelativePath -BasePath $stagedSource -RelativePath $InstallerRelativePath

    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "Installer not found after staging: $installerPath"
    }

    $workingDirectory = Split-Path -Path $installerPath -Parent

    switch ($InstallerType) {
        'Msi' {
            $msiArguments = '/i "{0}" {1}' -f $installerPath, $InstallArguments
            Invoke-PTIProcess -FilePath 'msiexec.exe' -ArgumentList $msiArguments.Trim() -WorkingDirectory $workingDirectory -SuccessExitCodes $SuccessExitCodes -LogPath $LogPath | Out-Null
        }
        'Executable' {
            Invoke-PTIProcess -FilePath $installerPath -ArgumentList $InstallArguments -WorkingDirectory $workingDirectory -SuccessExitCodes $SuccessExitCodes -LogPath $LogPath | Out-Null
        }
    }
}

[pscustomobject]@{
    PackageName   = $PackageName
    SourcePath    = $SourcePath
    StagedSource  = $stagedSource
    InstallerPath = $installerPath
    InstallerType = $InstallerType
    LogPath       = $LogPath
}
