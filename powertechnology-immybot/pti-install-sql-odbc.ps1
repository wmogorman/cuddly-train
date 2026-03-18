[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$blocker = Join-Path -Path $PSScriptRoot -ChildPath 'pti-blocked-package.ps1'
& $blocker -PackageName 'PTI SQL ODBC' -MissingInputs @(
    "William's ODBC notes",
    'validated driver version list',
    'DSN names and connection settings',
    'silent install arguments'
)
