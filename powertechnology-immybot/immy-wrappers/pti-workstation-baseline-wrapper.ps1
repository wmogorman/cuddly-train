[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PTIPayloadZipFolder,

    [string]$ApprovedSecurityProducts = '',

    [switch]$EnableUnauthorizedSecurityRemoval,

    [switch]$SkipUnauthorizedSecurityRemoval,

    [switch]$SkipDellCleanup,

    [switch]$SkipConsumerBloatwareRemoval,

    [switch]$SkipOneDriveRemoval,

    [switch]$SkipCortanaDisable,

    [switch]$SkipRemoteAssistance,

    [string]$LogPath = 'C:\ProgramData\PTI\Logs\pti-workstation-baseline.log'
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

$approvedProductList = @(
    $ApprovedSecurityProducts -split ';' |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

$entrypoint = Get-PTIPayloadEntrypoint -PayloadFolder $PTIPayloadZipFolder -ScriptName 'pti-workstation-baseline.ps1'

& $entrypoint `
    -ApprovedSecurityProducts $approvedProductList `
    -EnableUnauthorizedSecurityRemoval:$EnableUnauthorizedSecurityRemoval.IsPresent `
    -SkipUnauthorizedSecurityRemoval:$SkipUnauthorizedSecurityRemoval.IsPresent `
    -SkipDellCleanup:$SkipDellCleanup.IsPresent `
    -SkipConsumerBloatwareRemoval:$SkipConsumerBloatwareRemoval.IsPresent `
    -SkipOneDriveRemoval:$SkipOneDriveRemoval.IsPresent `
    -SkipCortanaDisable:$SkipCortanaDisable.IsPresent `
    -SkipRemoteAssistance:$SkipRemoteAssistance.IsPresent `
    -LogPath $LogPath
