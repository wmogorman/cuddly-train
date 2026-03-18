[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$OutputPath,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path -Path $PSScriptRoot -ChildPath 'dist\PTI-Immy-Payload.zip'
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$payloadScripts = @(Get-ChildItem -Path $PSScriptRoot -Filter 'pti-*.ps1' -File | Sort-Object Name)
if ($payloadScripts.Count -eq 0) {
    throw "No PTI payload scripts were found in [$PSScriptRoot]."
}

$helperFiles = @(
    (Join-Path -Path $repoRoot -ChildPath 'dell-cleanup.ps1'),
    (Join-Path -Path $repoRoot -ChildPath 'Remove-LegacyAV.ps1')
)

foreach ($helperFile in $helperFiles) {
    if (-not (Test-Path -LiteralPath $helperFile)) {
        throw "Required helper file not found: $helperFile"
    }
}

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
Ensure-Directory -Path $outputDirectory

if ((Test-Path -LiteralPath $resolvedOutputPath) -and -not $Force) {
    throw "Output file already exists: $resolvedOutputPath. Use -Force to overwrite it."
}

$stagingRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('pti-immy-payload-' + [guid]::NewGuid().ToString('N'))
$payloadRoot = Join-Path -Path $stagingRoot -ChildPath 'payload'

try {
    Ensure-Directory -Path $payloadRoot

    foreach ($payloadScript in $payloadScripts) {
        Copy-Item -LiteralPath $payloadScript.FullName -Destination (Join-Path -Path $payloadRoot -ChildPath $payloadScript.Name) -Force
    }

    foreach ($helperFile in $helperFiles) {
        Copy-Item -LiteralPath $helperFile -Destination (Join-Path -Path $stagingRoot -ChildPath ([System.IO.Path]::GetFileName($helperFile))) -Force
    }

    if ($PSCmdlet.ShouldProcess($resolvedOutputPath, 'Create PTI Immy payload zip')) {
        if (Test-Path -LiteralPath $resolvedOutputPath) {
            Remove-Item -LiteralPath $resolvedOutputPath -Force
        }

        Compress-Archive -Path (Join-Path -Path $stagingRoot -ChildPath '*') -DestinationPath $resolvedOutputPath -Force
    }

    [pscustomobject]@{
        OutputPath     = $resolvedOutputPath
        PayloadScripts = $payloadScripts.Name
        HelperFiles    = ($helperFiles | ForEach-Object { [System.IO.Path]::GetFileName($_) })
    }
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
