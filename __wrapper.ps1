Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$core = Join-Path $scriptDir '__inner.ps1'
'WRAPPER ARGS='+(($args | ForEach-Object { '['+$_+']' }) -join ',')
& $core @args
