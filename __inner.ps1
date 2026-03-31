[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param([string]$Name,[string]$ClientId,[string]$BreakGlassGroupId,[switch]$SkipGraphConnect)
'INNER PSBound='+(($PSBoundParameters.Keys | Sort-Object) -join ',')
'INNER ARGS='+(($args | ForEach-Object { '['+$_+']' }) -join ',')
'ConfirmPref='+$ConfirmPreference
'WhatIfPref='+$WhatIfPreference
if ($PSCmdlet.ShouldProcess('x','do x')) { 'did' } else { 'whatif' }
