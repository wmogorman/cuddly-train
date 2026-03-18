[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$blocker = Join-Path -Path $PSScriptRoot -ChildPath 'pti-blocked-package.ps1'
& $blocker -PackageName 'PTI GoldMine 9.2' -MissingInputs @(
    "William's GoldMine install notes",
    'validated UNC source path',
    'silent install arguments',
    'post-install verification steps'
)
