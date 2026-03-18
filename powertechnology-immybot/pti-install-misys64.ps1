[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$blocker = Join-Path -Path $PSScriptRoot -ChildPath 'pti-blocked-package.ps1'
& $blocker -PackageName 'PTI MISys 6.4' -MissingInputs @(
    "William's MISys install notes",
    'validated UNC source path',
    'silent install arguments',
    'post-install verification steps'
)
