[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PTIPayloadZipFolder,

    [ValidateSet('DriverStage', 'SharedCopiers', 'Scheduling', 'Sales', 'Accounting', 'Hp5000', 'DepartmentBundle')]
    [string[]]$InstallSet = @('DepartmentBundle'),

    [ValidateSet('Sales', 'Marketing', 'Scheduling', 'Production', 'Procurement', 'Quality', 'Engineering', 'Accounting', 'Management')]
    [string]$PrimaryDepartment,

    [switch]$NeedsAccountingPrinter,

    [switch]$NeedsHp5000,

    [string]$LexmarkDriverSourcePath,

    [string]$LexmarkInfRelativePath,

    [string]$LexmarkDriverName,

    [string]$HpDriverSourcePath,

    [string]$HpInfRelativePath,

    [string]$HpDriverName,

    [string]$ShareUserName,

    [string]$SharePassword,

    [string]$StageRoot = 'C:\ProgramData\PTI\PrinterDrivers',

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-printers.log'
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

$entrypoint = Get-PTIPayloadEntrypoint -PayloadFolder $PTIPayloadZipFolder -ScriptName 'pti-install-printers.ps1'

& $entrypoint `
    -InstallSet $InstallSet `
    -PrimaryDepartment $PrimaryDepartment `
    -NeedsAccountingPrinter:$NeedsAccountingPrinter.IsPresent `
    -NeedsHp5000:$NeedsHp5000.IsPresent `
    -LexmarkDriverSourcePath $LexmarkDriverSourcePath `
    -LexmarkInfRelativePath $LexmarkInfRelativePath `
    -LexmarkDriverName $LexmarkDriverName `
    -HpDriverSourcePath $HpDriverSourcePath `
    -HpInfRelativePath $HpInfRelativePath `
    -HpDriverName $HpDriverName `
    -ShareUserName $ShareUserName `
    -SharePassword $SharePassword `
    -StageRoot $StageRoot `
    -LogPath $LogPath
