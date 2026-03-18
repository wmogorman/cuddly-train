[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$blocker = Join-Path -Path $PSScriptRoot -ChildPath 'pti-blocked-package.ps1'
& $blocker -PackageName 'PTI ACCPAC 6.1A' -MissingInputs @(
    "William's ACCPAC install notes",
    'validated UNC source path',
    'silent install arguments',
    'post-install verification steps'
)
