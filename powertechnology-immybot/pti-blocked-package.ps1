[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageName,

    [Parameter(Mandatory = $true)]
    [string[]]$MissingInputs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$details = $MissingInputs -join '; '
throw "[$PackageName] is intentionally blocked until the following inputs are supplied and validated: $details"
