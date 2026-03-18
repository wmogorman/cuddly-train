[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$blocker = Join-Path -Path $PSScriptRoot -ChildPath 'pti-blocked-package.ps1'
& $blocker -PackageName 'PTI Crystal Runtime or Editor' -MissingInputs @(
    "William's Crystal notes",
    'validated UNC source path',
    'silent install arguments',
    'post-install verification steps'
)
